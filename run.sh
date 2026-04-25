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
UPSTREAM_PORT="${DISCOUNT_BANDIT_UPSTREAM_PORT:-80}"
INGRESS_PORT="${DISCOUNT_BANDIT_INGRESS_PORT:-8099}"
NGINX_CONF_PATH=""

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

json_integer() {
  filter="$1"
  default_value="$2"
  minimum="$3"
  maximum="$4"

  value="$(json_string "${filter}" "${default_value}")"

  case "${value}" in
    ''|*[!0-9]*)
      log_warn "Valor invalido para ${filter}: '${value}'. Usando ${default_value}."
      printf "%s" "${default_value}"
      return 0
      ;;
  esac

  if [ "${value}" -lt "${minimum}" ]; then
    log_warn "Valor demasiado bajo para ${filter}: '${value}'. Usando ${minimum}."
    printf "%s" "${minimum}"
    return 0
  fi

  if [ "${value}" -gt "${maximum}" ]; then
    log_warn "Valor demasiado alto para ${filter}: '${value}'. Usando ${maximum}."
    printf "%s" "${maximum}"
    return 0
  fi

  printf "%s" "${value}"
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
  ensure_directory "${STORAGE_DIR}/logs"
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
    rm -rf /app/database/sqlite
  fi
  ln -sfn "${DB_FILE}" /app/database/sqlite
}

patch_supervisor_logs() {
  if [ -f "${SUPERVISOR_CONF}" ] && grep -q "/var/log/default_worker.log" "${SUPERVISOR_CONF}"; then
    sed -i 's#/var/log/default_worker.log#/logs/default_worker.log#g' "${SUPERVISOR_CONF}"
  fi
}

start_log_tail() {
  # Mirror both the upstream process logs and Laravel app logs to stdout for HA visibility.
  current_laravel_log="${STORAGE_DIR}/logs/laravel-$(date -u +%Y-%m-%d).log"

  touch \
    "${STORAGE_DIR}/logs/laravel.log" \
    "${current_laravel_log}" \
    "${LOG_DIR}/supervisord_stdout.log" \
    "${LOG_DIR}/octane_stdout.log" \
    "${LOG_DIR}/octane_stderr.log" \
    "${LOG_DIR}/scheduler.log" \
    "${LOG_DIR}/default_worker.log"

  tail -q -n 0 -F \
    "${STORAGE_DIR}/logs/laravel.log" \
    "${current_laravel_log}" \
    "${LOG_DIR}/supervisord_stdout.log" \
    "${LOG_DIR}/octane_stdout.log" \
    "${LOG_DIR}/octane_stderr.log" \
    "${LOG_DIR}/scheduler.log" \
    "${LOG_DIR}/default_worker.log" &
  LOG_TAIL_PID=$!
}

should_use_nginx_proxy() {
  command -v nginx >/dev/null 2>&1 || return 1

  NGINX_CONF_PATH="$(resolve_nginx_conf_path)" || return 1
  export NGINX_CONF_PATH
  return 0
}

resolve_nginx_conf_path() {
  if [ -n "${DISCOUNT_BANDIT_NGINX_CONF:-}" ]; then
    if [ -f "${DISCOUNT_BANDIT_NGINX_CONF}" ]; then
      printf "%s" "${DISCOUNT_BANDIT_NGINX_CONF}"
      return 0
    fi
    return 1
  fi

  for candidate in \
    /etc/nginx/conf.d/discount-bandit-ingress.conf \
    /etc/nginx/http.d/default.conf
  do
    if [ -f "${candidate}" ]; then
      printf "%s" "${candidate}"
      return 0
    fi
  done

  return 1
}

start_upstream_background() {
  log_info "Arrancando Discount Bandit upstream en ${FRANKEN_HOST}:${UPSTREAM_PORT}."
  "${UPSTREAM_ENTRYPOINT}" &
  UPSTREAM_PID=$!
}

start_nginx_proxy() {
  log_info "Arrancando proxy nginx para ingress en el puerto interno ${INGRESS_PORT} usando ${NGINX_CONF_PATH}."
  nginx -t
  nginx -g "daemon off;" &
  NGINX_PID=$!
}

cleanup() {
  exit_code=$?
  trap - EXIT INT TERM

  if [ -n "${NGINX_PID:-}" ] && kill -0 "${NGINX_PID}" 2>/dev/null; then
    kill "${NGINX_PID}" 2>/dev/null || true
    wait "${NGINX_PID}" 2>/dev/null || true
  fi

  if [ -n "${UPSTREAM_PID:-}" ] && kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
    kill "${UPSTREAM_PID}" 2>/dev/null || true
    wait "${UPSTREAM_PID}" 2>/dev/null || true
  fi

  if [ -n "${LOG_TAIL_PID:-}" ] && kill -0 "${LOG_TAIL_PID}" 2>/dev/null; then
    kill "${LOG_TAIL_PID}" 2>/dev/null || true
    wait "${LOG_TAIL_PID}" 2>/dev/null || true
  fi

  exit "${exit_code}"
}

