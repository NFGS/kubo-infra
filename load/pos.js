/**
 * Prueba de carga del POS (P-10): 50 cajas vendiendo a la vez.
 *
 * Simula el turno real: cada caja busca un producto y registra una venta.
 * El criterio de aceptacion de la Fase 2 es p95 < 300 ms en la venta.
 *
 * El limite de tasa por usuario se eleva durante la prueba (make load lo hace):
 * aqui se mide la capacidad del POS, no el limitador.
 *
 * Uso:  make load
 */
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter } from 'k6/metrics';

// Desglose de respuestas de la venta: un 409 de negocio (stock, numero) se
// distingue de un 429 o un 5xx, y eso hace la prueba diagnosticable.
const saleStatus = new Counter('sale_status');

const BASE = __ENV.KUBO_API ?? 'http://host.docker.internal:9080/api/v1';
const EMAIL = __ENV.KUBO_ADMIN_EMAIL ?? 'admin@kubo.local';
const PASSWORD = __ENV.KUBO_ADMIN_PASSWORD ?? 'Admin123!';

const PRODUCTOS = 10;
const STOCK_INICIAL = 1000000;

export const options = {
  scenarios: {
    pos: {
      executor: 'constant-vus',
      vus: 50,
      duration: '30s',
    },
  },
  thresholds: {
    'http_req_duration{name:pos_sale}': ['p(95)<300'],
    checks: ['rate>0.99'],
  },
};

export function setup() {
  const login = http.post(
    `${BASE}/auth/login`,
    JSON.stringify({ email: EMAIL, password: PASSWORD }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'setup_login' } },
  );
  const token = login.json('accessToken');
  if (!token) {
    throw new Error(`No fue posible autenticar en setup: ${login.status} ${login.body}`);
  }

  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` };
  const productIds = [];
  const stamp = Date.now();

  for (let index = 0; index < PRODUCTOS; index += 1) {
    const sku = `LOAD-${stamp}-${index}`;
    const created = http.post(
      `${BASE}/products`,
      JSON.stringify({ sku, name: `Producto de carga ${index}`, price: 1000, cost: 600, min_stock: 0 }),
      { headers, tags: { name: 'setup_product' } },
    );
    const id = created.json('data.id');
    if (!id) {
      throw new Error(`No fue posible crear el producto de carga: ${created.status} ${created.body}`);
    }

    http.post(
      `${BASE}/products/${id}/stock`,
      JSON.stringify({ kind: 'ADJUST', quantity: STOCK_INICIAL, reason: 'Prueba de carga' }),
      { headers, tags: { name: 'setup_stock' } },
    );
    productIds.push(id);
  }

  return { token, productIds };
}

export default function (data) {
  const headers = { 'Content-Type': 'application/json', Authorization: `Bearer ${data.token}` };
  const productId = data.productIds[__VU % data.productIds.length];

  // La caja busca en el catalogo (el POS filtra mientras se escribe).
  http.get(`${BASE}/products?q=carga&limit=5`, { headers, tags: { name: 'pos_search' } });

  // Y cobra.
  const sale = http.post(
    `${BASE}/sales`,
    JSON.stringify({
      items: [{ product_id: productId, quantity: 1 }],
      payment_method: 'CASH',
    }),
    { headers, tags: { name: 'pos_sale' } },
  );

  saleStatus.add(1, { status: String(sale.status) });

  check(sale, {
    'la venta responde 201': (response) => response.status === 201,
  });

  sleep(0.1);
}
