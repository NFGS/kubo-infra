#!/bin/bash
# ---------------------------------------------------------------------------
# Espeja la documentacion de Kubo en Notion (tercer entorno).
#
# Idempotente: reutiliza las paginas por titulo y refresca su contenido.
# PRESERVA EL DISENO: inyecta el callout de resumen tras el H1 y reemplaza los
# bloques Mermaid por los diagramas archify ya subidos (file-uploads), usando
# el mapa persistente de ids.
#
# Requiere: NOTION_KUBO_TOKEN y jq.
# Uso:  KUBO_SYNC_FINGERPRINT=<huella> ./kubo-infra/scripts/notion-sync.sh
# ---------------------------------------------------------------------------
set -uo pipefail

# El directorio de trabajo temporal debe existir tambien tras un reinicio.
mkdir -p /tmp/opencode

API="https://api.notion.com/v1"
TOKEN="${NOTION_KUBO_TOKEN:?falta NOTION_KUBO_TOKEN en el entorno}"
WS="$(cd "$(dirname "$0")/../.." && pwd)"
ROOT="${KUBO_NOTION_PAGE:-3ef7d55f-d95e-8040-b09e-d5fb5e2dbdb1}"
FILE_IDS="${KUBO_NOTION_FILE_IDS:-$HOME/.config/opencode/scripts/notion-design/file-ids.json}"
FP="${KUBO_SYNC_FINGERPRINT:-desconocida}"
LOG="/tmp/opencode/notion-sync.log"
V="2025-09-03"
VMD="2026-03-11"
OK=0
ERR=0

: > "$LOG"
log() { echo "$*" >> "$LOG"; }

req() { # metodo ruta version [json]
  local method="$1" path="$2" ver="$3" data="${4:-}"
  if [ -n "$data" ]; then
    curl -sS --max-time 180 -X "$method" "$API$path" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Notion-Version: ${ver}" \
      -H "Content-Type: application/json" \
      --data-binary "$data"
  else
    curl -sS --max-time 180 -X "$method" "$API$path" \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "Notion-Version: ${ver}"
  fi
}

child_id() { # padre titulo -> id de la pagina hija o vacio
  local parent="$1" title="$2"
  req GET "/blocks/${parent}/children?page_size=100" "$V" \
    | jq -r --arg t "$title" '.results[]? | select(.type=="child_page" and .child_page.title==$t) | .id' 2>/dev/null \
    | head -1
}

create_page() { # padre titulo -> id o vacio
  local parent="$1" title="$2" body resp id
  body=$(jq -n --arg p "$parent" --arg t "$title" \
    '{parent:{page_id:$p},properties:{title:{title:[{text:{content:$t}}]}}}')
  resp=$(req POST "/pages" "$V" "$body")
  id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
  if [ -z "$id" ]; then
    log "ERROR crear '$title': $(echo "$resp" | jq -r '.message // .code // "?"' 2>/dev/null)"
    ERR=$((ERR + 1))
  else
    OK=$((OK + 1))
    log "OK pagina: $title"
  fi
  sleep 0.35
  echo "$id"
}

