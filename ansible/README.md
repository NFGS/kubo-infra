# Instalación remota (Fase 5)

Deja Kubo corriendo en un servidor propio con **secretos únicos** y la malla
cifrada, sin pasos manuales.

## Uso

```bash
cd kubo-infra/ansible
cp inventory.example.ini inventory.ini   # ajustar host y usuario
ansible-playbook -i inventory.ini playbook.yml
```

El playbook, en orden:

1. Instala los paquetes base y **Docker + compose** (los servicios tienen
   `restart: unless-stopped`: vuelven solos tras un reinicio del servidor).
2. Trae el código del repositorio en `KUBO_VERSION` (por defecto `main`).
3. **Genera los secretos en el host** (`kubo-infra/.env`, permisos 600): bases,
   RabbitMQ, firma de tokens, cifrado del secreto TOTP y la contraseña inicial
   del propietario. Nada de eso viaja en el repositorio y es idempotente: si
   `.env` ya existe, no se toca.
4. Genera la **CA y los certificados de la malla** (P-28, ADR-0020).
5. Levanta el sistema (`make up`).
6. Enciende el **cortafuegos**: solo la PWA y el borde TLS; las bases y los
   servicios internos no se publican.

## Operación

| Tarea | Comando (en el servidor) |
| --- | --- |
| Ver estado | `make ps` |
| Actualizar | `git pull && make up` |
| Respaldar | `make backup` |
| Rotar la CA de la malla | `make rotate-ca` |
| Parar (conserva datos) | `make down` |

## Alcance

Este playbook cubre un servidor único con compose, que es el despliegue natural
de un negocio de barrio. Un despliegue con orquestador (Kubernetes) o con varios
nodos necesita malla de servicio (`cert-manager`/Istio) y queda fuera del
alcance declarado de la Fase 5.
