#!/bin/bash
# ---------------------------------------------------------------------------
# Verifica el demo publico 100% OSS (ADR-0028): local, DNS y HTTPS.
#
# La comprobacion de puertos externos se hace desde check-host.net (fuera de la
# red del local) porque muchos routers no soportan hairpin NAT.
#
# Uso:  ./kubo-infra/scripts/demo-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"
leer() { grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }
DOMINIO="$(leer KUBO_TLS_DOMAIN)"; DOMINIO="${DOMINIO:-kubo-app.duckdns.org}"
OK=0
FALLA=0

check() { # descripcion esperado real
  if [ "$2" = "$3" ]; then
    echo "  PASA  $1"
    OK=$((OK + 1))
  else
    echo "  FALLA $1 (esperado: $2, real: $3)"
    FALLA=$((FALLA + 1))
  fi
}

echo "Kubo · verificacion del demo publico ($DOMINIO)"
echo "================================================================"

echo "[1] Local"
check "contenedores healthy (12)" "12" \
  "$(docker compose -f "${ROOT}/kubo-infra/docker-compose.yml" ps --format '{{.Status}}' | grep -c healthy)"
check "PWA local responde" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3000/)"
check "Caddy local (sonda de salud)" "200" \
  "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost/)"

echo "[2] DNS"
IP_DNS="$(dig +short "${DOMINIO}" A 2>/dev/null | tail -1)"
IP_PUB="$(curl -s --max-time 10 https://ifconfig.me/ip)"
check "A de ${DOMINIO} apunta a la IP publica" "${IP_PUB}" "${IP_DNS:-vacio}"

echo "[3] HTTPS publico (desde el propio host; puede fallar por hairpin NAT)"
check "https://${DOMINIO} responde" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${DOMINIO}/")"
check "certificado Let's Encrypt" "1" \
  "$(echo | openssl s_client -connect "${DOMINIO}:443" -servername "${DOMINIO}" 2>/dev/null \
     | openssl x509 -noout -issuer 2>/dev/null | grep -c "Let's Encrypt")"

echo "================================================================"
echo "Resultado: ${OK} PASA, ${FALLA} FALLA"
echo "Prueba externa definitiva: https://check-host.net/check-tcp?host=${DOMINIO}:443"
[ "${FALLA}" -eq 0 ]
