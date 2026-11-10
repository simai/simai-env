#!/usr/bin/env bash
# Host-wide PHP-FPM settings owned by simai-env: graceful reloads
# (process_control_timeout) and the OPcache/realpath baseline of Bitrix hosts.
# Sourced by simai-admin.sh and by the installer (simai-env.sh); needs only
# info/warn, LOG_FILE and os_svc_reload_or_restart.

PHP_FPM_PROCESS_CONTROL_TIMEOUT=${PHP_FPM_PROCESS_CONTROL_TIMEOUT:-10s}
PHP_FPM_OPCACHE_BASELINE_NAME="99-zz-simai-opcache.ini"
# Same values as PROFILE_PHP_INI_RECOMMENDED in profiles/bitrix.profile.sh.
# All of them are PHP_INI_SYSTEM: OPcache memory is shared by every pool of a
# version, so they belong to the version, not to a pool.
PHP_FPM_OPCACHE_BASELINE=(
  "opcache.memory_consumption=256"
  "opcache.interned_strings_buffer=16"
  "opcache.max_accelerated_files=20000"
  "realpath_cache_ttl=600"
)

php_fpm_host_bin() {
  local ver="$1"
  if [[ -x "/usr/sbin/php-fpm${ver}" ]]; then
    printf '%s\n' "/usr/sbin/php-fpm${ver}"
  else
    command -v "php-fpm${ver}" 2>/dev/null
  fi
}

