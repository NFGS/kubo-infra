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

echo
echo "Kubo · prueba de humo end-to-end"
echo "================================================================"

# ---------------------------------------------------------------------------
echo "[1/11] Salud de los servicios"
# ---------------------------------------------------------------------------
for service in "kubo-gateway:9080" "kubo-iam:9081" "kubo-crm:9082" "kubo-erp:9083" "kubo-analytics:9084"; do
  name="${service%%:*}"
  port="${service##*:}"
  status=$(curl -sS --max-time 5 "http://localhost:${port}/api/v1/health" | jq -r '.status // "sin respuesta"')
  check "${name} responde" "UP" "${status}"
done

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
  "$(curl -sS -o /dev/null -w '%{http_code}' http://localhost:9083/api/v1/products -H 'X-Tenant-Id: no-es-uuid')"

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

KARDEX=$(curl -sS "${BASE}/stock/movements?product_id=${PRODUCTO_ID}" "${AUTH[@]}" | jq '.total')
check "el kardex registra 2 movimientos" "2" "${KARDEX}"

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

OUTBOX_FALLIDOS=$(curl -sS http://localhost:9083/api/v1/health | jq -r '.outbox.failed // "?"')
check "la bandeja de salida no tiene eventos fallidos" "0" "${OUTBOX_FALLIDOS}"

# ---------------------------------------------------------------------------
echo
echo "[7/11] Anulacion de venta (devolucion de inventario)"
# ---------------------------------------------------------------------------
ANULADA=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/void" "${AUTH[@]}" | jq -r '.data.status')
check "la venta queda anulada" "VOIDED" "${ANULADA}"

STOCK_DEVUELTO=$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')
check "el inventario vuelve a 10 unidades" "10" "${STOCK_DEVUELTO}"

# ---------------------------------------------------------------------------
echo
echo "[8/11] Aislamiento entre negocios"
# ---------------------------------------------------------------------------
OTRO=$(curl -sS -X POST "${BASE}/auth/register" -H 'Content-Type: application/json' \
  -d "{\"tenantName\":\"Negocio Aislado $(date +%H%M%S)\",\"fullName\":\"Otro Dueno\",\"email\":\"otro$(date +%H%M%S)@kubo.local\",\"password\":\"OtraClave123!\"}")
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
  -d "{\"supplier_id\":\"${PROVEEDOR_ID}\",\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":5,\"unit_cost\":5000}]}")
COMPRA_ID=$(echo "${COMPRA}" | jq -r '.data.id // empty')
check "compra registrada por 25000.00" "25000.00" "$(echo "${COMPRA}" | jq -r '.data.total // empty')"
check "el IVA de la compra se desagrega" "3991.60" "$(echo "${COMPRA}" | jq -r '.data.tax // empty')"

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
