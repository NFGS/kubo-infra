#!/bin/bash
# ---------------------------------------------------------------------------
# Verifica el demo publico 100% OSS (ADR-0028): stack local, DNS, tunel zrok
# (ruta vigente, plan B) y ruta directa por DuckDNS (informativa: requiere
# reenvio de puertos en el router).
#
# La comprobacion externa definitiva se hace abriendo la URL del demo desde
# fuera de la red local (o check-host.net para la ruta directa).
#
# Uso:  ./kubo-infra/scripts/demo-check.sh
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"
leer() { grep -E "^$1=" "${ENV_FILE}" 2>/dev/null | tail -1 | cut -d= -f2-; }
DOMINIO="$(leer KUBO_TLS_DOMAIN)"; DOMINIO="${DOMINIO:-kubo-app.duckdns.org}"
TUNEL="$(leer KUBO_DEMO_URL)"; TUNEL="${TUNEL:-https://kubo.shares.zrok.io}"
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

info() { echo "  INFO  $1"; }

echo "Kubo · verificacion del demo publico ($TUNEL)"
echo "================================================================"

echo "[1] Local"
check "contenedores healthy (12)" "12" \
  "$(docker compose -f "${ROOT}/kubo-infra/docker-compose.yml" ps --format '{{.Status}}' | grep -c healthy)"
check "PWA local responde" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:3000/)"
check "Caddy local (sonda de salud)" "200" \
  "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 https://localhost:3443/)"

echo "[2] DNS"
IP_DNS="$(dig +short "${DOMINIO}" A 2>/dev/null | tail -1)"
IP_PUB="$(curl -s --max-time 10 https://ifconfig.me/ip)"
check "A de ${DOMINIO} apunta a la IP publica" "${IP_PUB}" "${IP_DNS:-vacio}"

echo "[3] Tunel zrok (demo vigente; plan B de ADR-0028)"
check "servicio kubo-tunnel activo" "active" \
  "$(systemctl --user is-active kubo-tunnel.service 2>/dev/null || echo inactivo)"
check "URL del demo responde" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "${TUNEL}/")"

echo "[4] Ruta directa (informativa: requiere reenvio de puertos del router)"
HTTP_DIR="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMINIO}/")"
if [ "${HTTP_DIR}" = "200" ]; then
  check "https://${DOMINIO} responde (ruta directa)" "200" "${HTTP_DIR}"
  check "certificado Let's Encrypt (ruta directa)" "1" \
    "$(echo | openssl s_client -connect "${DOMINIO}:443" -servername "${DOMINIO}" 2>/dev/null \
       | openssl x509 -noout -issuer 2>/dev/null | grep -c "Let's Encrypt")"
else
  info "ruta directa aun no activa (real: ${HTTP_DIR:-000}); se habilitara con el reenvio de 80/443"
  info "prueba externa de la ruta directa: https://check-host.net/check-tcp?host=${DOMINIO}:443"
fi

echo "================================================================"
echo "Resultado: ${OK} PASA, ${FALLA} FALLA"
[ "${FALLA}" -eq 0 ]

# marcador-github-1791289870
