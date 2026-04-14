# Discount Bandit Wrapper Source

Este repositorio ya no es un add-on final de Home Assistant. Su función es actuar como `wrapper-source` para el ecosistema `sanher-ha-addons`, de forma que el repo padre pueda consumir este wrapper por tag y construir allí el add-on final.

## Qué contiene

- `run.sh`: lógica wrapper para ejecutar Discount Bandit dentro del add-on final.
- `wrapper-source.yaml`: metadata que el repo padre puede usar para sincronizar la integración.
- `.github/workflows/notify-parent-add-on-repo.yml`: notificación al repo padre cuando se publica una tag semver.

## Responsabilidad del wrapper

El wrapper se encarga de:

- preparar `/data/discount_bandit`
- generar y conservar `APP_KEY` en `/data`
- enlazar SQLite, storage y logs persistentes
- exportar la configuración mínima necesaria al runtime upstream
- reenviar logs internos a stdout/stderr del add-on
- arrancar el entrypoint upstream de forma robusta

## Upstream fijado

- `upstream_repo`: `https://github.com/cybrarist/discount-bandit.git`
- `upstream_ref`: `ef0637c9a7a1c01a31ad96754f2ae1bb17ac7d9b`

Ese `upstream_ref` corresponde al estado upstream revisado para esta integración v1.

## Integración con el repo padre

El repo padre `sanher-ha-addons` debería:

- consumir este repositorio por tag semver (`0.1.0`, `0.1.1`, etc.)
- copiar `run.sh` al add-on final
- usar `wrapper-source.yaml` para fijar `APP_REF`/upstream y metadatos relacionados
- encargarse allí de `config.yaml`, `Dockerfile`, `CHANGELOG.md` y publicación final del add-on

## Lo que este repo no incluye

- `repository.yaml`
- `build.yaml`
- estructura final de add-on Home Assistant

Eso vive en el repo padre.
