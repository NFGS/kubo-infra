#!/bin/bash
# ---------------------------------------------------------------------------
# Reconciliacion Notion -> directorio del proyecto (bidireccional, ADR-0030).
#
#   check   lista las paginas editadas a mano en Notion desde el ultimo sync
#   pull    importa las editables al archivo canonico (con staging de conflictos)
#
# Reglas:
#   - Solo se importan paginas "importables" (respaldadas por un archivo real).
#     Las generadas (indices, intro) se reportan como REGENERABLE y `run` las
#     reconstruye desde el repositorio.
#   - Si el archivo local cambio desde el ultimo sync, o contiene diagramas
#     Mermaid (el viaje de ida y vuelta perderia el codigo fuente), NO se
#     importa: la version de Notion se guarda en .sync/conflictos/ y se reporta.
#
# Requiere: NOTION_KUBO_TOKEN, jq y el manifiesto que deja notion-sync.sh.
# Uso:  ./kubo-infra/scripts/notion-pull.sh [check|pull]
# ---------------------------------------------------------------------------
set -uo pipefail

API="https://api.notion.com/v1"
TOKEN="${NOTION_KUBO_TOKEN:?falta NOTION_KUBO_TOKEN en el entorno}"
WS="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${KUBO_SYNC_STATE:-$HOME/.config/opencode/kubo-sync}"
MANIFEST="$STATE_DIR/notion-manifest.json"
BASELINE="$STATE_DIR/notion-baseline.json"
FILES_BASE="$STATE_DIR/files-baseline.json"
CONF_DIR="$WS/.sync/conflictos"
V="2025-09-03"
VMD="2026-03-11"
MODE="${1:-check}"

# El export markdown de Notion no es fiel: convierte tablas a HTML, escapa
# enlaces dentro de formato y usa tabs (incidente 2026-10-07, ADR-0030).
# Con estas marcas la pagina NO se importa: queda como conflicto a revisar.
LOSSY_RE='<table|\\\[|\\!|'$'\t'

if [ ! -f "$MANIFEST" ] || [ ! -f "$BASELINE" ]; then
  echo "NOTION: sin manifiesto ni linea base (ejecuta make sync una vez)"
  exit 0
fi

req() { # metodo ruta version
  curl -sS --max-time 180 -X "$1" "$API$2" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Notion-Version: $3"
}

# --- deteccion de deriva: last_edited_time contra la linea base ---------------
DERIVA="$(mktemp)"
: > "$DERIVA"
while IFS= read -r page_id; do
  ts_now=$(req GET "/pages/${page_id}" "$V" | jq -r '.last_edited_time // empty' 2>/dev/null)
  ts_base=$(jq -r --arg id "$page_id" '.[$id] // empty' "$BASELINE" 2>/dev/null)
  if [ -n "$ts_now" ] && [ "$ts_now" != "$ts_base" ]; then
    printf '%s\n' "$page_id" >> "$DERIVA"
  fi
  sleep 0.35
done < <(jq -r 'keys[]' "$MANIFEST")

importables=0; regenerables=0; importadas=0; conflictos=0

while IFS= read -r page_id; do
  title=$(jq -r --arg id "$page_id" '.[$id].title // "?"' "$MANIFEST")
  file=$(jq -r --arg id "$page_id" '.[$id].file // empty' "$MANIFEST")
  kind=$(jq -r --arg id "$page_id" '.[$id].kind // "generado"' "$MANIFEST")

  if [ "$kind" != "importable" ] || [ -z "$file" ]; then
    regenerables=$((regenerables + 1))
    [ "$MODE" != "pull" ] && echo "  REGENERABLE  $title (pagina generada; make sync la reconstruye)"
    continue
  fi

  importables=$((importables + 1))
  if [ "$MODE" != "pull" ]; then
    echo "  EDITADA      $title  ->  $file"
    continue
  fi

  # Conflicto: el archivo local tambien cambio desde el ultimo sync.
  base_hash=$(jq -r --arg f "$file" '.[$f] // empty' "$FILES_BASE" 2>/dev/null)
  cur_hash=$([ -f "$WS/$file" ] && sha256sum "$WS/$file" | cut -d' ' -f1 || echo "")
  if [ -n "$base_hash" ] && [ "$cur_hash" != "$base_hash" ]; then
    mkdir -p "$CONF_DIR"; slug=$(echo "$file" | tr '/' '-')
    req GET "/pages/${page_id}/markdown" "$VMD" | jq -r '.markdown // ""' > "$CONF_DIR/notion--$slug"
    echo "  CONFLICTO    $title (el archivo local tambien cambio) -> .sync/conflictos/notion--$slug"
    conflictos=$((conflictos + 1))
    continue
  fi

  # Conflicto: viaje de ida y vuelta perderia el codigo Mermaid.
  if grep -q '```mermaid' "$WS/$file" 2>/dev/null; then
    mkdir -p "$CONF_DIR"; slug=$(echo "$file" | tr '/' '-')
    req GET "/pages/${page_id}/markdown" "$VMD" | jq -r '.markdown // ""' > "$CONF_DIR/notion--$slug"
    echo "  CONFLICTO    $title (contiene Mermaid; revisar a mano) -> .sync/conflictos/notion--$slug"
    conflictos=$((conflictos + 1))
    continue
  fi

  # Importar solo si el redondeo de Notion es fiel; con perdida => conflicto,
  # no se pisa el archivo canonico.
  tmp=$(mktemp)
  req GET "/pages/${page_id}/markdown" "$VMD" | jq -r '.markdown // ""' | grep -v '^<callout ' > "$tmp"
  if [ ! -s "$tmp" ]; then
    echo "  ERROR        $title (markdown vacio; no se toco $file)"
    conflictos=$((conflictos + 1))
  elif grep -qE "$LOSSY_RE" "$tmp"; then
    mkdir -p "$CONF_DIR"; slug=$(echo "$file" | tr '/' '-')
    cp "$tmp" "$CONF_DIR/notion--$slug"
    echo "  CONFLICTO    $title (el redondeo de Notion no es fiel; revisar a mano) -> .sync/conflictos/notion--$slug"
    conflictos=$((conflictos + 1))
  else
    cp "$tmp" "$WS/$file"
    echo "  IMPORTADA    $title -> $file"
    importadas=$((importadas + 1))
  fi
  rm -f "$tmp"
done < <(sort -u "$DERIVA")
rm -f "$DERIVA"

if [ "$MODE" = "pull" ]; then
  echo "NOTION: importables=$importables importadas=$importadas regenerables=$regenerables conflictos=$conflictos"
  [ "$conflictos" -eq 0 ] || exit 1
else
  echo "NOTION: importables=$importables regenerables=$regenerables"
  [ $((importables + regenerables)) -gt 0 ] && exit 1 || exit 0
fi
