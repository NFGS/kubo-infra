#!/bin/bash
# ---------------------------------------------------------------------------
# Prueba de humo end-to-end de Kubo.
#
# Verifica, contra el sistema en ejecucion: salud de los contenedores, cookie
# httpOnly del refresh token, autenticacion JWT, bloqueo por intentos fallidos,
# auditoria versionada, recuperacion de contrasena, RLS en las tres bases,
# outbox transaccional, cifrado de datos personales, inventario, proyeccion del
# evento, limites de tasa y TLS.
#
# Uso:  make smoke
# ---------------------------------------------------------------------------
set -uo pipefail

# El directorio de trabajo temporal debe existir tambien tras un reinicio.
mkdir -p /tmp/opencode

BASE="${KUBO_API:-http://localhost:9080/api/v1}"
EMAIL="${KUBO_ADMIN_EMAIL:-admin@kubo.local}"
PASSWORD="${KUBO_ADMIN_PASSWORD:-Admin123!}"

JAR1=$(mktemp)
JAR2=$(mktemp)
HDR1=$(mktemp)
HDR2=$(mktemp)
cleanup() { rm -f "${JAR1}" "${JAR2}" "${HDR1}" "${HDR2}"; }
trap cleanup EXIT

PASS=0
FAIL=0

ok() {
  printf '  \033[32mPASA\033[0m  %s\n' "$1"
  PASS=$((PASS + 1))
}

ko() {
  printf '  \033[31mFALLA\033[0m %s\n' "$1"
  FAIL=$((FAIL + 1))
}

# Codigo TOTP vigente (RFC 6238) para un secreto Base32: la prueba del segundo
# factor no puede depender de una implementacion propia que podria estar mal.
totp_code() {
  python3 - "$1" << 'PYTOTP'
import base64, hmac, hashlib, struct, sys, time
secret = sys.argv[1]
key = base64.b32decode(secret + "=" * ((8 - len(secret) % 8) % 8))
digest = hmac.new(key, struct.pack(">Q", int(time.time()) // 30), hashlib.sha1).digest()
offset = digest[-1] & 0x0F
print(f"{(struct.unpack('>I', digest[offset:offset + 4])[0] & 0x7FFFFFFF) % 10**6:06d}")
PYTOTP
}

check() {
  local description="$1" expected="$2" actual="$3"
  if [[ "${actual}" == "${expected}" ]]; then
    ok "${description}"
  else
    ko "${description} (esperado '${expected}', obtenido '${actual}')"
  fi
}

check_positivo() {
  local description="$1" actual="$2"
  if [[ "${actual}" =~ ^[0-9]+$ && "${actual}" -gt 0 ]]; then
    ok "${description}"
  else
    ko "${description} (obtenido '${actual}')"
  fi
}

ROOT_SMOKE="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_SMOKE}/docker-compose.yml"

# La malla interna exige certificado de cliente (P-28, ADR-0020): las llamadas
# directas de esta prueba presentan el del gateway, igual que la aplicacion.
CURL_TLS=(--cacert "${ROOT_SMOKE}/certs/ca.crt" --cert "${ROOT_SMOKE}/certs/gateway.crt" --key "${ROOT_SMOKE}/certs/gateway.key")

# El humo hace ~20 peticiones de autenticacion; para que la prueba sea
# idempotente (repetible en el mismo minuto) se eleva el limite de autenticacion
# solo durante la corrida y se restaura al terminar. El limite real (40/min) es
# una defensa contra fuerza bruta que se configura en el compose; el humo no lo
# debilita en operacion normal.
restaurar_limite() {
  KUBO_AUTH_RATE_LIMIT_PER_MINUTE=40 docker compose -f "${COMPOSE_FILE}" up -d kubo-gateway >/dev/null 2>&1
}
KUBO_AUTH_RATE_LIMIT_PER_MINUTE=1000000 docker compose -f "${COMPOSE_FILE}" up -d kubo-gateway >/dev/null 2>&1
trap restaurar_limite EXIT
sleep 5

echo
echo "Kubo · prueba de humo end-to-end"
echo "================================================================"

# ---------------------------------------------------------------------------
echo "[1/11] Salud de los servicios"
# ---------------------------------------------------------------------------
for service in "kubo-iam:9081" "kubo-crm:9082" "kubo-analytics:9084"; do
  name="${service%%:*}"
  port="${service##*:}"
  status=$(curl -sS --max-time 5 "${CURL_TLS[@]}" "https://localhost:${port}/api/v1/health" | jq -r '.status // "sin respuesta"')
  check "${name} responde" "UP" "${status}"
done

# El gateway es el borde: sigue en HTTP para el navegador.
check "kubo-gateway responde" "UP" \
  "$(curl -sS --max-time 5 http://localhost:9080/api/v1/health | jq -r '.status // "sin respuesta"')" 

# El ERP ya vive en la malla cifrada (P-28, ADR-0020): sin certificado de cliente
# no hay handshake, asi que la comprobacion presenta el del gateway.
# Un certificado por vencer tumba toda la malla (P-28): se avisa con 30 dias de
# anticipacion, que es cuando `make rotate-ca` resuelve sin apuro.
check "la CA de la malla es valida por 30 dias mas" "true" \
  "$(openssl x509 -checkend 2592000 -noout -in "${ROOT_SMOKE}/certs/ca.crt" >/dev/null 2>&1 && echo true || echo false)"

check "kubo-erp responde" "UP" \
  "$(curl -sS --max-time 5 "${CURL_TLS[@]}" https://localhost:9083/api/v1/health | jq -r '.status // "sin respuesta"')"
check "la malla rechaza a un cliente sin certificado" "000" \
  "$(curl -sS -o /dev/null -w '%{http_code}' --max-time 5 --cacert "${ROOT_SMOKE}/certs/ca.crt" https://localhost:9083/api/v1/health 2>/dev/null)"

# ---------------------------------------------------------------------------
echo
echo "[2/11] Autenticacion y cookie httpOnly"
# ---------------------------------------------------------------------------
# El humo hace ~17 peticiones de autenticacion. Si se ejecuta varias veces en el
# mismo minuto, la ventana de 40/min por IP puede estar saturada: se espera a que
# se libere en lugar de fallar (la prueba debe poder repetirse).
for intento in 1 2 3; do
  LOGIN=$(curl -sS -c "${JAR1}" -D "${HDR1}" -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")
  if [[ "$(echo "${LOGIN}" | jq -r '.code // empty')" == "RATE_LIMIT_EXCEEDED" ]]; then
    echo "  (limite de autenticacion alcanzado; esperando 60 s antes del intento $((intento + 1)))"
    sleep 60
  else
    break
  fi
done
TOKEN=$(echo "${LOGIN}" | jq -r '.accessToken // empty')
TENANT=$(echo "${LOGIN}" | jq -r '.user.tenantId // empty')

if [[ -n "${TOKEN}" ]]; then
  ok "login devuelve access token"
else
  ko "login no devolvio token: ${LOGIN}"
  echo "No es posible continuar sin token."
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json')

ALG=$(python3 -c "
import base64, json, sys
part = sys.argv[1].split('.')[0]
part += '=' * (-len(part) % 4)
print(json.loads(base64.urlsafe_b64decode(part)).get('alg', ''))
" "${TOKEN}")
check "el token es un JWT RS256" "RS256" "${ALG}"
check "el token trae el negocio" "true" "$([[ -n "${TENANT}" ]] && echo true || echo false)"

JWKS=$(curl -sS "${BASE}/auth/.well-known/jwks.json" | jq -r '.keys | length')
check "JWKS publica la llave de verificacion" "1" "${JWKS}"

check "el refresh token NO viaja en el cuerpo del login" "AUSENTE" \
  "$(echo "${LOGIN}" | jq -r '.refreshToken // "AUSENTE"')"

COOKIE=$(grep -i '^set-cookie: kubo_refresh=' "${HDR1}" | head -1)
check "la cookie de refresco es httpOnly y SameSite=Strict" "si" \
  "$([[ "${COOKIE}" == *"HttpOnly"* && "${COOKIE}" == *"SameSite=Strict"* ]] && echo si || echo no)"

ROTADO=$(curl -sS -b "${JAR1}" -c "${JAR2}" -X POST "${BASE}/auth/refresh")
ACCESS_2=$(echo "${ROTADO}" | jq -r '.accessToken // empty')
check "el refresco con la cookie emite un access token nuevo" "true" \
  "$([[ -n "${ACCESS_2}" && "${ACCESS_2}" != "${TOKEN}" ]] && echo true || echo false)"
check "el refresh token NO viaja en el cuerpo del refresco" "AUSENTE" \
  "$(echo "${ROTADO}" | jq -r '.refreshToken // "AUSENTE"')"

PERFIL=$(curl -sS "${BASE}/auth/me" -H "Authorization: Bearer ${ACCESS_2}" | jq -r '.email')
check "el token refrescado sirve para autenticarse" "${EMAIL}" "${PERFIL}"

REUSO=$(curl -sS -o /dev/null -w '%{http_code}' -b "${JAR1}" -X POST "${BASE}/auth/refresh")
check "reutilizar la cookie ya rotada responde 401" "401" "${REUSO}"

# El reuso es senal de robo: la familia completa debe quedar revocada.
FAMILIA=$(curl -sS -o /dev/null -w '%{http_code}' -b "${JAR2}" -X POST "${BASE}/auth/refresh")
check "el reuso invalida la familia completa de tokens" "401" "${FAMILIA}"

CIERRE=$(curl -sS -o /dev/null -w '%{http_code}' -b "${JAR2}" -c "${JAR2}" -D "${HDR2}" -X POST "${BASE}/auth/logout")
check "cerrar sesion responde 204" "204" "${CIERRE}"
check "el cierre de sesion borra la cookie" "1" \
  "$(grep -i '^set-cookie: kubo_refresh=' "${HDR2}" | grep -ci 'Max-Age=0\|Expires=Thu, 01 Jan 1970')"
check "tras cerrar sesion el refresco responde 401" "401" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -b "${JAR2}" -X POST "${BASE}/auth/refresh")"

# ---------------------------------------------------------------------------
echo
echo "[3/11] Control de acceso, auditoria y bloqueo de cuenta"
# ---------------------------------------------------------------------------
SIN_TOKEN=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/customers")
check "sin token responde 401" "401" "${SIN_TOKEN}"

FALSO=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.falso.firma" "${BASE}/customers")
check "token falsificado responde 401" "401" "${FALSO}"

SUPLANTACION=$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-User-Id: 00000000-0000-0000-0000-000000000000' "${BASE}/customers")
check "cabecera de identidad inyectada es ignorada" "401" "${SUPLANTACION}"

# Defensa en profundidad: una cabecera de negocio malformada no llega al motor.
check "una cabecera de negocio malformada se rechaza con 400" "400" \
  "$(curl -sS "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' https://localhost:9083/api/v1/products -H 'X-Tenant-Id: no-es-uuid')"

# Bloqueo de cuenta (P-11): el usuario se crea aqui y se reutiliza en el bloque 9.
SUFIJO=$(date +%s)
LOCK_EMAIL="bloqueo${SUFIJO}@kubo.local"
LOCK_PASSWORD="ClaveBloqueo1!"
REGISTRO=$(curl -sS -X POST "${BASE}/auth/register" -H 'Content-Type: application/json' \
  -d "{\"tenantName\":\"Negocio Aislado Bloqueo ${SUFIJO}\",\"fullName\":\"Usuario Bloqueo\",\"email\":\"${LOCK_EMAIL}\",\"password\":\"${LOCK_PASSWORD}\"}")
check "usuario de prueba registrado" "true" \
  "$([[ -n "$(echo "${REGISTRO}" | jq -r '.accessToken // empty')" ]] && echo true || echo false)"

for intento in 1 2 3 4 5; do
  curl -sS -o /dev/null -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${LOCK_EMAIL}\",\"password\":\"mala-${intento}\"}"
done
BLOQUEO=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${LOCK_EMAIL}\",\"password\":\"${LOCK_PASSWORD}\"}" | jq -r '.code // empty')
check "la cuenta se bloquea tras 5 intentos fallidos" "ACCOUNT_LOCKED" "${BLOQUEO}"

AUDITORIA=$(curl -sS "${BASE}/audit/verify" "${AUTH[@]}")
check "la cadena de auditoria esta intacta" "true" "$(echo "${AUDITORIA}" | jq -r '.chainIntact')"
check_positivo "se verificaron entradas de auditoria" "$(echo "${AUDITORIA}" | jq -r '.entriesChecked')"
check "la bitacora declara la version vigente del algoritmo" "true" \
  "$([[ "$(echo "${AUDITORIA}" | jq -r '.hashVersions["2"] // 0')" -ge 1 ]] && echo true || echo false)"

# --- Usuarios y roles (P-20) --------------------------------------------------
USUARIO_NUEVO="equipo$(date +%s)@kubo.local"
CREADO=$(curl -sS -X POST "${BASE}/users" "${AUTH[@]}" \
  -d "{\"fullName\":\"Vendedor de Prueba\",\"email\":\"${USUARIO_NUEVO}\",\"password\":\"Vendedor123!\",\"role\":\"SELLER\"}")
check "un administrador crea un usuario con rol" "SELLER" "$(echo "${CREADO}" | jq -r '.role // empty')"

NUEVO_TOKEN=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${USUARIO_NUEVO}\",\"password\":\"Vendedor123!\"}" | jq -r '.accessToken // empty')
check "el usuario nuevo puede ingresar" "true" \
  "$([[ -n "${NUEVO_TOKEN}" ]] && echo true || echo false)"
check "un vendedor no puede crear usuarios" "403" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/users" -H "Authorization: Bearer ${NUEVO_TOKEN}" \
     -H 'Content-Type: application/json' \
     -d "{\"fullName\":\"X\",\"email\":\"x$(date +%s)@kubo.local\",\"password\":\"Clave1234!\",\"role\":\"SELLER\"}")"

# Un administrador no puede dejar al negocio sin administrador: ni degradarse
# ni deshabilitarse a si mismo (antes quedaba bloqueado sin recuperacion).
YO_ID=$(curl -sS "${BASE}/auth/me" "${AUTH[@]}" | jq -r '.id // empty')
AUTO_DEGRADE=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "${BASE}/users/${YO_ID}" "${AUTH[@]}" -d '{"role":"SELLER"}')
check "un administrador no puede degradarse a si mismo" "409" "${AUTO_DEGRADE}"
AUTO_BAJA=$(curl -sS -o /dev/null -w '%{http_code}' -X PATCH "${BASE}/users/${YO_ID}" "${AUTH[@]}" -d '{"status":"DISABLED"}')
check "un administrador no puede deshabilitarse a si mismo" "409" "${AUTO_BAJA}"

