#!/bin/bash
# ---------------------------------------------------------------------------
# CA interna y certificados de la malla (P-28, ADR-0020).
#
# Los nombres de los servicios solo existen en la red del compose: se firma con
# una CA propia, no con una publica. Las llaves NO se versionan; cada despliegue
# genera las suyas con `make certs`.
#
# Idempotente: no reescribe un certificado existente. Para rotar, borrar
# `certs/` y volver a generar (despues hay que recrear los servicios).
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DIR="${ROOT}/kubo-infra/certs"
SERVICIOS="iam crm erp analytics gateway"

mkdir -p "${DIR}"
chmod 700 "${DIR}"

if [[ ! -f "${DIR}/ca.crt" ]]; then
  echo "[certs] creando CA interna"
  openssl req -x509 -newkey rsa:4096 -sha256 -days 3650 -nodes \
    -keyout "${DIR}/ca.key" -out "${DIR}/ca.crt" \
    -subj "/CN=Kubo Internal CA/O=Kubo" 2>/dev/null
fi

for servicio in ${SERVICIOS}; do
  nombre="kubo-${servicio}"

  if [[ -f "${DIR}/${servicio}.crt" ]]; then
    echo "[certs] ${nombre}: ya existe"
    continue
  fi

  echo "[certs] certificado de ${nombre}"

  openssl req -newkey rsa:2048 -sha256 -nodes \
    -keyout "${DIR}/${servicio}.key" -out "${DIR}/${servicio}.csr" \
    -subj "/CN=${nombre}/O=Kubo" 2>/dev/null

  # `localhost` en los SAN: los healthchecks corren dentro del contenedor y la
  # verificacion de nombre tambien debe ejercerse ahi.
  cat > "${DIR}/${servicio}.ext" <<EOF
subjectAltName=DNS:${nombre},DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth,clientAuth
basicConstraints=CA:FALSE
EOF

  openssl x509 -req -in "${DIR}/${servicio}.csr" \
    -CA "${DIR}/ca.crt" -CAkey "${DIR}/ca.key" -CAcreateserial \
    -out "${DIR}/${servicio}.crt" -days 825 -sha256 \
    -extfile "${DIR}/${servicio}.ext" 2>/dev/null

  rm -f "${DIR}/${servicio}.csr" "${DIR}/${servicio}.ext"
done

# 644: el contenedor (que puede correr como usuario sin privilegios) necesita
# leer su llave para servir TLS y para el healthcheck; el directorio del host
# (700) sigue cerrando el acceso desde fuera del despliegue.
chmod 644 "${DIR}"/*.key
echo "[certs] listo: ${DIR}"
