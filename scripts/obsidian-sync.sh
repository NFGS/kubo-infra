#!/bin/bash
# ---------------------------------------------------------------------------
# Espeja la documentacion de Kubo en el vault de Obsidian (cuarto entorno).
#
# Genera dentro del vault:
#   Kubo/Documentación/       15 notas (13 documentos + estado + evidencia)
#   Kubo/Decisiones Técnicas/ 26 ADRs
#   Kubo/Recursos/            diagramas, portadas, evidencias y PDF
#   Kubo/README.md            hub del proyecto (regenerado)
# y agrega la fila de Kubo en Home.md (idempotente).
#
# Uso:  ./kubo-infra/scripts/obsidian-sync.sh [ruta-del-vault]
#       KUBO_VAULT=/ruta/al/vault ./kubo-infra/scripts/obsidian-sync.sh
#
# Vault por defecto: ~/Documents/Obsidian Vaults/Ningendo Bee
# ---------------------------------------------------------------------------
set -euo pipefail

WS="$(cd "$(dirname "$0")/../.." && pwd)"
VAULT="${1:-${KUBO_VAULT:-$HOME/Documents/Obsidian Vaults/Ningendo Bee}}"
FP="${KUBO_SYNC_FINGERPRINT:-desconocida}"

if [ ! -d "$VAULT" ]; then
  echo "ERROR: no existe el vault: $VAULT" >&2
  exit 1
fi

python3 - "$WS" "$VAULT" "$FP" <<'PY'
import datetime, os, re, shutil, sys

ws, vault, huella = sys.argv[1], sys.argv[2], sys.argv[3]
kubo = os.path.join(vault, "Kubo")
docs_dir = os.path.join(kubo, "Documentación")
adr_dir = os.path.join(kubo, "Decisiones Técnicas")
rec_dir = os.path.join(kubo, "Recursos")
evi_dir = os.path.join(rec_dir, "evidencias")
for d in (docs_dir, adr_dir, rec_dir, evi_dir):
    os.makedirs(d, exist_ok=True)
fecha = datetime.date.today().isoformat()

def title_of(path):
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("# "):
                return line[2:].strip()
    return os.path.splitext(os.path.basename(path))[0]

DOCS = [
    "01-arquitectura", "02-modelo-datos", "03-api", "04-seguridad",
    "05-despliegue", "06-manual-usuario", "07-pruebas", "08-trazabilidad",
    "09-demo-guion", "10-auditoria", "11-plan-de-cierre",
    "12-runbook-operacion", "13-guia-adaptador-facturacion",
]

mapa = {}  # src normalizado -> (nota relativa al vault sin .md, titulo, tipo)

def safe_name(t):
    # El titulo puede traer caracteres invalidos para un nombre de archivo.
    return t.replace("/", "-").replace("\\", "-").strip()

def add(src, carpeta, tipo, nombre=None):
    t = nombre or title_of(src)
    nota = f"Kubo/{carpeta}/{safe_name(t)}"
    mapa[os.path.normpath(src)] = (nota, t, tipo)
    return t

add(os.path.join(ws, "README.md"), "Documentación", "documentación", "Estado del proyecto")
for d in DOCS:
    add(os.path.join(ws, "kubo-docs", f"{d}.md"), "Documentación", "documentación")
add(os.path.join(ws, "kubo-docs", "evidencia", "README.md"),
    "Documentación", "evidencia", "Evidencia de funcionamiento")
for f in sorted(os.listdir(os.path.join(ws, "kubo-docs", "adr"))):
    if f.endswith(".md"):
        add(os.path.join(ws, "kubo-docs", "adr", f), "Decisiones Técnicas", "adr")

LINK = re.compile(r"(?<!!)\[([^\]]+)\]\(([^)]+?\.md)(#[^)]*)?\)")

def rewrite(text, src):
    base = os.path.dirname(src)
    def repl(m):
        label, target, anchor = m.group(1), m.group(2), m.group(3) or ""
        resolved = os.path.normpath(os.path.join(base, target))
        if resolved in mapa:
            return f"[[{mapa[resolved][0]}{anchor}|{label}]]"
        return m.group(0)
    return LINK.sub(repl, text)

TAGS = {
    "documentación": ["kubo", "documentación"],
    "adr": ["kubo", "adr", "arquitectura"],
    "evidencia": ["kubo", "evidencia"],
}

def adr_estado(texto):
    # Los ADR declaran el estado en una tabla MADR: "| Estado | Aceptada |".
    m = re.search(r"^\|\s*Estado\s*\|\s*([^|]+?)\s*\|", texto, re.M)
    return m.group(1).strip() if m else None