# Segundo factor (P-30): configuracion, activacion y acceso en dos pasos con un
# codigo TOTP real. Se hace con el usuario de prueba para no tocar al admin.
NUEVO_AUTH=(-H "Authorization: Bearer ${NUEVO_TOKEN}" -H 'Content-Type: application/json')
SETUP=$(curl -sS -X POST "${BASE}/auth/totp/setup" "${NUEVO_AUTH[@]}")
SECRETO=$(echo "${SETUP}" | jq -r '.secret // empty')
check "el segundo factor entrega secreto y URI otpauth" "true" \
  "$([[ -n "${SECRETO}" && "$(echo "${SETUP}" | jq -r '.otpauthUri // empty')" == otpauth://totp/* ]] && echo true || echo false)"

check "activar el segundo factor con el codigo vigente responde 200" "200" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth/totp/enable" "${NUEVO_AUTH[@]}" \
     -d "{\"code\":\"$(totp_code "${SECRETO}")\"}")"

LOGIN_TOTP=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${USUARIO_NUEVO}\",\"password\":\"Vendedor123!\"}")
check "el acceso con segundo factor pide el codigo" "true" "$(echo "${LOGIN_TOTP}" | jq -r '.totpRequired // false')"
DESAFIO=$(echo "${LOGIN_TOTP}" | jq -r '.challengeToken // empty')
check "el codigo vigente cierra el acceso" "true" \
  "$([[ -n "$(curl -sS -X POST "${BASE}/auth/totp/verify" -H 'Content-Type: application/json' \
       -d "{\"challengeToken\":\"${DESAFIO}\",\"code\":\"$(totp_code "${SECRETO}")\"}" | jq -r '.accessToken // empty')" ]] && echo true || echo false)"
check "un codigo invalido no cierra el acceso" "INVALID_TOTP" \
  "$(curl -sS -X POST "${BASE}/auth/totp/verify" -H 'Content-Type: application/json' \
     -d "{\"challengeToken\":\"${DESAFIO}\",\"code\":\"000000\"}" | jq -r '.code // "OK"')"

# Se restaura el usuario de prueba (sin segundo factor).
curl -sS -o /dev/null -X POST "${BASE}/auth/totp/disable" "${NUEVO_AUTH[@]}" \
  -d "{\"code\":\"$(totp_code "${SECRETO}")\"}"

USUARIO_ID=$(echo "${CREADO}" | jq -r '.id')
curl -sS -o /dev/null -X PATCH "${BASE}/users/${USUARIO_ID}" "${AUTH[@]}" -d '{"status":"DISABLED"}'
check "un usuario deshabilitado no puede ingresar" "USER_DISABLED" \
  "$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
     -d "{\"email\":\"${USUARIO_NUEVO}\",\"password\":\"Vendedor123!\"}" | jq -r '.code // "OK"')"

EVENTOS=$(curl -sS "${BASE}/audit" "${AUTH[@]}")
check "el intento de acceso fallido queda en la auditoria" "true" \
  "$([[ "$(echo "${EVENTOS}" | jq '[.[] | select(.action == "LOGIN_FAILED")] | length')" -ge 1 ]] && echo true || echo false)"
