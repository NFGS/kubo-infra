#!/bin/bash
# ---------------------------------------------------------------------------
# Respaldo completo de Kubo (P-05).
#
#   * PostgreSQL: las tres bases de negocio (kubo_iam, kubo_crm, kubo_erp) en
#     formato custom de pg_dump (comprimido y restaurable con pg_restore).
#   * MongoDB: la proyeccion de analitica (reconstruible desde los eventos,
#     pero se respalda igual).
#   * Configuracion: kubo-infra/.env. Si hay `age` y KUBO_BACKUP_AGE_RECIPIENT,
#     se cifra; si no, se guarda con permisos 600 y se advierte.
#
# Uso:  make backup
# Programacion sugerida: diaria (ver kubo-infra/systemd/kubo-backup.timer).
# Retencion: KUBO_BACKUP_RETENTION_DAYS (por defecto 14).
# ---------------------------------------------------------------------------
set -euo pipefail

WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
BACKUP_ROOT="${KUBO_BACKUP_DIR:-${WORKSPACE_DIR}/kubo-infra/backups}"
STAMP="$(date +%Y-%m-%d_%H%M%S)"
DEST="${BACKUP_ROOT}/${STAMP}"
RETENTION_DAYS="${KUBO_BACKUP_RETENTION_DAYS:-14}"

mkdir -p "${DEST}"
echo "[kubo] respaldando en ${DEST}"

for db in kubo_iam kubo_crm kubo_erp; do
  docker exec kubo-postgres pg_dump -U kubo_root -Fc -d "${db}" > "${DEST}/${db}.dump"
  echo "  postgres: ${db}.dump ($(du -h "${DEST}/${db}.dump" | cut -f1))"
done

docker exec kubo-mongo mongodump --db kubo_analytics --archive --quiet > "${DEST}/kubo_analytics.archive"
echo "  mongo: kubo_analytics.archive ($(du -h "${DEST}/kubo_analytics.archive" | cut -f1))"

# Documentos (P-25): el XML de las facturas y los comprobantes en PDF viven en
# un volumen, no en la base: un respaldo sin ellos no restaura un negocio.
if docker volume inspect kubo_documents >/dev/null 2>&1; then
  docker run --rm -v kubo_documents:/documents:ro -v "${DEST}":/dest alpine \
    tar -czf /dest/documents.tar.gz -C /documents .
  echo "  documentos: documents.tar.gz ($(du -h "${DEST}/documents.tar.gz" | cut -f1))"
fi

if command -v age >/dev/null 2>&1 && [[ -n "${KUBO_BACKUP_AGE_RECIPIENT:-}" ]]; then
  age -r "${KUBO_BACKUP_AGE_RECIPIENT}" -o "${DEST}/env.age" "${WORKSPACE_DIR}/kubo-infra/.env"
  echo "  configuracion: env.age (cifrada con age)"
else
  cp "${WORKSPACE_DIR}/kubo-infra/.env" "${DEST}/env.env"
  chmod 600 "${DEST}/env.env"
  echo "  configuracion: env.env (SIN cifrar; defina KUBO_BACKUP_AGE_RECIPIENT para cifrarla)"
fi

cat > "${DEST}/MANIFEST" <<EOF
fecha=${STAMP}
postgres=kubo_iam.dump,kubo_crm.dump,kubo_erp.dump
mongo=kubo_analytics.archive
documentos=documents.tar.gz
retencion_dias=${RETENTION_DAYS}
verificacion=no_ejecutada
fuera_del_sitio=no_configurada
EOF

# Retencion: se eliminan los respaldos mas viejos que el limite.
if [[ "${RETENTION_DAYS}" =~ ^[0-9]+$ && "${RETENTION_DAYS}" -gt 0 ]]; then
  find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d -mtime "+${RETENTION_DAYS}" -exec rm -rf {} +
  echo "[kubo] retencion aplicada: se conservan ${RETENTION_DAYS} dias"
fi

echo "[kubo] respaldo completo. Verifique la restauracion con: make restore-drill"
