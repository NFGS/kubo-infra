#!/bin/bash
# ---------------------------------------------------------------------------
# Pruebas del ERP.
#
#   1. Pruebas puras (dinero, outbox y paginacion) sin base de datos: la imagen
#      de ejecucion no incluye test/ y el contenedor de produccion se queda sin
#      memoria al compilar el entorno de pruebas, asi que se ejecuta con 3 GB y
#      el directorio de pruebas montado.
#   2. Pruebas de integracion (P-08) contra el PostgreSQL real del compose:
#      RLS, numeracion atomica por negocio, atomicidad de la bandeja de salida y
#      kardex. La base de test se crea como superusuario (el rol de la aplicacion
#      no puede crear bases) y las pruebas corren como el rol de la aplicacion:
#      un superusuario ignora RLS incluso con FORCE.
#
# Uso:  ./kubo-infra/scripts/erp-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGEN="kubo-kubo-erp"
RED="${KUBO_NETWORK:-kubo_kubo-net}"
DB_NAME="kubo_erp_test"
DB_USER="kubo_erp"
ROOT_USER="kubo_root"

# Las credenciales reales viven en kubo-infra/.env (el mismo archivo que lee
# compose); los valores por defecto solo aplican en un clon sin .env. Se leen
# clave por clave en lugar de `source`: hay valores con espacios (nombres de
# negocio) y un archivo de entorno no debe ejecutarse como shell.
ENV_FILE="${ROOT}/kubo-infra/.env"

leer_env() {
  local clave="$1" por_defecto="$2" valor=""
  if [[ -f "${ENV_FILE}" ]]; then
    valor="$(grep -E "^${clave}=" "${ENV_FILE}" | tail -1 | cut -d= -f2-)"
  fi
  printf '%s' "${valor:-${por_defecto}}"
}

DB_PASSWORD="$(leer_env KUBO_ERP_DB_PASSWORD kubo_erp_dev)"
ROOT_PASSWORD="$(leer_env KUBO_POSTGRES_ROOT_PASSWORD kubo_root_dev)"

echo "[erp-tests] pruebas puras (sin base de datos)"
docker run --rm -m 3g -e MIX_ENV=test \
  -v "${ROOT}/kubo-erp/test:/app/test:ro" \
  --entrypoint bash "${IMAGEN}" -c 'cd /app && mix compile >/dev/null 2>&1 && ERL_LIBS=/app/_build/test/lib elixir -e "ExUnit.start(); Code.require_file(\"test/kubo_erp/sales_totals_test.exs\"); Code.require_file(\"test/kubo_erp/outbox_test.exs\"); Code.require_file(\"test/kubo_erp/pagination_test.exs\"); Code.require_file(\"test/kubo_erp/packs_test.exs\")"'

if ! docker ps --format '{{.Names}}' | grep -q '^kubo-postgres$'; then
  echo "[erp-tests] kubo-postgres no esta corriendo: se omiten las pruebas de integracion"
  exit 0
fi

echo "[erp-tests] preparando ${DB_NAME} con dueno ${DB_USER}"
existe="$(docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
  psql -U "${ROOT_USER}" -d postgres -tAc "select 1 from pg_database where datname='${DB_NAME}'")"
if [[ "${existe}" != "1" ]]; then
  docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
    psql -U "${ROOT_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8'"
fi

# Se monta `config/` ademas de `test/`: la imagen se compila en MIX_ENV=prod y
# su config/test.exs puede estar desactualizado respecto al arbol de trabajo.
echo "[erp-tests] pruebas de integracion contra PostgreSQL real"
docker run --rm -m 3g --network "${RED}" \
  -e MIX_ENV=test \
  -e TEST_DB_HOST=postgres -e TEST_DB_USER="${DB_USER}" \
  -e TEST_DB_PASSWORD="${DB_PASSWORD}" -e TEST_DB_NAME="${DB_NAME}" \
  -v "${ROOT}/kubo-erp/test:/app/test:ro" \
  -v "${ROOT}/kubo-erp/config:/app/config:ro" \
  --entrypoint bash "${IMAGEN}" -c 'cd /app && mix ecto.migrate >/dev/null && mix test test/kubo_erp/integration'
