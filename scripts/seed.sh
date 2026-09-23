#!/bin/bash
# ---------------------------------------------------------------------------
# Carga datos de demostracion en Kubo.
#
# Todo pasa por el API Gateway con un token real: el script no toca ninguna base
# de datos, igual que lo haria un cliente legitimo. Es idempotente: si ya hay
# productos o clientes, omite esa parte.
# ---------------------------------------------------------------------------
set -euo pipefail

BASE="${KUBO_API:-http://localhost:9080/api/v1}"
EMAIL="${KUBO_ADMIN_EMAIL:-admin@kubo.local}"
PASSWORD="${KUBO_ADMIN_PASSWORD:-Admin123!}"

echo "[kubo] autenticando como ${EMAIL}"
LOGIN=$(curl -sS -X POST "${BASE}/auth/login" \
  -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}")

TOKEN=$(echo "${LOGIN}" | jq -r '.accessToken // empty')
if [[ -z "${TOKEN}" ]]; then
  echo "ERROR: no fue posible autenticar. Respuesta: ${LOGIN}"
  exit 1
fi

AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json')

product_id() {
  curl -sS "${BASE}/products" "${AUTH[@]}" \
    | jq -r --arg sku "$1" '.data[] | select(.sku == $sku) | .id' | head -1
}

customer_id() {
  curl -sS "${BASE}/customers" "${AUTH[@]}" \
    | jq -r --arg nombre "$1" '.data[] | select(.name | contains($nombre)) | .id' | head -1
}

# ---------------------------------------------------------------------------
# Productos
# ---------------------------------------------------------------------------
EXISTING_PRODUCTS=$(curl -sS "${BASE}/products" "${AUTH[@]}" | jq '.total // 0')
if [[ "${EXISTING_PRODUCTS}" -gt 0 ]]; then
  echo "[kubo] ya existen ${EXISTING_PRODUCTS} productos: se omite la creacion"
else
  echo "[kubo] creando catalogo de ejemplo"
  while IFS='|' read -r sku name price cost stock min tax; do
    CREATED=$(curl -sS -X POST "${BASE}/products" "${AUTH[@]}" \
      -d "{\"sku\":\"${sku}\",\"name\":\"${name}\",\"price\":${price},\"cost\":${cost},\"min_stock\":${min},\"tax_rate\":${tax}}")
    ID=$(echo "${CREATED}" | jq -r '.data.id // empty')
    if [[ -z "${ID}" ]]; then
      echo "  aviso: no se pudo crear ${name}: $(echo "${CREATED}" | jq -r '.message // "error"')"
      continue
    fi
    curl -sS -X POST "${BASE}/products/${ID}/stock" "${AUTH[@]}" \
      -d "{\"kind\":\"IN\",\"quantity\":${stock},\"reason\":\"Inventario inicial\"}" > /dev/null
    echo "  ${name} (stock inicial ${stock})"
  done <<'CATALOGO'
7701001|Cafe molido 250 g|9500|6200|40|10|19
7701002|Panela 500 g|4200|2800|60|15|19
7701003|Aceite de girasol 1 L|12800|9500|25|8|19
7701004|Arroz 500 g|3100|2100|80|20|19
7701005|Detergente 900 g|15600|11200|18|6|19
7701006|Gaseosa 1.5 L|6500|4200|30|12|19
CATALOGO
fi

# ---------------------------------------------------------------------------
# Clientes
# ---------------------------------------------------------------------------
EXISTING_CUSTOMERS=$(curl -sS "${BASE}/customers" "${AUTH[@]}" | jq '.total // 0')
if [[ "${EXISTING_CUSTOMERS}" -gt 0 ]]; then
  echo "[kubo] ya existen ${EXISTING_CUSTOMERS} clientes: se omite la creacion"
