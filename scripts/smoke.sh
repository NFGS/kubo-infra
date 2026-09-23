#!/bin/bash
# ---------------------------------------------------------------------------
# Prueba de humo end-to-end de Kubo.
#
# Verifica, contra el sistema en ejecucion: salud de los 5 contenedores de
# aplicacion, autenticacion JWT, rechazo de peticiones sin token, cifrado de
# datos personales, descuento de inventario y proyeccion del evento de venta en
# analitica.
#
# Uso:  make smoke
# ---------------------------------------------------------------------------
set -uo pipefail

BASE="${KUBO_API:-http://localhost:9080/api/v1}"
EMAIL="${KUBO_ADMIN_EMAIL:-admin@kubo.local}"
PASSWORD="${KUBO_ADMIN_PASSWORD:-Admin123!}"

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

echo
echo "Kubo · prueba de humo end-to-end"
echo "================================================================"

# ---------------------------------------------------------------------------
echo "[1/8] Salud de los servicios"
# ---------------------------------------------------------------------------
for service in "kubo-gateway:9080" "kubo-iam:9081" "kubo-crm:9082" "kubo-erp:9083" "kubo-analytics:9084"; do
  name="${service%%:*}"
  port="${service##*:}"
  status=$(curl -sS --max-time 5 "http://localhost:${port}/api/v1/health" | jq -r '.status // "sin respuesta"')
  check "${name} responde" "UP" "${status}"
done

# ---------------------------------------------------------------------------
echo
echo "[2/8] Autenticacion"
# ---------------------------------------------------------------------------
LOGIN=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")
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

# ---------------------------------------------------------------------------
echo
echo "[3/8] Control de acceso"
# ---------------------------------------------------------------------------
SIN_TOKEN=$(curl -sS -o /dev/null -w '%{http_code}' "${BASE}/customers")
check "sin token responde 401" "401" "${SIN_TOKEN}"

FALSO=$(curl -sS -o /dev/null -w '%{http_code}' -H "Authorization: Bearer eyJhbGciOiJSUzI1NiJ9.falso.firma" "${BASE}/customers")
check "token falsificado responde 401" "401" "${FALSO}"

SUPLANTACION=$(curl -sS -o /dev/null -w '%{http_code}' -H 'X-User-Id: 00000000-0000-0000-0000-000000000000' "${BASE}/customers")
check "cabecera de identidad inyectada es ignorada" "401" "${SUPLANTACION}"

# ---------------------------------------------------------------------------
echo
echo "[4/8] Clientes y cifrado de datos personales"
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

# ---------------------------------------------------------------------------
echo
echo "[5/8] Inventario y venta"
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

SOBREVENTA=$(curl -sS -o /dev/null -w '%{http_code}' -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO_ID}\",\"quantity\":99}],\"payment_method\":\"CASH\"}")
check "vender sin existencias responde 409" "409" "${SOBREVENTA}"

# ---------------------------------------------------------------------------
echo
echo "[6/8] Evento de venta y tablero (RabbitMQ + MongoDB)"
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
if [[ "${EN_MONGO}" =~ ^[0-9]+$ && "${EN_MONGO}" -ge 1 ]]; then
  ok "MongoDB guardo ${EN_MONGO} evento(s) sale.created"
else
  ko "no se encontraron eventos en MongoDB: ${EN_MONGO}"
fi

TABLERO=$(curl -sS "${BASE}/dashboard/summary" "${AUTH[@]}" | jq -r '.data.sales_count')
if [[ "${TABLERO}" =~ ^[0-9]+$ && "${TABLERO}" -ge 1 ]]; then
  ok "el tablero reporta ${TABLERO} venta(s)"
else
  ko "el tablero no reporta ventas: ${TABLERO}"
fi

# Vista compuesta (BFF): una sola peticion debe traer las siete vistas.
COMPUESTA=$(curl -sS "${BASE}/dashboard/overview" "${AUTH[@]}")
VISTAS=$(echo "${COMPUESTA}" | jq -r '.data | keys | length')
check "la vista compuesta del tablero trae las 7 vistas en una peticion" "7" "${VISTAS}"
check "la vista compuesta no reporta vistas caidas" "0" "$(echo "${COMPUESTA}" | jq -r '.unavailable // [] | length')"
check "la zona horaria del negocio viaja en la respuesta" "America/Bogota" \
  "$(curl -sS "${BASE}/sales/stats" "${AUTH[@]}" | jq -r '.data.timezone // "sin zona"')"

# ---------------------------------------------------------------------------
echo
echo "[7/8] Anulacion de venta (devolucion de inventario)"
# ---------------------------------------------------------------------------
ANULADA=$(curl -sS -X POST "${BASE}/sales/${VENTA_ID}/void" "${AUTH[@]}" | jq -r '.data.status')
check "la venta queda anulada" "VOIDED" "${ANULADA}"

STOCK_DEVUELTO=$(curl -sS "${BASE}/products/${PRODUCTO_ID}" "${AUTH[@]}" | jq -r '.data.stock')
check "el inventario vuelve a 10 unidades" "10" "${STOCK_DEVUELTO}"

# ---------------------------------------------------------------------------
echo
echo "[8/8] Aislamiento entre negocios"
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

# ---------------------------------------------------------------------------
echo
echo "================================================================"
printf 'Resultado: \033[32m%d pruebas exitosas\033[0m, \033[31m%d fallidas\033[0m\n' "${PASS}" "${FAIL}"
echo

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
