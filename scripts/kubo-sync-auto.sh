#!/bin/bash
# ---------------------------------------------------------------------------
# Ciclo automatico del sincronizador de los 4 entornos (lo ejecuta el timer
# kubo-sync.timer). Carga el token de Notion y corre `auto --commit`.
#
# Uso:  ./kubo-infra/scripts/kubo-sync-auto.sh
# ---------------------------------------------------------------------------
set -u

# `set -a` exporta todo lo que se asigne al sourcear: secrets.env no marca
# todas sus lineas con `export` y sin esto el token no llega al hijo (exec).
if [ -f "$HOME/.config/secrets.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/secrets.env"
  set +a
fi

exec "$(dirname "$0")/kubo-sync.sh" auto --commit
