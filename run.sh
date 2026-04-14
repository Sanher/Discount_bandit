#!/bin/sh
set -eu

UPSTREAM_ENTRYPOINT="/app/docker/entrypoint.sh"
OPTIONS_FILE="/data/options.json"
STATE_DIR="/data/discount_bandit"
DB_FILE="${STATE_DIR}/database.sqlite"
APP_KEY_FILE="${STATE_DIR}/app_key"
STORAGE_DIR="${STATE_DIR}/storage"
LOG_DIR="${STATE_DIR}/logs"
SUPERVISOR_CONF="/etc/supervisor/conf.d/supervisord.conf"

timestamp() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_info() {
  printf "%s [INFO] %s\n" "$(timestamp)" "$*"
}

log_warn() {
  printf "%s [WARN] %s\n" "$(timestamp)" "$*" >&2
}

fail() {
  printf "%s [ERROR] %s\n" "$(timestamp)" "$*" >&2
  exit 1
}

json_string() {
  filter="$1"
  default_value="$2"

  if [ -f "${OPTIONS_FILE}" ]; then
    value="$(jq -er "${filter} // empty" "${OPTIONS_FILE}" 2>/dev/null || true)"
    if [ -n "${value}" ] && [ "${value}" != "null" ]; then
      printf "%s" "${value}"
      return 0
    fi
  fi

  printf "%s" "${default_value}"
}

trim_trailing_slash() {
  printf "%s" "$1" | sed 's:/*$::'
}

ensure_directory() {
  directory="$1"
  [ -d "${directory}" ] || mkdir -p "${directory}"
}

ensure_state() {
  ensure_directory "${STATE_DIR}"
  ensure_directory "${LOG_DIR}"
  ensure_directory /app/database

  if [ ! -d "${STORAGE_DIR}" ]; then
    mkdir -p "${STORAGE_DIR}"
    if [ -d /app/storage ]; then
      cp -a /app/storage/. "${STORAGE_DIR}/"
    fi
  fi

  if [ ! -f "${DB_FILE}" ]; then
    touch "${DB_FILE}"
    chmod 600 "${DB_FILE}"
    log_info "Base de datos SQLite inicializada en ${DB_FILE}."
  fi

  if [ ! -s "${APP_KEY_FILE}" ]; then
    php -r 'echo "base64:".base64_encode(random_bytes(32));' > "${APP_KEY_FILE}"
    chmod 600 "${APP_KEY_FILE}"
    log_info "APP_KEY generado y guardado en /data para que sea persistente."
  fi
}

link_persistent_paths() {
  # Persist the upstream writable paths under /data so upgrades keep state.
  if [ -e /logs ] && [ ! -L /logs ]; then
    rm -rf /logs
  fi
  ln -sfn "${LOG_DIR}" /logs

  if [ -e /app/storage ] && [ ! -L /app/storage ]; then
    rm -rf /app/storage
  fi
  ln -sfn "${STORAGE_DIR}" /app/storage

  if [ -e /app/database/sqlite ] && [ ! -L /app/database/sqlite ]; then
    rm -f /app/database/sqlite
  fi
  ln -sfn "${DB_FILE}" /app/database/sqlite
}

patch_supervisor_logs() {
  if [ -f "${SUPERVISOR_CONF}" ] && grep -q "/var/log/default_worker.log" "${SUPERVISOR_CONF}"; then
    sed -i 's#/var/log/default_worker.log#/logs/default_worker.log#g' "${SUPERVISOR_CONF}"
  fi
}

start_log_tail() {
  # The upstream stack logs to files; mirror them to stdout for HA visibility.
  touch \
    "${LOG_DIR}/supervisord_stdout.log" \
    "${LOG_DIR}/octane_stdout.log" \
    "${LOG_DIR}/octane_stderr.log" \
    "${LOG_DIR}/scheduler.log" \
    "${LOG_DIR}/default_worker.log"

  tail -q -n 0 -F \
    "${LOG_DIR}/supervisord_stdout.log" \
    "${LOG_DIR}/octane_stdout.log" \
    "${LOG_DIR}/octane_stderr.log" \
    "${LOG_DIR}/scheduler.log" \
    "${LOG_DIR}/default_worker.log" &
}

export_runtime_config() {
  public_base_url="$(trim_trailing_slash "$(json_string '.public_base_url' '')")"
  theme_color="$(json_string '.theme_color' 'Red')"
  cron_expression="$(json_string '.cron' '*/5 * * * *')"
  exchange_rate_api_key="$(json_string '.exchange_rate_api_key' '')"

  export APP_ENV="production"
  export APP_DEBUG="false"
  export APP_KEY="$(cat "${APP_KEY_FILE}")"
  export DB_CONNECTION="sqlite"
  export DB_DATABASE="/app/database/sqlite"
  export SESSION_DRIVER="database"
  export CACHE_STORE="database"
  export QUEUE_CONNECTION="database"
  # Listen on all interfaces so the HA-published port can reach FrankenPHP.
  export FRANKEN_HOST="0.0.0.0"
  export LOG_LEVEL="info"
  export THEME_COLOR="${theme_color}"
  export CRON="${cron_expression}"
  export EXCHANGE_RATE_API_KEY="${exchange_rate_api_key}"

  if [ -n "${public_base_url}" ]; then
    export APP_URL="${public_base_url}"
    export ASSET_URL="${public_base_url}"
    log_info "APP_URL configurado a ${public_base_url}."
  else
    log_warn "public_base_url vacio; Discount Bandit usara su APP_URL por defecto. Configuralo si accedes desde otra URL o puerto."
  fi

  log_info "Usando SQLite persistente en ${DB_FILE}."
  log_info "Logs persistentes en ${LOG_DIR}."
  log_info "Frecuencia de comprobacion configurada a '${cron_expression}'."
}

main() {
  [ -x "${UPSTREAM_ENTRYPOINT}" ] || fail "No encuentro el entrypoint upstream en ${UPSTREAM_ENTRYPOINT}."

  ensure_state
  link_persistent_paths
  patch_supervisor_logs
  start_log_tail
  export_runtime_config

  cd /app
  log_info "Arrancando Discount Bandit upstream."
  exec "${UPSTREAM_ENTRYPOINT}"
}

main "$@"