check "el bloqueo de cuenta queda en la auditoria" "true" \
  "$([[ "$(echo "${EVENTOS}" | jq '[.[] | select(.action == "ACCOUNT_LOCKED")] | length')" -ge 1 ]] && echo true || echo false)"
check "el reuso de token queda en la auditoria" "true" \
  "$([[ "$(echo "${EVENTOS}" | jq '[.[] | select(.action == "REFRESH_REUSE_DETECTED")] | length')" -ge 1 ]] && echo true || echo false)"

# ---------------------------------------------------------------------------
echo
echo "[4/11] Clientes, cifrado y RLS"
# ---------------------------------------------------------------------------
DOCUMENTO="1099$(date +%H%M%S)"
CLIENTE=$(curl -sS -X POST "${BASE}/customers" "${AUTH[@]}" \
  -d "{\"name\":\"Cliente Prueba Humo\",\"document_number\":\"${DOCUMENTO}\",\"phone\":\"3001112233\",\"city\":\"Armenia\",\"stage\":\"LEAD\"}")
CLIENTE_ID=$(echo "${CLIENTE}" | jq -r '.data.id // empty')

if [[ -n "${CLIENTE_ID}" ]]; then
  ok "cliente creado"
else
  ko "no se pudo crear el cliente: ${CLIENTE}"
fi

DETALLE=$(curl -sS "${BASE}/customers/${CLIENTE_ID}" "${AUTH[@]}" | jq -r '.data.document_number')
check "el detalle muestra el documento completo" "${DOCUMENTO}" "${DETALLE}"

LISTADO=$(curl -sS -G "${BASE}/customers" --data-urlencode "q=Prueba Humo" "${AUTH[@]}" | jq -r '.data[0].document_number')
if [[ "${LISTADO}" == *"*"* ]]; then
  ok "el listado enmascara el documento (${LISTADO})"
else
  ko "el listado no enmascaro el documento: ${LISTADO}"
fi

CIFRADO=$(docker exec kubo-postgres psql -U kubo_root -d kubo_crm -tAc \
  "select document_number_encrypted from customers where id = '${CLIENTE_ID}'" 2>/dev/null)
if [[ -n "${CIFRADO}" && "${CIFRADO}" != *"${DOCUMENTO}"* ]]; then
  ok "en PostgreSQL el documento esta cifrado (${CIFRADO:0:24}…)"
else
  ko "el documento no parece cifrado en la base: ${CIFRADO}"
fi

INDICE=$(docker exec kubo-postgres psql -U kubo_root -d kubo_crm -tAc \
  "select document_number_bidx from customers where id = '${CLIENTE_ID}'" 2>/dev/null)
if [[ -n "${INDICE}" && "${INDICE}" != *"${DOCUMENTO}"* ]]; then
  ok "el indice ciego permite buscar sin descifrar"
else
  ko "el indice ciego no es correcto: ${INDICE}"
fi

BUSCADO=$(curl -sS "${BASE}/customers/by-document/${DOCUMENTO}" "${AUTH[@]}" | jq -r '.data.name // empty')
check "la busqueda por documento encuentra al cliente (indice ciego)" "Cliente Prueba Humo" "${BUSCADO}"

CRM_SIN=$(docker exec kubo-postgres psql -U kubo_crm -d kubo_crm -tAc "select count(*) from customers" 2>/dev/null | tr -d '[:space:]')
check "RLS en CRM: sin contexto de negocio no hay filas" "0" "${CRM_SIN}"
CRM_CON=$(docker exec kubo-postgres psql -U kubo_crm -d kubo_crm -tAc \
  "select set_config('app.tenant_id','${TENANT}',false); select count(*) from customers" 2>/dev/null | tail -1 | tr -d '[:space:]')
check_positivo "RLS en CRM: con el negocio en contexto hay filas" "${CRM_CON}"

# ---------------------------------------------------------------------------
echo
echo "[5/11] Inventario, venta y outbox transaccional"
# ---------------------------------------------------------------------------
SKU="SMOKE-$(date +%H%M%S)"
PRODUCTO=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
  -d "{\"sku\":\"${SKU}\",\"name\":\"Producto Prueba Humo\",\"price\":11900,\"cost\":7000,\"min_stock\":2}")
PRODUCTO_ID=$(echo "${PRODUCTO}" | jq -r '.data.id // empty')

if [[ -n "${PRODUCTO_ID}" ]]; then
  ok "producto creado"
else
  ko "no se pudo crear el producto: ${PRODUCTO}"
  echo "No es posible continuar sin producto."
  exit 1
fi

curl -sS -X POST "${BASE}/products/${PRODUCTO_ID}/stock" "${AUTH[@]}" \
  -d '{"kind":"IN","quantity":10,"reason":"Prueba de humo"}' > /dev/null
STOCK_INICIAL=$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')
check "entrada de inventario deja 10 unidades" "10" "${STOCK_INICIAL}"

# Multi-bodega (P-22, ADR-0016): segunda bodega, transferencia atomica y kardex
# por bodega. La mercancia no sale del negocio: el total del producto no cambia.
BODEGAS=$(curl -sS "${BASE}/warehouses" "${AUTH[@]}")
DEFECTO_ID=$(echo "${BODEGAS}" | jq -r '.data[] | select(.is_default) | .id' | head -1)
BODEGA_ID=$(echo "${BODEGAS}" | jq -r '.data[] | select(.is_default == false) | .id' | head -1)
if [[ -z "${BODEGA_ID}" ]]; then
  BODEGA=$(curl -sS -X POST "${BASE}/warehouses" "${AUTH[@]}" -d '{"name":"Bodega norte"}')
  BODEGA_ID=$(echo "${BODEGA}" | jq -r '.data.id // empty')
fi
check "el negocio tiene su bodega por defecto y una segunda" "true" \
  "$([[ -n "${DEFECTO_ID}" && -n "${BODEGA_ID}" ]] && echo true || echo false)"

TRANSFERENCIA=$(curl -sS -X POST "${BASE}/transfers" "${AUTH[@]}" \
  -d "{\"from_warehouse_id\":\"${DEFECTO_ID}\",\"to_warehouse_id\":\"${BODEGA_ID}\",\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":2}]}")
check "la transferencia mueve el producto entre bodegas" "2" \
  "$(echo "${TRANSFERENCIA}" | jq -r '.data.items[0].quantity // empty')"
check "el total del producto no cambia con la transferencia" "10" \
  "$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')"
check "el kardex registra los dos movimientos de la transferencia" "2" \
  "$(curl -sS "${BASE}/stock/movements?product_id=${PRODUCTO_ID}" "${AUTH[@]}" \
     | jq '[.data[] | select(.reference_type == "TRANSFER")] | length')"
check "transferir mas de lo disponible se rechaza" "409" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/transfers" "${AUTH[@]}" \
     -d "{\"from_warehouse_id\":\"${DEFECTO_ID}\",\"to_warehouse_id\":\"${BODEGA_ID}\",\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":999}]}")"
check "la bodega por defecto no se puede borrar" "409" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE "${BASE}/warehouses/${DEFECTO_ID}" "${AUTH[@]}")"

# El plan tambien limita las bodegas (ADR-0021): la demo es community (2).
LIMITE_BODEGAS=$(curl -sS -X POST "${BASE}/warehouses" "${AUTH[@]}" -d '{"name":"Bodega extra"}')
check "el plan limita las bodegas" "PLAN_LIMIT_REACHED" \
  "$(echo "${LIMITE_BODEGAS}" | jq -r '.code // "OK"')"

# La venta puede despachar desde una bodega elegida (P-22). Se usa un producto
# propio para no descuadrar el inventario del producto de las demas pruebas.
SKU_BODEGA="BOD-$(date +%s)"
PROD_BODEGA=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
  -d "{\"sku\":\"${SKU_BODEGA}\",\"name\":\"Producto de bodega\",\"price\":8000,\"cost\":5000}" \
  | jq -r '.data.id // empty')
curl -sS -o /dev/null -X POST "${BASE}/products/${PROD_BODEGA}/stock" "${AUTH[@]}" \
  -d '{"kind":"IN","quantity":5,"reason":"Prueba de bodega"}'
curl -sS -o /dev/null -X POST "${BASE}/transfers" "${AUTH[@]}" \
  -d "{\"from_warehouse_id\":\"${DEFECTO_ID}\",\"to_warehouse_id\":\"${BODEGA_ID}\",\"items\":[{\"product_id\":\"${PROD_BODEGA}\",\"quantity\":3}]}"
VENTA_BODEGA=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PROD_BODEGA}\",\"quantity\":1}],\"payment_method\":\"CARD\",\"warehouse_id\":\"${BODEGA_ID}\"}")
check "la venta despacha desde la bodega elegida" "true" \
  "$([[ -n "$(echo "${VENTA_BODEGA}" | jq -r '.data.id // empty')" ]] && echo true || echo false)"
