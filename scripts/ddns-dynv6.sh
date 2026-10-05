#!/bin/bash
# ---------------------------------------------------------------------------
# DDNS para el demo publico (ADR-0028) con dynv6.net.
# Actualiza el registro A de la zona con la IP publica actual.
#
# Requiere en kubo-infra/.env: KUBO_TLS_DOMAIN (kubo.dynv6.net) y KUBO_DYNV6_TOKEN
# (token HTTP de la zona, creado en https://dynv6.com/keys).
#
# Uso:  ./kubo-infra/scripts/ddns-dynv6.sh
# Cron: */5 * * * * cd <workspace> && ./kubo-infra/scripts/ddns-dynv6.sh >> /tmp/kubo-ddns.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"

leer() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2-; }

DOMINIO="$(leer KUBO_TLS_DOMAIN)"
TOKEN="$(leer KUBO_DYNV6_TOKEN)"

if [ -z "${DOMINIO}" ] || [ -z "${TOKEN}" ]; then
  echo "[kubo] faltan KUBO_TLS_DOMAIN o KUBO_DYNV6_TOKEN en ${ENV_FILE}" >&2
  exit 1
fi

IP="$(curl -fsS --max-time 15 https://ifconfig.me/ip)"
RESP="$(curl -fsS --max-time 20 "https://dynv6.com/api/update?zone=${DOMINIO}&token=${TOKEN}&ipv4=${IP}")"
echo "[kubo] ddns ${DOMINIO} -> ${IP}: ${RESP}"