# Enriquecimiento de presentacion (callout + diagramas archify).
enrich() { # archivo titulo -> markdown enriquecido por stdout
  python3 - "$1" "$2" "$FILE_IDS" <<'PY'
import json, sys

archivo, titulo, ids_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    ids = json.load(open(ids_path, encoding="utf-8"))
except Exception:
    ids = {}

CALLOUTS = {
    "01 —": ("🏛️", "blue_bg", "Cómo está armado Kubo: contexto C4, contenedores, componentes del ERP, el flujo crítico de una venta y el modo sin conexión."),
    "02 —": ("🗄️", "blue_bg", "Qué guarda cada servicio y por qué: PostgreSQL con RLS por negocio, el modelo de lectura en MongoDB y los índices que sostienen el POS."),
    "03 —": ("🔌", "blue_bg", "El contrato HTTP completo: autenticación, endpoints por servicio, errores tipados y ejemplos de uso."),
    "04 —": ("🔐", "blue_bg", "El modelo de confianza: borde único, malla mTLS, RLS activo, cifrado de campos y las pruebas de seguridad del gate."),
    "05 —": ("🚀", "blue_bg", "Cómo se instala y opera: compose de 12 contenedores, instalación remota con Ansible y el borde TLS."),
    "06 —": ("📖", "blue_bg", "La guía del día a día: vender, comprar, inventario, clientes y preguntas frecuentes."),
    "07 —": ("✅", "blue_bg", "Los tres niveles de verificación: 231 pruebas de servicio, 192 comprobaciones de humo y el gate local de 13 verificaciones."),
    "08 —": ("🔗", "blue_bg", "Requisito ↔ caso de uso ↔ historia ↔ prueba: cada pendiente con su evidencia."),
    "09 —": ("🎬", "blue_bg", "El guion de 6–7 minutos para demostrar el producto, con frases de respaldo si algo falla en vivo."),
    "10 —": ("🔍", "blue_bg", "La auditoría que originó el plan: hallazgos corregidos, mediciones de carga y pendientes declarados."),
    "11 —": ("🎯", "blue_bg", "El cierre fase por fase: qué se construyó, con qué evidencia y qué queda como backlog declarado."),
    "12 —": ("🛠️", "blue_bg", "El runbook de la semana uno: chequeo diario, playbooks de incidentes y métricas que se vigilan."),
    "Runbook de operación": ("🛠️", "blue_bg", "El runbook de la semana uno: chequeo diario, playbooks de incidentes y métricas que se vigilan."),
    "13 —": ("🧾", "blue_bg", "Cómo enchufar un proveedor tecnológico DIAN: contrato del adaptador, configuración y checklist de habilitación."),
}
DIAGRAMAS = {
    "01 —": ["diag-01-contexto", "diag-01-contenedores", "diag-01-componentes", "diag-01-venta", "diag-01-offline"],
    "02 —": ["diag-02-panorama"],
    "04 —": ["diag-04-confianza"],
    "11 —": ["diag-11-camino"],
}

md = open(archivo, encoding="utf-8").read()

# 1) Callout de resumen tras el H1.
for pref, (emoji, color, texto) in CALLOUTS.items():
    if titulo.startswith(pref):
        lineas = md.split("\n")
        if lineas and lineas[0].startswith("# "):
            lineas[1:1] = ["", f'<callout icon="{emoji}" color="{color}">{texto}</callout>']
            md = "\n".join(lineas)
        break

# 2) Bloques Mermaid -> imagenes archify (los no mapeados se conservan).
for pref, claves in DIAGRAMAS.items():
    if titulo.startswith(pref):
        salida, bloque, dentro = [], [], False
        idx = 0
        for linea in md.split("\n"):
            if not dentro and linea.strip().startswith("```mermaid"):
                dentro, bloque = True, [linea]
                continue
            if dentro:
                bloque.append(linea)
                if linea.strip() == "```":
                    dentro = False
                    fid = ids.get(claves[idx]) if idx < len(claves) else None
                    if fid:
                        salida.append(f"![Diagrama](file-upload://{fid})")
                    else:
                        salida.extend(bloque)
                    idx += 1
                continue
            salida.append(linea)
        md = "\n".join(salida)
        break

sys.stdout.write(md)
PY
}

set_markdown() { # pagina archivo titulo
  local page="$1" file="$2" titulo="$3" tmp body resp
  tmp="/tmp/opencode/notion-md-enriched.md"
  enrich "$file" "$titulo" > "$tmp"
  body=$(jq -n --rawfile md "$tmp" \
    '{type:"replace_content",replace_content:{new_str:$md,allow_deleting_content:false}}')
  resp=$(req PATCH "/pages/${page}/markdown" "$VMD" "$body")
  if echo "$resp" | jq -e '.object=="page_markdown"' >/dev/null 2>&1; then
    OK=$((OK + 1))
    log "OK contenido: $(basename "$file")"
  else
    ERR=$((ERR + 1))
    log "ERROR contenido '$(basename "$file")': $(echo "$resp" | jq -r '.message // .code // "?"' 2>/dev/null)"
  fi
  sleep 0.35
}

ensure_page() { # padre titulo archivo -> id
  local parent="$1" title="$2" file="$3" id
  id=$(child_id "$parent" "$title")
  if [ -z "$id" ]; then id=$(create_page "$parent" "$title"); fi
  if [ -z "$id" ]; then return 1; fi
  set_markdown "$id" "$file" "$title"
  echo "$id"
}

ensure_container() { # padre titulo -> id (sin contenido)
  local parent="$1" title="$2" id
  id=$(child_id "$parent" "$title")
  if [ -z "$id" ]; then id=$(create_page "$parent" "$title"); fi
  echo "$id"
}

title_of() { # archivo -> primer H1 o nombre
  local t
  t=$(grep -m1 '^# ' "$1" | sed 's/^# //')
  echo "${t:-$(basename "$1" .md)}"
}

echo "== Sincronizando documentacion de Kubo con Notion (huella ${FP}) =="

DOC=$(ensure_container "$ROOT" "Documentación")
ADR=$(ensure_container "$ROOT" "ADRs")
EVI=$(ensure_container "$ROOT" "Evidencia")
REP=$(ensure_container "$ROOT" "Repositorios")

ensure_page "$ROOT" "Estado del proyecto" "$WS/README.md" >/dev/null
ensure_page "$DOC" "Índice de documentación" "$WS/kubo-docs/README.md" >/dev/null

DOCS=(01-arquitectura 02-modelo-datos 03-api 04-seguridad 05-despliegue 06-manual-usuario
      07-pruebas 08-trazabilidad 09-demo-guion 10-auditoria 11-plan-de-cierre
      12-runbook-operacion 13-guia-adaptador-facturacion)
