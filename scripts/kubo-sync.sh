#!/bin/bash
# ---------------------------------------------------------------------------
# Sincroniza los 4 entornos de Kubo.
#
#   Canónico   directorio del proyecto (repos git locales)
#   Espejos    GitHub (push) · Notion · Obsidian
#
# Cada espejo guarda la HUELLA de las fuentes canónicas con la que fue
# generado; `status` la compara y `run` propaga solo lo que está desviado.
# Los cambios hechos a mano en Notion/Obsidian se detectan como desvío (la
# huella no coincide) y se regeneran desde el repositorio: la fuente de verdad
# es el directorio del proyecto.
#
# Uso:
#   ./kubo-infra/scripts/kubo-sync.sh status [--json]
#   ./kubo-infra/scripts/kubo-sync.sh run [--commit] [--force]
#   ./kubo-infra/scripts/kubo-sync.sh watch [--commit] [--interval 30]
# ---------------------------------------------------------------------------
set -uo pipefail

WS="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${KUBO_SYNC_STATE:-$HOME/.config/opencode/kubo-sync}"
STATE="$STATE_DIR/state.json"
ROOT="${KUBO_NOTION_PAGE:-3ef7d55f-d95e-8040-b09e-d5fb5e2dbdb1}"
VAULT="${KUBO_VAULT:-$HOME/Documents/Obsidian Vaults/Ningendo Bee}"
REPOS=(. kubo-gateway kubo-iam kubo-crm kubo-erp kubo-analytics kubo-web kubo-infra kubo-docs)