check "una bodega inexistente se rechaza" "404" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/sales" "${AUTH[@]}" \
     -d "{\"items\":[{\"product_id\":\"${PROD_BODEGA}\",\"quantity\":1}],\"payment_method\":\"CARD\",\"warehouse_id\":\"00000000-0000-0000-0000-000000000000\"}")"
check "el inventario del producto de bodega cuadra" "4" \
  "$(curl -sS "${BASE}/products/${PROD_BODEGA}" "${AUTH[@]}" | jq -r '.data.stock')"

# Aviso de stock bajo (P-19): se dispara al cruzar el minimo, una sola vez.
SKU_ALERTA="ALR-$(date +%s)"
ALERTA_PROD=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
  -d "{\"sku\":\"${SKU_ALERTA}\",\"name\":\"Producto con alerta\",\"price\":5000,\"cost\":3000,\"min_stock\":5}" \
  | jq -r '.data.id // empty')
curl -sS -o /dev/null -X POST "${BASE}/products/${ALERTA_PROD}/stock" "${AUTH[@]}" \
  -d '{"kind":"IN","quantity":6,"reason":"Prueba de alerta"}'
curl -sS -o /dev/null -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${ALERTA_PROD}\",\"quantity\":2}],\"payment_method\":\"CARD\"}"
AVISOS=$(curl -sS "${BASE}/notifications" "${AUTH[@]}")
check "la venta que cruza el minimo deja un aviso" "1" \
  "$(echo "${AVISOS}" | jq --arg id "${ALERTA_PROD}" '[.data[] | select(.kind == "LOW_STOCK" and .reference_id == $id)] | length')"
check "el aviso dice cuantas unidades quedan" "true" \
  "$([[ "$(echo "${AVISOS}" | jq -r --arg id "${ALERTA_PROD}" '[.data[] | select(.reference_id == $id)][0].body')" == *"4 unidades"* ]] && echo true || echo false)"

# El aviso nace encolado y el entregador lo envia en segundo plano (P-19).
ESTADO_AVISO=""
for _ in $(seq 1 12); do
  ESTADO_AVISO=$(curl -sS "${BASE}/notifications" "${AUTH[@]}" \
    | jq -r --arg id "${ALERTA_PROD}" '[.data[] | select(.reference_id == $id)][0].status // empty')
  [[ "${ESTADO_AVISO}" == "SENT" ]] && break
  sleep 1
done
check "el aviso se entrega en segundo plano" "SENT" "${ESTADO_AVISO}"

VENTA=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":3}],\"payment_method\":\"CASH\"}")
VENTA_ID=$(echo "${VENTA}" | jq -r '.data.id // empty')
VENTA_TOTAL=$(echo "${VENTA}" | jq -r '.data.total // empty')

if [[ -n "${VENTA_ID}" ]]; then
  ok "venta registrada por ${VENTA_TOTAL}"
else
  ko "no se pudo registrar la venta: ${VENTA}"
fi

check "el total con IVA incluido es 35700.00" "35700.00" "${VENTA_TOTAL}"
check "el IVA desagregado es 5700.00" "5700.00" "$(echo "${VENTA}" | jq -r '.data.tax')"

STOCK_FINAL=$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')
check "el stock baja a 7 unidades" "7" "${STOCK_FINAL}"

# El kardex del producto ya trae la entrada inicial, la salida de la venta y los
# movimientos de la transferencia: se comprueba cada uno por su referencia.
KARDEX=$(curl -sS "${BASE}/stock/movements?product_id=${PRODUCTO_ID}" "${AUTH[@]}")
check "el kardex registra la salida de la venta" "1" \
  "$(echo "${KARDEX}" | jq '[.data[] | select(.reference_type == "SALE")] | length')"
check_positivo "el kardex conserva la entrada inicial" \
  "$(echo "${KARDEX}" | jq '[.data[] | select(.kind == "IN")] | length')"

# Importacion de catalogo (P-24): una fila nueva entra con su stock por kardex.
CSV_IMPORT="sku,nombre,precio,costo,stock,stock_minimo
IMP-SMOKE-$(date +%s),Producto Importado,5000,3000,7,2"
IMPORTADO=$(curl -sS -X POST "${BASE}/products/import" "${AUTH[@]}" \
  -d "$(jq -nc --arg csv "${CSV_IMPORT}" '{csv: $csv}')")
check "la importacion crea productos desde CSV" "1" "$(echo "${IMPORTADO}" | jq -r '.data.created // empty')"
check "el producto importado entra con su stock por kardex" "7" \
  "$(curl -sS -G "${BASE}/products" --data-urlencode "q=Producto Importado" "${AUTH[@]}" | jq -r '.data[0].stock // empty')"

PAGINA=$(curl -sS "${BASE}/products?limit=1" "${AUTH[@]}" | jq -c 'select((.data | length) == 1 and .total >= 2)')
check "la paginacion respeta el limite y reporta el total real" "true" \
  "$([[ -n "${PAGINA}" ]] && echo true || echo false)"
check "el servidor acota el tamano de pagina" "200" \
  "$(curl -sS "${BASE}/products?limit=9999" "${AUTH[@]}" | jq -r '.limit')"

SOBREVENTA=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":99}],\"payment_method\":\"CASH\"}")
check "vender sin existencias responde 409" "409" "${SOBREVENTA}"

# Outbox (P-01): la venta y su evento se confirman juntos.
OUTBOX_FILA=$(docker exec kubo-postgres psql -U kubo_root -d kubo_erp -tAc \
  "select count(*) from outbox_events where payload->'data'->>'sale_id' = '${VENTA_ID}'" 2>/dev/null | tr -d '[:space:]')
check "el evento de la venta quedo en la bandeja de salida" "1" "${OUTBOX_FILA}"

PUBLICADO="no"
for _ in $(seq 1 15); do
  ESTADO=$(docker exec kubo-postgres psql -U kubo_root -d kubo_erp -tAc \
    "select status from outbox_events where payload->'data'->>'sale_id' = '${VENTA_ID}'" 2>/dev/null | tr -d '[:space:]')
  if [[ "${ESTADO}" == "PUBLISHED" ]]; then
    PUBLICADO="si"
    break
  fi
  sleep 1
done
check "el evento se publico en el bus" "si" "${PUBLICADO}"

ERP_SIN=$(docker exec kubo-postgres psql -U kubo_erp -d kubo_erp -tAc "select count(*) from products" 2>/dev/null | tr -d '[:space:]')
check "RLS en ERP: sin contexto de negocio no hay filas" "0" "${ERP_SIN}"
ERP_CON=$(docker exec kubo-postgres psql -U kubo_erp -d kubo_erp -tAc \
  "select set_config('app.tenant_id','${TENANT}',false); select count(*) from products" 2>/dev/null | tail -1 | tr -d '[:space:]')
check_positivo "RLS en ERP: con el negocio en contexto hay filas" "${ERP_CON}"

# ---------------------------------------------------------------------------
echo
echo "[6/11] Evento de venta y tablero (RabbitMQ + MongoDB)"
# ---------------------------------------------------------------------------
PROYECTADA="no"
for _ in $(seq 1 15); do
  TOTAL=$(curl -sS "${BASE}/dashboard/recent-sales?limit=50" "${AUTH[@]}" | jq --arg id "${VENTA_ID}" '[.data[] | select(.sale_id == $id)] | length')
  if [[ "${TOTAL}" == "1" ]]; then
    PROYECTADA="si"
    break
  fi
  sleep 1
done
check "la venta llego al modelo de lectura de analitica" "si" "${PROYECTADA}"

EN_MONGO=$(docker exec kubo-mongo mongosh kubo_analytics --quiet --eval \
  "db.events.countDocuments({event_type: 'sale.created'})" 2>/dev/null | tr -d '\r')
check_positivo "MongoDB guardo eventos sale.created" "${EN_MONGO}"

TABLERO=$(curl -sS "${BASE}/dashboard/summary" "${AUTH[@]}" | jq -r '.data.sales_count')
check_positivo "el tablero reporta ventas" "${TABLERO}"

COMPUESTA=$(curl -sS "${BASE}/dashboard/overview" "${AUTH[@]}")
VISTAS=$(echo "${COMPUESTA}" | jq -r '.data | keys | length')
check "la vista compuesta del tablero trae las 7 vistas en una peticion" "7" "${VISTAS}"
check "la vista compuesta no reporta vistas caidas" "0" "$(echo "${COMPUESTA}" | jq -r '.unavailable // [] | length')"
check "la zona horaria del negocio viaja en la respuesta" "America/Bogota" \
  "$(curl -sS "${BASE}/sales/stats" "${AUTH[@]}" | jq -r '.data.timezone // "sin zona"')"

