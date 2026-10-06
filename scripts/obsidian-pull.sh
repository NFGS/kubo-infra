#!/bin/bash
# ---------------------------------------------------------------------------
# Reconciliacion Obsidian -> directorio del proyecto (bidireccional, ADR-0030).
#
#   check   lista las notas editadas a mano en el vault desde el ultimo sync
#   pull    importa las editables al archivo canonico (con staging de conflictos)
#
# Reglas:
#   - Solo se importan notas respaldadas por un archivo real (las del mapa);
#     el hub del vault es generado y no se importa.
#   - Si el archivo local cambio desde el ultimo sync, NO se importa: la
#     version del vault se guarda en .sync/conflictos/ y se reporta.
#   - La importacion deshace la conversion: quita el frontmatter y devuelve
#     los wikilinks [[nota|texto]] a enlaces Markdown relativos.
#
# Uso:  ./kubo-infra/scripts/obsidian-pull.sh [check|pull]
# ---------------------------------------------------------------------------
set -uo pipefail

WS="$(cd "$(dirname "$0")/../.." && pwd)"
STATE_DIR="${KUBO_SYNC_STATE:-$HOME/.config/opencode/kubo-sync}"
VAULT="${KUBO_VAULT:-$HOME/Documents/Obsidian Vaults/Ningendo Bee}"
MANIFEST="$STATE_DIR/obsidian-manifest.json"
BASELINE="$STATE_DIR/obsidian-baseline.json"
FILES_BASE="$STATE_DIR/files-baseline.json"
CONF_DIR="$WS/.sync/conflictos"
MODE="${1:-check}"

if [ ! -f "$MANIFEST" ] || [ ! -f "$BASELINE" ]; then
  echo "OBSIDIAN: sin manifiesto ni linea base (ejecuta make sync una vez)"
  exit 0
fi

editadas=0; importadas=0; conflictos=0

while IFS= read -r nota; do
  actual=$(sha256sum "$VAULT/$nota.md" 2>/dev/null | cut -d' ' -f1)
  base=$(jq -r --arg n "$nota" '.[$n] // empty' "$BASELINE")
  if [ -n "$actual" ] && [ "$actual" = "$base" ]; then
    continue
  fi

  src=$(jq -r --arg n "$nota" '.[$n].src // empty' "$MANIFEST")
  title=$(jq -r --arg n "$nota" '.[$n].title // "?"' "$MANIFEST")
  editadas=$((editadas + 1))

  if [ -z "$actual" ]; then
    echo "  FALTA        $title (nota eliminada; make sync la regenera)"
    continue
  fi
  if [ "$MODE" != "pull" ]; then
    echo "  EDITADA      $title -> $src"
    continue
  fi

  base_hash=$(jq -r --arg f "$src" '.[$f] // empty' "$FILES_BASE" 2>/dev/null)
  cur_hash=$([ -f "$WS/$src" ] && sha256sum "$WS/$src" | cut -d' ' -f1 || echo "")
  if [ -n "$base_hash" ] && [ "$cur_hash" != "$base_hash" ]; then
    mkdir -p "$CONF_DIR"; slug=$(echo "$src" | tr '/' '-')
    cp "$VAULT/$nota.md" "$CONF_DIR/obsidian--$slug"
    echo "  CONFLICTO    $title (el archivo local tambien cambio) -> .sync/conflictos/obsidian--$slug"
    conflictos=$((conflictos + 1))
    continue
  fi

  python3 - "$VAULT/$nota.md" "$WS/$src" "$MANIFEST" "$WS" <<'PY'
import json, os, re, sys

nota_path, src_path, manifest_path, ws = sys.argv[1:5]
texto = open(nota_path, encoding="utf-8").read()

# Quitar el frontmatter generado por el sync.
if texto.startswith("---\n"):
    fin = texto.find("\n---\n", 4)
    if fin != -1:
        texto = texto[fin + 5:]

# Devolver los wikilinks a enlaces Markdown relativos.
mapa = json.load(open(manifest_path, encoding="utf-8"))
nota_a_src = {nota: datos["src"] for nota, datos in mapa.items()}
base_dir = os.path.dirname(src_path)

def repl(m):
    nota, label = m.group(1), m.group(2)
    src_rel = nota_a_src.get(nota)
    if not src_rel:
        return m.group(0)
    destino = os.path.relpath(os.path.join(ws, src_rel), base_dir)
    return f"[{label}]({destino})"

texto = re.sub(r"\[\[([^\]|]+)\|([^\]]+)\]\]", repl, texto)
open(src_path, "w", encoding="utf-8").write(texto)
PY
  echo "  IMPORTADA    $title -> $src"
  importadas=$((importadas + 1))
done < <(jq -r 'keys[]' "$MANIFEST" 2>/dev/null)

if [ "$MODE" = "pull" ]; then
  echo "OBSIDIAN: editadas=$editadas importadas=$importadas conflictos=$conflictos"
  [ "$conflictos" -eq 0 ] || exit 1
else
  echo "OBSIDIAN: editadas=$editadas"
  [ "$editadas" -gt 0 ] && exit 1 || exit 0
fi
