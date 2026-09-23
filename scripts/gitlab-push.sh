#!/bin/bash
# ---------------------------------------------------------------------------
# Publica los repositorios de Kubo en GitLab.
#
# Requisitos:
#   1. Un Personal Access Token de GitLab con alcance `api` (o `write_repository`).
#   2. La variable de entorno GITLAB_TOKEN, o pasarlo como primer argumento.
#
# Uso:
#   GITLAB_TOKEN=glpat-xxxx ./kubo-infra/scripts/gitlab-push.sh
#   ./kubo-infra/scripts/gitlab-push.sh glpat-xxxx [grupo]
#
# El token se usa solo en memoria: no se guarda en .git/config ni en el
# almacen de credenciales. Al terminar, revocalo en GitLab.
# ---------------------------------------------------------------------------
set -uo pipefail

TOKEN="${GITLAB_TOKEN:-${1:-}}"
GROUP="${2:-}"

if [[ -z "${TOKEN}" ]]; then
  cat <<'AYUDA'
Falta el token de GitLab.

  1. Entra a GitLab → Preferences → Access tokens
  2. Crea un token con el alcance `api` (caduca pronto, por seguridad)
  3. Ejecuta:

       GITLAB_TOKEN=glpat-xxxxxxxx ./kubo-infra/scripts/gitlab-push.sh

  Si quieres publicar bajo un grupo, pasalo como segundo argumento:

       GITLAB_TOKEN=glpat-xxxxxxxx ./kubo-infra/scripts/gitlab-push.sh glpat-xxxxxxxx mi-grupo
AYUDA
  exit 1
fi

WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
API="https://gitlab.com/api/v4"

echo "[kubo] verificando el token…"
USUARIO=$(curl -sS --header "PRIVATE-TOKEN: ${TOKEN}" "${API}/user" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('username', ''))
except Exception:
    print('')
")

if [[ -z "${USUARIO}" ]]; then
  echo "ERROR: el token no es valido o no tiene el alcance 'api'." >&2
  exit 1
fi
echo "[kubo] autenticado como ${USUARIO}"

if [[ -n "${GROUP}" ]]; then
  GRUPO_ID=$(curl -sS --header "PRIVATE-TOKEN: ${TOKEN}" \
    "${API}/groups?search=${GROUP}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data[0]['id'] if data else '')
except Exception:
    print('')
")
  if [[ -z "${GRUPO_ID}" ]]; then
    echo "ERROR: no se encontro el grupo '${GROUP}'." >&2
    exit 1
  fi
  echo "[kubo] publicando en el grupo ${GROUP} (id ${GRUPO_ID})"
  NAMESPACE="\"namespace_id\": ${GRUPO_ID},"
else
  NAMESPACE=""
fi

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

crear_proyecto() {
  local nombre="$1"
  local respuesta
  respuesta=$(curl -sS --request POST --header "PRIVATE-TOKEN: ${TOKEN}" \
    --header "Content-Type: application/json" \
    --data "{
      ${NAMESPACE}
      \"name\": \"${nombre}\",
      \"path\": \"${nombre}\",
      \"visibility\": \"public\",
      \"description\": \"Kubo — ${nombre}\",
      \"initialize_with_readme\": false
    }" \
    "${API}/projects")

  echo "${respuesta}" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    if 'web_url' in data:
        print('OK ' + data['http_url_to_repo'])
    elif 'message' in data:
        message = data['message']
        if isinstance(message, dict) and 'path' in message:
            print('EXISTE')
        else:
            print('ERROR ' + str(message))
    else:
        print('ERROR ' + str(data)[:160])
except Exception as error:
    print('ERROR ' + str(error))
"
}

for repo in "${REPOS[@]}"; do
  # El repositorio raiz del workspace vive en la carpeta Kubo/
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
  resultado=$(crear_proyecto "${repo}")
  url=""

  if [[ "${resultado}" == OK* ]]; then
    url="${resultado#OK }"
    echo "proyecto creado"
  elif [[ "${resultado}" == "EXISTE" ]]; then
    url="https://gitlab.com/${GROUP:+${GROUP}/}${USUARIO}/${repo}.git"
    echo "ya existia, se reutiliza"
  else
    echo "${resultado}"
    continue
  fi

  # Push sin guardar el token en la configuracion del repositorio
  url_con_token=$(echo "${url}" | sed "s#https://#https://oauth2:${TOKEN}@#")
  if git -C "${ruta}" remote get-url origin >/dev/null 2>&1; then
    git -C "${ruta}" remote set-url origin "${url}"
  else
    git -C "${ruta}" remote add origin "${url}"
  fi

  if git -C "${ruta}" push --quiet "${url_con_token}" main 2>/dev/null; then
    echo "                  publicado en ${url}"
  else
    echo "                  ERROR al publicar (revisa permisos del token)"
  fi
done

echo
echo "[kubo] listo. Recuerda revocar el token en GitLab."
