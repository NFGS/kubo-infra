#!/bin/bash
# ---------------------------------------------------------------------------
# DDNS para el demo publico (ADR-0028) con DuckDNS.
# Actualiza el registro A del subdominio con la IP publica actual.
#
# Requiere en kubo-infra/.env: KUBO_TLS_DOMAIN (kubo.duckdns.org) y KUBO_DUCK_TOKEN
# (token de la cuenta DuckDNS, en https://www.duckdns.org).
#
# Uso:  ./kubo-infra/scripts/ddns-duckdns.sh
# Cron: */5 * * * * cd <workspace> && ./kubo-infra/scripts/ddns-duckdns.sh >> /tmp/kubo-ddns.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"

leer() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2-; }

DOMINIO="$(leer KUBO_TLS_DOMAIN)"
TOKEN="$(leer KUBO_DUCK_TOKEN)"
SUBDOMINIO="${DOMINIO%%.duckdns.org}"

if [ -z "${DOMINIO}" ] || [ -z "${TOKEN}" ]; then
  echo "[kubo] faltan KUBO_TLS_DOMAIN o KUBO_DUCK_TOKEN en ${ENV_FILE}" >&2
  exit 1
fi

IP="$(curl -fsS --max-time 15 https://ifconfig.me/ip)"
RESP="$(curl -fsS --max-time 20 "https://www.duckdns.org/update?domains=${SUBDOMINIO}&token=${TOKEN}&ip=${IP}")"

if [ "${RESP}" = "OK" ]; then
  echo "[kubo] ddns ${DOMINIO} -> ${IP} (OK)"
else
  echo "[kubo] ddns fallo en ${DOMINIO}: ${RESP}" >&2
  exit 1
fi
