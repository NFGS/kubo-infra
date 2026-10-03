#!/bin/bash
# ---------------------------------------------------------------------------
# Administracion de negocios (P-27, ADR-0024).
#
#   tenant-admin.sh list                          Negocios: slug, plan, estado, cupo y renovacion
#   tenant-admin.sh suspend <slug|correo>         Suspende el negocio (reversible, no toca datos)
#   tenant-admin.sh activate <slug|correo>        Reactiva el negocio
#   tenant-admin.sh renew <slug|correo> [dias]    Registra el pago: extiende la renovacion (30 dias)
#   tenant-admin.sh usage                         Uso y soporte por negocio (F6.5)
#   tenant-admin.sh platform-reset                Desbloquea al operador de plataforma (P-11)
#
# Es la superficie del operador mientras no exista un rol de plataforma: el
# dueno del despliegue ya tiene acceso al servidor, y un script no agrega
# superficie de ataque. Solo consulta la base de identidad: nunca los datos del
# CRM ni del ERP (el aislamiento lo garantiza RLS, no la buena voluntad).
#
# Uso:  ./kubo-infra/scripts/tenant-admin.sh list
# ---------------------------------------------------------------------------
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ENV_FILE="${ROOT}/kubo-infra/.env"

leer_env() {
  local clave="$1" por_defecto="$2" valor=""
  if [[ -f "${ENV_FILE}" ]]; then
    valor="$(grep -E "^${clave}=" "${ENV_FILE}" | tail -1 | cut -d= -f2-)"
  fi
  printf '%s' "${valor:-${por_defecto}}"
}

ROOT_PASSWORD="$(leer_env KUBO_POSTGRES_ROOT_PASSWORD kubo_root_dev)"

psql_iam() {
  docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
    psql -U kubo_root -d kubo_iam -tAc "$1"
}

# El ERP tambien se consulta como superusuario: agrega por negocio sin depender
# de RLS, pero SOLO cuenta filas (nunca lee datos de negocio).
psql_erp() {
  docker exec -e PGPASSWORD="${ROOT_PASSWORD}" kubo-postgres \
    psql -U kubo_root -d kubo_erp -tAc "$1"
}

accion="${1:-list}"
objetivo="${2:-}"

