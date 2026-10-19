#!/usr/bin/env bash
# Application requirements (.simai/app.json + composer.json) and the units
# derived from them. The manifest is parsed and validated by
# lib/app_manifest.py; this file only consumes its validated records.

# shellcheck disable=SC2034 # APP_* globals are read by site adopt/deploy/describe
app_manifest_load() {
  local root="$1" out
  APP_MANIFEST="absent" APP_PROFILE="" APP_PHP_MIN="" APP_DB_ENGINE="" APP_DB_VERSION=""
  APP_SCHEDULER="" APP_MIGRATE=""
  APP_NODE_VERSION="" APP_START="" APP_INSTALL="" APP_BUILD="" APP_PYTHON_REQUIREMENTS=""
  APP_HEALTH_PATH="" APP_HEALTH_TIMEOUT=""
  APP_PHP_EXTS=() APP_PACKAGES=() APP_EXECUTABLES=() APP_ENV=() APP_WORKERS=() APP_FRAME_ANCESTORS=() APP_SHARED=()
  out=$(python3 "${SIMAI_ENV_ROOT}/lib/app_manifest.py" "$root" 2>&1) || {
    error "${out:-app manifest could not be read}"
    return 1
  }
  local kind a b c d
  while IFS=$'\t' read -r kind a b c d; do
    case "$kind" in
      manifest) APP_MANIFEST="$a" ;;
      profile) APP_PROFILE="$a" ;;
      php_min) APP_PHP_MIN="$a" ;;
      php_ext) APP_PHP_EXTS+=("$a") ;;
      package) APP_PACKAGES+=("$a") ;;
      executable) APP_EXECUTABLES+=("$a") ;;
      db_engine) APP_DB_ENGINE="$a" ;;
      db_version) APP_DB_VERSION="$a" ;;
      env) APP_ENV+=("${a}=${b}") ;;
      scheduler) APP_SCHEDULER="$a" ;;
      worker) APP_WORKERS+=("${a}|${b}|${c}|${d}") ;;
      migrate) APP_MIGRATE="$a" ;;
      frame_ancestor) APP_FRAME_ANCESTORS+=("$a") ;;
      node_version) APP_NODE_VERSION="$a" ;;
      start) APP_START="$a" ;;
      install) APP_INSTALL="$a" ;;
      build) APP_BUILD="$a" ;;
      python_requirements) APP_PYTHON_REQUIREMENTS="$a" ;;
      shared) APP_SHARED+=("$a") ;;
      health_path) APP_HEALTH_PATH="$a" ;;
      health_timeout) APP_HEALTH_TIMEOUT="$a" ;;
    esac
  done <<<"$out"
}

# PHP major.minor that satisfies the application's lower bound.
app_php_series() {
  local min="$1"
  [[ -n "$min" ]] || return 1
  printf '%s\n' "$min" | awk -F. '{print $1"."$2}'
}

app_missing_packages() {
  local pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" || printf '%s\n' "$pkg"
  done
}

# apt packages for the PHP extensions the application requires.
app_php_ext_packages() {
  local ver="$1" ext pkg
  shift
  for ext in "$@"; do
    "php${ver}" -m 2>/dev/null | grep -qix "$ext" && continue
    pkg=$(doctor_ext_to_apt_pkg "$ver" "$ext")
    [[ -n "$pkg" ]] && printf '%s\n' "$pkg"
  done | sort -u
}

# All worker units of a project: the default worker keeps the historical
# laravel-queue-<project>.service name, others get a suffix.
app_worker_unit_name() {
  local project="$1" name="$2" index="$3" count="$4"
  local unit="laravel-queue-${project}"
  [[ "$name" != "default" ]] && unit+="-${name}"
  (( count > 1 )) && unit+="-${index}"
  printf '%s.service\n' "$unit"
}

