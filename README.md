# Discount Bandit Wrapper Source

Este repositorio ya no es un add-on final de Home Assistant. Su función es actuar como `wrapper-source` para el ecosistema `sanher-ha-addons`, de forma que el repo padre pueda consumir este wrapper por tag y construir allí el add-on final.

## Qué contiene

- `run.sh`: lógica wrapper para ejecutar Discount Bandit dentro del add-on final.
- `nginx.conf`: proxy interno para ingress de Home Assistant.
- `patches/discount-bandit-ingress-v4.patch`: parche upstream para respetar `X-Ingress-Path`.
- `wrapper-source.yaml`: metadata que el repo padre puede usar para sincronizar la integración.
- `.github/workflows/notify-parent-add-on-repo.yml`: notificación al repo padre cuando se publica una tag semver.

## Responsabilidad del wrapper

El wrapper se encarga de:

- preparar `/data/discount_bandit`
- generar y conservar `APP_KEY` en `/data`
- enlazar SQLite, storage y logs persistentes
- exportar la configuración mínima necesaria al runtime upstream
- arrancar nginx en modo ingress cuando el add-on final copie `nginx.conf` e instale nginx
- reenviar logs internos a stdout/stderr del add-on
- arrancar el entrypoint upstream de forma robusta

## Upstream fijado

- `upstream_repo`: `https://github.com/cybrarist/discount-bandit.git`
- `upstream_ref`: `2175ced1c82407ac35483b9912b9f6514cb5c63c`

Ese `upstream_ref` corresponde al contenido upstream usado por la imagen `cybrarist/discount-bandit:v4.0.3` que parchea el add-on padre.

## Integración con el repo padre

El repo padre `sanher-ha-addons` debería:

- consumir este repositorio por tag semver (`0.1.0`, `0.1.1`, etc.)
- copiar `run.sh`, `nginx.conf` y `patches/`
- usar `wrapper-source.yaml` para fijar `APP_REF`/upstream y metadatos relacionados
- aplicar `patches/discount-bandit-ingress-v4.patch` sobre el upstream antes de construir
- habilitar ingress en el add-on final usando nginx como listener interno y Discount Bandit en `127.0.0.1:80`
- encargarse allí de `config.yaml`, `Dockerfile`, `CHANGELOG.md` y publicación final del add-on

## Lo que este repo no incluye

- `repository.yaml`
- `build.yaml`
- estructura final de add-on Home Assistant

Eso vive en el repo padre.

## Nota sobre ingress

La estrategia es distinta a una SPA estática tipo `Omnitools`. `Discount Bandit` es Laravel/Filament, así que el parche no intenta reescribir assets en frontend; en su lugar, añade un middleware que recalcula la base URL por request usando `X-Ingress-Path`, `X-Forwarded-Host` y `X-Forwarded-Proto`. Eso permite que rutas, redirects y assets respeten el prefijo de ingress de Home Assistant y Nabu Casa.
