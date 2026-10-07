# kubo-infra
[!\[CI](https://github.com/NFGS/kubo-infra/actions/workflows/ci.yml/badge.svg)\]([https://github.com/NFGS/kubo-infra/actions/workflows/ci.yml](https://github.com/NFGS/kubo-infra/actions/workflows/ci.yml))
> Parte del proyecto **Kubo** — [kubo-workspace](https://github.com/NFGS/kubo-workspace) (ERP + CRM autoalojable para PYMES).
Infraestructura como codigo del sistema Kubo: orquestacion de contenedores,
semilla de datos, pruebas de humo y utilidades de operacion.
## Contenido
<table header-row="true">
<tr>
<td>Ruta</td>
<td>Descripcion</td>
</tr>
<tr>
<td>`docker-compose.yml`</td>
<td>Define los 12 contenedores (4 microservicios + gateway + web + TLS + OTel + Postgres + Mongo + RabbitMQ + Redis)</td>
</tr>
<tr>
<td>`.env.example`</td>
<td>Plantilla de variables de entorno</td>
</tr>
<tr>
<td>`caddy/Caddyfile`</td>
<td>Terminacion TLS del local (HTTPS, redireccion y HSTS)</td>
</tr>
<tr>
<td>`systemd/kubo-backup.*`</td>
<td>Respaldo diario programado (03:30)</td>
</tr>
<tr>
<td>`scripts/init-db.sh`</td>
<td>Crea una base de datos y un rol aislado por microservicio</td>
</tr>
<tr>
<td>`scripts/seed.sh`</td>
<td>Carga datos de demostracion (clientes, productos, ventas)</td>
</tr>
<tr>
<td>`scripts/smoke.sh`</td>
<td>Prueba el flujo completo end-to-end (192 comprobaciones)</td>
</tr>
<tr>
<td>`scripts/bus-drill.sh`</td>
<td>Simulacro: caida del bus sin perdida de eventos (outbox)</td>
</tr>
<tr>
<td>`scripts/backup.sh`</td>
<td>Respaldo de PostgreSQL, MongoDB y la configuracion</td>
</tr>
<tr>
<td>`scripts/restore-drill.sh`</td>
<td>Restaura en bases de prueba y compara filas</td>
</tr>
<tr>
<td>`scripts/operacion-check.sh`</td>
<td>Chequeo diario de operación (salud, respaldo verificado, disco, certificados)</td>
</tr>
<tr>
<td>`scripts/tenant-admin.sh`</td>
<td>Superficie del operador: listar, suspender, reactivar, renovar y uso</td>
</tr>
<tr>
<td>`scripts/gen-internal-certs.sh`</td>
<td>CA interna y certificados de la malla mTLS (P-28)</td>
</tr>
<tr>
<td>`scripts/obsidian-sync.sh`</td>
<td>Espeja la documentación en el vault de Obsidian (4.º entorno)</td>
</tr>
<tr>
<td>`scripts/notion-sync.sh`</td>
<td>Espeja la documentación en Notion preservando callouts y diagramas</td>
</tr>
<tr>
<td>`scripts/kubo-sync.sh`</td>
<td>Orquestador de los 4 entornos: `status`, `run` y `watch`</td>
</tr>
<tr>
<td>`backup/`</td>
<td>Operador de respaldos: respaldo → retención → verificación → manifiesto (ADR-0022)</td>
</tr>
<tr>
<td>`load/pos.js` · `load/catalog.js`</td>
<td>Carga k6: 50 cajas en el POS y catálogo de 50.000 productos</td>
</tr>
<tr>
<td>`load/seed-big-catalog.sh`</td>
<td>Siembra/limpia el catálogo voluminoso de la demo (`make load-big`)</td>
</tr>
<tr>
<td>`scripts/github-push.sh`</td>
<td>Publica los 9 repositorios en GitHub con `gh` autenticado (`make push-github`)</td>
</tr>
<tr>
<td>`ansible/`</td>
<td>Instalación remota con secretos únicos generados en el host</td>
</tr>
<tr>
<td>`scripts/foreign-stop.sh`</td>
<td>Detiene contenedores ajenos para liberar RAM</td>
</tr>
<tr>
<td>`scripts/foreign-start.sh`</td>
<td>Reactiva los contenedores detenidos</td>
</tr>
</table>
## Puertos publicados
<table header-row="true">
<tr>
<td>Servicio</td>
<td>Host</td>
<td>Contenedor</td>
</tr>
<tr>
<td>PWA</td>
<td>3000</td>
<td>80</td>
</tr>
<tr>
<td>TLS (Caddy): HTTPS · HTTP</td>
<td>3443 · 3080</td>
<td>443 · 80</td>
</tr>
<tr>
<td>OTel collector: gRPC · HTTP · salud</td>
<td>4317 · 4318 · 13133</td>
<td>4317 · 4318 · 13133</td>
</tr>
<tr>
<td>Grafana (perfil `observability`)</td>
<td>3001</td>
<td>3000</td>
</tr>
<tr>
<td>API Gateway</td>
<td>9080</td>
<td>8080</td>
</tr>
<tr>
<td>IAM</td>
<td>9081</td>
<td>8081</td>
</tr>
<tr>
<td>CRM</td>
<td>9082</td>
<td>8082</td>
</tr>
<tr>
<td>ERP</td>
<td>9083</td>
<td>8083</td>
</tr>
<tr>
<td>Analytics</td>
<td>9084</td>
<td>8084</td>
</tr>
<tr>
<td>Postgres</td>
<td>5433</td>
<td>5432</td>
</tr>
<tr>
<td>MongoDB</td>
<td>27018</td>
<td>27017</td>
</tr>
<tr>
<td>RabbitMQ (AMQP)</td>
<td>5673</td>
<td>5672</td>
</tr>
<tr>
<td>RabbitMQ (UI)</td>
<td>15673</td>
<td>15672</td>
</tr>
<tr>
<td>Redis</td>
<td>6380</td>
<td>6379</td>
</tr>
</table>
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
make smoke          # 192 comprobaciones end-to-end
make bus-drill      # caida del bus sin perdida de eventos
make backup         # respaldo de bases y configuracion
make restore-drill  # simulacro de restauracion cronometrado
make down
```
Espejo de conocimiento (opcional):
```bash
./kubo-infra/scripts/obsidian-sync.sh   # documentacion -> vault de Obsidian
```
Sincronización de los 4 entornos (directorio del proyecto, GitHub, Notion y
Obsidian): cada espejo guarda la huella de las fuentes canónicas y `run`
propaga solo lo desviado (PDF → Notion → Obsidian → push).
```bash
make sync-status   # estado y desvíos (no cambia nada)
make sync          # propaga los cambios y empuja commits pendientes
./kubo-infra/scripts/kubo-sync.sh watch   # vigila y propaga al detectar cambios
```
## Observabilidad (Fase 2)
<table header-row="true">
<tr>
<td>Ruta</td>
<td>Descripcion</td>
</tr>
<tr>
<td>`otel/collector.yaml`</td>
<td>Collector OTLP base: recibe trazas de los cinco servicios y las escribe en su log</td>
</tr>
<tr>
<td>`otel/collector-observability.yaml`</td>
<td>Variante que además exporta a Tempo</td>
</tr>
<tr>
<td>`docker-compose.observability.yml`</td>
<td>Perfil `observability`: Tempo + Grafana con datasource provisionado</td>
</tr>
</table>
```bash
make observability   # Grafana en http://localhost:3001 (admin / kubo_admin)
docker logs kubo-otel  # las trazas crudas, sin stack visual
```
## Calidad (Fase 2)
<table header-row="true">
<tr>
<td>Ruta</td>
<td>Descripcion</td>
</tr>
<tr>
<td>`scripts/secret-scan.sh`</td>
<td>Escaneo de secretos sobre archivos versionados</td>
</tr>
<tr>
<td>`scripts/ci-local.sh`</td>
<td>Gate completo: secretos, suites, contratos, humo y E2E (`make ci`)</td>
</tr>
<tr>
<td>`scripts/erp-tests.sh`</td>
<td>Pruebas puras del ERP en contenedor aparte</td>
</tr>
<tr>
<td>`scripts/bus-drill.sh`</td>
<td>Simulacro de caída del bus</td>
</tr>
<tr>
<td>`scripts/backup.sh` · `scripts/restore-drill.sh`</td>
<td>Respaldo y simulacro cronometrado</td>
</tr>
</table>