# Paquetes de configuracion por vertical (P-17, ADR-0013): catalogo, paquete
# activo y cambio de vertical, que aplica al siguiente inicio de sesion porque
# el vertical viaja en el token.
check "el catalogo ofrece los cuatro verticales" "4" \
  "$(curl -sS "${BASE}/packs" "${AUTH[@]}" | jq -r '.data | length')"
check "el negocio de la demo esta en retail" "retail" \
  "$(curl -sS "${BASE}/packs/current" "${AUTH[@]}" | jq -r '.data.key // empty')"
check "el paquete define la terminologia del catalogo" "Producto" \
  "$(curl -sS "${BASE}/packs/current" "${AUTH[@]}" | jq -r '.data.product_label // empty')"
check "un vertical desconocido se rechaza" "INVALID_VERTICAL" \
  "$(curl -sS -X PATCH "${BASE}/tenants/me" "${AUTH[@]}" -d '{"vertical":"inventado"}' | jq -r '.code // "OK"')"

curl -sS -o /dev/null -X PATCH "${BASE}/tenants/me" "${AUTH[@]}" -d '{"vertical":"restaurantes"}'
TOKEN_REST=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"admin@kubo.local","password":"Admin123!"}' | jq -r '.accessToken // empty')
check "el cambio de vertical aplica al nuevo token" "Platillo" \
  "$(curl -sS "${BASE}/packs/current" -H "Authorization: Bearer ${TOKEN_REST}" \
     | jq -r '.data.product_label // empty')"
# Se restaura el vertical de la demostracion.
curl -sS -o /dev/null -X PATCH "${BASE}/tenants/me" "${AUTH[@]}" -d '{"vertical":"retail"}'

# El paquete tambien cambia el comportamiento (P-17): un servicio no lleva
# inventario, se vende sin existencias y no deja kardex; la venta guarda la mesa.
SKU_SERVICIO="SRV-$(date +%s)"
SERVICIO=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
  -d "{\"sku\":\"${SKU_SERVICIO}\",\"name\":\"Servicio de prueba\",\"price\":25000,\"cost\":0,\"tracks_stock\":false}" \
  | jq -r '.data.id // empty')
VENTA_SERVICIO=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${SERVICIO}\",\"quantity\":3}],\"payment_method\":\"CARD\",\"table_number\":\"Mesa 4\"}")
check "un servicio se vende sin existencias" "3" \
  "$(echo "${VENTA_SERVICIO}" | jq -r '.data.items[0].quantity // empty')"
check "la venta guarda la mesa del vertical" "Mesa 4" \
  "$(echo "${VENTA_SERVICIO}" | jq -r '.data.table_number // empty')"
check "el servicio no deja movimientos de kardex" "0" \
  "$(curl -sS "${BASE}/stock/movements?product_id=${SERVICIO}" "${AUTH[@]}" | jq -r '.data | length')"

# El paquete siembra el catalogo de arranque (P-17) y es idempotente: aplicarlo
# dos veces no duplica productos.
SIEMBRA=$(curl -sS -X POST "${BASE}/packs/apply" "${AUTH[@]}")
check "el paquete aplica su catalogo de arranque" "3" \
  "$(echo "${SIEMBRA}" | jq -r '.data.created + .data.skipped // empty')"
SIEMBRA2=$(curl -sS -X POST "${BASE}/packs/apply" "${AUTH[@]}")
check "sembrar dos veces no duplica" "0" "$(echo "${SIEMBRA2}" | jq -r '.data.created // empty')"
check "los productos ya sembrados se omiten" "3" "$(echo "${SIEMBRA2}" | jq -r '.data.skipped // empty')"

# ADR-0012: el ERP respeta la zona horaria del negocio que propaga el gateway y
# rechaza una zona desconocida en lugar de caer a UTC en silencio.
TZ_DIRECTA=$(curl -sS "${CURL_TLS[@]}" https://localhost:9083/api/v1/sales/stats \
  -H "x-tenant-id: ${TENANT}" -H "x-user-id: ${TENANT}" -H "x-tenant-timezone: America/Mexico_City" \
  | jq -r '.data.timezone // "sin zona"')
check "el erp respeta la zona horaria del negocio" "America/Mexico_City" "${TZ_DIRECTA}"
check "una zona horaria desconocida se rechaza" "400" \
  "$(curl -sS "${CURL_TLS[@]}" -o /dev/null -w '%{http_code}' https://localhost:9083/api/v1/sales/stats \
     -H "x-tenant-id: ${TENANT}" -H "x-user-id: ${TENANT}" -H 'x-tenant-timezone: Marte/Olympus')"

# Reportes exportables (P-21): CSV de ventas e inventario; el filtro de fechas
# se interpreta en la zona horaria del negocio.
VENTA_NUMERO=$(echo "${VENTA}" | jq -r '.data.number // empty')
REPORTE_VENTAS=$(curl -sS "${BASE}/reports/sales.csv" "${AUTH[@]}")
check_positivo "el reporte de ventas incluye la venta recien creada" \
  "$(echo "${REPORTE_VENTAS}" | grep -c "${VENTA_NUMERO}")"
check_positivo "el reporte de inventario incluye el producto" \
  "$(curl -sS "${BASE}/reports/inventory.csv" "${AUTH[@]}" | grep -c "${SKU}")"
HOY_NEGOCIO=$(TZ=America/Bogota date +%F)
check_positivo "el filtro de fechas usa la zona del negocio" \
  "$(curl -sS "${BASE}/reports/sales.csv?from=${HOY_NEGOCIO}&to=${HOY_NEGOCIO}" "${AUTH[@]}" | grep -c "${VENTA_NUMERO}")"
check "una fecha invalida responde 400" "400" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/reports/sales.csv?from=no-es-fecha" "${AUTH[@]}")"

# Datos fiscales del emisor (DIAN): el negocio los registra una vez; viajan en
# el token y el adaptador los usa sin consultar a IAM. El DV del NIT lo calcula
# el servidor.
FISCAL=$(curl -sS -X PATCH "${BASE}/tenants/me" "${AUTH[@]}" \
  -d '{"tax_id":"900123456","fiscal_address":"Calle 1 # 2-3","tax_regime":"RESPONSABLE_IVA","invoice_resolution":"Resolucion 18764","invoice_prefix":"FE"}')
check "el negocio registra sus datos fiscales con el DV calculado" "8" \
  "$(echo "${FISCAL}" | jq -r '.data.taxIdDv // empty')"

check "el adaptador de facturacion configurado es el sandbox" "sandbox" \
  "$(curl -sS "${CURL_TLS[@]}" https://localhost:9083/api/v1/health 2>/dev/null | jq -r '.billing.adapter // empty')"

# El token nuevo lleva los datos fiscales; el gateway los propaga al ERP.
TOKEN_FISCAL=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" | jq -r '.accessToken // empty')
AUTH_FISCAL=(-H "Authorization: Bearer ${TOKEN_FISCAL}" -H 'Content-Type: application/json')

# Factura electronica (P-18): puerto de facturacion con adaptador sandbox. Se
# emite una sola vez (el CUFE es inmutable) y el XML sigue UBL 2.1.
FACTURA=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/invoice" "${AUTH_FISCAL[@]}")
CUFE=$(echo "${FACTURA}" | jq -r '.data.cufe // empty')
check "la venta se factura con CUFE valido" "true" \
  "$([[ "${CUFE}" =~ ^[0-9a-f]{96}$ ]] && echo true || echo false)"
check "la factura trae el NIT del negocio con su DV" "true" \
  "$([[ "$(echo "${FACTURA}" | jq -r '.data.xml')" == *'schemeID="8">900123456'* ]] && echo true || echo false)"
check "la factura usa el prefijo del negocio" "true" \
  "$([[ "$(echo "${FACTURA}" | jq -r '.data.xml')" == *"<cbc:ID>FE-"* ]] && echo true || echo false)"
check "la factura reporta su estado del proveedor" "ISSUED" \
  "$(echo "${FACTURA}" | jq -r '.data.status // empty')"
FACTURA2=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/invoice" "${AUTH_FISCAL[@]}")
check "facturar dos veces devuelve la misma factura" "true" \
  "$([[ "${CUFE}" == "$(echo "${FACTURA2}" | jq -r '.data.cufe')" ]] && echo true || echo false)"
check "la factura es un documento UBL 2.1" "true" \
  "$([[ "$(echo "${FACTURA}" | jq -r '.data.xml')" == *"UBL 2.1"* ]] && echo true || echo false)"
check "el XML trae el nombre del negocio que propaga el gateway" "true" \
  "$([[ "$(echo "${FACTURA}" | jq -r '.data.xml')" == *"Tienda La Esquina"* ]] && echo true || echo false)"

