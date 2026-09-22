#!/usr/bin/env bash
# Application requirements (.simai/app.json + composer.json) and the units
# derived from them. The manifest is parsed and validated by
# lib/app_manifest.py; this file only consumes its validated records.

# shellcheck disable=SC2034 # APP_* globals are read by site adopt/deploy/describe
app_manifest_load() {
  local root="$1" out
  APP_MANIFEST="absent" APP_PROFILE="" APP_PHP_MIN="" APP_DB_ENGINE="" APP_DB_VERSION=""
  APP_SCHEDULER="" APP_MIGRATE=""
  APP_PHP_EXTS=() APP_PACKAGES=() APP_EXECUTABLES=() APP_ENV=() APP_WORKERS=() APP_FRAME_ANCESTORS=()
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
  local -A wanted=()
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
      mv -f "$tmp" "/etc/systemd/system/${unit}"
    done
  done
  for unit in $(app_project_worker_units "$project"); do
    if [[ -z "${wanted[$unit]:-}" ]]; then
      os_svc_disable_now "$unit" >/dev/null 2>&1 || true
      rm -f -- "/etc/systemd/system/${unit}"
    fi
  done
  os_svc_daemon_reload || true
  if [[ "$start" == yes ]]; then
    for unit in "${!wanted[@]}"; do
      os_svc_enable_now "$unit" >/dev/null 2>&1 || warn "Worker ${unit} did not start; see: journalctl -u ${unit}"
    done
  fi
}