case "${accion}" in
  list)
    echo "slug|plan|estado|usuarios_activos|renueva"
    psql_iam "
      select t.slug || '|' || t.plan || '|' || t.status || '|' ||
             count(u.id) filter (where u.status = 'ACTIVE') || '|' ||
             coalesce(to_char(t.plan_renews_at, 'YYYY-MM-DD'), 'sin fecha')
      from tenants t
      left join users u on u.tenant_id = t.id
      group by t.id
      order by t.created_at"
    ;;

  suspend | activate)
    if [[ -z "${objetivo}" ]]; then
      echo "Falta el negocio: slug o correo de un usuario" >&2
      exit 1
    fi

    # El objetivo lo escribe el operador, pero se acota igual: nada de comillas
    # ni sentencias en un valor que entra a SQL.
    if [[ ! "${objetivo}" =~ ^[A-Za-z0-9@._-]+$ ]]; then
      echo "El negocio solo admite letras, numeros, arroba, punto, guion y guion bajo" >&2
      exit 1
    fi

    estado="ACTIVE"
    [[ "${accion}" = "suspend" ]] && estado="SUSPENDED"

    afectados=$(psql_iam "
      with negocio as (
        select id from tenants where slug = '${objetivo}'
        union
        select tenant_id from users where lower(email) = lower('${objetivo}')
      )
      update tenants set status = '${estado}' where id in (select id from negocio)
      returning slug")

    if [[ -z "${afectados}" ]]; then
      echo "No se encontro un negocio para '${objetivo}'" >&2
      exit 1
    fi

    echo "[kubo] negocio ${afectados} -> ${estado}"
    ;;

  usage)
    # Metricas de operacion y soporte (F6.5): uso por negocio contra su plan y
    # accesos fallidos de la ultima semana (el primer sintoma de un problema).
    echo "slug|plan|estado|usuarios|bodegas|productos|ventas_mes|documentos_kb|accesos_fallidos_7d"

    psql_iam "
      select t.id || ' ' || t.slug || ' ' || t.plan || ' ' || t.status || ' ' || t.timezone || ' ' ||
             (select count(*) from users u where u.tenant_id = t.id and u.status = 'ACTIVE') || ' ' ||
             (select count(*) from audit_logs a
               where a.tenant_id = t.id and a.action = 'LOGIN_FAILED'
                 and a.created_at > now() - interval '7 days')
      from tenants t
      order by t.created_at" | while read -r id slug plan estado zona usuarios fallidos; do
      erp=$(psql_erp "
        select (select count(*) from warehouses w where w.tenant_id = '${id}' and w.deleted_at is null)
             || '|' ||
               (select count(*) from products p where p.tenant_id = '${id}' and p.deleted_at is null)
             || '|' ||
               (select count(*) from sales s
                 where s.tenant_id = '${id}' and s.status = 'COMPLETED'
                   and to_char(s.inserted_at, 'YYYY-MM') = to_char(now() at time zone '${zona}', 'YYYY-MM'))
             || '|' ||
               (select coalesce(sum(d.size), 0) / 1024 from documents d where d.tenant_id = '${id}')")

      echo "${slug}|${plan}|${estado}|${usuarios}|${erp}|${fallidos}"
    done
    ;;

  renew)
    if [[ -z "${objetivo}" ]]; then
      echo "Falta el negocio: slug o correo de un usuario" >&2
      exit 1
    fi

    if [[ ! "${objetivo}" =~ ^[A-Za-z0-9@._-]+$ ]]; then
      echo "El negocio solo admite letras, numeros, arroba, punto, guion y guion bajo" >&2
      exit 1
    fi

    dias="${3:-30}"
    if [[ ! "${dias}" =~ ^[0-9]+$ ]] || [[ "${dias}" -lt 1 ]]; then
      echo "Los dias deben ser un entero positivo" >&2
      exit 1
    fi

    # La fecha se extiende desde hoy o desde la renovacion vigente, la que sea
    # mayor: pagar antes de vencer no regala dias. "Hoy" es el dia del negocio
    # (su zona horaria), no la fecha UTC del contenedor: a las 19:00 de Bogota
    # UTC ya es el dia siguiente y la renovacion quedaria corrida un dia.
    afectados=$(psql_iam "
      with negocio as (
        select t.id, (now() at time zone t.timezone)::date as hoy
        from tenants t
        where t.slug = '${objetivo}'
           or exists (select 1 from users u
                      where u.tenant_id = t.id and lower(u.email) = lower('${objetivo}'))
      )
      update tenants t
      set plan_renews_at = greatest(coalesce(t.plan_renews_at, n.hoy), n.hoy)
                           + make_interval(days => ${dias})
      from negocio n
      where t.id = n.id
      returning t.slug || ' hasta ' || to_char(t.plan_renews_at, 'YYYY-MM-DD')")

    if [[ -z "${afectados}" ]]; then
      echo "No se encontro un negocio para '${objetivo}'" >&2
      exit 1
    fi

    echo "[kubo] renovado ${afectados}"
    ;;

  platform-reset)
    # Camino de emergencia (ADR-0025): limpia el contador de intentos fallidos
    # y el bloqueo del operador. No toca su segundo factor.
    limpiados=$(psql_iam "
      update platform_admins
      set failed_login_attempts = 0, locked_until = null
      where failed_login_attempts > 0 or locked_until is not null
      returning email")

    echo "[kubo] operador sin bloqueo: ${limpiados:-no habia bloqueos}"
    ;;

  *)
    echo "Uso: tenant-admin.sh list | usage | suspend <slug|correo> | activate <slug|correo> | renew <slug|correo> [dias] | platform-reset" >&2
    exit 1
    ;;
esac