app_project_worker_units() {
  local project="$1" unit
  for unit in /etc/systemd/system/laravel-queue-"${project}".service /etc/systemd/system/laravel-queue-"${project}"-*.service; do
    [[ -f "$unit" ]] && basename "$unit"
  done
  return 0
}

# Writes one unit per worker instance from APP_WORKERS and removes worker
# units the manifest no longer lists. Units start only when start=yes.
app_write_workers() {
  local project="$1" root="$2" php_version="$3" start="${4:-yes}"
  local template="${SIMAI_ENV_ROOT}/systemd/app-worker.service" php_bin user group
  php_bin=$(resolve_php_bin "$php_version")
  user=$(site_effective_user "$project")
  group=$(site_effective_group "$project")
  local -A wanted=() changed=()
  local spec name args stop count i unit tmp
  for spec in "${APP_WORKERS[@]}"; do
    IFS='|' read -r name args stop count <<<"$spec"
    for (( i = 1; i <= count; i++ )); do
      unit=$(app_worker_unit_name "$project" "$name" "$i" "$count")
      wanted["$unit"]=1
      tmp=$(mktemp) || return 1
      WORKER="$name" PROJECT_NAME="$project" PROJECT_ROOT="$root" PHP_BIN="$php_bin" ARGS="$args" \
        STOP_TIMEOUT="$stop" USER_NAME="$user" GROUP_NAME="$group" perl -pe '
          s/\{\{WORKER\}\}/$ENV{WORKER}/g; s/\{\{PROJECT_NAME\}\}/$ENV{PROJECT_NAME}/g;
          s/\{\{PROJECT_ROOT\}\}/$ENV{PROJECT_ROOT}/g; s/\{\{PHP_BIN\}\}/$ENV{PHP_BIN}/g;
          s/\{\{ARGS\}\}/$ENV{ARGS}/g; s/\{\{STOP_TIMEOUT\}\}/$ENV{STOP_TIMEOUT}/g;
          s/\{\{USER\}\}/$ENV{USER_NAME}/g; s/\{\{GROUP\}\}/$ENV{GROUP_NAME}/g' "$template" >"$tmp"
      chmod 0644 "$tmp"
      cmp -s "$tmp" "/etc/systemd/system/${unit}" || changed["$unit"]=1
      mv -f "$tmp" "/etc/systemd/system/${unit}"
    done
  done
  for unit in $(app_project_worker_units "$project"); do
    if [[ -z "${wanted[$unit]:-}" ]]; then
      os_svc_disable_now "$unit" >/dev/null 2>&1 || true
      rm -f -- "/etc/systemd/system/${unit}"
    fi
  done
  os_svc_daemon_reload || return 1
  if [[ "$start" == yes ]]; then
    for unit in "${!wanted[@]}"; do
      if [[ -n "${changed[$unit]:-}" ]] && systemctl is-active --quiet "$unit"; then
        # New definition for a running worker. --no-block: the stop waits for
        # the current job (TimeoutStopSec may be days), not for this command.
        systemctl restart --no-block "$unit" >/dev/null 2>&1 || { error "Worker restart failed: ${unit}"; return 1; }
        systemctl enable "$unit" >/dev/null 2>&1 || return 1
      else
        os_svc_enable_now "$unit" >/dev/null 2>&1 || { error "Worker ${unit} did not start; see: journalctl -u ${unit}"; return 1; }
      fi
    done
  fi
}

# --- Long-running application services (profile node) ----------------------
# service.env in the site state directory records the local port; nginx
# proxies to it and the service unit receives it as PORT/HOST.

app_service_env_file() {
  echo "$(site_sites_config_dir)/$1/service.env"
}

app_port_get() {
  sed -n 's/^APP_PORT=//p' "$(app_service_env_file "$1")" 2>/dev/null | tail -n1
}

