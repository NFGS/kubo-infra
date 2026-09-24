#!/bin/bash
# ---------------------------------------------------------------------------
# Escaneo de secretos (P-06).
#
# Revisa solo archivos VERSIONADOS de los nueve repositorios: un secreto en un
# archivo ignorado no llega al repositorio, pero uno versionado es un incidente.
# Los patrones son de alta senal (claves privadas y tokens conocidos) para no
# generar ruido con contrasenas de prueba o claves de ejemplo.
#
# Uso:  make ci   (o directamente este script)
# ---------------------------------------------------------------------------
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
REPOS=(kubo-gateway kubo-iam kubo-crm kubo-erp kubo-analytics kubo-web kubo-infra kubo-docs)

PASS=0
FAIL=0

ok() { printf '  \033[32mPASA\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
ko() { printf '  \033[31mFALLA\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

echo
echo "Kubo · escaneo de secretos"
echo "================================================================"

# 1. Archivos .env versionados -------------------------------------------------
ENV_VERSIONADOS=""
for repo in "${REPOS[@]}"; do
  archivo="$(git -C "${ROOT}/${repo}" ls-files 2>/dev/null | grep -E '(^|/)\.env$' || true)"
  [[ -n "${archivo}" ]] && ENV_VERSIONADOS+="${repo}/${archivo} "
done
if [[ -z "${ENV_VERSIONADOS}" ]]; then
  ok "ningun archivo .env esta versionado"
else
  ko "hay .env versionados: ${ENV_VERSIONADOS}"
fi

# 2. Patrones de alta senal ----------------------------------------------------
PATRONES=(
  "clave privada PEM|-----BEGIN [A-Z ]*PRIVATE KEY-----"
  "token de AWS|AKIA[0-9A-Z]{16}"
  "token de GitLab|glpat-[A-Za-z0-9_-]{20,}"
  "token de GitHub|ghp_[A-Za-z0-9]{36}"
  "token de Slack|xox[baprs]-[A-Za-z0-9-]{10,}"
)

for entrada in "${PATRONES[@]}"; do
  descripcion="${entrada%%|*}"
  patron="${entrada##*|}"
  hallazgos=""

  for repo in "${REPOS[@]}"; do
    while IFS= read -r archivo; do
      case "${archivo}" in
        *.env.example|*package-lock.json|*.dump|*.archive) continue ;;
      esac
      ruta="${ROOT}/${repo}/${archivo}"
      [[ -f "${ruta}" ]] || continue
      if grep -InE -- "${patron}" "${ruta}" >/dev/null 2>&1; then
        hallazgos+="${repo}/${archivo} "
      fi
    done < <(git -C "${ROOT}/${repo}" ls-files 2>/dev/null)
  done

  if [[ -z "${hallazgos}" ]]; then
    ok "sin ${descripcion} versionado"
  else
    ko "${descripcion} encontrado en: ${hallazgos}"
  fi
done

echo "================================================================"
printf 'Resultado: \033[32m%d verificaciones\033[0m, \033[31m%d hallazgos\033[0m\n\n' "${PASS}" "${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
  exit 1
fi
