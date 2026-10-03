/**
 * Carga con catalogo voluminoso (P-10): busqueda concurrente sobre un catalogo
 * de decenas de miles de productos, el escenario real de un negocio grande.
 *
 * `make load-big` siembra el catalogo y eleva el limite de tasa durante la
 * prueba; aqui se mide la busqueda del POS, no el limitador.
 *
 * Uso:  make load-big
 */
import http from 'k6/http';
import { check } from 'k6';

const BASE = __ENV.KUBO_API ?? 'http://kubo-gateway:8080/api/v1';
const EMAIL = __ENV.KUBO_ADMIN_EMAIL ?? 'admin@kubo.local';
const PASSWORD = __ENV.KUBO_ADMIN_PASSWORD ?? 'Admin123!';
// 10 cajas concurrentes: la busqueda individual cuesta ~6 ms, y este host de
// desarrollo (con presion de memoria) satura alrededor de 54 req/s, de modo que
// a 20 cajas el p95 se va a ~531 ms. La curva completa esta en 10-auditoria.
const VUS = Number(__ENV.KUBO_VUS ?? 10);
const TERMINOS = ['arroz', 'aceite', 'panela', 'cafe', 'jabon', 'gaseosa'];

export const options = {
  scenarios: {
    busqueda: {
      executor: 'constant-vus',
      vus: VUS,
      duration: '30s',
    },
  },
  thresholds: {
    'http_req_duration{name:catalogo_busqueda}': ['p(95)<300'],
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

  return { token };
}

export default function (data) {
  const headers = { Authorization: `Bearer ${data.token}` };
  const termino = TERMINOS[__VU % TERMINOS.length];

  const busqueda = http.get(`${BASE}/products?q=${termino}&limit=5`, {
    headers,
    tags: { name: 'catalogo_busqueda' },
  });

  check(busqueda, {
    'la busqueda responde 200': (response) => response.status === 200,
    'la busqueda devuelve productos': (response) => (response.json('data') ?? []).length > 0,
  });
}
