#!/bin/bash
# ---------------------------------------------------------------------------
# Sincroniza los 4 entornos de Kubo (bidireccional: ADR-0027 + ADR-0030).
#
#   Canónico   directorio del proyecto (repos git locales)
#   Espejos    GitHub (push/pull) · Notion · Obsidian
#
# Direcciones:
#   local -> espejos   `run` propaga los cambios canónicos (huella).
#   espejos -> local   `pull` importa cambios hechos a mano en Notion/Obsidian
#                      (con staging de conflictos en .sync/conflictos/) y
#                      actualiza los repos desde GitHub (fast-forward).
#   ciclo completo     `auto` = check + pull + run (lo que ejecuta el timer).
#
# Política de conflictos: nada se pisa en silencio. Si el mismo ítem cambió en
# dos entornos, o el viaje de ida y vuelta perdería información (diagramas
# Mermaid en Notion), la versión del espejo se guarda en .sync/conflictos/ y
# se reporta; el usuario resuelve y vuelve a sincronizar.
#
# Uso:
#   ./kubo-infra/scripts/kubo-sync.sh status              (rápido: huellas + git)
#   ./kubo-infra/scripts/kubo-sync.sh check               (profundo: deriva)
#   ./kubo-infra/scripts/kubo-sync.sh pull                (espejos -> local)
#   ./kubo-infra/scripts/kubo-sync.sh run [--commit] [--force]
#   ./kubo-infra/scripts/kubo-sync.sh auto [--commit]     (para el timer)
#   ./kubo-infra/scripts/kubo-sync.sh watch [--interval N]
# ---------------------------------------------------------------------------
set -uo pipefail

WS="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${KUBO_SYNC_STATE:-$HOME/.config/opencode/kubo-sync}"
STATE="$STATE_DIR/state.json"
FILES_BASE="$STATE_DIR/files-baseline.json"
ROOT="${KUBO_NOTION_PAGE:-3ef7d55f-d95e-8040-b09e-d5fb5e2dbdb1}"
VAULT="${KUBO_VAULT:-$HOME/Documents/Obsidian Vaults/Ningendo Bee}"
REPOS=(. kubo-gateway kubo-iam kubo-crm kubo-erp kubo-analytics kubo-web kubo-infra kubo-docs)
CONF_DIR="$WS/.sync/conflictos"

# Candado: un solo ciclo a la vez. Evita la carrera timer <-> sync manual que
# el 2026-10-07 importo paginas a medio escribir (ADR-0030, actualizacion).
mkdir -p "$STATE_DIR"
exec 9>"$STATE_DIR/lock"
if ! flock -n 9; then
  echo "Kubo sync: hay otro ciclo en curso; se omite esta ejecución."
  exit 0
fi

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