fingerprint() { # huella de las fuentes canonicas (16 hex)
  {
    cat "$WS/README.md" 2>/dev/null
    for f in "$WS"/kubo-docs/*.md "$WS"/kubo-docs/adr/*.md \
             "$WS"/kubo-docs/evidencia/README.md "$WS"/kubo-docs/diagramas/README.md; do
      [ -f "$f" ] && cat "$f"
    done
    for r in "${REPOS[@]:1}"; do cat "$WS/$r/README.md" 2>/dev/null; done
  } | sha256sum | cut -c1-16
}

state_fp() { [ -f "$STATE" ] && jq -r '.fingerprint // empty' "$STATE" 2>/dev/null || true; }
state_ts() { [ -f "$STATE" ] && jq -r '.updated_at // "nunca"' "$STATE" 2>/dev/null || echo "nunca"; }
save_state() {
  mkdir -p "$STATE_DIR"
  jq -n --arg fp "$1" --arg ts "$(date -Is)" '{fingerprint:$fp, updated_at:$ts}' > "$STATE"
}

git_line() { # repo -> "sucio adelante atras"
  local d="$1" s a b
  s=$(git -C "$WS/$d" status --porcelain 2>/dev/null | wc -l)
  a=$(git -C "$WS/$d" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
  b=$(git -C "$WS/$d" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)
  echo "$s $a $b"
}

notion_fp() {
  [ -n "${NOTION_KUBO_TOKEN:-}" ] || return 0
  curl -sS --max-time 60 "https://api.notion.com/v1/pages/$ROOT/markdown" \
    -H "Authorization: Bearer ${NOTION_KUBO_TOKEN}" \
    -H "Notion-Version: 2026-03-11" 2>/dev/null \
    | jq -r '.markdown // ""' 2>/dev/null \
    | grep -oE '`[a-f0-9]{16}`' | tr -d '`' | head -1
}

obsidian_fp() {
  local hub="$VAULT/Kubo/README.md"
  [ -f "$hub" ] && grep -m1 '^huella:' "$hub" | awk '{print $2}' || true
}

do_status() {
  local fp nf of veredicto="SINCRONIZADO"
  fp=$(fingerprint)
  nf=$(notion_fp)
  of=$(obsidian_fp)

  echo "Kubo · sincronización de los 4 entornos"
  echo "================================================================"
  echo "Canónico (local):  huella ${fp} · última sincronización: $(state_ts) ($(state_fp))"
  echo
  echo "GitHub:"
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    local marca="ok"
    [ "$s" != "0" ] && marca="sucio=$s"
    [ "$a" != "0" ] && marca="$marca adelante=$a"
    [ "$b" != "0" ] && marca="$marca atras=$b"
    [ "$marca" != "ok" ] && veredicto="PENDIENTE"
    printf "  %-14s %s\n" "$d" "$marca"
  done
  echo
  local nv="ok" ov="ok"
  [ "$nf" != "$fp" ] && nv="DESVIADO" && veredicto="PENDIENTE"
  [ "$of" != "$fp" ] && ov="DESVIADO" && veredicto="PENDIENTE"
  echo "Notion:    huella ${nf:-desconocida} -> $nv"
  echo "Obsidian:  huella ${of:-desconocida} -> $ov"
  echo
  echo "Veredicto: $veredicto"
  [ "$veredicto" = "SINCRONIZADO" ] && return 0 || return 1
}

do_run() {
  local commit="$1" force="$2" fp nf of cambio=0
  fp=$(fingerprint)
  nf=$(notion_fp)
  of=$(obsidian_fp)

  if [ "$force" = "1" ] || [ "$fp" != "$(state_fp)" ]; then
    echo "[1/4] PDF consolidado"
    (cd "$WS" && make pdf) | tail -2
    cambio=1
  fi

  if [ "$force" = "1" ] || [ "$fp" != "$(state_fp)" ] || [ "$nf" != "$fp" ]; then
    echo "[2/4] Notion"
    KUBO_SYNC_FINGERPRINT="$fp" "$WS/kubo-infra/scripts/notion-sync.sh" | tail -3
    cambio=1
  else
    echo "[2/4] Notion: al día"
  fi

  if [ "$force" = "1" ] || [ "$fp" != "$(state_fp)" ] || [ "$of" != "$fp" ]; then
    echo "[3/4] Obsidian"
    KUBO_SYNC_FINGERPRINT="$fp" "$WS/kubo-infra/scripts/obsidian-sync.sh" | tail -2
    cambio=1
  else
    echo "[3/4] Obsidian: al día"
  fi

  if [ "$cambio" = "1" ]; then
    save_state "$fp"
    echo "[4/4] Estado guardado: huella $fp"
  else
    echo "[4/4] Sin cambios canónicos: nada que propagar"
  fi

  # GitHub: commits pendientes y cambios sucios
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    if [ "$s" != "0" ] && [ "$commit" = "1" ]; then
      git -C "$WS/$d" add -A
      git -C "$WS/$d" commit -m "sync: cambios locales desde kubo-sync" --quiet
      echo "  $d: commit creado"
      a=$((a + 1))
    elif [ "$s" != "0" ]; then
      echo "  AVISO: $d tiene $s archivo(s) sin commitear (usa --commit o commitea tú)"
    fi
    if [ "$a" != "0" ]; then
      if env -u GITHUB_TOKEN git -C "$WS/$d" push origin main >/dev/null 2>&1; then
        echo "  $d: push OK ($a commit(s))"
      else
        echo "  ERROR: no se pudo empujar $d ($a commit(s) pendientes)"
      fi
    fi
    if [ "$b" != "0" ]; then
      echo "  AVISO: $d está $b commit(s) atrás de origin/main (haz git pull)"
    fi
  done
}

COMANDO="${1:-status}"
COMMIT=0
FORCE=0
INTERVALO=30
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --commit) COMMIT=1 ;;
    --force) FORCE=1 ;;
    --interval) INTERVALO="$2"; shift ;;
  esac
  shift
done

case "$COMANDO" in
  status) do_status ;;
  run) do_run "$COMMIT" "$FORCE" ;;
  watch)
    echo "Vigilando cambios (cada ${INTERVALO}s). Ctrl-C para salir."
    while :; do
      fp=$(fingerprint)
      hay_sucio=0
      for d in "${REPOS[@]}"; do
        read -r s _ _ <<< "$(git_line "$d")"
        [ "$s" != "0" ] && hay_sucio=1
      done
      if [ "$fp" != "$(state_fp)" ] || [ "$hay_sucio" = "1" ]; then
        echo "[$(date +%H:%M:%S)] cambio detectado (huella $fp)"
        do_run "$COMMIT" 0
      fi
      sleep "$INTERVALO"
    done
    ;;
  *)
    echo "Uso: kubo-sync.sh [status|run|watch] [--commit] [--force] [--interval N]" >&2
    exit 2
    ;;
esac
