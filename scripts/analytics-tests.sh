#!/bin/bash
# ---------------------------------------------------------------------------
# Pruebas de analitica: unitarias con gate de cobertura del dominio + las de
# integracion con MongoDB real (P-08, testcontainers).
#
# El contenedor comparte la red del host y monta el socket de Docker: las
# pruebas de integracion levantan un Mongo efimero y se conectan a su puerto
# publicado, que con `--network host` es alcanzable como localhost. El codigo se
# copia dentro del contenedor para no dejar `__pycache__` en el arbol.
#
# Uso:  ./kubo-infra/scripts/analytics-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "[analytics-tests] pytest + cobertura de dominio + integracion con MongoDB"
docker run --rm --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "${ROOT}/kubo-analytics:/origen:ro" \
  python:3.13-slim sh -c '
    set -e
    cp -r /origen /app && cd /app
    pip install --quiet -r requirements-dev.txt
    pytest -q --cov=app.processing --cov-report=term --cov-fail-under=80
  '
