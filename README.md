# kubo-infra

Infraestructura como codigo del sistema Kubo: orquestacion de contenedores,
semilla de datos, pruebas de humo y utilidades de operacion.

## Contenido

| Ruta | Descripcion |
| --- | --- |
| `docker-compose.yml` | Define los 11 contenedores (4 microservicios + gateway + web + TLS + Postgres + Mongo + RabbitMQ + Redis) |
| `.env.example` | Plantilla de variables de entorno |
| `caddy/Caddyfile` | Terminacion TLS del local (HTTPS, redireccion y HSTS) |
| `systemd/kubo-backup.*` | Respaldo diario programado (03:30) |
| `scripts/init-db.sh` | Crea una base de datos y un rol aislado por microservicio |
| `scripts/seed.sh` | Carga datos de demostracion (clientes, productos, ventas) |
| `scripts/smoke.sh` | Prueba el flujo completo end-to-end (73 comprobaciones) |
| `scripts/bus-drill.sh` | Simulacro: caida del bus sin perdida de eventos (outbox) |
| `scripts/backup.sh` | Respaldo de PostgreSQL, MongoDB y la configuracion |
| `scripts/restore-drill.sh` | Restaura en bases de prueba y compara filas |
| `scripts/foreign-stop.sh` | Detiene contenedores ajenos para liberar RAM |
| `scripts/foreign-start.sh` | Reactiva los contenedores detenidos |

## Puertos publicados

| Servicio | Host | Contenedor |
| --- | --- | --- |
| PWA | 3000 | 80 |
| TLS (Caddy): HTTPS · HTTP | 3443 · 3080 | 443 · 80 |
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
make smoke          # 73 comprobaciones end-to-end
make bus-drill      # caida del bus sin perdida de eventos
make backup         # respaldo de bases y configuracion
make restore-drill  # simulacro de restauracion cronometrado
make down
```