for src, (nota, t, tipo) in sorted(mapa.items()):
    texto = open(src, encoding="utf-8").read()
    texto = rewrite(texto, src)
    estado = adr_estado(texto) if tipo == "adr" else None
    fm = (
        "---\n"
        "proyecto: Kubo\n"
        f"tipo: {tipo}\n"
        f"actualizado: {fecha}\n"
        f"fuente: {os.path.relpath(src, ws)}\n"
        + (f"estado: {estado}\n" if estado else "")
        + "tags:\n" + "".join(f"  - {x}\n" for x in TAGS[tipo]) + "---\n\n"
    )
    with open(os.path.join(vault, nota + ".md"), "w", encoding="utf-8") as fh:
        fh.write(fm + texto)

# --- recursos ---------------------------------------------------------------
diag = os.path.join(ws, "kubo-docs", "diagramas")
for f in sorted(os.listdir(diag)):
    if f.endswith(".png"):
        shutil.copy2(os.path.join(diag, f), os.path.join(rec_dir, f))
evi = os.path.join(ws, "kubo-docs", "evidencia")
for f in sorted(os.listdir(evi)):
    if f.endswith((".png", ".webm", ".txt")):
        shutil.copy2(os.path.join(evi, f), os.path.join(evi_dir, f))
shutil.copy2(os.path.join(ws, "Kubo-Documentacion.pdf"),
             os.path.join(rec_dir, "Kubo-Documentacion.pdf"))

# --- hub README -------------------------------------------------------------
docs_notas = [v for v in mapa.values() if v[2] in ("documentación", "evidencia")]
adr_notas = [v for v in mapa.values() if v[2] == "adr"]
lista_docs = "\n".join(f"- [[{n}|{t}]]" for n, t, _ in sorted(docs_notas, key=lambda v: v[1]))
lista_adrs = "\n".join(f"- [[{n}|{t}]]" for n, t, _ in adr_notas)

REPOS = [
    ("kubo-workspace", "Workspace: Makefile, PDF consolidado y utilidades"),
    ("kubo-gateway", "API Gateway, autenticación y rate limiting (TypeScript + NestJS)"),
    ("kubo-iam", "Identidad, tenants, roles y auditoría (Java 21 + Spring Boot 4)"),
    ("kubo-crm", "Clientes, cifrado de PII y pipeline (Ruby + Rails 8)"),
    ("kubo-erp", "Catálogo, inventario y ventas (Elixir + Phoenix)"),
    ("kubo-analytics", "KPIs, tablero y agregaciones (Python + FastAPI)"),
    ("kubo-web", "PWA offline-first (React 19 + Vite + Tailwind)"),
    ("kubo-infra", "Compose, seed y pruebas de humo (Docker)"),
    ("kubo-docs", "Arquitectura, ADRs y manuales (Markdown + Mermaid)"),
]
enlaces = "\n".join(f"| 🐙 **{r}** | <https://github.com/NFGS/{r}> — {d} |" for r, d in REPOS)

