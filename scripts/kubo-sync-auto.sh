#!/bin/bash
# ---------------------------------------------------------------------------
# Ciclo automatico del sincronizador de los 4 entornos (lo ejecuta el timer
# kubo-sync.timer). Carga el token de Notion y corre `auto --commit`.
#
# Uso:  ./kubo-infra/scripts/kubo-sync-auto.sh
# ---------------------------------------------------------------------------
set -u

if [ -f "$HOME/.config/secrets.env" ]; then
  # shellcheck disable=SC1091
  . "$HOME/.config/secrets.env"
fi

exec "$(dirname "$0")/kubo-sync.sh" auto --commit