app_port_in_use() {
  local port="$1" f
  for f in "$(site_sites_config_dir)"/*/service.env; do
    [[ -f "$f" ]] && grep -qx "APP_PORT=${port}" "$f" && return 0
  done
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
}

# First free port in 3100..3999 unless one is requested.
app_port_allocate() {
  local requested="${1:-}" port
  if [[ -n "$requested" ]]; then
    [[ "$requested" =~ ^[0-9]{4,5}$ ]] && (( requested >= 1024 && requested <= 65535 )) || { error "--app-port must be 1024..65535"; return 1; }
    app_port_in_use "$requested" && { error "Port ${requested} is already used by another site or service"; return 1; }
    echo "$requested"
    return 0
  fi
  for (( port = 3100; port <= 3999; port++ )); do
    app_port_in_use "$port" || { echo "$port"; return 0; }
  done
  error "No free application port in 3100..3999"
  return 1
}

app_port_set() {
  local domain="$1" port="$2" file
  file=$(app_service_env_file "$domain")
  install -d -m 0750 "$(dirname "$file")"
  printf 'APP_PORT=%s\n' "$port" >"$file"
  chmod 0640 "$file"
}

app_service_unit_name() {
  printf 'simai-app-%s.service\n' "$1"
}

# Writes the service unit for <root>/current from APP_START; enables it.
app_service_write() {
  local project="$1" root="$2" user group unit tmp
  user=$(site_effective_user "$project")
  group=$(site_effective_group "$project")
  unit=$(app_service_unit_name "$project")
  tmp=$(mktemp) || return 1
  PROJECT_NAME="$project" PROJECT_ROOT="$root" START="$APP_START" USER_NAME="$user" GROUP_NAME="$group" perl -pe '
    s/\{\{PROJECT_NAME\}\}/$ENV{PROJECT_NAME}/g; s/\{\{PROJECT_ROOT\}\}/$ENV{PROJECT_ROOT}/g;
    s/\{\{START\}\}/$ENV{START}/g; s/\{\{USER\}\}/$ENV{USER_NAME}/g; s/\{\{GROUP\}\}/$ENV{GROUP_NAME}/g' \
    "${SIMAI_ENV_ROOT}/systemd/app-node.service" >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "/etc/systemd/system/${unit}"
  os_svc_daemon_reload || return 1
  systemctl enable "$unit" >/dev/null 2>&1 || return 1
}

app_service_remove() {
  local project="$1" unit
  unit=$(app_service_unit_name "$project")
  [[ -f "/etc/systemd/system/${unit}" ]] || return 0
  os_svc_disable_now "$unit" >/dev/null 2>&1 || true
  rm -f -- "/etc/systemd/system/${unit}"
  os_svc_daemon_reload >/dev/null 2>&1 || true
}

# Shared .env of a service site: created from the release's .env.example and
# the manifest env on first deploy; PORT and HOST are always simai-managed.
app_service_env_ensure() {
  local root="$1" release="$2" port="$3" group="$4" env="${1}/.env" kv key
  if [[ ! -f "$env" ]]; then
    if [[ -f "${release}/.env.example" ]]; then
      install -m 0640 -o root -g "$group" "${release}/.env.example" "$env"
    else
      install -m 0640 -o root -g "$group" /dev/null "$env"
    fi
    for kv in "${APP_ENV[@]}"; do
      key="${kv%%=*}"
      sed -i "/^${key}=/d" "$env"
      printf '%s\n' "$kv" >>"$env"
    done
  fi
  sed -i -E '/^(PORT|HOST)=/d' "$env"
  printf 'PORT=%s\nHOST=127.0.0.1\n' "$port" >>"$env"
  chown "root:${group}" "$env" && chmod 0640 "$env"
}

# Waits until the service answers on its health path with 2xx/3xx.
app_health_wait() {
  local port="$1" path="${2:-/}" timeout="${3:-120}" waited=0 code
  while (( waited < timeout )); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${port}${path}" 2>/dev/null || true)
    [[ "$code" =~ ^[23] ]] && return 0
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}
