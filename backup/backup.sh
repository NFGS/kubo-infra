#!/bin/bash
# ---------------------------------------------------------------------------
# Ciclo del operador de respaldos (P-05, ADR-0022).
#
#   respaldo -> retencion -> verificacion -> manifiesto
#
# La verificacion RESTAURA los dumps en bases de usar y tirar y compara conteos
# con el origen: un respaldo que no se restaura no es un respaldo. Si falla, el
# ciclo termina con error y el manifiesto lo declara.
#
# Uso:  backup.sh --once    (un ciclo; lo usa `make backup-operator`)
#       backup.sh           (bucle cada KUBO_BACKUP_INTERVAL_HOURS, por defecto 24)
# ---------------------------------------------------------------------------
set -euo pipefail

BACKUP_ROOT="${KUBO_BACKUP_DIR:-/backups}"
RETENTION_DAYS="${KUBO_BACKUP_RETENTION_DAYS:-14}"
KEEP_MIN="${KUBO_BACKUP_KEEP_MIN:-3}"
VERIFY="${KUBO_BACKUP_VERIFY:-true}"
OFFSITE="${KUBO_BACKUP_OFFSITE_DIR:-}"
INTERVAL_H="${KUBO_BACKUP_INTERVAL_HOURS:-24}"

PGHOST="${PGHOST:-postgres}"
PGUSER="${PGUSER:-kubo_root}"
export PGPASSWORD="${KUBO_POSTGRES_ROOT_PASSWORD:-kubo_root_dev}"
MONGO_HOST="${KUBO_MONGO_HOST:-mongo}"
DOCUMENTS_DIR="${KUBO_DOCUMENTS_DIR:-/documents}"
ENV_FILE="${KUBO_ENV_FILE:-/config/.env}"

BASES="kubo_iam kubo_crm kubo_erp"
# Conteos que la verificacion compara (base.tabla): son las tablas que no pueden
# quedar vacias en un negocio real.
CONTEOS="kubo_iam.users kubo_crm.customers kubo_erp.products kubo_erp.sales"

log() { echo "[backup] $*"; }

cuenta() { psql -h "${PGHOST}" -U "${PGUSER}" -d "$1" -tAc "select count(*) from $2" 2>/dev/null | tr -d '[:space:]'; }

# ---------------------------------------------------------------------------
# Verificacion: restaurar en bases de usar y tirar y comparar conteos.
# ---------------------------------------------------------------------------
verificar() {
  local destino="$1" ok=true pares="" base tabla origen restaurado

  for db in ${BASES}; do
    psql -h "${PGHOST}" -U "${PGUSER}" -d postgres -q -c "drop database if exists ${db}_verify" >/dev/null 2>&1 || true
    psql -h "${PGHOST}" -U "${PGUSER}" -d postgres -q -c "create database ${db}_verify" >/dev/null

    if ! pg_restore -h "${PGHOST}" -U "${PGUSER}" -d "${db}_verify" --no-owner --jobs=2 \
         "${destino}/${db}.dump" >/dev/null 2>&1; then
      log "verificacion: no se pudo restaurar ${db}"
      ok=false
    fi
  done

  for par in ${CONTEOS}; do
    base="${par%%.*}"
    tabla="${par##*.}"
    origen="$(cuenta "${base}" "${tabla}")"
    restaurado="$(cuenta "${base}_verify" "${tabla}")"
    pares="${pares}${par}=${origen}/${restaurado},"

    if [[ -z "${origen}" || "${origen}" != "${restaurado}" ]]; then
      log "verificacion: ${par} origen=${origen} restaurado=${restaurado}"
      ok=false
    fi
  done

  for db in ${BASES}; do
    psql -h "${PGHOST}" -U "${PGUSER}" -d postgres -q -c "drop database if exists ${db}_verify" >/dev/null 2>&1 || true
  done

  CONTEOS_RESULTADO="${pares%,}"
  [ "${ok}" = "true" ]
}

