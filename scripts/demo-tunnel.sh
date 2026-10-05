#!/bin/bash
# ---------------------------------------------------------------------------
# Tunel publico de demostracion (ADR-0028): comparte la PWA por zrok (100% OSS)
# en https://kubo.shares.zrok.io, sin abrir puertos ni tocar el router.
#
# Requiere el entorno zrok habilitado una sola vez:
#   zrok2 enable <account-token>   (token de myzrok.io)
#
# Uso:  ./kubo-infra/scripts/demo-tunnel.sh [start|stop|status]
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZROK="${ZROK_BIN:-$HOME/.local/bin/zrok2}"
LOG="/tmp/opencode/kubo-zrok.log"
NOMBRE="${KUBO_ZROK_NAME:-public:kubo}"
TARGET="${KUBO_ZROK_TARGET:-http://localhost:3000}"
URL="https://kubo.shares.zrok.io"

case "${1:-status}" in
  start)
    if pgrep -f "zrok2 share public" >/dev/null; then
      echo "[kubo] el tunel ya esta corriendo"
      exit 0
    fi
    nohup "${ZROK}" share public --headless -n "${NOMBRE}" "${TARGET}" > "${LOG}" 2>&1 &
    sleep 6
    echo "[kubo] tunel iniciado: ${URL}"
    ;;
  stop)
    if pkill -f "zrok2 share public"; then
      echo "[kubo] tunel detenido"
    else
      echo "[kubo] no estaba corriendo"
    fi
    ;;
  status)
    if pgrep -f "zrok2 share public" >/dev/null; then
      echo "[kubo] tunel activo: ${URL}"
      curl -s -o /dev/null -w "  ${URL} -> %{http_code}\n" --max-time 20 "${URL}/"
    else
      echo "[kubo] tunel detenido (usa: demo-tunnel.sh start)"
    fi
    ;;
  *)
    echo "uso: demo-tunnel.sh [start|stop|status]" >&2
    exit 2
    ;;
esac