# Documentos (P-25, ADR-0018): la factura deja su XML como documento
# descargable y el hash verifica que el contenido no cambio.
DOCS=$(curl -sS "${BASE}/documents" "${AUTH[@]}")
# Se filtra por tipo: el comprobante de la venta puede ser mas reciente y con
# la misma marca de tiempo, y el orden dejaria de ser determinista.
DOC_ID=$(echo "${DOCS}" | jq -r '[.data[] | select(.kind == "INVOICE_XML")][0].id // empty')
DOC_HASH=$(echo "${DOCS}" | jq -r '[.data[] | select(.kind == "INVOICE_XML")][0].sha256 // empty')
check_positivo "la factura deja su documento XML" \
  "$(echo "${DOCS}" | jq '[.data[] | select(.kind == "INVOICE_XML")] | length')"
curl -sS -o /tmp/opencode/documento.xml "${BASE}/documents/${DOC_ID}" "${AUTH[@]}"
check "el documento descargado coincide con su hash" "${DOC_HASH}" \
  "$(sha256sum /tmp/opencode/documento.xml | cut -d' ' -f1)"
check "el documento es el XML de la factura" "true" \
  "$(grep -q "UBL 2.1" /tmp/opencode/documento.xml && echo true || echo false)"

# El comprobante de la venta queda como PDF descargable (P-25): antes se
# imprimia desde el navegador y no se conservaba.
DOCS_COMPROBANTE=$(curl -sS "${BASE}/documents" "${AUTH[@]}")
COMPROBANTE_ID=$(echo "${DOCS_COMPROBANTE}" \
  | jq -r --arg venta "${VENTA_ID}" \
      '[.data[] | select(.kind == "RECEIPT_PDF" and .reference_id == $venta)][0].id // empty')
check_positivo "la venta deja su comprobante en PDF" \
  "$([[ -n "${COMPROBANTE_ID}" ]] && echo 1 || echo 0)"
curl -sS -o /tmp/opencode/comprobante.pdf "${BASE}/documents/${COMPROBANTE_ID}" "${AUTH[@]}"
check "el comprobante es un PDF valido" "true" \
  "$([[ "$(head -c 8 /tmp/opencode/comprobante.pdf)" == "%PDF-1.4" ]] && echo true || echo false)"
check "el comprobante trae el numero de la venta" "true" \
  "$(grep -q "${VENTA_NUMERO}" /tmp/opencode/comprobante.pdf && echo true || echo false)"

# El cliente se denormaliza en la venta: si viene cliente, el nombre es
# obligatorio (fail-fast) y el CSV no debe ejecutar formulas al abrirlo.
SKU_FORMULA="FORMULA-$(date +%s)"
PRODUCTO_FORMULA=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
  -d "{\"sku\":\"${SKU_FORMULA}\",\"name\":\"Producto Formula\",\"price\":5000,\"cost\":3000,\"min_stock\":1}" \
  | jq -r '.data.id // empty')
curl -sS -o /dev/null -X POST "${BASE}/products/${PRODUCTO_FORMULA}/stock" "${AUTH[@]}" \
  -d '{"kind":"IN","quantity":5,"reason":"Prueba de reportes"}'
CLIENTE_FORMULA=$(curl -sS -X POST "${BASE}/customers" "${AUTH[@]}" \
  -d "{\"name\":\"=SUM(1+1)\",\"doc_type\":\"CC\",\"doc_number\":\"FORMULA$(date +%s)\"}" \
  | jq -r '.data.id // empty')
VENTA_FORMULA=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_FORMULA}\",\"quantity\":1}],\"payment_method\":\"CARD\",\"customer_id\":\"${CLIENTE_FORMULA}\",\"customer_name\":\"=SUM(1+1)\"}")
check "la venta conserva el nombre del cliente" "=SUM(1+1)" \
  "$(echo "${VENTA_FORMULA}" | jq -r '.data.customer_name // empty')"
check_positivo "el CSV neutraliza formulas del cliente" \
  "$(curl -sS "${BASE}/reports/sales.csv" "${AUTH[@]}" | grep -c "'=SUM(1+1)")"
SIN_NOMBRE=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_FORMULA}\",\"quantity\":1}],\"payment_method\":\"CARD\",\"customer_id\":\"${CLIENTE_FORMULA}\"}")
check "vender con cliente sin nombre se rechaza" "CUSTOMER_NAME_REQUIRED" \
  "$(echo "${SIN_NOMBRE}" | jq -r '.code // "OK"')"

OUTBOX_FALLIDOS=$(curl -sS "${CURL_TLS[@]}" https://localhost:9083/api/v1/health | jq -r '.outbox.failed // "?"')
check "la bandeja de salida no tiene eventos fallidos" "0" "${OUTBOX_FALLIDOS}"

# ---------------------------------------------------------------------------
echo
echo "[7/11] Anulacion de venta (devolucion de inventario)"
# ---------------------------------------------------------------------------
ANULADA=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/void" "${AUTH[@]}" | jq -r '.data.status')
check "la venta queda anulada" "VOIDED" "${ANULADA}"

STOCK_DEVUELTO=$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')
check "el inventario vuelve a 10 unidades" "10" "${STOCK_DEVUELTO}"

# Una venta anulada SIN factura no se factura: el camino es una nota credito.
VENTA_ANULADA=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":1}],\"payment_method\":\"CASH\"}" \
  | jq -r '.data.id // empty')
curl -sS -o /dev/null -X POST "${BASE}/sales/${VENTA_ANULADA}/void" "${AUTH[@]}"
check "una venta anulada no se factura" "409" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/sales/${VENTA_ANULADA}/invoice" "${AUTH[@]}")"

# Nota credito (P-18, ADR-0014): anular una venta facturada emite el documento
# que corrige la factura; la factura no se edita ni se borra. La emision es
# idempotente, como la factura.
NOTA=$(curl -sS "${BASE}/sales/${VENTA_ID}/credit-note" "${AUTH[@]}")
NOTA_NUM=$(echo "${NOTA}" | jq -r '.data.number // empty')
CUDE=$(echo "${NOTA}" | jq -r '.data.cude // empty')
check "la anulacion emitio la nota credito" "true" \
  "$([[ "${NOTA_NUM}" == NC-* ]] && echo true || echo false)"
check "la nota credito trae CUDE valido" "true" \
  "$([[ "${CUDE}" =~ ^[0-9a-f]{96}$ ]] && echo true || echo false)"
check "la nota credito referencia la factura que corrige" "true" \
  "$([[ "$(echo "${NOTA}" | jq -r '.data.xml')" == *"${CUFE}"* ]] && echo true || echo false)"
check "el XML de la nota es UBL CreditNote tipo 91" "true" \
  "$([[ "$(echo "${NOTA}" | jq -r '.data.xml')" == *"<cbc:CreditNoteTypeCode>91</cbc:CreditNoteTypeCode>"* ]] && echo true || echo false)"
NOTA2=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/credit-note" "${AUTH[@]}")
check "reemitir devuelve la misma nota (idempotente)" "${NOTA_NUM}" \
  "$(echo "${NOTA2}" | jq -r '.data.number // empty')"
check_positivo "la nota credito deja su documento XML" \
  "$(curl -sS "${BASE}/documents" "${AUTH[@]}" | jq '[.data[] | select(.kind == "CREDIT_NOTE_XML")] | length')"
check "sin factura no hay nota que emitir" "INVOICE_NOT_FOUND" \
  "$(curl -sS -X POST "${BASE}/sales/${VENTA_ANULADA}/credit-note" "${AUTH[@]}" | jq -r '.code // "OK"')"

# ---------------------------------------------------------------------------
echo
echo "[8/11] Aislamiento entre negocios"
# ---------------------------------------------------------------------------
OTRO_EMAIL="otro$(date +%H%M%S)@kubo.local"
OTRO=$(curl -sS -X POST "${BASE}/auth/register" -H 'Content-Type: application/json' \
  -d "{\"tenantName\":\"Negocio Aislado $(date +%H%M%S)\",\"fullName\":\"Otro Dueno\",\"email\":\"${OTRO_EMAIL}\",\"password\":\"OtraClave123!\"}")
OTRO_TOKEN=$(echo "${OTRO}" | jq -r '.accessToken // empty')

if [[ -n "${OTRO_TOKEN}" ]]; then
  ok "segundo negocio registrado"
  VISIBLES=$(curl -sS "${BASE}/customers" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq '.total')
  check "el segundo negocio no ve los clientes del primero" "0" "${VISIBLES}"

  PRODUCTOS_AJENOS=$(curl -sS "${BASE}/products" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq '.total')
  check "el segundo negocio no ve el catalogo del primero" "0" "${PRODUCTOS_AJENOS}"
else
  ko "no fue posible registrar el segundo negocio: ${OTRO}"
fi

IAM_SIN=$(docker exec kubo-postgres psql -U kubo_iam -d kubo_iam -tAc "select count(*) from users" 2>/dev/null | tr -d '[:space:]')
check "RLS en IAM: sin contexto de negocio no hay filas" "0" "${IAM_SIN}"

