#!/usr/bin/env bash
# Profile rules of a site with a one-click fix (site doctor items with a
# "fix" id, and `site check-fix`). Each rule has a stable id, a state check
# that changes nothing and a fix that reuses the toolkit's own function, so
# the panel button, `bitrix finalize` and `self migrate` do the same thing.
#
# site_check_state <id> <domain>  -> SC_STATE ok|needed|n/a, SC_DETAIL
# site_check_apply <id> <domain>  -> SC_RESULT; returns 1 when the fix failed
#
# Needs admin/commands/bitrix.sh, admin/lib/php_fpm_host.sh and
# admin/lib/doctor_utils.sh (all sourced by simai-admin.sh).

SITE_CHECK_IDS_BITRIX=(
  bitrix.docroot-leftovers
  bitrix.dot-default
  bitrix.db-session-modes
  bitrix.db-charset
  bitrix.timezone
  bitrix.opcache
)
SITE_CHECK_IDS_PHP=(php.fpm-graceful-reload)

# Rules that apply to a profile, in report order.
site_check_ids_for_profile() {
  local profile="$1" id
  case "$profile" in
    bitrix)
      for id in "${SITE_CHECK_IDS_BITRIX[@]}"; do printf '%s\n' "$id"; done ;;
  esac
  case "$profile" in
    bitrix|wordpress|laravel|generic)
      for id in "${SITE_CHECK_IDS_PHP[@]}"; do printf '%s\n' "$id"; done ;;
  esac
}

site_check_known() {
  local id="$1" known
  for known in "${SITE_CHECK_IDS_BITRIX[@]}" "${SITE_CHECK_IDS_PHP[@]}"; do
    [[ "$known" == "$id" ]] && return 0
  done
  return 1
}

site_check_title() {
  case "$1" in
    bitrix.docroot-leftovers) echo "Bitrix restore files outside the web root" ;;
    bitrix.dot-default) echo "Bitrix .default folders are served" ;;
    bitrix.db-session-modes) echo "Bitrix MySQL session modes" ;;
    bitrix.db-charset) echo "Bitrix database default charset" ;;
    bitrix.timezone) echo "Bitrix PHP time zone" ;;
    bitrix.opcache) echo "PHP OPcache baseline for Bitrix" ;;
    php.fpm-graceful-reload) echo "PHP-FPM reload lets requests finish" ;;
    *) return 1 ;;
  esac
}

# One line: what the fix does.
site_check_plan_text() {
  case "$1" in
    bitrix.docroot-leftovers) echo "Move backup archives, restore.php and SQL dumps from the web root to <site>/restore-archive (nothing is deleted)." ;;
    bitrix.dot-default) echo "Allow .default folders in the nginx hidden-file rule (.env, .git stay closed), test nginx and reload it." ;;
    bitrix.db-session-modes) echo "Append sql_mode='' and innodb_strict_mode=0 to bitrix/php_interface/after_connect_d7.php (existing lines stay)." ;;
    bitrix.db-charset) echo "Set the database default to the profile charset (tables are not converted)." ;;
    bitrix.timezone) echo "Set the site's PHP date.timezone to the server time zone (MySQL uses it too) and reload PHP-FPM." ;;
    bitrix.opcache) echo "Write the host OPcache baseline for this PHP version (never lowers a value) and reload PHP-FPM." ;;
    php.fpm-graceful-reload) echo "Set process_control_timeout in php-fpm.conf so a reload waits for busy requests, then reload PHP-FPM." ;;
    *) return 1 ;;
  esac
}

# FAIL rules break the site or expose data; the others are WARN.
site_check_severity() {
  case "$1" in
    bitrix.docroot-leftovers|bitrix.dot-default) echo "FAIL" ;;
    *) echo "WARN" ;;
  esac
}

# Old and new hidden-file rules of the Bitrix nginx template.
SITE_CHECK_NGINX_DOT_OLD='location ~ /\.(?!well-known/) {'
SITE_CHECK_NGINX_DOT_NEW='location ~ /\.(?!well-known/|default/) {'

