# Operador de respaldos (ADR-0022)

Ciclo **respaldo → retención → verificación → manifiesto**, sin socket de Docker:
habla con Postgres y Mongo por la red del compose y lee el volumen de documentos
en solo lectura.

```bash
make backup-operator        # un ciclo (con verificación de restauración)
make backup-operator-loop   # deja el operador corriendo (ciclo diario)
```

## Qué guarda cada respaldo

| Archivo | Contenido |
| --- | --- |
| `kubo_iam.dump`, `kubo_crm.dump`, `kubo_erp.dump` | Las tres bases (formato custom de `pg_dump`) |
| `kubo_analytics.archive` | La proyección de analítica (`mongodump`) |
| `documents.tar.gz` | El volumen de documentos: XML de facturas y comprobantes PDF |
| `env.env` | La configuración (permisos 600; se cifra con `age` si está disponible) |
| `MANIFEST` | Fecha, conteos, resultado de la verificación y **SHA-256** de cada archivo |

## Variables

| Variable | Por defecto | Para qué |
| --- | --- | --- |
| `KUBO_BACKUP_RETENTION_DAYS` | `14` | Antigüedad máxima de un respaldo |
| `KUBO_BACKUP_KEEP_MIN` | `3` | Respaldos que se conservan aunque la antigüedad los alcance |
| `KUBO_BACKUP_VERIFY` | `true` | Restaurar en bases de usar y tirar y comparar conteos |
| `KUBO_BACKUP_INTERVAL_HOURS` | `24` | Frecuencia del modo bucle |
| `KUBO_BACKUP_OFFSITE_DIR` | `./backups-offsite` | Copia fuera del sitio con `rclone`: una ruta montada (otro disco, NFS) **o un remoto configurado** (`s3:bucket/kubo`, `b2:...`, `drive:...`). La copia se verifica con `rclone check` |
| `KUBO_BACKUP_UID` / `KUBO_BACKUP_GID` | `1000` / `1000` | Usuario con el que corre el operador: los respaldos quedan en el volumen del dueño, **no de root** |

## Operación

- **Comprobar sin restaurar**: el `MANIFEST` trae el SHA-256 de cada archivo;
  `sha256sum -c` sobre él detecta un archivo alterado.
- **Verificación completa**: `make restore-drill` restaura en bases de prueba y
  valida la aplicación contra los datos (el operador verifica conteos en cada
  ciclo; el simulacro es la prueba de extremo a extremo).
- **Un ciclo fallido** termina con código de salida distinto de cero y deja
  `verificacion=fallida` en el manifiesto: no debe pasar por bueno.
- **Restaurar a mano**: `pg_restore -d kubo_erp kubo_erp.dump` y
  `tar -xzf documents.tar.gz -C /data/documents`.
- **Remoto de objeto**: para S3/B2/Drive, configurar el remoto de rclone en el
  contenedor (`rclone config` sobre un archivo montado en `/root/.config/rclone`)
  y apuntar `KUBO_BACKUP_OFFSITE_DIR` a ese remoto; la verificación y el
  manifiesto funcionan igual.
