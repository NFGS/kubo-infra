#!/bin/bash
# ---------------------------------------------------------------------------
# Gate local de calidad (P-06): las mismas verificaciones que bloquean el merge
# en GitLab, ejecutables en la maquina del desarrollador.
#
#   1. Escaneo de secretos.
#   2. Suites unitarias e integracion de los cinco servicios + web.
#   3. Contratos OpenAPI contra el sistema levantado.
#   4. Prueba de humo end-to-end.
#   5. E2E de navegador con auditoria de accesibilidad (Playwright + axe).
#
# Uso:  make ci
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

ok() { printf '  \033[32mPASA\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31mFALLA\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

paso() {
  local descripcion="$1"
  shift
  if "$@" >/tmp/kubo-ci-paso.log 2>&1; then
    ok "${descripcion}"
  else
    ko "${descripcion} (ver /tmp/kubo-ci-paso.log)"
    tail -5 /tmp/kubo-ci-paso.log | sed 's/^/         /'
  fi
}

echo
echo "Kubo · gate local de calidad"
echo "================================================================"

echo "[1/5] secretos"
"${ROOT}/kubo-infra/scripts/secret-scan.sh" >/tmp/kubo-ci-secretos.log 2>&1
if [[ $? -eq 0 ]]; then
  ok "escaneo de secretos sin hallazgos"
else
  ko "el escaneo de secretos encontro hallazgos"
  grep "FALLA" /tmp/kubo-ci-secretos.log | sed 's/^/         /'
fi

echo "[2/5] pruebas unitarias e integracion"
paso "kubo-gateway (typecheck + tests)" bash -c "cd '${ROOT}/kubo-gateway' && npm run typecheck && npm test"
paso "kubo-iam (mvn verify: unitarias + Testcontainers + cobertura >= 80%)" bash -c "cd '${ROOT}/kubo-iam' && mvn -q verify"
paso "kubo-crm (cifrado de campos)" bash -c "cd '${ROOT}/kubo-crm' && ruby test/field_cipher_test.rb"
paso "kubo-erp (dinero, outbox, paginacion)" "${ROOT}/kubo-infra/scripts/erp-tests.sh"

if python3 -c "import pytest" >/dev/null 2>&1; then
  paso "kubo-analytics (pytest + cobertura de dominio >= 80%)" bash -c "cd '${ROOT}/kubo-analytics' && python3 -m pytest -q --cov=app.processing --cov-fail-under=80"
else
  printf '  \033[33mOMITIDO\033[0m kubo-analytics: falta pytest (pip install -r requirements-dev.txt)\n'
fi
paso "kubo-web (typecheck)" bash -c "cd '${ROOT}/kubo-web' && npm run typecheck"

echo "[3/5] contratos OpenAPI"
paso "contratos contra el sistema en ejecucion" bash -c "cd '${ROOT}' && node kubo-gateway/scripts/contracts.mjs"

echo "[4/5] prueba de humo"
paso "humo end-to-end" bash -c "'${ROOT}/kubo-infra/scripts/smoke.sh'"

echo "[5/5] E2E y accesibilidad"
# Cada pantalla restaura la sesion (refresh + me) y eso consume el limite de
# autenticacion; se eleva solo durante la corrida y se restaura al terminar.
COMPOSE_FILE="${ROOT}/kubo-infra/docker-compose.yml"
KUBO_AUTH_RATE_LIMIT_PER_MINUTE=1000000 docker compose -f "${COMPOSE_FILE}" up -d kubo-gateway >/dev/null 2>&1
sleep 5
paso "kubo-web (Playwright + axe)" bash -c "cd '${ROOT}/kubo-web' && npx playwright test"
KUBO_AUTH_RATE_LIMIT_PER_MINUTE=40 docker compose -f "${COMPOSE_FILE}" up -d kubo-gateway >/dev/null 2>&1

echo "================================================================"
printf 'Resultado: \033[32m%d verificaciones\033[0m, \033[31m%d fallos\033[0m\n\n' "${PASS}" "${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
