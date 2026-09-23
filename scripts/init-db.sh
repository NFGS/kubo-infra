#!/bin/bash
# Crea una base de datos y un rol aislado por microservicio (database-per-service).
# Se ejecuta una sola vez, cuando el volumen de Postgres se inicializa.
set -euo pipefail

create_service_db() {
  local name="$1"
  local password="$2"

  echo "[kubo] creando rol y base de datos para ${name}"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname postgres <<-EOSQL
    CREATE ROLE ${name} LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
    CREATE DATABASE ${name} OWNER ${name} ENCODING 'UTF8';
    REVOKE ALL ON DATABASE ${name} FROM PUBLIC;
    GRANT CONNECT ON DATABASE ${name} TO ${name};
EOSQL
}

create_service_db "kubo_iam" "${KUBO_IAM_DB_PASSWORD}"
create_service_db "kubo_crm" "${KUBO_CRM_DB_PASSWORD}"
create_service_db "kubo_erp" "${KUBO_ERP_DB_PASSWORD}"

echo "[kubo] bases de datos listas: kubo_iam, kubo_crm, kubo_erp"
