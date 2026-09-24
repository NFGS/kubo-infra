#!/bin/bash
# ---------------------------------------------------------------------------
# Pruebas puras del ERP (dinero, outbox y paginacion) sin base de datos.
#
# La imagen de ejecucion no incluye test/ y el contenedor de produccion se queda
# sin memoria al compilar el entorno de pruebas: se ejecuta con 3 GB y el
# directorio de pruebas montado.
#
# Uso:  ./kubo-infra/scripts/erp-tests.sh
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

docker run --rm -m 3g -e MIX_ENV=test \
  -v "${ROOT}/kubo-erp/test:/app/test:ro" \
  --entrypoint bash kubo-kubo-erp -c 'cd /app && mix compile >/dev/null 2>&1 && ERL_LIBS=/app/_build/test/lib elixir -e "ExUnit.start(); Code.require_file(\"test/kubo_erp/sales_totals_test.exs\"); Code.require_file(\"test/kubo_erp/outbox_test.exs\"); Code.require_file(\"test/kubo_erp/pagination_test.exs\")"'