# Superficie del operador (ADR-0024): suspender un negocio es reversible y no
# toca sus datos; el ingreso lo delata. Se usa el negocio aislado para no
# afectar la demo.
"${ROOT_SMOKE}/scripts/tenant-admin.sh" suspend "${OTRO_EMAIL}" >/dev/null
check "un negocio suspendido no ingresa" "TENANT_SUSPENDED" \
  "$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
     -d "{\"email\":\"${OTRO_EMAIL}\",\"password\":\"OtraClave123!\"}" | jq -r '.code // "OK"')"
"${ROOT_SMOKE}/scripts/tenant-admin.sh" activate "${OTRO_EMAIL}" >/dev/null
check "al reactivar el negocio vuelve a entrar" "true" \
  "$([[ -n "$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
       -d "{\"email\":\"${OTRO_EMAIL}\",\"password\":\"OtraClave123!\"}" | jq -r '.accessToken // empty')" ]] && echo true || echo false)"

# Cobro manual (F6.2): el operador registra el pago renovando la fecha.
"${ROOT_SMOKE}/scripts/tenant-admin.sh" renew "${OTRO_EMAIL}" 30 >/dev/null
RENOVADA_ESPERADA="$(TZ=America/Bogota date -d "+30 days" +%F)"
check "la renovacion del plan queda registrada" "${RENOVADA_ESPERADA}" \
  "$(curl -sS "${BASE}/tenants/me" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq -r '.data.planRenewsAt // empty')"

# El intento invalido de esta prueba alimenta el contador del operador (P-11):
# se limpia antes para que el humo sea repetible sin bloquear al operador real.
"${ROOT_SMOKE}/scripts/tenant-admin.sh" platform-reset >/dev/null

# Reino de plataforma (F6.4, ADR-0025): el acceso del operador SIEMPRE pide el
# codigo (segundo factor obligatorio) y un token de negocio no entra al panel.
PLATAFORMA_LOGIN=$(curl -sS -X POST "${BASE}/platform/auth/login" -H 'Content-Type: application/json' \
  -d '{"email":"operador@kubo.local","password":"Operador123!"}')
check "el acceso de plataforma exige el codigo" "true" "$(echo "${PLATAFORMA_LOGIN}" | jq -r '.totpRequired // false')"
check "un codigo invalido no abre la sesion de plataforma" "INVALID_TOTP" \
  "$(curl -sS -X POST "${BASE}/platform/auth/totp" -H 'Content-Type: application/json' \
     -d "{\"challengeToken\":\"$(echo "${PLATAFORMA_LOGIN}" | jq -r '.challengeToken')\",\"code\":\"000000\"}" | jq -r '.code // "OK"')"
check "un token de negocio no entra al panel de plataforma" "403" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/platform/tenants" "${AUTH[@]}")"
check "un token de negocio no lee el uso de los negocios" "403" \
  "$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/platform/usage" "${AUTH[@]}")"

# Uso del plan (F6.1): el negocio ve lo que consume y el operador lo consulta.
USO=$(curl -sS "${BASE}/usage" "${AUTH[@]}")
check_positivo "el uso reporta las bodegas" "$(echo "${USO}" | jq '.data.warehouses')"
check_positivo "el uso reporta las ventas del mes" "$(echo "${USO}" | jq '.data.sales_month.count')"
check_positivo "el uso reporta los documentos" "$(echo "${USO}" | jq '.data.documents.count')"
check_positivo "el perfil reporta los usuarios activos" \
  "$(curl -sS "${BASE}/tenants/me" "${AUTH[@]}" | jq '.data.activeUsers')" 

# Plan comercial (ADR-0021): el cupo del plan se aplica por negocio y el sexto
# usuario activo del plan community se rechaza. Se hace con el negocio aislado
# para no tocar la demo.
PLANES=$(curl -sS "${BASE}/tenants/plans" "${AUTH[@]}")
check_positivo "el catalogo de planes esta disponible" "$(echo "${PLANES}" | jq 'length')"
for i in 1 2 3 4; do
  curl -sS -o /dev/null -X POST "${BASE}/users" -H "Authorization: Bearer ${OTRO_TOKEN}" \
    -H 'Content-Type: application/json' \
    -d "{\"fullName\":\"Vendedor ${i}\",\"email\":\"cupo${i}-$(date +%s)@kubo.local\",\"password\":\"Vendedor123!\",\"role\":\"SELLER\"}"
done
check "el plan limita los usuarios activos" "PLAN_LIMIT_REACHED" \
  "$(curl -sS -X POST "${BASE}/users" -H "Authorization: Bearer ${OTRO_TOKEN}" \
     -H 'Content-Type: application/json' \
     -d "{\"fullName\":\"Uno mas\",\"email\":\"cupo6-$(date +%s)@kubo.local\",\"password\":\"Vendedor123!\",\"role\":\"SELLER\"}" \
     | jq -r '.code // "OK"')"

# Puerto de cobro (F6.6, ADR-0026): el negocio pide pagar, el proveedor confirma
# por webhook firmado, y un webhook repetido NO extiende dos veces el plan.
# Se usa el negocio aislado para no tocar la demo.
PAGO=$(curl -sS -X POST "${BASE}/tenants/me/payments" -H "Authorization: Bearer ${OTRO_TOKEN}" \
  -H 'Content-Type: application/json' -d '{"plan":"pro","cycle_months":1}')
PAGO_REF=$(echo "${PAGO}" | jq -r '.reference // empty')
check "la intencion de pago toma el precio del catalogo" "49000.00" "$(echo "${PAGO}" | jq -r '.amount // empty')"
check "la intencion queda pendiente de confirmar" "PENDING" "$(echo "${PAGO}" | jq -r '.status // empty')"

RENOV_ANTES=$(curl -sS "${BASE}/tenants/me" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq -r '.data.planRenewsAt // ""')

SECRETO_WH=$(docker exec kubo-iam printenv KUBO_PAYMENTS_WEBHOOK_SECRET 2>/dev/null | tr -d '[:space:]')
CUERPO_WH="{\"reference\":\"${PAGO_REF}\",\"amount\":49000,\"status\":\"APPROVED\"}"
FIRMA_WH=$(printf '%s' "${CUERPO_WH}" | openssl dgst -sha256 -hmac "${SECRETO_WH}" | awk '{print $2}')

check "el webhook sin firma valida se rechaza" "401" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/webhooks/payments/manual" \
     -H 'Content-Type: application/json' -d "${CUERPO_WH}")"

check "el webhook firmado confirma el pago" "ok" \
  "$(curl -sS -X POST "${BASE}/webhooks/payments/manual" -H "X-Kubo-Signature: ${FIRMA_WH}" \
     -H 'Content-Type: application/json' -d "${CUERPO_WH}" | jq -r '.recibido // "FALLO"')"

RENOV_PAGADO=$(curl -sS "${BASE}/tenants/me" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq -r '.data.planRenewsAt // ""')
check "el pago extiende la vigencia del plan" "true" \
  "$([[ -n "${RENOV_PAGADO}" && "${RENOV_PAGADO}" > "${RENOV_ANTES}" ]] && echo true || echo false)"
check "el pago deja el plan contratado" "pro" \
  "$(curl -sS "${BASE}/tenants/me" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq -r '.data.plan // empty')"

check "un webhook repetido responde igual" "ok" \
  "$(curl -sS -X POST "${BASE}/webhooks/payments/manual" -H "X-Kubo-Signature: ${FIRMA_WH}" \
     -H 'Content-Type: application/json' -d "${CUERPO_WH}" | jq -r '.recibido // "FALLO"')"
check "y NO extiende dos veces el plan (idempotencia)" "${RENOV_PAGADO}" \
  "$(curl -sS "${BASE}/tenants/me" -H "Authorization: Bearer ${OTRO_TOKEN}" | jq -r '.data.planRenewsAt // ""')"

# Un monto que no coincide con la intencion se rechaza (el precio manda el catalogo).
PAGO_2=$(curl -sS -X POST "${BASE}/tenants/me/payments" -H "Authorization: Bearer ${OTRO_TOKEN}" \
  -H 'Content-Type: application/json' -d '{"plan":"pro","cycle_months":1}')
CUERPO_MAL="{\"reference\":\"$(echo "${PAGO_2}" | jq -r '.reference')\",\"amount\":1000,\"status\":\"APPROVED\"}"
FIRMA_MAL=$(printf '%s' "${CUERPO_MAL}" | openssl dgst -sha256 -hmac "${SECRETO_WH}" | awk '{print $2}')
check "un monto distinto al de la intencion se rechaza" "AMOUNT_MISMATCH" \
  "$(curl -sS -X POST "${BASE}/webhooks/payments/manual" -H "X-Kubo-Signature: ${FIRMA_MAL}" \
     -H 'Content-Type: application/json' -d "${CUERPO_MAL}" | jq -r '.code // "OK"')"

# ---------------------------------------------------------------------------
echo
echo "[9/11] Recuperacion de contrasena"
# ---------------------------------------------------------------------------
check "solicitar el enlace responde 204" "204" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth/forgot-password" \
    -H 'Content-Type: application/json' -d "{\"email\":\"${LOCK_EMAIL}\"}")"

