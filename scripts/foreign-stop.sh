#!/bin/bash
# Detiene contenedores ajenos al proyecto para liberar RAM durante la demo.
# Guarda la lista en un archivo para poder reactivarlos despues.
set -uo pipefail

STATE_FILE="$(dirname "$0")/../.foreign-stopped"

CONTAINERS=(
  guacd
  guacamole
  guacamole-postgres
  open-notebook-open_notebook-1
  open-notebook-surrealdb-1
  recuca_app
  recuca_db
)

: > "${STATE_FILE}"
for c in "${CONTAINERS[@]}"; do
  if docker ps --format '{{.Names}}' | grep -qx "$c"; then
    docker stop "$c" >/dev/null 2>&1 && echo "[kubo] detenido: $c" && echo "$c" >> "${STATE_FILE}"
  fi
done

echo "[kubo] contenedores ajenos detenidos. Reactivar con: make foreign-start"
free -h | head -2
