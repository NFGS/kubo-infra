#!/bin/bash
# Reactiva los contenedores que se detuvieron con foreign-stop.sh
set -uo pipefail

STATE_FILE="$(dirname "$0")/../.foreign-stopped"

if [[ ! -f "${STATE_FILE}" ]]; then
  echo "[kubo] no hay contenedores por reactivar"
  exit 0
fi

while read -r c; do
  [[ -z "$c" ]] && continue
  docker start "$c" >/dev/null 2>&1 && echo "[kubo] reactivado: $c"
done < "${STATE_FILE}"

rm -f "${STATE_FILE}"
echo "[kubo] contenedores ajenos reactivados"
