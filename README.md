# kubo-infra

Infraestructura como codigo del sistema Kubo: orquestacion de contenedores,
semilla de datos, pruebas de humo y utilidades de operacion.

## Contenido

| Ruta | Descripcion |
| --- | --- |
| `docker-compose.yml` | Define los 12 contenedores (4 microservicios + gateway + web + TLS + OTel + Postgres + Mongo + RabbitMQ + Redis) |
| `.env.example` | Plantilla de variables de entorno |
| `caddy/Caddyfile` | Terminacion TLS del local (HTTPS, redireccion y HSTS) |
| `systemd/kubo-backup.*` | Respaldo diario programado (03:30) |
| `scripts/init-db.sh` | Crea una base de datos y un rol aislado por microservicio |
| `scripts/seed.sh` | Carga datos de demostracion (clientes, productos, ventas) |
| `scripts/smoke.sh` | Prueba el flujo completo end-to-end (184 comprobaciones) |
| `scripts/bus-drill.sh` | Simulacro: caida del bus sin perdida de eventos (outbox) |
| `scripts/backup.sh` | Respaldo de PostgreSQL, MongoDB y la configuracion |
| `scripts/restore-drill.sh` | Restaura en bases de prueba y compara filas |
| `scripts/operacion-check.sh` | Chequeo diario de operación (salud, respaldo verificado, disco, certificados) |
| `scripts/tenant-admin.sh` | Superficie del operador: listar, suspender, reactivar, renovar y uso |
| `scripts/gen-internal-certs.sh` | CA interna y certificados de la malla mTLS (P-28) |
| `backup/` | Operador de respaldos: respaldo → retención → verificación → manifiesto (ADR-0022) |
| `load/pos.js` · `load/catalog.js` | Carga k6: 50 cajas en el POS y catálogo de 50.000 productos |
| `load/seed-big-catalog.sh` | Siembra/limpia el catálogo voluminoso de la demo (`make load-big`) |
| `scripts/github-push.sh` | Publica los 9 repositorios en GitHub con `gh` autenticado (`make push-github`) |
| `ansible/` | Instalación remota con secretos únicos generados en el host |
| `scripts/foreign-stop.sh` | Detiene contenedores ajenos para liberar RAM |
| `scripts/foreign-start.sh` | Reactiva los contenedores detenidos |

## Puertos publicados

| Servicio | Host | Contenedor |
| --- | --- | --- |
| PWA | 3000 | 80 |
| TLS (Caddy): HTTPS · HTTP | 3443 · 3080 | 443 · 80 |
| OTel collector: gRPC · HTTP · salud | 4317 · 4318 · 13133 | 4317 · 4318 · 13133 |
| Grafana (perfil `observability`) | 3001 | 3000 |
| API Gateway | 9080 | 8080 |
| IAM | 9081 | 8081 |
| CRM | 9082 | 8082 |
| ERP | 9083 | 8083 |
| Analytics | 9084 | 8084 |
| Postgres | 5433 | 5432 |
| MongoDB | 27018 | 27017 |
| RabbitMQ (AMQP) | 5673 | 5672 |
| RabbitMQ (UI) | 15673 | 15672 |
| Redis | 6380 | 6379 |

Los puertos se eligieron fuera del rango 8000-8100 para no chocar con otros
servicios que puedan estar corriendo en la maquina del negocio.

## Preparacion

```bash
cp .env.example .env
# Generar claves de cifrado reales:
openssl rand -hex 32   # KUBO_FIELD_ENCRYPTION_KEY
openssl rand -hex 32   # KUBO_BLIND_INDEX_KEY
```

## Uso

```bash
make up             # desde la raiz del workspace
make smoke          # 184 comprobaciones end-to-end
make bus-drill      # caida del bus sin perdida de eventos
make backup         # respaldo de bases y configuracion
make restore-drill  # simulacro de restauracion cronometrado
make down
```

## Observabilidad (Fase 2)

| Ruta | Descripcion |
| --- | --- |
| `otel/collector.yaml` | Collector OTLP base: recibe trazas de los cinco servicios y las escribe en su log |
| `otel/collector-observability.yaml` | Variante que además exporta a Tempo |
| `docker-compose.observability.yml` | Perfil `observability`: Tempo + Grafana con datasource provisionado |

```bash
make observability   # Grafana en http://localhost:3001 (admin / kubo_admin)
docker logs kubo-otel  # las trazas crudas, sin stack visual
```

## Calidad (Fase 2)

| Ruta | Descripcion |
| --- | --- |
| `scripts/secret-scan.sh` | Escaneo de secretos sobre archivos versionados |
| `scripts/ci-local.sh` | Gate completo: secretos, suites, contratos, humo y E2E (`make ci`) |
| `scripts/erp-tests.sh` | Pruebas puras del ERP en contenedor aparte |
| `scripts/bus-drill.sh` | Simulacro de caída del bus |
| `scripts/backup.sh` · `scripts/restore-drill.sh` | Respaldo y simulacro cronometrado |
