# Discount Bandit para Home Assistant

Este add-on empaqueta [Discount Bandit](https://github.com/Cybrarist/Discount-Bandit) como una app web para Home Assistant con un enfoque pragmático de v1: SQLite persistente, puerto expuesto y el menor número posible de piezas móviles.

## Qué hace

- Despliega la interfaz web de Discount Bandit dentro del ecosistema de Home Assistant.
- Mantiene el estado importante en `/data`, para que sobreviva a reinicios y actualizaciones del add-on.
- Usa la imagen upstream fijada a `cybrarist/discount-bandit:v4.0.3`.

## Arquitecturas soportadas

- `amd64`
- `aarch64`

## Puerto usado

- Puerto interno del contenedor: `80/tcp`
- Puerto expuesto por defecto en Home Assistant: `8099`

La URL rápida del add-on se genera con `http://[HOST]:[PORT:80]`.

## Persistencia

La persistencia de esta v1 vive bajo `/data/discount_bandit`:

- `/data/discount_bandit/database.sqlite`: base de datos SQLite principal.
- `/data/discount_bandit/app_key`: `APP_KEY` generado automáticamente en el primer arranque.
- `/data/discount_bandit/storage`: almacenamiento de Laravel.
- `/data/discount_bandit/logs`: logs persistentes del proceso web, scheduler y cola.

## Configuración

Opciones expuestas en Home Assistant:

- `public_base_url`: URL pública desde la que vas a abrir la app. Ejemplo: `http://homeassistant.local:8099` o `http://192.168.1.10:8099`.
- `theme_color`: color principal que entiende el upstream. Por defecto `Red`.
- `cron`: expresión CRON usada por el scheduler interno. Por defecto `*/5 * * * *`.
- `exchange_rate_api_key`: opcional. Solo hace falta si quieres usar la funcionalidad de tipo de cambio del upstream.

Configuración mínima recomendada:

```yaml
public_base_url: "http://homeassistant.local:8099"
theme_color: "Red"
cron: "*/5 * * * *"
exchange_rate_api_key: ""
```

## Notas de funcionamiento

- El add-on fuerza `DB_CONNECTION=sqlite` y enlaza la base de datos al almacenamiento persistente.
- Si no existe `APP_KEY`, se genera automáticamente en el primer arranque y se guarda en `/data`.
- Los logs de Discount Bandit se guardan en `/data/discount_bandit/logs` y además se reenvían al log del add-on para facilitar soporte.

## Limitaciones de la v1

- Esta versión prioriza un add-on funcional por puerto expuesto. No usa ingress todavía.
- `public_base_url` conviene configurarlo para evitar URLs generadas incorrectamente en assets o enlaces.
- El upstream fija algunos comportamientos de arranque y optimización; este add-on los envuelve pero no los reescribe.
- La documentación del upstream menciona `APP_TIMEZONE`, pero en `v-4` no se aplica realmente en la configuración de Laravel. Por eso no se expone aún como opción del add-on.

## Qué dejaría para una v2

- Añadir ingress de Home Assistant.
- Revisar si merece la pena exponer más opciones del upstream sin complicar el panel.
- Endurecer validaciones y healthchecks si la experiencia real del add-on lo pide.