fetch_all() { # trae origin/main de los 9 repos (silencioso y tolerante a fallos)
  local d
  for d in "${REPOS[@]}"; do
    timeout 25 git -C "$WS/$d" fetch --quiet origin main 2>/dev/null || true
  done
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

indent() { # sangra la entrada estandar sin subprocesos: journald atribuye mal
           # las lineas de procesos muy cortos (p. ej. sed) en las unidades
  local linea
  while IFS= read -r linea; do echo "  $linea"; done
}

write_files_baseline() { # sha256 por archivo canonico (para detectar conflictos)
  mkdir -p "$STATE_DIR"
  python3 - "$WS" "$FILES_BASE" <<'PY'
import hashlib, json, os, sys

ws, out = sys.argv[1], sys.argv[2]
rel = ["README.md", "kubo-docs/evidencia/README.md", "kubo-docs/diagramas/README.md"]
rel += [f"kubo-docs/{f}" for f in sorted(os.listdir(os.path.join(ws, "kubo-docs"))) if f.endswith(".md")]
rel += [f"kubo-docs/adr/{f}" for f in sorted(os.listdir(os.path.join(ws, "kubo-docs", "adr"))) if f.endswith(".md")]
rel += [f"{r}/README.md" for r in ("kubo-gateway", "kubo-iam", "kubo-crm", "kubo-erp",
                                   "kubo-analytics", "kubo-web", "kubo-infra", "kubo-docs")]
d = {}
for f in rel:
    p = os.path.join(ws, f)
    if os.path.isfile(p):
        d[f] = hashlib.sha256(open(p, "rb").read()).hexdigest()
json.dump(d, open(out, "w", encoding="utf-8"), indent=1, sort_keys=True)
PY
}

# --- status (rápido) ---------------------------------------------------------
do_status() {
  local fp nf of veredicto="SINCRONIZADO" d s a b marca
  fp=$(fingerprint)
  nf=$(notion_fp)
  of=$(obsidian_fp)
  fetch_all

  echo "Kubo · sincronización de los 4 entornos"
  echo "================================================================"
  echo "Canónico (local):  huella ${fp} · última sincronización: $(state_ts) ($(state_fp))"
  echo
  echo "GitHub:"
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    marca="ok"
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
  echo "Deriva por ediciones manuales: usa 'make sync-check' (chequeo profundo)"
  echo "Veredicto: $veredicto"
  [ "$veredicto" = "SINCRONIZADO" ] && return 0 || return 1
}

# --- check (profundo) --------------------------------------------------------
do_check() {
  local fp veredicto="SINCRONIZADO" d s a b marca nout oout
  fp=$(fingerprint)

  echo "Kubo · chequeo de los 4 entornos"
  echo "================================================================"
  echo "Canónico (local):  huella ${fp} · último sync: $(state_ts)"
  if [ "$fp" != "$(state_fp)" ]; then
    veredicto="PENDIENTE"
    echo "  CAMBIÓ desde el último sync. Archivos:"
    if [ -f "$FILES_BASE" ]; then
      python3 - "$WS" "$FILES_BASE" <<'PY' | sed 's/^/    /'
import hashlib, json, os, sys

ws, base = sys.argv[1], sys.argv[2]
d = json.load(open(base, encoding="utf-8"))
cambios = []
for f, h in d.items():
    p = os.path.join(ws, f)
    cur = hashlib.sha256(open(p, "rb").read()).hexdigest() if os.path.isfile(p) else None
    if cur != h:
        cambios.append(f)
print("\n".join(cambios) if cambios else "(solo archivos fuera de la línea base)")
PY
    fi
  else
    echo "  al día"
  fi

  echo
  echo "GitHub (con fetch):"
  fetch_all
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    marca="ok"
    [ "$s" != "0" ] && marca="sucio=$s"
    [ "$a" != "0" ] && marca="$marca adelante=$a"
    [ "$b" != "0" ] && marca="$marca atras=$b"
    [ "$marca" != "ok" ] && veredicto="PENDIENTE"
    printf "  %-14s %s\n" "$d" "$marca"
  done

  echo
  echo "Notion (deriva):"
  nout=$(KUBO_SYNC_STATE="$STATE_DIR" "$WS/kubo-infra/scripts/notion-pull.sh" check 2>&1)
  indent <<< "$nout"
  if echo "$nout" | grep -q 'importables=0 regenerables=0'; then :; else
    veredicto="PENDIENTE"
    echo "$nout" | grep -q 'NOTION:' || echo "  ERROR: el chequeo de Notion no produjo resultado (¿token?)"
  fi

  echo
  echo "Obsidian (deriva):"
  oout=$(KUBO_SYNC_STATE="$STATE_DIR" KUBO_VAULT="$VAULT" "$WS/kubo-infra/scripts/obsidian-pull.sh" check 2>&1)
  indent <<< "$oout"
  if echo "$oout" | grep -q 'editadas=0'; then :; else
    veredicto="PENDIENTE"
    echo "$oout" | grep -q 'OBSIDIAN:' || echo "  ERROR: el chequeo de Obsidian no produjo resultado"
  fi

  echo
  echo "Veredicto: $veredicto"
  [ "$veredicto" = "SINCRONIZADO" ]
}

# --- pull (espejos -> local) -------------------------------------------------
do_pull() {
  local conflictos=0 actualizados=0 d s a b nout oout

  echo "Kubo · importando cambios de los espejos"
  echo "================================================================"

  echo "[1/3] GitHub (fast-forward)"
  fetch_all
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    if [ "$b" != "0" ]; then
      if [ "$a" != "0" ]; then
        echo "  CONFLICTO $d: divergido ($a locales / $b remotos); resuélvelo a mano"
        conflictos=$((conflictos + 1))
      elif [ "$s" != "0" ]; then
        echo "  CONFLICTO $d: atras=$b pero hay $s archivo(s) sin commitear"
        conflictos=$((conflictos + 1))
      elif env -u GITHUB_TOKEN git -C "$WS/$d" pull --ff-only --quiet origin main 2>/dev/null; then
        echo "  $d: actualizado (fast-forward, $b commit(s))"
        actualizados=$((actualizados + 1))
      else
        echo "  CONFLICTO $d: el fast-forward falló"
        conflictos=$((conflictos + 1))
      fi
    fi
  done
  [ "$actualizados" -eq 0 ] && echo "  (sin novedades remotas)"

  echo "[2/3] Notion"
  nout=$(KUBO_SYNC_STATE="$STATE_DIR" "$WS/kubo-infra/scripts/notion-pull.sh" pull 2>&1)
  indent <<< "$nout"
  echo "$nout" | grep -q 'conflictos=0' || conflictos=$((conflictos + 1))

  echo "[3/3] Obsidian"
  oout=$(KUBO_SYNC_STATE="$STATE_DIR" KUBO_VAULT="$VAULT" "$WS/kubo-infra/scripts/obsidian-pull.sh" pull 2>&1)
  indent <<< "$oout"
  echo "$oout" | grep -q 'conflictos=0' || conflictos=$((conflictos + 1))

  echo
  if [ "$conflictos" -eq 0 ]; then
    echo "Importación completa sin conflictos (ejecuta make sync para propagar)"
    return 0
  fi
  echo "CONFLICTOS: $conflictos (revisa $CONF_DIR/)"
  return 1
}

# --- run (local -> espejos) --------------------------------------------------
do_run() {
  local commit="$1" force="$2" fp nf of cambio=0 d s a b
  fp=$(fingerprint)
  nf=$(notion_fp)
  of=$(obsidian_fp)

  if [ "$force" = "1" ] || ! "$WS/kubo-docs/scripts/check-pdf.sh" >/dev/null 2>&1; then
    echo "[1/4] PDF consolidado"
    (cd "$WS" && make pdf) | tail -2
    cambio=1
  else
    echo "[1/4] PDF consolidado: al día"
  fi

  if [ "$force" = "1" ] || [ "$fp" != "$(state_fp)" ] || [ "$nf" != "$fp" ]; then
    echo "[2/4] Notion"
    KUBO_SYNC_FINGERPRINT="$fp" KUBO_SYNC_STATE="$STATE_DIR" "$WS/kubo-infra/scripts/notion-sync.sh" | tail -3
    cambio=1
  else
    echo "[2/4] Notion: al día"
  fi

  if [ "$force" = "1" ] || [ "$fp" != "$(state_fp)" ] || [ "$of" != "$fp" ]; then
    echo "[3/4] Obsidian"
    KUBO_SYNC_FINGERPRINT="$fp" KUBO_SYNC_STATE="$STATE_DIR" "$WS/kubo-infra/scripts/obsidian-sync.sh" | tail -2
    cambio=1
  else
    echo "[3/4] Obsidian: al día"
  fi

  if [ "$cambio" = "1" ]; then
    save_state "$fp"
    write_files_baseline
    echo "[4/4] Estado y líneas base guardados: huella $fp"
  else
    echo "[4/4] Sin cambios canónicos: nada que propagar"
  fi

  # GitHub: commits acotados al alcance del sync + push de pendientes.
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    if [ "$s" != "0" ] && [ "$commit" = "1" ]; then
      if [ "$d" = "." ]; then
        git -C "$WS/$d" add -- README.md kubo-docs Kubo-Documentacion.pdf Kubo-Documentacion.pdf.sha256 2>/dev/null
      elif [ "$d" = "kubo-docs" ]; then
        git -C "$WS/$d" add -- README.md '*.md' adr evidencia diagramas 2>/dev/null
      else
        git -C "$WS/$d" add -- README.md 2>/dev/null
      fi
      if [ "$(git -C "$WS/$d" diff --cached --name-only | wc -l)" != "0" ]; then
        git -C "$WS/$d" commit -m "sync: documentacion actualizada (kubo-sync)" --quiet
        echo "  $d: commit creado"
        a=$((a + 1))
      else
        echo "  AVISO: $d tiene $s archivo(s) sin commitear fuera del alcance del sync"
      fi
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
      echo "  AVISO: $d está $b commit(s) atrás de origin/main (usa make sync-pull)"
    fi
  done
}

# --- auto (ciclo completo para el timer) -------------------------------------
do_auto() {
  local commit="$1" fp local_cambio=0 needs_run=0 conflictos=0 actualizados=0
  local d s a b nout oout resultado

  mkdir -p "$STATE_DIR"
  echo "Kubo · ciclo automático (check → pull → run)"
  echo "================================================================"

  fp=$(fingerprint)
  [ "$fp" != "$(state_fp)" ] && local_cambio=1

  echo "[1/3] GitHub"
  fetch_all
  for d in "${REPOS[@]}"; do
    read -r s a b <<< "$(git_line "$d")"
    if [ "$b" != "0" ]; then
      if [ "$a" != "0" ] || [ "$s" != "0" ]; then
        echo "  CONFLICTO $d (divergido o sucio); sin auto-merge"
        conflictos=$((conflictos + 1))
      elif env -u GITHUB_TOKEN git -C "$WS/$d" pull --ff-only --quiet origin main 2>/dev/null; then
        echo "  $d: fast-forward ($b commit(s) remotos)"
        actualizados=1
      else
        echo "  CONFLICTO $d: el fast-forward falló"
        conflictos=$((conflictos + 1))
      fi
    fi
  done
  [ "$actualizados" = "1" ] && needs_run=1
  [ "$actualizados" = "0" ] && echo "  (sin novedades remotas)"

  echo "[2/3] Notion"
  nout=$(KUBO_SYNC_STATE="$STATE_DIR" "$WS/kubo-infra/scripts/notion-pull.sh" pull 2>&1)
  indent <<< "$nout"
  if ! echo "$nout" | grep -q 'NOTION:'; then
    echo "  ERROR: el chequeo de Notion no produjo resultado (¿token?)"
    conflictos=$((conflictos + 1))
  fi
  echo "$nout" | grep -Eq 'importadas=[1-9]' && local_cambio=1
  echo "$nout" | grep -Eq 'conflictos=[1-9]' && conflictos=$((conflictos + 1))
  echo "$nout" | grep -Eq 'importables=[1-9]|regenerables=[1-9]' && needs_run=1

  echo "[3/3] Obsidian"
  oout=$(KUBO_SYNC_STATE="$STATE_DIR" KUBO_VAULT="$VAULT" "$WS/kubo-infra/scripts/obsidian-pull.sh" pull 2>&1)
  indent <<< "$oout"
  if ! echo "$oout" | grep -q 'OBSIDIAN:'; then
    echo "  ERROR: el chequeo de Obsidian no produjo resultado"
    conflictos=$((conflictos + 1))
  fi
  echo "$oout" | grep -Eq 'importadas=[1-9]' && local_cambio=1
  echo "$oout" | grep -Eq 'conflictos=[1-9]' && conflictos=$((conflictos + 1))
  echo "$oout" | grep -Eq 'editadas=[1-9]' && needs_run=1

  if [ "$local_cambio" = "1" ] || [ "$needs_run" = "1" ]; then
    do_run "$commit" 0
  else
    echo "  Sin cambios que propagar"
  fi

  if [ "$conflictos" -gt 0 ]; then
    resultado="CONFLICTOS=$conflictos"
    command -v notify-send >/dev/null 2>&1 && \
      notify-send -u critical "Kubo sync" "$conflictos conflicto(s): revisa .sync/conflictos/" || true
    echo "RESULTADO: CONFLICTOS ($conflictos) — revisa $CONF_DIR/"
  else
    resultado="ALINEADO"
    echo "RESULTADO: ALINEADO"
  fi
  {
    printf '%s %s\n' "$(date -Is)" "$resultado"
    printf '  notion:   %s\n' "${nout//$'\n'/ | }"
    printf '  obsidian: %s\n' "${oout//$'\n'/ | }"
  } >> "$STATE_DIR/auto.log"
  [ "$conflictos" -eq 0 ]
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
  check) do_check ;;
  pull) do_pull ;;
  run) do_run "$COMMIT" "$FORCE" ;;
  auto) do_auto "$COMMIT" ;;
  watch)
    echo "Vigilando los 4 entornos (cada ${INTERVALO}s). Ctrl-C para salir."
    while :; do
      echo "[$(date +%H:%M:%S)] ciclo"
      do_auto "$COMMIT"
      sleep "$INTERVALO"
    done
    ;;
  *)
    echo "Uso: kubo-sync.sh [status|check|pull|run|auto|watch] [--commit] [--force] [--interval N]" >&2
    exit 2
    ;;
esac
