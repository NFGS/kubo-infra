#!/bin/bash
# ---------------------------------------------------------------------------
# Publica los 9 repositorios de Kubo en GitHub (crea y empuja con `gh`).
#
# Requisitos:
#   1. GitHub CLI (`gh`) autenticado:  gh auth login
#   2. Que la cuenta activa sea la correcta:  gh auth status
#
# Uso:
#   ./kubo-infra/scripts/github-push.sh                 # cuenta activa, públicos (ADR-0029)
#   ./kubo-infra/scripts/github-push.sh --private       # visibles solo para ti
#   ./kubo-infra/scripts/github-push.sh mi-org          # bajo una organizacion
#   KUBO_FORCE=true ./kubo-infra/scripts/github-push.sh # sin confirmacion
#
# La credencial la administra `gh` (keyring); este script no guarda tokens.
# ---------------------------------------------------------------------------
set -uo pipefail

OWNER=""
# ADR-0029: los repositorios de Kubo son publicos por defecto.
VISIBILIDAD="--public"

for argumento in "$@"; do
  case "${argumento}" in
    --public) VISIBILIDAD="--public" ;;
    --private) VISIBILIDAD="--private" ;;
    *) OWNER="${argumento}" ;;
  esac
done

WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

# Un GITHUB_TOKEN invalido en el entorno tapa la sesion valida de `gh`
# (aparece como cuenta activa y hace fallar los comandos): se ignora aqui.
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  echo "[kubo] aviso: se ignora el GITHUB_TOKEN del entorno; se usa la sesion de gh"
  unset GITHUB_TOKEN
fi

if ! command -v gh >/dev/null 2>&1; then
  echo "ERROR: falta GitHub CLI (gh). Instalalo y ejecuta: gh auth login" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "ERROR: gh no tiene una sesion valida." >&2
  echo "       Ejecuta: gh auth login   (y luego: gh auth status)" >&2
  exit 1
fi

USUARIO="$(gh api user --jq .login 2>/dev/null)"
if [[ -z "${USUARIO}" ]]; then
  echo "ERROR: no fue posible leer la cuenta autenticada de gh" >&2
  exit 1
fi

DESTINO="${OWNER:-${USUARIO}}"
if [[ -n "${OWNER}" ]]; then
  if ! gh api "orgs/${OWNER}" >/dev/null 2>&1 && ! gh api "users/${OWNER}" >/dev/null 2>&1; then
    echo "ERROR: '${OWNER}' no es una organizacion ni un usuario accesible" >&2
    exit 1
  fi
fi

echo "[kubo] autenticado como ${USUARIO}; destino: ${DESTINO} (${VISIBILIDAD#--})"

if [[ "${KUBO_FORCE:-}" != "true" ]]; then
  read -r -p "Se crearan 9 repositorios y se empujara main. ¿Continuar? [s/N] " respuesta
  [[ "${respuesta}" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
fi

# Git usa la credencial de gh para HTTPS (sin tocar ~/.git-credentials).
gh auth setup-git >/dev/null 2>&1 || true

REPOS=(
  "kubo-workspace"
  "kubo-gateway"
  "kubo-iam"
  "kubo-crm"
  "kubo-erp"
  "kubo-analytics"
  "kubo-web"
  "kubo-infra"
  "kubo-docs"
)

for repo in "${REPOS[@]}"; do
  # El repositorio raiz del workspace vive en la carpeta Kubo/.
  if [[ "${repo}" == "kubo-workspace" ]]; then
    ruta="${WORKSPACE_DIR}"
  else
    ruta="${WORKSPACE_DIR}/${repo}"
  fi

  if [[ ! -d "${ruta}/.git" ]]; then
    echo "  omitido: ${repo} no tiene repositorio git"
    continue
  fi

  printf '  %-16s ' "${repo}"

  if git -C "${ruta}" remote get-url origin >/dev/null 2>&1; then
    if git -C "${ruta}" push --quiet -u origin main 2>/dev/null; then
      echo "empujado a origin existente"
    else
      echo "ERROR al empujar (revisa permisos de la cuenta)"
    fi
    continue
  fi

  if (cd "${ruta}" && gh repo create "${DESTINO}/${repo}" \
      --source=. --remote=origin --push ${VISIBILIDAD} >/dev/null 2>&1); then
    echo "creado y publicado en https://github.com/${DESTINO}/${repo}"
  else
    # El repositorio puede existir ya: se configura el remoto y se empuja.
    if git -C "${ruta}" remote add origin "https://github.com/${DESTINO}/${repo}.git" 2>/dev/null &&
       git -C "${ruta}" push --quiet -u origin main 2>/dev/null; then
      echo "ya existia, empujado a https://github.com/${DESTINO}/${repo}"
    else
      echo "ERROR al crear/publicar (revisa la cuenta y los permisos)"
    fi
  fi
done

echo
echo "[kubo] publicacion terminada en https://github.com/${DESTINO}"
