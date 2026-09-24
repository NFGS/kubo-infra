#!/bin/bash
# ---------------------------------------------------------------------------
# Pruebas del CRM.
#
#   1. Prueba pura de cifrado de campos (sin base de datos).
#   2. Pruebas de integracion (P-08) contra el PostgreSQL real del compose:
#      aislamiento RLS entre negocios y round-trip del cifrado con indice ciego.
#      La base de test se crea como superusuario (el rol de la aplicacion no
#      puede crear bases) y las pruebas corren como el rol de la aplicacion:
#      un superusuario ignora RLS incluso con FORCE.
#
# Uso:  ./kubo-infra/scripts/crm-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
IMAGEN="kubo-kubo-crm"
RED="${KUBO_NETWORK:-kubo_kubo-net}"
DB_NAME="kubo_crm_test"
DB_USER="kubo_crm"
ROOT_USER="kubo_root"

# Las credenciales reales viven en kubo-infra/.env (el mismo archivo que lee
# compose); se leen clave por clave en lugar de `source`: hay valores con
# espacios (nombres de negocio) y un archivo de entorno no debe ejecutarse.
ENV_FILE="${ROOT}/kubo-infra/.env"

leer_env() {
  local clave="$1" por_defecto="$2" valor=""
  if [[ -f "${ENV_FILE}" ]]; then
    valor="$(grep -E "^${clave}=" "${ENV_FILE}" | tail -1 | cut -d= -f2-)"
  fi
  printf '%s' "${valor:-${por_defecto}}"
}

DB_PASSWORD="$(leer_env KUBO_CRM_DB_PASSWORD kubo_crm_dev)"
ROOT_PASSWORD="$(leer_env KUBO_POSTGRES_ROOT_PASSWORD kubo_root_dev)"

echo "[crm-tests] prueba pura de cifrado"
docker run --rm \
  -v "${ROOT}/kubo-crm/test:/app/test:ro" \
  -v "${ROOT}/kubo-crm/app:/app/app:ro" \
  --entrypoint ruby "${IMAGEN}" test/field_cipher_test.rb

if ! docker ps --format '{{.Names}}' | grep -q '^kubo-postgres$'; then
  echo "[crm-tests] kubo-postgres no esta corriendo: se omiten las pruebas de integracion"
  exit 0
fi

echo "[crm-tests] preparando ${DB_NAME} con dueno ${DB_USER}"
existe="$(docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
  psql -U "${ROOT_USER}" -d postgres -tAc "select 1 from pg_database where datname='${DB_NAME}'")"
if [[ "${existe}" != "1" ]]; then
  docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
    psql -U "${ROOT_USER}" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE ${DB_NAME} OWNER ${DB_USER} ENCODING 'UTF8'"
fi

# Se montan `test/`, `db/` y `config/` para usar el arbol de trabajo, no lo que
# quedo horneado en la imagen (que se construye en produccion).
echo "[crm-tests] pruebas de integracion contra PostgreSQL real"
docker run --rm --network "${RED}" \
  -e RAILS_ENV=test \
  -e TEST_DATABASE_URL="postgres://${DB_USER}:${DB_PASSWORD}@postgres:5432/${DB_NAME}" \
  -v "${ROOT}/kubo-crm/test:/app/test:ro" \
  -v "${ROOT}/kubo-crm/db:/app/db:ro" \
  -v "${ROOT}/kubo-crm/config:/app/config:ro" \
  --entrypoint bash "${IMAGEN}" -c \
  'cd /app && bundle exec rails db:migrate >/dev/null && bundle exec ruby test/integration/rls_and_cipher_test.rb'