# Lets one Bitrix config serve .default folders; backup, nginx -t, rollback.
# Returns 0 when the file was changed, 1 when it failed, 2 when nothing to do.
bitrix_nginx_dot_default_fix() {
  local cfg="$1" backup
  [[ -f "$cfg" ]] || return 2
  grep -q '^# simai-nginx-template: bitrix$' "$cfg" || return 2
  grep -qF "$SITE_CHECK_NGINX_DOT_OLD" "$cfg" || return 2
  backup="${cfg}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$cfg" "$backup" || return 1
  sed -i 's#location ~ /\\.(?!well-known/) {#location ~ /\\.(?!well-known/|default/) {#' "$cfg"
  if grep -qF "$SITE_CHECK_NGINX_DOT_NEW" "$cfg" && nginx -t >>"${LOG_FILE:-/dev/null}" 2>&1; then
    return 0
  fi
  cp -p "$backup" "$cfg"
  return 1
}

# Read-only twin of bitrix_db_default_charset_ensure.
bitrix_db_default_charset_state() {
  local domain="$1" charset="$2" collation="$3" engine db_name="" entry current
  engine=$(site_db_engine "$domain")
  [[ "$engine" == mysql ]] || { echo "n/a"; return 0; }
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == "DB_NAME" ]] && db_name="${entry#*|}"
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  [[ -n "$db_name" ]] && db_validate_db_name "$db_name" 2>/dev/null || { echo "n/a"; return 0; }
  current=$(mysql_root_query_stdin "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}'" 2>/dev/null) || { echo "n/a"; return 0; }
  [[ -n "$current" ]] || { echo "n/a"; return 0; }
  if [[ "${current%%$'\t'*}" == "$charset" && "${current#*$'\t'}" == "$collation" ]]; then
    echo "ok"
  else
    echo "needed ${current%%$'\t'*}/${current#*$'\t'}"
  fi
}

# UTC has several names (Etc/UTC from timedatectl, UTC from PHP).
site_check_tz_canonical() {
  case "$1" in
    UTC|Etc/UTC|Etc/UCT|UCT|Etc/Universal|Universal|Etc/Zulu|Zulu|GMT|Etc/GMT|Etc/GMT0|Etc/GMT+0|Etc/GMT-0|GMT0|Greenwich|Etc/Greenwich) echo UTC ;;
    *) echo "$1" ;;
  esac
}

php_fpm_process_control_timeout_get() {
  local conf="/etc/php/$1/fpm/php-fpm.conf"
  [[ -f "$conf" ]] || return 1
  awk '
    /^[[:space:]]*\[/ { global = ($0 ~ /^[[:space:]]*\[global\]/); next }
    global && /^[[:space:]]*process_control_timeout[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(;.*)?$/, ""); v = $0 }
    END { print v }
  ' "$conf"
}

# Site facts shared by the rules: SC_PROFILE, SC_ROOT, SC_DOC_ROOT,
# SC_PHP, SC_POOL, SC_NGINX.
site_check_load_site() {
  local domain="$1" public_dir project
  read_site_metadata "$domain" >/dev/null 2>&1 || return 1
  SC_PROFILE="${SITE_META[profile]:-generic}"
  SC_ROOT="${SITE_META[root]:-}"
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then public_dir="public"; else public_dir="${SITE_META[public_dir]}"; fi
  SC_DOC_ROOT=$(site_compute_doc_root "$SC_ROOT" "$public_dir" 2>/dev/null) || SC_DOC_ROOT=""
  SC_PHP="${SITE_META[php]:-}"
  [[ "$SC_PHP" == none ]] && SC_PHP=""
  project="${SITE_META[php_socket_project]:-${SITE_META[project]:-}}"
  SC_POOL=""
  [[ -n "$SC_PHP" && -n "$project" ]] && SC_POOL="/etc/php/${SC_PHP}/fpm/pool.d/${project}.conf"
  SC_NGINX="/etc/nginx/sites-available/${domain}.conf"
  return 0
}