# ---------------------------------------------------------------------------
# Retencion: por antiguedad, conservando al menos KEEP_MIN respaldos.
# ---------------------------------------------------------------------------
retener() {
  local dirs=() i
  mapfile -t dirs < <(find "${BACKUP_ROOT}" -mindepth 1 -maxdepth 1 -type d | sort -r)

  for i in "${!dirs[@]}"; do
    if [ "${i}" -ge "${KEEP_MIN}" ] && [ -n "$(find "${dirs[$i]}" -maxdepth 0 -mtime "+${RETENTION_DAYS}")" ]; then
      log "retencion: se elimina $(basename "${dirs[$i]}")"
      rm -rf "${dirs[$i]}"
    fi
  done
}

# ---------------------------------------------------------------------------
# Ciclo
# ---------------------------------------------------------------------------
ciclo() {
  local stamp dest verificacion="omitida" resultado=0
  local OFFSITE_RESULTADO=""
  stamp="$(date +%Y-%m-%d_%H%M%S)"
  dest="${BACKUP_ROOT}/${stamp}"
  mkdir -p "${dest}"
  log "respaldando en ${dest}"

  for db in ${BASES}; do
    pg_dump -h "${PGHOST}" -U "${PGUSER}" -Fc -d "${db}" > "${dest}/${db}.dump"
  done

  if [ -d "${DOCUMENTS_DIR}" ]; then
    tar -czf "${dest}/documents.tar.gz" -C "$(dirname "${DOCUMENTS_DIR}")" "$(basename "${DOCUMENTS_DIR}")"
    log "documentos: $(du -h "${dest}/documents.tar.gz" | cut -f1)"
  fi

  mongodump --host "${MONGO_HOST}" --db kubo_analytics --archive --quiet > "${dest}/kubo_analytics.archive"

  if [ -f "${ENV_FILE}" ]; then
    cp "${ENV_FILE}" "${dest}/env.env"
    chmod 600 "${dest}/env.env"
  fi

  CONTEOS_RESULTADO=""
  if [ "${VERIFY}" = "true" ]; then
    if verificar "${dest}"; then
      verificacion="ok"
      log "verificacion: ok (${CONTEOS_RESULTADO})"
    else
      verificacion="fallida"
      resultado=1
      log "verificacion: FALLIDA"
    fi
  fi

  # Copia fuera del sitio (F6.3): rclone acepta una ruta montada (disco, NFS)
  # o un remoto configurado (s3, b2, drive). La copia se VERIFICA con `rclone
  # check`: un respaldo que no se puede leer en el destino no es un respaldo.
  # Va ANTES del manifiesto para que este declare el resultado real.
  if [ -n "${OFFSITE}" ]; then
    if rclone copy "${dest}" "${OFFSITE}/${stamp}" --no-traverse >/dev/null 2>&1 &&
       rclone check "${dest}" "${OFFSITE}/${stamp}" --size-only >/dev/null 2>&1; then
      OFFSITE_RESULTADO="ok"
      log "copia fuera del sitio verificada en ${OFFSITE}"
    else
      OFFSITE_RESULTADO="fallida"
      resultado=1
      log "copia fuera del sitio FALLIDA en ${OFFSITE}"
    fi
  fi

  {
    echo "fecha=${stamp}"
    echo "postgres=$(printf '%s.dump,' ${BASES} | sed 's/,$//')"
    echo "mongo=kubo_analytics.archive"
    echo "documentos=documents.tar.gz"
    echo "retencion_dias=${RETENTION_DAYS}"
    echo "retencion_minima=${KEEP_MIN}"
    echo "verificacion=${verificacion}"
    echo "conteos=${CONTEOS_RESULTADO}"
    echo "fuera_del_sitio=${OFFSITE_RESULTADO:-no_configurada}"
  } > "${dest}/MANIFEST"

  # Integridad: el hash permite auditar un respaldo viejo sin restaurarlo.
  (cd "${dest}" && sha256sum ./* >> MANIFEST)

  retener
  log "ciclo terminado (verificacion=${verificacion})"
  return "${resultado}"
}

if [ "${1:-}" = "--once" ]; then
  ciclo
else
  while true; do
    ciclo || log "el ciclo fallo; se reintenta en ${INTERVAL_H} h"
    sleep "$((INTERVAL_H * 3600))"
  done
fi