php_fpm_host_versions() {
  local dir ver
  for dir in /etc/php/*/fpm; do
    [[ -f "${dir}/php-fpm.conf" ]] || continue
    ver=$(basename "$(dirname "$dir")")
    php_fpm_host_bin "$ver" >/dev/null || continue
    printf '%s\n' "$ver"
  done
}

# Master (php.ini + conf.d) value of an ini key as PHP-FPM of a version sees
# it, before any pool php_admin_value. Optional scan dir replaces conf.d.
php_fpm_master_ini_get() {
  local ver="$1" key="$2" scan_dir="${3:-}" bin
  bin=$(php_fpm_host_bin "$ver") || return 1
  [[ -n "$bin" ]] || return 1
  if [[ -n "$scan_dir" ]]; then
    PHP_INI_SCAN_DIR="$scan_dir" "$bin" -i 2>/dev/null
  else
    "$bin" -i 2>/dev/null
  fi | awk -F' => ' -v k="$key" '!found && $1 == k { v = $2; found = 1 } END { if (found && v != "no value") print v; exit !found }'
}

# Keys that only the FPM master applies: a pool php_admin_value does not
# change them, so checks must read the master value.
php_fpm_master_only_key() {
  case "$1" in
    opcache.memory_consumption|opcache.interned_strings_buffer|opcache.max_accelerated_files) return 0 ;;
  esac
  return 1
}

php_fpm_host_test() {
  local ver="$1" bin
  bin=$(php_fpm_host_bin "$ver") || return 1
  "$bin" -t >>"${LOG_FILE:-/dev/null}" 2>&1
}

# Busy workers get up to PHP_FPM_PROCESS_CONTROL_TIMEOUT to finish a request
# on reload instead of being killed (nginx answered those requests with 502).
# An explicit non-zero value set by an administrator stays.
# Prints "changed" when php-fpm.conf was updated.
php_fpm_process_control_timeout_ensure() {
  local ver="$1" reload="${2:-yes}" conf current backup
  conf="/etc/php/${ver}/fpm/php-fpm.conf"
  [[ -f "$conf" ]] || return 0
  php_fpm_host_bin "$ver" >/dev/null || return 0
  current=$(awk '
    /^[[:space:]]*\[/ { global = ($0 ~ /^[[:space:]]*\[global\]/); next }
    global && /^[[:space:]]*process_control_timeout[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(;.*)?$/, ""); v = $0 }
    END { print v }
  ' "$conf")
  if [[ -n "$current" && ! "$current" =~ ^0+[smhd]?$ ]]; then
    return 0
  fi
  backup=$(mktemp) || return 1
  cp -p "$conf" "$backup" || { rm -f "$backup"; return 1; }
  if [[ -n "$current" ]]; then
    # An explicit zero in [global]: replace it in place.
    awk -v val="$PHP_FPM_PROCESS_CONTROL_TIMEOUT" '
      /^[[:space:]]*\[/ { global = ($0 ~ /^[[:space:]]*\[global\]/) }
      global && /^[[:space:]]*process_control_timeout[[:space:]]*=/ { print "process_control_timeout = " val; next }
      { print }
    ' "$backup" >"$conf"
  elif grep -q '^[[:space:]]*\[global\]' "$conf"; then
    # Directives after the pool include would belong to the last pool, so the
    # line goes right after [global].
    awk -v val="$PHP_FPM_PROCESS_CONTROL_TIMEOUT" '
      { print }
      !done && /^[[:space:]]*\[global\]/ {
        print "; simai-env: let busy workers finish their request on reload"
        print "process_control_timeout = " val
        done = 1
      }
    ' "$backup" >"$conf"
  else
    rm -f "$backup"
    warn "No [global] section in ${conf}; process_control_timeout not set"
    return 0
  fi
  if ! php_fpm_host_test "$ver"; then
    cp -p "$backup" "$conf"
    rm -f "$backup"
    warn "php-fpm${ver} rejected process_control_timeout; ${conf} restored"
    return 1
  fi
  rm -f "$backup"
  if [[ "$reload" == yes ]]; then
    os_svc_reload_or_restart "php${ver}-fpm" >>"${LOG_FILE:-/dev/null}" 2>&1 || warn "php${ver}-fpm did not reload after setting process_control_timeout"
  fi
  printf 'changed\n'
}

php_fpm_opcache_baseline_path() {
  printf '/etc/php/%s/fpm/conf.d/%s\n' "$1" "$PHP_FPM_OPCACHE_BASELINE_NAME"
}

# Writes the OPcache/realpath baseline of one PHP-FPM version. Each value is
# the larger of the baseline and what the other ini files already set, so a
# higher value chosen by an administrator stays. The file loads last (99-zz)
# so other conf.d files, including the performance preset, cannot lower it.
# Prints "changed" when the file was written.
php_fpm_opcache_baseline_ensure() {
  local ver="$1" reload="${2:-yes}" file confd scan entry key want have f backup="" content
  confd="/etc/php/${ver}/fpm/conf.d"
  [[ -d "$confd" ]] || return 0
  php_fpm_host_bin "$ver" >/dev/null || return 0
  file=$(php_fpm_opcache_baseline_path "$ver")
  scan=$(mktemp -d) || return 1
  for f in "$confd"/*.ini; do
    [[ -e "$f" && "$f" != "$file" ]] || continue
    ln -s "$f" "${scan}/$(basename "$f")"
  done
  content="; managed by simai-env: host OPcache/realpath baseline for Bitrix sites (php ${ver})
; Values never go below what other ini files set. Do not edit: raise a value in
; your own conf.d file and run: simai-admin.sh bitrix php-baseline-sync --all yes --confirm yes"
  for entry in "${PHP_FPM_OPCACHE_BASELINE[@]}"; do
    key="${entry%%=*}"; want="${entry#*=}"
    have=$(php_fpm_master_ini_get "$ver" "$key" "$scan" || true)
    if [[ "$have" =~ ^[0-9]+$ ]] && (( have > want )); then
      want="$have"
    fi
    content+=$'\n'"${key}=${want}"
  done
  rm -rf "$scan"
  if [[ -f "$file" && "$(cat "$file")" == "$content" ]]; then
    return 0
  fi
  if [[ -f "$file" ]]; then
    backup=$(mktemp) && cp -p "$file" "$backup"
  fi
  printf '%s\n' "$content" >"$file"
  chmod 0644 "$file"
  if ! php_fpm_host_test "$ver"; then
    if [[ -n "$backup" ]]; then cp -p "$backup" "$file"; else rm -f "$file"; fi
    rm -f "${backup:-}"
    warn "php-fpm${ver} rejected the OPcache baseline; ${file} restored"
    return 1
  fi
  rm -f "${backup:-}"
  for entry in "${PHP_FPM_OPCACHE_BASELINE[@]}"; do
    key="${entry%%=*}"; want="${entry#*=}"
    have=$(php_fpm_master_ini_get "$ver" "$key" || true)
    [[ "$have" =~ ^[0-9]+$ ]] && (( have >= want )) || warn "php ${ver}: ${key}=${have:-?} after the baseline (expected ${want}); another ini file loads after ${file}"
  done
  if [[ "$reload" == yes ]]; then
    os_svc_reload_or_restart "php${ver}-fpm" >>"${LOG_FILE:-/dev/null}" 2>&1 || warn "php${ver}-fpm did not reload after the OPcache baseline"
  fi
  printf 'changed\n'
}

# PHP versions that serve at least one Bitrix site (nginx metadata + pools).
php_fpm_bitrix_versions() {
  local cfg project pool
  for cfg in /etc/nginx/sites-available/*.conf; do
    [[ -f "$cfg" ]] || continue
    grep -q '^# simai-profile: bitrix$' "$cfg" || continue
    project=$(sed -n 's/^# simai-php-socket-project: *//p' "$cfg" | head -n1)
    [[ -n "$project" ]] || project=$(sed -n 's/^# simai-project: *//p' "$cfg" | head -n1)
    [[ "$project" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || continue
    for pool in /etc/php/*/fpm/pool.d/"${project}".conf; do
      [[ -f "$pool" ]] && awk -F/ '{print $4}' <<<"$pool"
    done
  done | sort -u
}