site_check_state() {
  local id="$1" domain="$2" state entry key want have
  SC_STATE="n/a"
  SC_DETAIL=""
  site_check_load_site "$domain" || return 0
  case "$id" in
    bitrix.*) [[ "$SC_PROFILE" == bitrix && -n "$SC_DOC_ROOT" ]] || return 0 ;;
    php.*) [[ -n "$SC_PHP" ]] || return 0 ;;
  esac
  local installed="no"
  [[ -f "${SC_DOC_ROOT}/bitrix/.settings.php" ]] && installed="yes"
  case "$id" in
    bitrix.docroot-leftovers)
      local -a files=()
      mapfile -t files < <(bitrix_restore_leftovers_list "$SC_DOC_ROOT")
      if (( ${#files[@]} > 0 )); then
        SC_STATE="needed"; SC_DETAIL="${#files[@]} file(s) downloadable from the web root"
      else
        SC_STATE="ok"; SC_DETAIL="none in the web root"
      fi ;;
    bitrix.dot-default)
      if grep -qF "$SITE_CHECK_NGINX_DOT_NEW" "$SC_NGINX" 2>/dev/null; then
        SC_STATE="ok"; SC_DETAIL="served"
      elif grep -qF "$SITE_CHECK_NGINX_DOT_OLD" "$SC_NGINX" 2>/dev/null && grep -q '^# simai-nginx-template: bitrix$' "$SC_NGINX"; then
        SC_STATE="needed"; SC_DETAIL="nginx refuses .default folders (admin tables lose styles and scripts)"
      fi ;;
    bitrix.db-session-modes)
      [[ "$installed" == yes ]] || return 0
      state=$(bitrix_perf_after_connect_state "${SC_DOC_ROOT}/bitrix/php_interface/after_connect_d7.php")
      if [[ "$state" == ready ]]; then
        SC_STATE="ok"; SC_DETAIL="sql_mode and innodb_strict_mode set"
      else
        SC_STATE="needed"; SC_DETAIL="after_connect_d7.php: ${state}"
      fi ;;
    bitrix.db-charset)
      [[ "$installed" == yes ]] || return 0
      local charset="utf8mb4" collation="utf8mb4_unicode_ci"
      if load_profile "bitrix" >/dev/null 2>&1; then
        charset="${PROFILE_DB_CHARSET:-utf8mb4}"; collation="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
      fi
      state=$(bitrix_db_default_charset_state "$domain" "$charset" "$collation")
      case "$state" in
        ok) SC_STATE="ok"; SC_DETAIL="${charset}/${collation}" ;;
        needed*) SC_STATE="needed"; SC_DETAIL="${state#needed } (expected ${charset}/${collation})" ;;
      esac ;;
    bitrix.timezone)
      [[ -n "$SC_PHP" ]] || return 0
      # PHP 8.2+ reports UTC when nothing is set, while MySQL follows the
      # server zone: the rule holds when the site has its own zone or PHP
      # already runs in the server zone.
      local own="" host
      while IFS= read -r entry; do
        [[ "${entry%%|*}" == "date.timezone" ]] && own="${entry#*|}"
      done < <(read_site_php_ini_overrides "$domain" 2>/dev/null)
      have=$(doctor_php_ini_effective_get "$(resolve_php_bin "$SC_PHP")" "$SC_POOL" "date.timezone" 2>/dev/null || true)
      host=$(bitrix_host_timezone "$(resolve_php_bin "$SC_PHP")")
      if [[ -n "$own" ]]; then
        SC_STATE="ok"; SC_DETAIL="${own} (site setting)"
      elif [[ -n "$have" && "$(site_check_tz_canonical "$have")" == "$(site_check_tz_canonical "$host")" ]]; then
        SC_STATE="ok"; SC_DETAIL="$have"
      else
        SC_STATE="needed"; SC_DETAIL="PHP ${have:-UTC}, server and MySQL ${host}"
      fi ;;
    bitrix.opcache)
      [[ -n "$SC_PHP" ]] && php_fpm_host_bin "$SC_PHP" >/dev/null 2>&1 || return 0
      SC_STATE="ok"; SC_DETAIL="baseline met"
      for entry in "${PHP_FPM_OPCACHE_BASELINE[@]}"; do
        key="${entry%%=*}"; want="${entry#*=}"
        have=$(php_fpm_master_ini_get "$SC_PHP" "$key" 2>/dev/null || true)
        if ! [[ "$have" =~ ^[0-9]+$ ]] || (( have < want )); then
          SC_STATE="needed"; SC_DETAIL="${key}=${have:-?} (baseline ${want})"
          break
        fi
      done ;;
    php.fpm-graceful-reload)
      php_fpm_host_bin "$SC_PHP" >/dev/null 2>&1 || return 0
      have=$(php_fpm_process_control_timeout_get "$SC_PHP" 2>/dev/null || true)
      if [[ -n "$have" && ! "$have" =~ ^0+[smhd]?$ ]]; then
        SC_STATE="ok"; SC_DETAIL="process_control_timeout ${have}"
      else
        SC_STATE="needed"; SC_DETAIL="a reload kills busy requests (502)"
      fi ;;
  esac
  return 0
}

