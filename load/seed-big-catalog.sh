#!/bin/bash
# ---------------------------------------------------------------------------
# Catalogo voluminoso para la prueba de carga (P-10).
#
# Inserta N productos por SQL directo (el alta por API tardaria minutos) en el
# negocio de demostracion, con su nivel en la bodega por defecto. Es
# idempotente: reemplaza los SKU BULK-% en cada corrida.
#
# Uso:  ./kubo-infra/load/seed-big-catalog.sh [cantidad]
#       ./kubo-infra/load/seed-big-catalog.sh --clean
# ---------------------------------------------------------------------------
set -euo pipefail

CANTIDAD=50000
LIMPIAR=false

if [[ "${1:-}" == "--clean" ]]; then
  LIMPIAR=true
elif [[ -n "${1:-}" ]]; then
  CANTIDAD="$1"
fi

psql_erp() {
  docker exec kubo-postgres psql -U kubo_root -d kubo_erp -v ON_ERROR_STOP=1 -tAc "$1"
}

psql_iam() {
  docker exec kubo-postgres psql -U kubo_root -d kubo_iam -tAc "$1"
}

TENANT="$(psql_iam "select id from tenants where slug = 'tienda-la-esquina' limit 1")"
if [[ -z "${TENANT}" ]]; then
  echo "No se encontro el negocio de demostracion (tienda-la-esquina)" >&2
  exit 1
fi

WAREHOUSE="$(psql_erp "select id from warehouses where tenant_id = '${TENANT}' and is_default limit 1")"
if [[ -z "${WAREHOUSE}" ]]; then
  echo "El negocio de demostracion no tiene bodega por defecto" >&2
  exit 1
fi

echo "[kubo] limpiando el catalogo de carga anterior"
psql_erp "delete from stock_levels where product_id in (select id from products where tenant_id = '${TENANT}' and sku like 'BULK-%')" >/dev/null
psql_erp "delete from products where tenant_id = '${TENANT}' and sku like 'BULK-%'" >/dev/null

if [[ "${LIMPIAR}" == "true" ]]; then
  echo "[kubo] catalogo de carga eliminado"
  exit 0
fi

echo "[kubo] sembrando ${CANTIDAD} productos..."
psql_erp "
  insert into products
    (id, tenant_id, sku, name, unit, price, cost, tax_rate, stock, min_stock, active, inserted_at, updated_at, tracks_stock)
  select gen_random_uuid(), '${TENANT}', 'BULK-' || lpad(i::text, 6, '0'),
         'Producto de carga ' || i || ' ' ||
           (array['arroz','aceite','panela','cafe','jabon','gaseosa'])[1 + (i % 6)],
         'UND', (1000 + (i % 500) * 100)::numeric, (600 + (i % 500) * 50)::numeric,
         19, 100000, 0, true, now(), now(), true
  from generate_series(1, ${CANTIDAD}) as i" >/dev/null

psql_erp "
  insert into stock_levels (id, tenant_id, warehouse_id, product_id, stock, inserted_at, updated_at)
  select gen_random_uuid(), '${TENANT}', '${WAREHOUSE}', p.id, p.stock, now(), now()
  from products p where p.tenant_id = '${TENANT}' and p.sku like 'BULK-%'" >/dev/null

TOTAL="$(psql_erp "select count(*) from products where tenant_id = '${TENANT}' and sku like 'BULK-%'")"
echo "[kubo] catalogo listo: ${TOTAL} productos de carga en la bodega por defecto"
