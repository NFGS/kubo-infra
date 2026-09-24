#!/bin/bash
# ---------------------------------------------------------------------------
# Deja la demostracion en un estado limpio y conocido.
#
# Borra los datos generados por las ejecuciones de la prueba de humo (clientes y
# productos de prueba, negocios de aislamiento) y vuelve a cargar la semilla.
#
# Uso:  make reset-demo
#
# ADVERTENCIA: elimina datos. Es una herramienta de demostracion, no de
# produccion: en un negocio real jamas debe ejecutarse.
# ---------------------------------------------------------------------------
set -euo pipefail

BASE="${KUBO_API:-http://localhost:9080/api/v1}"
WORKSPACE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

confirmar() {
  if [[ "${KUBO_FORCE:-}" == "true" ]]; then
    return
  fi
  read -r -p "Esto borra los datos de demostracion. ¿Continuar? [s/N] " respuesta
  [[ "${respuesta}" =~ ^[sS]$ ]] || { echo "Cancelado."; exit 0; }
}

confirmar

echo "[kubo] limpiando datos de demostracion"

# --- Identidad: negocios de prueba y bitacora ---------------------------------
docker exec kubo-postgres psql -U kubo_root -d kubo_iam -q -c "
  DELETE FROM tenants WHERE slug LIKE 'negocio-aislado%';
  TRUNCATE audit_logs;
  TRUNCATE mail_outbox;
" && echo "  identidad: negocios de prueba eliminados, bitacora y buzon reiniciados"

# --- CRM: clientes ------------------------------------------------------------
docker exec kubo-postgres psql -U kubo_root -d kubo_crm -q -c "DELETE FROM customers;" \
  && echo "  crm: clientes eliminados"

# --- ERP: ventas, kardex y catalogo ------------------------------------------
docker exec kubo-postgres psql -U kubo_root -d kubo_erp -q -c "
  TRUNCATE sale_items, sales, stock_movements, products CASCADE;
  TRUNCATE outbox_events;
" && echo "  erp: ventas, kardex, catalogo y bandeja de salida reiniciados"

# --- Analitica: modelo de lectura --------------------------------------------
docker exec kubo-mongo mongosh kubo_analytics --quiet --eval "
  db.events.deleteMany({});
  db.sales.deleteMany({});
" >/dev/null 2>&1 && echo "  analitica: modelo de lectura reiniciado"

echo "[kubo] cargando la semilla"
"${WORKSPACE_DIR}/kubo-infra/scripts/seed.sh" | tail -12

echo
echo "[kubo] demostracion lista. Estado:"
curl -sS -X POST "${BASE}/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"${KUBO_ADMIN_EMAIL:-admin@kubo.local}\",\"password\":\"${KUBO_ADMIN_PASSWORD:-Admin123!}\"}" \
  | jq -r '.accessToken' > /tmp/kubo-reset-token

curl -sS "${BASE}/dashboard/overview" -H "Authorization: Bearer $(cat /tmp/kubo-reset-token)" \
  | jq '.data | {ventas: .summary.sales_count, ingreso: .summary.revenue, clientes: .customers.total, productos: (.top_products | length)}'