for d in "${DOCS[@]}"; do
  f="$WS/kubo-docs/$d.md"
  if [ -f "$f" ]; then
    ensure_page "$DOC" "$(title_of "$f")" "$f" >/dev/null
  else
    log "ERROR falta $f"; ERR=$((ERR + 1))
  fi
done

IDX="/tmp/opencode/notion-adr-index.md"
{
  echo "# Índice de ADRs"
  echo
  echo "Decisiones de arquitectura en formato MADR ($(ls "$WS"/kubo-docs/adr/ADR-*.md | wc -l)), con opciones, trade-offs y consecuencias."
  echo
  for f in "$WS"/kubo-docs/adr/ADR-*.md; do echo "- $(title_of "$f")"; done
} > "$IDX"
ensure_page "$ADR" "Índice de ADRs" "$IDX" >/dev/null
for f in "$WS"/kubo-docs/adr/ADR-*.md; do
  ensure_page "$ADR" "$(title_of "$f")" "$f" >/dev/null
done

f="$WS/kubo-docs/evidencia/README.md"
if [ -f "$f" ]; then ensure_page "$EVI" "$(title_of "$f")" "$f" >/dev/null; fi

REPOS_ORDEN=(kubo-workspace kubo-gateway kubo-iam kubo-crm kubo-erp kubo-analytics kubo-web kubo-infra kubo-docs)
declare -A REPOS_DESC=(
  [kubo-workspace]="Workspace: Makefile, PDF consolidado de documentación y utilidades"
  [kubo-gateway]="API Gateway, autenticación y rate limiting (TypeScript + NestJS)"
  [kubo-iam]="Identidad, tenants, roles y auditoría (Java 21 + Spring Boot 4)"
  [kubo-crm]="Clientes, cifrado de PII y pipeline (Ruby + Rails 8)"
  [kubo-erp]="Catálogo, inventario y ventas (Elixir + Phoenix)"
  [kubo-analytics]="KPIs, tablero y agregaciones (Python + FastAPI)"
  [kubo-web]="PWA offline-first (React 19 + Vite + Tailwind)"
  [kubo-infra]="Compose, seed y pruebas de humo (Docker)"
  [kubo-docs]="Arquitectura, ADRs y manuales (Markdown + Mermaid)"
)
IDXR="/tmp/opencode/notion-repos-index.md"
{
  echo "# Repositorios"
  echo
  echo "Los 9 repositorios del workspace, publicados en GitHub (privados, cuenta NFGS):"
  echo
  for r in "${REPOS_ORDEN[@]}"; do
    echo "- [${r}](https://github.com/NFGS/${r}) — ${REPOS_DESC[$r]}"
  done
} > "$IDXR"
ensure_page "$REP" "Índice de repositorios" "$IDXR" >/dev/null
for r in kubo-gateway kubo-iam kubo-crm kubo-erp kubo-analytics kubo-web kubo-infra kubo-docs; do
  f="$WS/$r/README.md"
  if [ -f "$f" ]; then ensure_page "$REP" "$(title_of "$f")" "$f" >/dev/null; fi
done

INTRO="/tmp/opencode/notion-kubo-intro.md"
{
  echo "ERP + CRM autoalojable para PYMES. Documentación espejo del repositorio, sincronizada el $(date +%F)."
  echo
  echo "- **Verificación vigente**: \`make smoke\` 192/192 · \`make ci\` 13/13 · contratos 23/23 · E2E 5/5 · ERP ratchet 37.68 %."
  echo "- **Demo pública**: [https://kubo.shares.zrok.io](https://kubo.shares.zrok.io) — túnel zrok (despliegue en ADR-0028 y guía 05 §9)."
  echo "- **Contenido**: Estado del proyecto, Documentación (01–13), ADRs, Evidencia y Repositorios."
  echo "- **Fuente de verdad**: los repositorios en GitHub (cuenta NFGS); este espacio es un espejo de consulta."
  echo "- **Huella de sincronización**: \`${FP}\` (kubo-sync)."
  echo
  echo "### Repositorios"
  echo
  for r in "${REPOS_ORDEN[@]}"; do
    echo "- [${r}](https://github.com/NFGS/${r}) — ${REPOS_DESC[$r]}"
  done
  echo
  # replace_content exige listar las paginas hijas para no borrarlas.
  for t in "Documentación" "ADRs" "Evidencia" "Repositorios" "Estado del proyecto"; do
    cid=$(child_id "$ROOT" "$t")
    if [ -n "$cid" ]; then
      echo "<page url=\"https://app.notion.com/p/${cid//-/}\">$t</page>"
    fi
  done
} > "$INTRO"
set_markdown "$ROOT" "$INTRO" "Kubo"

echo "== Resultado: $OK OK, $ERR errores =="
if [ "$ERR" -gt 0 ]; then
  grep '^ERROR' "$LOG" | sed 's/^/  /'
  exit 1
fi
