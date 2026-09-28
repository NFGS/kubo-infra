#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Chequeo de operacion (runbook, semana uno).
#
# No reemplaza al humo (que es de desarrollo y necesita credenciales): esto es
# lo que se mira cada manana en el servidor del negocio, sin secretos de nadie.
#   - salud del gateway y de la bandeja de salida
#   - respaldo de anoche: verificado, con manifiesto y reciente
#   - disco con aire
#   - certificados internos vigentes
#
# Uso: kubo-infra/scripts/operacion-check.sh
# ---------------------------------------------------------------------------
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

PASS=0
FAIL=0

check() {
  local nombre="$1" esperado="$2" real="$3"
  if [[ "${esperado}" == "${real}" ]]; then
    printf '  \033[32mOK\033[0m   %s\n' "${nombre}"
    PASS=$((PASS + 1))
  else
    printf '  \033[31mFALLA\033[0m %s (esperado %s, real %s)\n' "${nombre}" "${esperado}" "${real}"
    FAIL=$((FAIL + 1))
  fi
}

info() {
  printf '  \033[36m%s\033[0m\n' "$1"
}

CURL_TLS=(--cacert certs/ca.crt --cert certs/gateway.crt --key certs/gateway.key)

echo "Kubo · chequeo de operacion"
echo "================================================================"

# 1) Servicios arriba y bandeja de salida sin eventos fallidos.
echo "[1/4] Servicios"
SALUD=$(curl -k -sS -o /dev/null -w '%{http_code}' https://localhost:3443/api/v1/health 2>/dev/null || echo 000)
check "el gateway responde su sonda" "200" "${SALUD}"

CORRIENDO=$(docker compose ps --status running --format '{{.Name}}' 2>/dev/null || true)
FALTAN=""
for servicio in kubo-gateway kubo-iam kubo-erp kubo-crm kubo-analytics kubo-web kubo-postgres kubo-rabbitmq kubo-redis kubo-mongo; do
  grep -q "^${servicio}$" <<< "${CORRIENDO}" || FALTAN="${FALTAN} ${servicio}"
done
check "los servicios del nucleo corren" "" "${FALTAN}"

OUTBOX=$(curl -sS "${CURL_TLS[@]}" https://localhost:9083/api/v1/health 2>/dev/null | jq -r '.outbox.failed // "?"')
check "la bandeja de salida no tiene eventos fallidos" "0" "${OUTBOX}"

# 2) Respaldo de anoche: verificado, con manifiesto y reciente.
echo "[2/4] Respaldo"
ULTIMO=$(ls -1dt backups/*/ 2>/dev/null | head -1 || true)
if [[ -z "${ULTIMO}" ]]; then
  check "hay un respaldo" "si" "no"
else
  VERIFICACION=$(grep -o 'verificacion=[a-z]*' "${ULTIMO}MANIFEST" 2>/dev/null | cut -d= -f2 || echo "sin-manifiesto")
  check "el respaldo de anoche paso la verificacion" "ok" "${VERIFICACION}"

  EDAD_HORAS=$(( ($(date +%s) - $(stat -c %Y "${ULTIMO}") ) / 3600 ))
  if [[ "${EDAD_HORAS}" -le 26 ]]; then
    info "el respaldo mas reciente tiene ${EDAD_HORAS} h"
    PASS=$((PASS + 1))
  else
    check "el respaldo es de las ultimas 26 horas" "<=26" "${EDAD_HORAS}"
  fi

  FUERA=$(grep -o 'fuera_del_sitio=[a-z]*' "${ULTIMO}MANIFEST" 2>/dev/null | cut -d= -f2 || echo "?")
  check "la copia fuera del sitio quedo hecha" "ok" "${FUERA}"
fi

# 3) Disco con aire.
echo "[3/4] Disco"
USO=$(df --output=pcent . | tail -1 | tr -d '[:space:]%')
if [[ "${USO}" -le 85 ]]; then
  info "el disco esta al ${USO}%"
  PASS=$((PASS + 1))
else
  check "el disco por debajo del 85%" "<=85" "${USO}"
fi

# 4) Certificados internos vigentes (la malla rechaza con uno vencido).
echo "[4/4] Certificados"
for certificado in certs/ca.crt certs/gateway.crt certs/iam.crt; do
  if openssl x509 -checkend 1296000 -noout -in "${certificado}" >/dev/null 2>&1; then
    info "$(basename "${certificado}") vence en mas de 15 dias"
    PASS=$((PASS + 1))
  else
    check "$(basename "${certificado}") vigente" ">15 dias" "vence pronto"
  fi
done

echo "================================================================"
printf 'Resultado: \033[32m%d ok\033[0m, \033[31m%d fallos\033[0m\n' "${PASS}" "${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