EN_BUZON=$(docker exec kubo-postgres psql -U kubo_root -d kubo_iam -tAc \
  "select count(*) from mail_outbox where recipient = '${LOCK_EMAIL}'" 2>/dev/null | tr -d '[:space:]')
check "el enlace quedo en el buzon de correo" "1" "${EN_BUZON}"

TOKEN_RESET=$(docker exec kubo-postgres psql -U kubo_root -d kubo_iam -tAc \
  "select body from mail_outbox where recipient = '${LOCK_EMAIL}' order by created_at desc limit 1" 2>/dev/null \
  | grep -o 'token=[A-Za-z0-9_-]*' | cut -d= -f2)

NUEVA_CLAVE="ClaveNueva9!"
check "consumir el enlace responde 204" "204" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth/reset-password" \
    -H 'Content-Type: application/json' -d "{\"token\":\"${TOKEN_RESET}\",\"newPassword\":\"${NUEVA_CLAVE}\"}")"

REINGRESO=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${LOCK_EMAIL}\",\"password\":\"${NUEVA_CLAVE}\"}" | jq -r '.user.email // empty')
check "la cuenta se desbloquea y entra con la clave nueva" "${LOCK_EMAIL}" "${REINGRESO}"

check "el enlace no se puede reutilizar" "400" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth/reset-password" \
    -H 'Content-Type: application/json' -d "{\"token\":\"${TOKEN_RESET}\",\"newPassword\":\"OtraClave10!\"}")"

check "no se revela si el correo existe" "204" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/auth/forgot-password" \
    -H 'Content-Type: application/json' -d '{"email":"no-existe@kubo.local"}')"

# ---------------------------------------------------------------------------
echo
echo "[10/11] Compras, proveedores y caja"
# ---------------------------------------------------------------------------
PROVEEDOR=$(curl -sS -X POST "${BASE}/suppliers" "${AUTH[@]}" \
  -d "{\"name\":\"Proveedor Prueba Humo $(date +%s)\",\"tax_id\":\"900$(date +%H%M%S)\",\"phone\":\"3100000000\"}")
PROVEEDOR_ID=$(echo "${PROVEEDOR}" | jq -r '.data.id // empty')
check "proveedor creado" "true" "$([[ -n "${PROVEEDOR_ID}" ]] && echo true || echo false)"

COMPRA=$(curl -sS -X POST "${BASE}/purchases" "${AUTH[@]}" \
  -d "{\"supplier_id\":\"${PROVEEDOR_ID}\",\"warehouse_id\":\"${BODEGA_ID}\",\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":5,\"unit_cost\":5000}]}")
COMPRA_ID=$(echo "${COMPRA}" | jq -r '.data.id // empty')
check "compra registrada por 25000.00" "25000.00" "$(echo "${COMPRA}" | jq -r '.data.total // empty')"
check "el IVA de la compra se desagrega" "3991.60" "$(echo "${COMPRA}" | jq -r '.data.tax // empty')"
check "la compra entra a la bodega elegida" "${BODEGA_ID}" \
  "$(echo "${COMPRA}" | jq -r '.data.warehouse_id // empty')"
check "una bodega inexistente rechaza la compra" "404" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/purchases" "${AUTH[@]}" \
     -d "{\"supplier_id\":\"${PROVEEDOR_ID}\",\"warehouse_id\":\"00000000-0000-0000-0000-000000000000\",\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":1,\"unit_cost\":1000}]}")"

# Soportes de compra (P-25): el archivo queda ligado a la compra que lo origina.
printf '%%PDF-1.4\n1 0 obj<<>>endobj\ntrailer<<>>\n%%%%EOF\n' > /tmp/opencode/soporte.pdf
# Multipart: solo la cabecera de autorizacion (el Content-Type lo pone curl).
SOPORTE=$(curl -sS -X POST "${BASE}/purchases/${COMPRA_ID}/documents" \
  -H "Authorization: Bearer ${TOKEN}" \
  -F "file=@/tmp/opencode/soporte.pdf;type=application/pdf")
check "la compra acepta un soporte" "PURCHASE_SUPPORT" "$(echo "${SOPORTE}" | jq -r '.data.kind // empty')"
printf 'no es un soporte valido' > /tmp/opencode/soporte.exe
check "un formato no soportado se rechaza" "INVALID_EXTENSION" \
  "$(curl -sS -X POST "${BASE}/purchases/${COMPRA_ID}/documents" \
     -H "Authorization: Bearer ${TOKEN}" \
     -F "file=@/tmp/opencode/soporte.exe" | jq -r '.code // "OK"')"
check "el soporte queda en el listado de documentos" "true" \
  "$([[ "$(curl -sS "${BASE}/documents" "${AUTH[@]}" | jq '[.data[] | select(.kind == "PURCHASE_SUPPORT")] | length')" -ge 1 ]] && echo true || echo false)"

check "la compra suma 5 unidades al inventario" "15" \
  "$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')"
check "el costo se actualiza al valor sin IVA" "4201.68" \
  "$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.cost')"
check "el kardex registra el movimiento de compra" "1" \
  "$(curl -sS "${BASE}/stock/movements?product_id=${PRODUCTO_ID}" "${AUTH[@]}" \
     | jq '[.data[] | select(.reference_type == "PURCHASE")] | length')"

check "la compra queda anulada" "VOIDED" \
  "$(curl -sS -X POST "${BASE}/purchases/${COMPRA_ID}/void" "${AUTH[@]}" | jq -r '.data.status')"
check "el inventario vuelve a 10 unidades" "10" \
  "$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')"
check "la anulacion revierte en la bodega elegida" "${BODEGA_ID}" \
  "$(curl -sS "${BASE}/stock/movements?product_id=${PRODUCTO_ID}" "${AUTH[@]}" \
     | jq -r '[.data[] | select(.reference_type == "PURCHASE_VOID")][0].warehouse_id // empty')"

check "RLS en compras: sin contexto de negocio no hay filas" "0" \
  "$(docker exec kubo-postgres psql -U kubo_erp -d kubo_erp -tAc "select count(*) from purchases" 2>/dev/null | tr -d '[:space:]')"

# --- Caja: apertura, arqueo y cierre (P-16) -----------------------------------
CAJA=$(curl -sS -X POST "${BASE}/cash-sessions/open" "${AUTH[@]}" -d '{"opening_amount":50000}')
check "la caja abre con una base de 50000" "OPEN" "$(echo "${CAJA}" | jq -r '.data.status // empty')"
check "una segunda apertura se rechaza" "409" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/cash-sessions/open" "${AUTH[@]}" -d '{"opening_amount":1000}')"
CAJA_ID=$(echo "${CAJA}" | jq -r '.data.id')

curl -sS -o /dev/null -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":1}],\"payment_method\":\"CASH\"}"
check "la venta en efectivo entra al arqueo del turno" "61900.00" \
  "$(curl -sS "${BASE}/cash-sessions/current" "${AUTH[@]}" | jq -r '.data.summary.expected_cash // empty')"

CIERRE_CAJA=$(curl -sS -X POST "${BASE}/cash-sessions/${CAJA_ID}/close" "${AUTH[@]}" -d '{"counted_amount":61900}')
check "el cierre cuadra con el efectivo contado" "0.00" "$(echo "${CIERRE_CAJA}" | jq -r '.data.difference // empty')"
check "un segundo cierre se rechaza" "409" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/cash-sessions/${CAJA_ID}/close" "${AUTH[@]}" -d '{"counted_amount":1}')"

# ---------------------------------------------------------------------------
echo
echo "[11/11] Limite de tasa, TLS y observabilidad"
# ---------------------------------------------------------------------------
LIMITE=$(curl -sS -o /dev/null -D - "${BASE}/products" "${AUTH[@]}" \
  | grep -i '^x-ratelimit-limit' | tr -d '\r' | awk '{print $2}')
check "el limite de tasa por usuario esta activo" "300" "${LIMITE}"

check "HTTPS responde 200" "200" "$(curl -k -sS -o /dev/null -w '%{http_code}' https://localhost:3443/)"
check "HTTP redirige a HTTPS" "308" "$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:3080/)"
check "HTTPS anuncia HSTS" "1" \
  "$(curl -k -sS -o /dev/null -D - https://localhost:3443/ | grep -ci 'strict-transport-security')"

check "el collector de trazas responde su sonda de salud" "200" \
  "$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:13133/ 2>/dev/null || echo 000)"
check_positivo "el collector recibio trazas de los servicios" \
  "$(docker logs kubo-otel --since 10m 2>&1 | grep -c 'service.name=kubo-')"

# ---------------------------------------------------------------------------
echo
echo "================================================================"
printf 'Resultado: \033[32m%d pruebas exitosas\033[0m, \033[31m%d fallidas\033[0m\n' "${PASS}" "${FAIL}"
echo

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
