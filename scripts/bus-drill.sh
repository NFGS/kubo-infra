#!/bin/bash
# ---------------------------------------------------------------------------
# Simulacro: caida del bus de eventos sin perdida de ventas.
#
# Verifica la promesa central del transactional outbox:
#   1. Con RabbitMQ detenido, la caja SIGUE vendiendo (201).
#   2. El evento queda en la bandeja de salida (PENDING), no se pierde.
#   3. Al volver el bus, el evento se publica y llega a analitica.
#
# Uso:  make bus-drill
# ---------------------------------------------------------------------------
set -uo pipefail

BASE="${KUBO_API:-http://localhost:9080/api/v1}"
EMAIL="${KUBO_ADMIN_EMAIL:-admin@kubo.local}"
PASSWORD="${KUBO_ADMIN_PASSWORD:-Admin123!}"
COMPOSE_FILE="$(cd "$(dirname "$0")/.." && pwd)/docker-compose.yml"

PASS=0
FAIL=0

ok() { printf '  \033[32mPASA\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31mFALLA\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo
echo "Kubo · simulacro de caida del bus (outbox)"
echo "================================================================"

TOKEN=$(curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${EMAIL}\",\"password\":\"${PASSWORD}\"}" | jq -r '.accessToken // empty')
if [[ -z "${TOKEN}" ]]; then
  echo "No fue posible autenticar; se aborta el simulacro."
  exit 1
fi
AUTH=(-H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json')

PRODUCTO=$(curl -sS "${BASE}/products" "${AUTH[@]}" | jq -r '.data[0].id // empty')
if [[ -z "${PRODUCTO}" ]]; then
  echo "No hay productos; ejecute make seed primero."
  exit 1
fi

echo "[1/4] deteniendo RabbitMQ"
docker stop kubo-rabbitmq >/dev/null

echo "[2/4] vendiendo con el bus caido"
VENTA=$(curl -sS -X POST "${BASE}/sales" "${AUTH[@]}" \
  -d "{\"items\":[{\"product_id\":\"${PRODUCTO}\",\"quantity\":1}],\"payment_method\":\"CASH\"}")
VENTA_ID=$(echo "${VENTA}" | jq -r '.data.id // empty')
if [[ -n "${VENTA_ID}" ]]; then
  ok "la venta se registra con el bus caido ($(echo "${VENTA}" | jq -r '.data.number'))"
else
  ko "la venta fallo con el bus caido: ${VENTA}"
fi

PENDIENTE=$(docker exec kubo-postgres psql -U kubo_root -d kubo_erp -tAc \
  "select count(*) from outbox_events where status = 'PENDING' and payload->'data'->>'sale_id' = '${VENTA_ID}'" 2>/dev/null | tr -d '[:space:]')
if [[ "${PENDIENTE}" == "1" ]]; then
  ok "el evento quedo en la bandeja como PENDING"
else
  ko "el evento no quedo en la bandeja (PENDING=${PENDIENTE})"
fi

echo "[3/4] reactivando RabbitMQ"
docker start kubo-rabbitmq >/dev/null

PUBLICADO="no"
for _ in $(seq 1 60); do
  ESTADO=$(docker exec kubo-postgres psql -U kubo_root -d kubo_erp -tAc \
    "select status from outbox_events where payload->'data'->>'sale_id' = '${VENTA_ID}'" 2>/dev/null | tr -d '[:space:]')
  if [[ "${ESTADO}" == "PUBLISHED" ]]; then
    PUBLICADO="si"
    break
  fi
  sleep 1
done
if [[ "${PUBLICADO}" == "si" ]]; then
  ok "al volver el bus, el evento se publico"
else
  ko "el evento no se publico tras reactivar el bus (estado=${ESTADO:-?})"
fi

echo "[4/4] comprobando la proyeccion en analitica"
PROYECTADA="no"
for _ in $(seq 1 20); do
  TOTAL=$(curl -sS "${BASE}/dashboard/recent-sales?limit=50" "${AUTH[@]}" \
    | jq --arg id "${VENTA_ID}" '[.data[] | select(.sale_id == $id)] | length')
  if [[ "${TOTAL}" == "1" ]]; then
    PROYECTADA="si"
    break
  fi
  sleep 1
done
if [[ "${PROYECTADA}" == "si" ]]; then
  ok "la venta llego al modelo de lectura de analitica"
else
  ko "la venta no llego a analitica tras el simulacro"
fi

echo
echo "================================================================"
printf 'Resultado: \033[32m%d pruebas exitosas\033[0m, \033[31m%d fallidas\033[0m\n' "${PASS}" "${FAIL}"
echo

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
