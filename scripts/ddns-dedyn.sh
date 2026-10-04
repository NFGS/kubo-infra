#!/bin/bash
# ---------------------------------------------------------------------------
# DDNS para el demo publico (ADR-0028): actualiza el registro A de
# kubo.dedyn.io con la IP publica actual, via el endpoint DynDNS2 de deSEC.
#
# Requiere en kubo-infra/.env: KUBO_TLS_DOMAIN (el dominio) y KUBO_DEDYN_TOKEN
# (token de la cuenta deSEC).
#
# Uso:  ./kubo-infra/scripts/ddns-dedyn.sh
# Cron: */5 * * * * cd <workspace> && ./kubo-infra/scripts/ddns-dedyn.sh >> /tmp/kubo-ddns.log 2>&1
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"

leer() { grep -E "^$1=" "${ENV_FILE}" | tail -1 | cut -d= -f2-; }

DOMINIO="$(leer KUBO_TLS_DOMAIN)"
TOKEN="$(leer KUBO_DEDYN_TOKEN)"

if [ -z "${DOMINIO}" ] || [ -z "${TOKEN}" ]; then
  echo "[kubo] faltan KUBO_TLS_DOMAIN o KUBO_DEDYN_TOKEN en ${ENV_FILE}" >&2
  exit 1
fi

RESP="$(curl -fsS --max-time 20 -u "${DOMINIO}:${TOKEN}" "https://update.dedyn.io/")"
echo "[kubo] ddns ${DOMINIO}: ${RESP}"
