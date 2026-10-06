#!/bin/bash
# ---------------------------------------------------------------------------
# Instala las unidades systemd de usuario de Kubo (tunel, DDNS y sincronizacion).
#
# Copia kubo-infra/systemd/user/* a ~/.config/systemd/user/, recarga el demonio
# y activa los temporizadores. El tunel NO se reinicia: el demo sigue arriba.
#
# Uso:  ./kubo-infra/scripts/instalar-unidades-usuario.sh
# ---------------------------------------------------------------------------
set -euo pipefail

WS="$(cd "$(dirname "$0")/../.." && pwd)"
ORIGEN="$WS/kubo-infra/systemd/user"
DESTINO="$HOME/.config/systemd/user"

if [ ! -d "$ORIGEN" ]; then
  echo "ERROR: no existe $ORIGEN" >&2
  exit 1
fi

mkdir -p "$DESTINO"
for u in "$ORIGEN"/*; do
  cp "$u" "$DESTINO/$(basename "$u")"
  echo "  instalada: $(basename "$u")"
done

systemctl --user daemon-reload
systemctl --user enable --now kubo-ddns.timer kubo-sync.timer
echo
echo "Temporizadores activos:"
systemctl --user list-timers --no-pager 2>/dev/null | grep -E "NEXT|kubo" || true
