#!/bin/bash
# ---------------------------------------------------------------------------
# Simulacro de restauracion (P-05). Un respaldo sin restaurar no es un respaldo.
#
# Toma un respaldo nuevo, lo restaura en bases de prueba (kubo_drill_*), compara
# el numero de filas de las tablas clave y mide el tiempo total. Al terminar
# elimina las bases de prueba: la base real no se toca en ningun momento.
#
# Objetivo: RPO 24 h · RTO 4 h. Este simulacro debe terminar en minutos.
#
# Uso:  make restore-drill
# ---------------------------------------------------------------------------
set -uo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DRILL_DIR="$(mktemp -d)"
PASS=0
FAIL=0

ok() { printf '  \033[32mPASA\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31mFALLA\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

cleanup() {
  if [[ "${KUBO_KEEP_DRILL:-}" == "true" ]]; then
    echo "[kubo] KUBO_KEEP_DRILL=true: se conservan ${DRILL_DIR} y las bases kubo_drill_*"
    return
  fi
  for db in kubo_drill_iam kubo_drill_crm kubo_drill_erp; do
    docker exec kubo-postgres psql -U kubo_root -d postgres -q -c "DROP DATABASE IF EXISTS ${db};" >/dev/null 2>&1
  done
  docker exec kubo-mongo mongosh kubo_analytics_drill --quiet --eval "db.dropDatabase()" >/dev/null 2>&1
  rm -rf "${DRILL_DIR}"
}
trap cleanup EXIT

echo
echo "Kubo · simulacro de restauracion"
echo "================================================================"

INICIO=$(date +%s)

echo "[1/5] respaldo de origen"
for db in kubo_iam kubo_crm kubo_erp; do
  docker exec kubo-postgres pg_dump -U kubo_root -Fc -d "${db}" > "${DRILL_DIR}/${db}.dump"
done
docker exec kubo-mongo mongodump --db kubo_analytics --archive --quiet > "${DRILL_DIR}/analytics.archive"
ok "respaldo tomado"

echo "[2/5] creando bases de prueba"
for db in kubo_drill_iam kubo_drill_crm kubo_drill_erp; do
  docker exec kubo-postgres psql -U kubo_root -d postgres -q \
    -c "DROP DATABASE IF EXISTS ${db};" -c "CREATE DATABASE ${db};"
done
ok "bases kubo_drill_* creadas"

echo "[3/5] restaurando"
for par in "kubo_iam:kubo_drill_iam" "kubo_crm:kubo_drill_crm" "kubo_erp:kubo_drill_erp"; do
  origen="${par%%:*}"
  destino="${par##*:}"
  if docker exec -i kubo-postgres pg_restore -U kubo_root -d "${destino}" \
       --no-owner --no-privileges < "${DRILL_DIR}/${origen}.dump" 2>"${DRILL_DIR}/${origen}.err"; then
    ok "postgres: ${origen} restaurado"
  else
    ko "postgres: fallo la restauracion de ${origen} ($(tail -1 "${DRILL_DIR}/${origen}.err"))"
  fi
done

if docker exec -i kubo-mongo mongorestore --archive --quiet \
     --nsFrom 'kubo_analytics.*' --nsTo 'kubo_analytics_drill.*' \
     < "${DRILL_DIR}/analytics.archive" >/dev/null 2>&1; then
  ok "mongo: analitica restaurada"
else
  ko "mongo: fallo la restauracion de analitica"
fi

echo "[4/5] comparando contenido"
comparar() {
  local descripcion="$1" origen_db="$2" destino_db="$3" tabla="$4"
  local origen destino
  origen=$(docker exec kubo-postgres psql -U kubo_root -d "${origen_db}" -tAc "select count(*) from ${tabla}" 2>/dev/null | tr -d '[:space:]')
  destino=$(docker exec kubo-postgres psql -U kubo_root -d "${destino_db}" -tAc "select count(*) from ${tabla}" 2>/dev/null | tr -d '[:space:]')
  if [[ -n "${origen}" && "${origen}" == "${destino}" ]]; then
    ok "${descripcion}: ${origen} filas"
  else
    ko "${descripcion}: origen=${origen:-?} restaurado=${destino:-?}"
  fi
}

comparar "IAM usuarios"   kubo_iam kubo_drill_iam "users"
comparar "IAM auditoria"  kubo_iam kubo_drill_iam "audit_logs"
comparar "CRM clientes"   kubo_crm kubo_drill_crm "customers"
comparar "ERP productos"  kubo_erp kubo_drill_erp "products"
comparar "ERP ventas"     kubo_erp kubo_drill_erp "sales"
comparar "ERP kardex"     kubo_erp kubo_drill_erp "stock_movements"

EVENTOS_ORIGEN=$(docker exec kubo-mongo mongosh kubo_analytics --quiet --eval "db.events.countDocuments()" 2>/dev/null | tr -d '[:space:]')
EVENTOS_DESTINO=$(docker exec kubo-mongo mongosh kubo_analytics_drill --quiet --eval "db.events.countDocuments()" 2>/dev/null | tr -d '[:space:]')
if [[ -n "${EVENTOS_ORIGEN}" && "${EVENTOS_ORIGEN}" == "${EVENTOS_DESTINO}" ]]; then
  ok "Analitica eventos: ${EVENTOS_ORIGEN} documentos"
else
  ko "Analitica eventos: origen=${EVENTOS_ORIGEN:-?} restaurado=${EVENTOS_DESTINO:-?}"
fi

FIN=$(date +%s)
SEGUNDOS=$((FIN - INICIO))

echo "[5/5] resultado"
if [[ "${SEGUNDOS}" -lt 14400 ]]; then
  ok "RTO del simulacro: ${SEGUNDOS}s (objetivo < 4 h)"
else
  ko "RTO del simulacro: ${SEGUNDOS}s supera las 4 h"
fi

echo
echo "================================================================"
printf 'Resultado: \033[32m%d pruebas exitosas\033[0m, \033[31m%d fallidas\033[0m · tiempo %ds\n' "${PASS}" "${FAIL}" "${SEGUNDOS}"
echo

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
