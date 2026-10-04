#!/bin/bash
# ---------------------------------------------------------------------------
# DDNS para el demo publico (ADR-0028): actualiza el registro A del dominio
# en deSEC con la IP publica actual, via la API REST (sirve tanto para
# subdominios dedyn.io como para dominios propios delegados a deSEC).
#
# Requiere en kubo-infra/.env: KUBO_TLS_DOMAIN (el dominio) y KUBO_DESEC_TOKEN
# (token de la cuenta deSEC).
#
# Uso:  ./kubo-infra/scripts/ddns-desec.sh
# Cron: */5 * * * * cd <workspace> && ./kubo-infra/scripts/ddns-desec.sh >> /tmp/kubo-ddns.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"

leer() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2-; }

DOMINIO="$(leer KUBO_TLS_DOMAIN)"
TOKEN="$(leer KUBO_DESEC_TOKEN)"

if [ -z "${DOMINIO}" ] || [ -z "${TOKEN}" ]; then
  echo "[kubo] faltan KUBO_TLS_DOMAIN o KUBO_DESEC_TOKEN en ${ENV_FILE}" >&2
  exit 1
fi

IP="$(curl -fsS --max-time 15 https://ifconfig.me/ip)"
CUERPO="$(jq -n --arg ip "${IP}" '[{subname:"", type:"A", ttl:60, records:[$ip]}]')"

CODIGO="$(curl -sS --max-time 20 -o /dev/null -w '%{http_code}' -X PATCH \
  "https://desec.io/api/v1/domains/${DOMINIO}/rrsets/" \
  -H "Authorization: Token ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data-binary "${CUERPO}")"

case "${CODIGO}" in
  200 | 201 | 202) echo "[kubo] ddns ${DOMINIO} -> ${IP} (HTTP ${CODIGO})" ;;
  *) echo "[kubo] ddns fallo en ${DOMINIO}: HTTP ${CODIGO}" >&2; exit 1 ;;
esac