monitor_processes() {
  while true; do
    if [ -n "${UPSTREAM_PID:-}" ] && ! kill -0 "${UPSTREAM_PID}" 2>/dev/null; then
      wait "${UPSTREAM_PID}"
      return $?
    fi

    if [ -n "${NGINX_PID:-}" ] && ! kill -0 "${NGINX_PID}" 2>/dev/null; then
      wait "${NGINX_PID}"
      return $?
    fi

    sleep 2
  done
}

export_runtime_config() {
  public_base_url="$(trim_trailing_slash "$(json_string '.public_base_url' '')")"
  theme_color="$(json_string '.theme_color' 'Red')"
  cron_expression="$(json_string '.cron' '*/5 * * * *')"
  exchange_rate_api_key="$(json_string '.exchange_rate_api_key' '')"
  max_links_per_store="$(json_integer '.max_links_per_store' '10' '1' '60')"

  export APP_ENV="production"
  export APP_DEBUG="false"
  export APP_KEY="$(cat "${APP_KEY_FILE}")"
  export DB_CONNECTION="sqlite"
  export DB_DATABASE="/app/database/sqlite"
  export SESSION_DRIVER="database"
  export CACHE_STORE="database"
  export QUEUE_CONNECTION="database"
  export LOG_CHANNEL="${LOG_CHANNEL:-daily}"
  export LOG_DAILY_DAYS="${LOG_DAILY_DAYS:-7}"
  export LOG_LEVEL="info"
  export THEME_COLOR="${theme_color}"
  export CRON="${cron_expression}"
  export EXCHANGE_RATE_API_KEY="${exchange_rate_api_key}"
  export DISCOUNT_BANDIT_CHROMIUM_KEEP_ALIVE="${DISCOUNT_BANDIT_CHROMIUM_KEEP_ALIVE:-false}"
  export DISCOUNT_BANDIT_CHROMIUM_ENABLE_IMAGES="${DISCOUNT_BANDIT_CHROMIUM_ENABLE_IMAGES:-false}"
  export DISCOUNT_BANDIT_SAVE_CRAWL_RESPONSE="${DISCOUNT_BANDIT_SAVE_CRAWL_RESPONSE:-false}"
  export DISCOUNT_BANDIT_MAX_LINKS_PER_STORE="${max_links_per_store}"

  if [ "${USE_NGINX_PROXY:-0}" = "1" ]; then
    export FRANKEN_HOST="127.0.0.1"
    log_info "Modo ingress habilitado: nginx publica ${INGRESS_PORT} y upstream queda solo en localhost:${UPSTREAM_PORT}."
  else
    # Listen on all interfaces so the HA-published port can reach FrankenPHP.
    export FRANKEN_HOST="0.0.0.0"
    log_info "Modo directo habilitado: upstream expuesto en ${FRANKEN_HOST}:${UPSTREAM_PORT}."
  fi

  if [ "${USE_NGINX_PROXY:-0}" = "1" ] && [ -n "${public_base_url}" ]; then
    log_warn "public_base_url esta configurado, pero se ignora en modo ingress para evitar assets fuera del prefijo de Home Assistant."
  elif [ -n "${public_base_url}" ]; then
    export APP_URL="${public_base_url}"
    export ASSET_URL="${public_base_url}"
    log_info "APP_URL configurado a ${public_base_url}."
  elif [ "${USE_NGINX_PROXY:-0}" = "1" ]; then
    log_info "public_base_url vacio en modo ingress; la base URL se resolvera dinamicamente con los headers de ingress."
  else
    log_warn "public_base_url vacio; Discount Bandit usara su APP_URL por defecto. Configuralo si accedes desde otra URL o puerto."
  fi

  log_info "Usando SQLite persistente en ${DB_FILE}."
  log_info "Logs persistentes en ${LOG_DIR}."
  log_info "Frecuencia de comprobacion configurada a '${cron_expression}'."
  log_info "Crawler limitado a ${max_links_per_store} enlaces por tienda activa y ciclo."
  log_info "Chromium persistente: ${DISCOUNT_BANDIT_CHROMIUM_KEEP_ALIVE}; guardar response.html: ${DISCOUNT_BANDIT_SAVE_CRAWL_RESPONSE}."
}

main() {
  [ -x "${UPSTREAM_ENTRYPOINT}" ] || fail "No encuentro el entrypoint upstream en ${UPSTREAM_ENTRYPOINT}."

  if should_use_nginx_proxy; then
    USE_NGINX_PROXY="1"
  else
    USE_NGINX_PROXY="0"
  fi
  export USE_NGINX_PROXY

  ensure_state
  link_persistent_paths
  patch_supervisor_logs
  start_log_tail
  export_runtime_config

  cd /app

  if [ "${USE_NGINX_PROXY}" = "1" ]; then
    trap cleanup EXIT INT TERM
    start_upstream_background
    start_nginx_proxy
    monitor_processes
    exit $?
  fi

  log_info "Arrancando Discount Bandit upstream."
  exec "${UPSTREAM_ENTRYPOINT}"
}

main "$@"