hub = f"""---
proyecto: Kubo
tipo: índice
actualizado: {fecha}
huella: {huella}
fuente: repositorio kubo-workspace (+ 8 hijos)
tags:
  - kubo
  - erp
  - crm
  - pymes
---

# 🏪 Kubo — Knowledge Base

> [!info] Punto de entrada
> Índice central del proyecto **Kubo** (ERP + CRM autoalojable para PYMES).
> Enlaza los repositorios, el espejo de Notion, los diagramas y la
> documentación completa. Empieza aquí antes de navegar a cualquier nota.

## Identidad

| Campo | Valor |
|---|---|
| **Nombre** | Kubo — ERP + CRM autoalojable para PYMES |
| **Tipo** | Monorepo poliglota (9 repos): gateway, IAM, CRM, ERP, analítica, PWA, infra y docs |
| **Autor** | Nelson Fabián Gallego Sánchez — SENA ADSO · Universidad del Quindío |
| **Estado** | **v0.3.0** operable en un negocio (fases 0–6 completadas) |
| **Calidad** | smoke 192/192 · `make ci` 13/13 · 231 pruebas de servicio · contratos 23/23 · E2E 5/5 · ERP ratchet 37.68 % |
| **Espejos** | GitHub (fuente de verdad) · Notion · este vault |

## Enlaces oficiales

| Recurso | Enlace |
|---|---|
{enlaces}
| 📓 **Documentación en Notion** | [Kubo — Documentación](https://app.notion.com/p/Kubo-3ef7d55fd95e8040b09ed5fb5e2dbdb1) |
| 💻 **Ruta local** | `~/Documents/Proyectos de Programación/Kubo` |

## Diagramas

### Vista de contexto (C4 nivel 1)

![[contexto-c4-1.png]]

_El dueño administra, el vendedor cobra en el mostrador y el cliente recibe comprobantes y avisos (Fase 4)._

### Vista de contenedores (C4 nivel 2)

![[contenedores-c4-2.png]]

_Gateway único, servicios con base propia, eventos por RabbitMQ y analítica como modelo de lectura._

### Flujo crítico: registrar una venta

![[flujo-venta.png]]

_Venta atómica con outbox; la facturación electrónica y los comprobantes salen por puertos._

### Modelo de confianza (seguridad)

![[modelo-confianza.png]]

_Borde único, malla mTLS, RLS por negocio y cifrado de campos con índice ciego._

## Documentación ({len(docs_notas)} notas)

> [!tip] Panel dinámico
> Requiere el plugin **Dataview** habilitado. Si ves bloques de código sin
> renderizar: Ajustes → Plugins de la comunidad → activa **Dataview**.

```dataview
TABLE file.folder AS "Carpeta", file.mtime AS "Actualizado"
FROM #kubo AND #documentación
SORT file.name ASC
```

### Índice curado

{lista_docs}

## Decisiones técnicas ({len(adr_notas)} ADRs)

> [!tip] Panel dinámico — ADRs por estado
> Se alimenta del campo `estado` que el sync extrae de la tabla MADR de cada ADR.

```dataview
TABLE estado AS "Estado", file.mtime AS "Modificado"
FROM #kubo AND #adr
WHERE estado AND tipo != "plantilla"
SORT file.name ASC
```

### Índice curado

{lista_adrs}

## Panorama dinámico

> [!tip] Notas por tag
> Distribución del conocimiento por tema (excluye el tag de proyecto).

```dataview
TABLE length(rows) AS "Notas"
FROM #kubo
FLATTEN file.etags AS tag
WHERE tag != "#kubo"
GROUP BY tag
SORT length(rows) DESC
```

> [!tip] Actualizadas recientemente
> Las últimas notas tocadas por el sync, útil para ver qué cambió.

```dataview
TABLE file.folder AS "Carpeta", file.mtime AS "Actualizado"
FROM #kubo
SORT file.mtime DESC
LIMIT 10
```

## Stack

| Capa | Tecnología |
|---|---|
| **Gateway** | TypeScript · NestJS |
| **Identidad** | Java 21 · Spring Boot 4 |
| **CRM** | Ruby · Rails 8 |
| **ERP** | Elixir · Phoenix |
| **Analítica** | Python · FastAPI |
| **PWA** | React 19 · Vite · Tailwind |
| **Infra** | Docker Compose · RabbitMQ · PostgreSQL · MongoDB · Redis · OpenTelemetry |

## Cómo usar esta knowledge base

1. Consulta esta nota índice antes de avanzar en cualquier tema del proyecto.
2. La documentación oficial vive en el repositorio y en Notion; estas notas son
   su espejo local para búsqueda, enlaces y grafo.
3. Refresca el espejo desde el repositorio con `./kubo-infra/scripts/obsidian-sync.sh`.

## Recursos

- **Diagramas y portadas**: `Kubo/Recursos/` (PNG de alta resolución, exportados con la skill `archify`).
- **Evidencias**: `Kubo/Recursos/evidencias/` (capturas, demo y comprobaciones).
- **PDF consolidado**: `Kubo/Recursos/Kubo-Documentacion.pdf` (142 páginas).
- **Código fuente**: <https://github.com/NFGS/kubo-workspace>.
- **Auditoría del ecosistema**: [[Auditorías/2026-10-04-auditoria-ecosistema-opencode|Auditoría OpenCode + Kubo — 2026-10-04]].

## Tags

#kubo #erp #crm #pymes #documentación
"""
with open(os.path.join(kubo, "README.md"), "w", encoding="utf-8") as fh:
    fh.write(hub)

# --- Home.md ----------------------------------------------------------------
home = os.path.join(vault, "Home.md")
txt = open(home, encoding="utf-8").read()
fila_agro = "| 🌱 **AgroConnect** | Plataforma agropecuaria B2B+B2C (SENA ADSO) | [[AgroConnect/README\\|AgroConnect — Knowledge Base]] |\n"
fila_kubo = "| 🏪 **Kubo** | ERP + CRM autoalojable para PYMES (monorepo poliglota, 9 repos) | [[Kubo/README\\|Kubo — Knowledge Base]] |\n"
cambio = False
if "[[Kubo/README" not in txt:
    if fila_agro in txt:
        txt = txt.replace(fila_agro, fila_agro + fila_kubo)
        cambio = True
    else:
        print("AVISO: no se encontro la fila de AgroConnect en Home.md; no se agrego Kubo")
if "obsidian-sync.sh" not in txt:
    item = "4. El espejo de **Kubo** se refresca con `./kubo-infra/scripts/obsidian-sync.sh` (vault).\n"
    txt = txt.rstrip("\n") + "\n" + item
    cambio = True
if cambio:
    txt = re.sub(r"^actualizado: .*$", f"actualizado: {fecha}", txt, count=1, flags=re.M)
    open(home, "w", encoding="utf-8").write(txt)

print(f"OK: {len(docs_notas)} notas de documentación, {len(adr_notas)} ADRs")
print(f"OK: recursos en {rec_dir}")
print(f"OK: hub en {os.path.join(kubo, 'README.md')}")
print("OK: Home.md actualizado" if cambio else "OK: Home.md ya estaba al día")
PY

echo "[kubo] espejo de Obsidian sincronizado en: $VAULT/Kubo"
