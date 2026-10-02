# syntax=docker/dockerfile:1.7

# ---------------------------------------------------------------------------
# Operador de respaldos (ADR-0022).
#
# La imagen del cliente de Postgres 17 (misma version que el servidor: un
# pg_dump viejo no puede volcar un servidor nuevo) mas las herramientas de
# Mongo y rclone para la copia fuera del sitio. Habla con los servicios por la
# red del compose: no necesita el socket de Docker ni acceso al host.
# ---------------------------------------------------------------------------
FROM postgres:17-alpine@sha256:b0f9560a2de083e2cc7382e75f808c7381a32852a7ec49117deedb300e552b24

RUN apk add --no-cache bash mongodb-tools rclone

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod +x /usr/local/bin/backup.sh

ENTRYPOINT ["/usr/local/bin/backup.sh"]