# shellcheck disable=SC2034 # SC_RESULT is read by the callers
site_check_apply() {
  local id="$1" domain="$2" rc
  SC_RESULT="failed"
  site_check_load_site "$domain" || { SC_RESULT="failed (cannot read site metadata)"; return 1; }
  case "$id" in
    bitrix.docroot-leftovers)
      rc=0; bitrix_restore_leftovers_move "$SC_ROOT" "$SC_DOC_ROOT" || rc=$?
      SC_RESULT="$BX_LEFTOVERS_RESULT"; return $rc ;;
    bitrix.dot-default)
      rc=0; bitrix_nginx_dot_default_fix "$SC_NGINX" || rc=$?
      case $rc in
        0) os_svc_reload nginx >/dev/null 2>&1 || { SC_RESULT="changed, but nginx did not reload"; return 1; }
           SC_RESULT="changed; nginx reloaded"; return 0 ;;
        2) SC_RESULT="unchanged"; return 0 ;;
        *) SC_RESULT="failed (nginx rejected the change; previous configuration restored)"; return 1 ;;
      esac ;;
    bitrix.db-session-modes)
      rc=0; bitrix_after_connect_session_modes_ensure "${SC_DOC_ROOT}/bitrix/php_interface/after_connect_d7.php" "$(resolve_php_bin "$SC_PHP")" || rc=$?
      SC_RESULT="$BX_AFTER_CONNECT_RESULT"; return $rc ;;
    bitrix.db-charset)
      local charset="utf8mb4" collation="utf8mb4_unicode_ci"
      if load_profile "bitrix" >/dev/null 2>&1; then
        charset="${PROFILE_DB_CHARSET:-utf8mb4}"; collation="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
      fi
      rc=0; bitrix_db_default_charset_ensure "$domain" "$charset" "$collation" || rc=$?
      SC_RESULT="$BX_DB_CHARSET_RESULT"; return $rc ;;
    bitrix.timezone)
      local tz
      tz=$(bitrix_host_timezone "$(resolve_php_bin "$SC_PHP")")
      if run_command site php-ini-set --domain "$domain" --name date.timezone --value "$tz" --apply yes --confirm yes >/dev/null; then
        SC_RESULT="date.timezone=${tz}"; return 0
      fi
      SC_RESULT="failed (site php-ini-set)"; return 1 ;;
    bitrix.opcache)
      if php_fpm_opcache_baseline_ensure "$SC_PHP" >/dev/null; then
        SC_RESULT="baseline in $(php_fpm_opcache_baseline_path "$SC_PHP")"; return 0
      fi
      SC_RESULT="failed (php-fpm rejected the baseline; file restored)"; return 1 ;;
    php.fpm-graceful-reload)
      if php_fpm_process_control_timeout_ensure "$SC_PHP" >/dev/null; then
        SC_RESULT="process_control_timeout $(php_fpm_process_control_timeout_get "$SC_PHP")"; return 0
      fi
      SC_RESULT="failed (php-fpm rejected the change; file restored)"; return 1 ;;
  esac
  SC_RESULT="unknown check"
  return 1
}

# Adds every rule of the site's profile to the doctor report.
doctor_add_profile_rules() {
  local domain="$1" profile="$2" id
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    site_check_state "$id" "$domain"
    case "$SC_STATE" in
      ok) doctor_add_result "PASS" "rules" "$(site_check_title "$id")" "$SC_DETAIL" "" "$id" "$id" ;;
      needed) doctor_add_result "$(site_check_severity "$id")" "rules" "$(site_check_title "$id")" "$SC_DETAIL" \
                "Run: simai-admin.sh site check-fix --domain ${domain} --id ${id} --confirm yes" "$id" "$id" ;;
    esac
  done < <(site_check_ids_for_profile "$profile")
}
