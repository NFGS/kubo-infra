#!/bin/bash
# ---------------------------------------------------------------------------
# Administracion de negocios (P-27, ADR-0024).
#
#   tenant-admin.sh list                          Negocios: slug, plan, estado, cupo y renovacion
#   tenant-admin.sh suspend <slug|correo>         Suspende el negocio (reversible, no toca datos)
#   tenant-admin.sh activate <slug|correo>        Reactiva el negocio
#   tenant-admin.sh renew <slug|correo> [dias]    Registra el pago: extiende la renovacion (30 dias)
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
    # mayor: pagar antes de vencer no regala dias.
    afectados=$(psql_iam "
      with negocio as (
        select id from tenants where slug = '${objetivo}'
        union
        select tenant_id from users where lower(email) = lower('${objetivo}')
      )
      update tenants
      set plan_renews_at = greatest(coalesce(plan_renews_at, current_date), current_date)
                           + make_interval(days => ${dias})
      where id in (select id from negocio)
      returning slug || ' hasta ' || to_char(plan_renews_at, 'YYYY-MM-DD')")

    if [[ -z "${afectados}" ]]; then
      echo "No se encontro un negocio para '${objetivo}'" >&2
      exit 1
    fi

    echo "[kubo] renovado ${afectados}"
    ;;

  *)
    echo "Uso: tenant-admin.sh list | suspend <slug|correo> | activate <slug|correo> | renew <slug|correo> [dias]" >&2
    exit 1
    ;;
esac