else
  echo "[kubo] creando clientes de ejemplo (documento y telefono cifrados)"
  while IFS='|' read -r name document phone city email stage; do
    CREATED=$(curl -sS -X POST "${BASE}/customers" "${AUTH[@]}" \
      -d "{\"name\":\"${name}\",\"document_number\":\"${document}\",\"phone\":\"${phone}\",\"city\":\"${city}\",\"email\":\"${email}\",\"stage\":\"${stage}\",\"credit_limit\":500000}")
    if [[ "$(echo "${CREATED}" | jq -r '.data.id // empty')" == "" ]]; then
      echo "  aviso: no se pudo crear ${name}"
      continue
    fi
    echo "  ${name}"
  done <<'CLIENTES'
Panaderia El Trigal|900123456-7|3105551234|Armenia|compras@eltrigal.co|CUSTOMER
Ferreteria La 14|900987654-3|3175559876|Calarca|contacto@ferreteriala14.co|PROSPECT
Jose Ramirez|1098765432|3205554321|Armenia|jose.ramirez@correo.co|CUSTOMER
Cafe Quindio S.A.S.|901222333-1|3185551122|Salento|gerencia@cafequindio.co|LEAD
CLIENTES
fi

# ---------------------------------------------------------------------------
# Ventas de ejemplo
# ---------------------------------------------------------------------------
EXISTING_SALES=$(curl -sS "${BASE}/sales" "${AUTH[@]}" | jq '.total // 0')
if [[ "${EXISTING_SALES}" -gt 0 ]]; then
  echo "[kubo] ya existen ${EXISTING_SALES} ventas: se omite la creacion"
else
  echo "[kubo] registrando ventas de ejemplo"
  CAFE=$(product_id "7701001")
  PANELA=$(product_id "7701002")
  ACEITE=$(product_id "7701003")
  ARROZ=$(product_id "7701004")
  CLIENTE=$(customer_id "Panaderia El Trigal")
  CLIENTE2=$(customer_id "Jose Ramirez")

  # Sin identificadores validos no se puede construir el cuerpo de la venta:
  # es mejor detenerse con un mensaje claro que enviar una peticion malformada.
  for par in "cafe:${CAFE}" "panela:${PANELA}" "aceite:${ACEITE}" "arroz:${ARROZ}" "cliente1:${CLIENTE}" "cliente2:${CLIENTE2}"; do
    if [[ -z "${par##*:}" ]]; then
      echo "ERROR: no se obtuvo el identificador de ${par%%:*} (¿se crearon los productos y clientes?)"
      exit 1
    fi
  done

  crear_venta() {
    local descripcion="$1" metodo="$2" cliente="$3" items="$4"
    local respuesta
    respuesta=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" -d "${items}")
    local numero
    numero=$(echo "${respuesta}" | jq -r '.data.number // empty')
    if [[ -z "${numero}" ]]; then
      echo "  aviso: venta no registrada (${descripcion}): $(echo "${respuesta}" | jq -r '.message // "error"')"
      return
    fi
    echo "  ${numero} · ${descripcion} · ${metodo} · total $(echo "${respuesta}" | jq -r '.data.total')"
  }

  crear_venta "cafe y panela" "CASH" "${CLIENTE}" \
    "{\"items\":[{\"product_id\":\"${CAFE}\",\"quantity\":2},{\"product_id\":\"${PANELA}\",\"quantity\":3}],\"customer_id\":\"${CLIENTE}\",\"customer_name\":\"Panaderia El Trigal\",\"payment_method\":\"CASH\"}"

  crear_venta "aceite y arroz" "TRANSFER" "${CLIENTE2}" \
    "{\"items\":[{\"product_id\":\"${ACEITE}\",\"quantity\":1},{\"product_id\":\"${ARROZ}\",\"quantity\":4}],\"customer_id\":\"${CLIENTE2}\",\"customer_name\":\"Jose Ramirez\",\"payment_method\":\"TRANSFER\"}"

  crear_venta "venta de mostrador" "CARD" "" \
    "{\"items\":[{\"product_id\":\"${CAFE}\",\"quantity\":1},{\"product_id\":\"${PANELA}\",\"quantity\":1}],\"payment_method\":\"CARD\"}"
fi

echo
echo "[kubo] semilla completa. Resumen del negocio:"
curl -sS "${BASE}/dashboard/summary" "${AUTH[@]}" | jq '.data'
