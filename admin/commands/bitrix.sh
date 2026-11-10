#!/usr/bin/env bash
set -euo pipefail

bitrix_cron_markers() {
  local cron_file="$1" domain="$2" slug="$3"
  BX_CRON_MANAGED="no"
  BX_CRON_DOMAIN_MATCH="no"
  BX_CRON_SLUG_MATCH="no"
  BX_CRON_ENTRY_MATCH="no"
  BX_CRON_SHORT_OPEN_TAG_MATCH="no"
  if [[ ! -f "$cron_file" ]]; then
    return 0
  fi
  grep -Eq "^# simai-managed: yes" "$cron_file" && BX_CRON_MANAGED="yes"
  grep -Eq "^# simai-domain: ${domain}$" "$cron_file" && BX_CRON_DOMAIN_MATCH="yes"
  grep -Eq "^# simai-slug: ${slug}$" "$cron_file" && BX_CRON_SLUG_MATCH="yes"
  grep -Eq "cron_events\\.php" "$cron_file" && BX_CRON_ENTRY_MATCH="yes"
  grep -Eq "short_open_tag=1.*cron_events\\.php" "$cron_file" && BX_CRON_SHORT_OPEN_TAG_MATCH="yes"
  return 0
}

bitrix_prepare_site() {
  local domain="$1"
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  local profile="${SITE_META[profile]:-}"
  if [[ "$profile" != "bitrix" ]]; then
    error "Bitrix commands are supported for bitrix profile only (got ${profile:-unknown})."
    return 2
  fi
  local root="${SITE_META[root]:-}"
  if ! validate_path "$root"; then
    return 1
  fi
  local public_dir
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then
    public_dir="public"
  else
    public_dir="${SITE_META[public_dir]}"
  fi
  local doc_root
  doc_root=$(site_compute_doc_root "$root" "$public_dir") || return 1
  local slug="${SITE_META[slug]:-${SITE_META[project]:-$(project_slug_from_domain "$domain")}}"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  local php_version="${SITE_META[php]:-}"
  BX_DOMAIN="$domain"
  BX_ROOT="$root"
  BX_DOC_ROOT="$doc_root"
  BX_SLUG="$slug"
  BX_PHP_VERSION="$php_version"
  BX_CRON_FILE="/etc/cron.d/${slug}"
  BX_SETTINGS_FILE="${doc_root}/bitrix/.settings.php"
  BX_DBCONN_FILE="${doc_root}/bitrix/php_interface/dbconn.php"
  BX_CRON_ENTRYPOINT="${doc_root}/bitrix/modules/main/tools/cron_events.php"
  BX_HAS_CORE="no"
  [[ -d "${doc_root}/bitrix/modules/main" && -f "${doc_root}/index.php" ]] && BX_HAS_CORE="yes"
  return 0
}

bitrix_dbconn_const_state() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*true" "$file"; then
    echo "true"
    return 0
  fi
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${const_name}['\"][[:space:]]*,[[:space:]]*false" "$file"; then
    echo "false"
    return 0
  fi
  echo "missing"
}

bitrix_dbconn_set_const_true() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local esc
  esc=$(printf '%s\n' "$const_name" | sed 's/[][^$.*/\\|+?(){}]/\\&/g')
  if grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]${esc}['\"][[:space:]]*," "$file"; then
    perl -0777 -i -pe "s/^\\s*define\\s*\\(\\s*(['\"])${esc}\\1\\s*,\\s*(true|false)\\s*\\)\\s*;\\s*\$/if (!defined('${const_name}')) {\\n    define('${const_name}', true);\\n}/img" "$file"
  fi
  if ! grep -Eqi "defined[[:space:]]*\\([[:space:]]*['\"]${esc}['\"]" "$file"; then
    {
      echo ""
      echo "// simai-managed: bitrix agents baseline"
      echo "if (!defined('${const_name}')) {"
      echo "    define('${const_name}', true);"
      echo "}"
    } >>"$file"
  fi
  return 0
}

bitrix_dbconn_drop_const() {
  local file="$1" const_name="$2"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  local esc
  esc=$(printf '%s\n' "$const_name" | sed 's/[][^$.*/\\|+?(){}]/\\&/g')
  perl -0777 -i -pe "s/^\\s*define\\s*\\(\\s*(['\"])${esc}\\1\\s*,[^;]*\\)\\s*;\\s*\\n?//img" "$file"
  return 0
}

bitrix_agents_ready_state() {
  local cron_managed="$1" cron_domain_match="$2" cron_slug_match="$3" cron_entry="$4" _crontab="$5" crontab_support="$6" cron_short_open_tag="${7:-yes}"
  if [[ "$cron_managed" == "yes" && "$cron_domain_match" == "yes" && "$cron_slug_match" == "yes" && "$cron_entry" == "yes" && "$cron_short_open_tag" == "yes" && "$crontab_support" == "true" ]]; then
    echo "yes"
    return 0
  fi
  echo "no"
}

bitrix_perf_read_mode() {
  local domain="$1"
  local mode="none"
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "${entry%%|*}" == "mode" ]]; then
      mode="${entry#*|}"
      break
    fi
  done < <(read_site_perf_settings "$domain")
  echo "$mode"
}

bitrix_perf_install_stage() {
  local short_install="$1" agents_ready="${2:-no}" web_state="${3:-unknown}"
  case "$web_state" in
    installed)
      echo "post-install"
      return 0
      ;;
    installer)
      echo "installer"
      return 0
      ;;
  esac
  if [[ "$agents_ready" == "yes" ]]; then
    echo "post-install"
    return 0
  fi
  case "$short_install" in
    true) echo "installer" ;;
    false) echo "post-install" ;;
    missing|unknown|"") echo "unknown" ;;
    *) echo "unknown" ;;
  esac
}

bitrix_perf_settings_init_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if grep -q "SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci" "$file" 2>/dev/null \
    && grep -q "SET SESSION sql_mode=''" "$file" 2>/dev/null \
    && grep -q "SET SESSION innodb_strict_mode=0" "$file" 2>/dev/null; then
    echo "ready"
    return 0
  fi
  echo "partial"
}

bitrix_perf_after_connect_state() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo "missing"
    return 0
  fi
  if bitrix_after_connect_has_sql_mode "$file" && bitrix_after_connect_has_strict_off "$file"; then
    echo "ready"
    return 0
  fi
  echo "partial"
}

# Session modes Bitrix requires (site checker: empty sql_mode,
# innodb_strict_mode OFF). A restored archive brings its own
# after_connect_d7.php, usually with charset lines only.
bitrix_after_connect_has_sql_mode() {
  local file="$1"
  grep -Eqi "sql_mode[[:space:]]*=[[:space:]]*(''|\"\"|\\\\'\\\\')" "$file" 2>/dev/null
}

bitrix_after_connect_has_strict_off() {
  local file="$1"
  grep -Eqi "innodb_strict_mode[[:space:]]*=[[:space:]]*('|\\\\')?(0|off)\\b" "$file" 2>/dev/null
}

# Makes after_connect_d7.php set the session modes. Keeps the existing lines
# (charset and collation from the archive stay as they are) and appends only
# what is missing, in the style the file already uses. Sets
# BX_AFTER_CONNECT_RESULT; returns 1 when the file could not be updated.
bitrix_after_connect_session_modes_ensure() {
  local file="$1" php_bin="${2:-php}"
  local dir
  dir=$(dirname "$file")
  BX_AFTER_CONNECT_RESULT="failed"
  if [[ -L "$file" || -L "$dir" ]]; then
    BX_AFTER_CONNECT_RESULT="failed (symlink is not changed)"
    return 1
  fi
  local need_sql="yes" need_strict="yes" existing="no"
  if [[ -f "$file" ]]; then
    existing="yes"
    bitrix_after_connect_has_sql_mode "$file" && need_sql="no"
    bitrix_after_connect_has_strict_off "$file" && need_strict="no"
    if [[ "$need_sql" == "no" && "$need_strict" == "no" ]]; then
      BX_AFTER_CONNECT_RESULT="unchanged (session modes present)"
      return 0
    fi
    if ! grep -q '<?' "$file" 2>/dev/null; then
      BX_AFTER_CONNECT_RESULT="failed (not a PHP file)"
      return 1
    fi
  elif [[ -e "$file" ]]; then
    BX_AFTER_CONNECT_RESULT="failed (not a regular file)"
    return 1
  fi
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || return 1
    chown "${SIMAI_USER}:${SIMAI_WEB_GROUP}" "$dir" 2>/dev/null || true
    chmod 0775 "$dir" 2>/dev/null || true
  fi

  local tmp
  tmp=$(mktemp "${dir}/.after_connect_d7.php.XXXXXX") || return 1
  local -a added=()
  if [[ "$existing" == "no" ]]; then
    bitrix_after_connect_template >"$tmp"
    added=("created")
  else
    local style="generic"
    if grep -Eq '\$this->queryExecute' "$file"; then
      style="this"
    elif grep -Eq '\$connection[[:space:]]*=' "$file" && grep -Eq '\$connection->queryExecute' "$file"; then
      style="connection"
    fi
    # A trailing closing tag would turn appended code into page output.
    if ! perl -0777 -pe 's/\?>\s*\z/\n/' "$file" >"$tmp"; then
      rm -f "$tmp"
      return 1
    fi
    [[ -s "$tmp" && "$(tail -c1 "$tmp" | od -An -c | tr -d ' ')" != '\n' ]] && printf '\n' >>"$tmp"
    local -a statements=()
    [[ "$need_sql" == "yes" ]] && statements+=("SET SESSION sql_mode=''") && added+=("sql_mode")
    [[ "$need_strict" == "yes" ]] && statements+=("SET SESSION innodb_strict_mode=0") && added+=("innodb_strict_mode")
    local stmt
    {
      printf '\n// simai-managed: MySQL session modes required by Bitrix\n'
      case "$style" in
        this)
          for stmt in "${statements[@]}"; do printf '$this->queryExecute("%s");\n' "$stmt"; done
          ;;
        connection)
          for stmt in "${statements[@]}"; do printf '$connection->queryExecute("%s");\n' "$stmt"; done
          ;;
        *)
          printf 'if (isset($this) && $this instanceof \\Bitrix\\Main\\DB\\Connection) {\n'
          for stmt in "${statements[@]}"; do printf '    $this->queryExecute("%s");\n' "$stmt"; done
          printf '}\n'
          ;;
      esac
    } >>"$tmp"
  fi

  if ! "$php_bin" -d short_open_tag=1 -l "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    BX_AFTER_CONNECT_RESULT="failed (php -l rejected the result; file left unchanged)"
    return 1
  fi
  if [[ "$existing" == "yes" ]]; then
    chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
    chown --reference="$file" "$tmp" 2>/dev/null || true
  else
    chmod 0640 "$tmp"
    chown "${SIMAI_USER}:${SIMAI_WEB_GROUP}" "$tmp" 2>/dev/null || true
  fi
  if ! mv -f "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
  if [[ "$existing" == "yes" ]]; then
    local IFS=', '
    BX_AFTER_CONNECT_RESULT="appended (${added[*]})"
  else
    BX_AFTER_CONNECT_RESULT="created"
  fi
  return 0
}

# Host time zone for PHP, so PHP and MySQL (system zone) agree.
bitrix_host_timezone() {
  local php_bin="${1:-php}" tz=""
  if command -v timedatectl >/dev/null 2>&1; then
    tz=$(timedatectl show -p Timezone --value 2>/dev/null || true)
  fi
  if [[ -z "$tz" && -r /etc/timezone ]]; then
    tz=$(head -n1 /etc/timezone 2>/dev/null | tr -d '[:space:]')
  fi
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null || true)
    tz="${tz#/usr/share/zoneinfo/}"
  fi
  if ! bitrix_timezone_valid "$tz" "$php_bin"; then
    tz="UTC"
  fi
  printf '%s\n' "$tz"
}

bitrix_timezone_valid() {
  local tz="$1" php_bin="${2:-php}"
  [[ -n "$tz" && ${#tz} -le 64 && "$tz" =~ ^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$ ]] || return 1
  validate_ini_key "date.timezone" >/dev/null 2>&1 || return 1
  validate_ini_value "$tz" >/dev/null 2>&1 || return 1
  if command -v "$php_bin" >/dev/null 2>&1; then
    "$php_bin" -r 'exit(in_array($argv[1], DateTimeZone::listIdentifiers(DateTimeZone::ALL_WITH_BC), true) ? 0 : 1);' "$tz" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# Sets the site database default (never the tables) to the profile charset.
# A restored *_after_connect.sql can switch it to utf8mb3. Sets
# BX_DB_CHARSET_RESULT and BX_DB_UTF8MB3_TABLES.
bitrix_db_default_charset_ensure() {
  local domain="$1" charset="${2:-utf8mb4}" collation="${3:-utf8mb4_unicode_ci}"
  BX_DB_CHARSET_RESULT="failed"
  BX_DB_UTF8MB3_TABLES="n/a"
  local engine
  engine=$(site_db_engine "$domain")
  if [[ "$engine" != "mysql" ]]; then
    BX_DB_CHARSET_RESULT="skipped (${engine})"
    return 0
  fi
  local db_name="" entry
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == "DB_NAME" ]] && db_name="${entry#*|}"
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  if [[ -z "$db_name" ]]; then
    BX_DB_CHARSET_RESULT="skipped (no db.env)"
    return 0
  fi
  if ! db_validate_db_name "$db_name" 2>/dev/null; then
    BX_DB_CHARSET_RESULT="failed (invalid database name in db.env)"
    return 1
  fi
  if [[ ! "$charset" =~ ^[a-z0-9_]+$ || ! "$collation" =~ ^[a-z0-9_]+$ ]]; then
    BX_DB_CHARSET_RESULT="failed (invalid profile charset)"
    return 1
  fi
  local current
  if ! current=$(mysql_root_query_stdin "SELECT DEFAULT_CHARACTER_SET_NAME, DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db_name}'"); then
    BX_DB_CHARSET_RESULT="failed (cannot query MySQL)"
    return 1
  fi
  if [[ -z "$current" ]]; then
    BX_DB_CHARSET_RESULT="failed (database ${db_name} not found)"
    return 1
  fi
  local cur_charset="${current%%$'\t'*}" cur_collation="${current#*$'\t'}"
  if [[ "$cur_charset" == "$charset" && "$cur_collation" == "$collation" ]]; then
    BX_DB_CHARSET_RESULT="unchanged (${charset}/${collation})"
  elif mysql_root_exec_stdin "ALTER DATABASE \`${db_name}\` CHARACTER SET ${charset} COLLATE ${collation};"; then
    BX_DB_CHARSET_RESULT="changed (${cur_charset}/${cur_collation} -> ${charset}/${collation})"
  else
    BX_DB_CHARSET_RESULT="failed (ALTER DATABASE)"
    return 1
  fi
  local count
  count=$(mysql_root_query_stdin "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db_name}' AND TABLE_TYPE='BASE TABLE' AND (TABLE_COLLATION LIKE 'utf8\\_%' OR TABLE_COLLATION LIKE 'utf8mb3\\_%')" || true)
  [[ "$count" =~ ^[0-9]+$ ]] && BX_DB_UTF8MB3_TABLES="$count"
  return 0
}

# Restore leftovers in the web root: backup volumes (<name>_<type>_<id>.tar.gz
# and .tar.gz.N, also .enc.gz), restore.php and the dump in bitrix/backup.
bitrix_restore_leftovers_list() {
  local doc_root="$1" path name
  local volume_re='^[A-Za-z0-9._-]+_[A-Za-z]+_[A-Za-z0-9]+\.(tar\.gz|enc\.gz)(\.[0-9]+)?$'
  shopt -s nullglob
  for path in "${doc_root}"/*.tar.gz "${doc_root}"/*.tar.gz.* "${doc_root}"/*.enc.gz "${doc_root}"/*.enc.gz.* "${doc_root}/restore.php" "${doc_root}"/bitrix/backup/*.sql; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    name=$(basename "$path")
    case "$path" in
      "${doc_root}/restore.php"|"${doc_root}"/bitrix/backup/*.sql) ;;
      *)
        [[ "$name" =~ $volume_re ]] || continue
        [[ "$name" == *_encode.tar.gz* ]] && continue
        ;;
    esac
    printf '%s\n' "$path"
  done | awk '!seen[$0]++'
  shopt -u nullglob
}

# Moves (never deletes) restore leftovers into <site root>/restore-archive,
# next to but outside the docroot. Sets BX_LEFTOVERS_RESULT.
bitrix_restore_leftovers_move() {
  local site_root="$1" doc_root="$2"
  local dest="${site_root}/restore-archive"
  BX_LEFTOVERS_RESULT="failed"
  local -a files=()
  mapfile -t files < <(bitrix_restore_leftovers_list "$doc_root")
  if [[ ${#files[@]} -eq 0 ]]; then
    BX_LEFTOVERS_RESULT="none in docroot"
    return 0
  fi
  local real_root real_doc
  real_root=$(readlink -f "$site_root" 2>/dev/null || echo "$site_root")
  real_doc=$(readlink -f "$doc_root" 2>/dev/null || echo "$doc_root")
  if [[ "$real_root" == "$real_doc" || "$real_root/" == "$real_doc"/* ]]; then
    BX_LEFTOVERS_RESULT="not moved: ${#files[@]} file(s), the docroot is the site root"
    return 1
  fi
  if [[ -L "$dest" || ( -e "$dest" && ! -d "$dest" ) ]]; then
    BX_LEFTOVERS_RESULT="failed (${dest} is not a directory)"
    return 1
  fi
  install -d -m 0700 "$dest" || return 1
  chmod 0700 "$dest"
  chown "${SIMAI_USER}:${SIMAI_WEB_GROUP}" "$dest" 2>/dev/null || true
  local stamp path name target moved=0 failed=0
  stamp=$(date +%Y%m%d-%H%M%S)
  for path in "${files[@]}"; do
    name=$(basename "$path")
    target="${dest}/${name}"
    [[ -e "$target" || -L "$target" ]] && target="${dest}/${stamp}-${name}"
    if mv -n -- "$path" "$target" && [[ ! -e "$path" ]]; then
      moved=$((moved + 1))
      info "Moved ${path} -> ${target}"
    else
      failed=$((failed + 1))
      warn "Could not move ${path}"
    fi
  done
  if (( failed > 0 )); then
    BX_LEFTOVERS_RESULT="moved ${moved}, failed ${failed} (to ${dest})"
    return 1
  fi
  BX_LEFTOVERS_RESULT="moved ${moved} file(s) to ${dest}"
  return 0
}

bitrix_perf_cache_dirs_state() {
  local doc_root="$1"
  local present=0 total=3
  local dir
  for dir in \
    "${doc_root}/bitrix/cache" \
    "${doc_root}/bitrix/managed_cache" \
    "${doc_root}/bitrix/stack_cache"; do
    [[ -d "$dir" ]] && present=$((present + 1))
  done
  echo "${present}/${total} present"
}

bitrix_perf_site_mode_for_apply() {
  local mode="$1"
  case "$mode" in
    standard) echo "balanced" ;;
    high-load) echo "aggressive" ;;
    *)
      return 1
      ;;
  esac
}

# Where a Bitrix site is on its way: route setup|restore|installed|none and
# step prepare|upload|validate|run_restore|run_setup|finalize|done, for the
# panel's step tracker. Sets BX_FLOW_ROUTE, BX_FLOW_STEP, BX_FLOW_URL,
# BX_FLOW_PENDING (finalize rules still failing) and BX_FLOW_ARCHIVE.
bitrix_restore_marker_path() {
  printf '%s/%s/bitrix-restore.env\n' "$(site_sites_config_dir)" "$1"
}

# Base archive volume in the docroot (what restore-ready validates).
bitrix_restore_base_archive() {
  local doc_root="$1" file
  local -a candidates=()
  shopt -s nullglob
  for file in "${doc_root}/"*.tar.gz "${doc_root}/"*.tgz "${doc_root}/"*.tar; do
    [[ "$file" == *_encode.tar.gz ]] && continue
    [[ -f "$file" && ! -L "$file" ]] && candidates+=("$file")
  done
  shopt -u nullglob
  (( ${#candidates[@]} == 1 )) && printf '%s\n' "${candidates[0]}"
  (( ${#candidates[@]} > 0 ))
}

bitrix_restore_marker_write() {
  local domain="$1" archive="$2" parts="$3" marker size
  marker=$(bitrix_restore_marker_path "$domain")
  size=$(stat -c %s "$archive" 2>/dev/null || echo 0)
  install -d -m 0750 "$(dirname "$marker")" 2>/dev/null || return 0
  printf 'ARCHIVE=%s\nSIZE=%s\nPARTS=%s\nVALIDATED_AT=%s\n' "$(basename "$archive")" "$size" "$parts" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
  chmod 0640 "$marker" 2>/dev/null || true
}

bitrix_restore_marker_matches() {
  local domain="$1" archive="$2" marker name="" size="" line
  marker=$(bitrix_restore_marker_path "$domain")
  [[ -f "$marker" ]] || return 1
  while IFS= read -r line; do
    case "$line" in ARCHIVE=*) name="${line#ARCHIVE=}" ;; SIZE=*) size="${line#SIZE=}" ;; esac
  done <"$marker"
  [[ "$name" == "$(basename "$archive")" && "$size" == "$(stat -c %s "$archive" 2>/dev/null)" ]]
}

bitrix_flow_state() {
  local domain="$1" web_state="${2:-}" id archive=""
  BX_FLOW_ROUTE="none"; BX_FLOW_STEP="prepare"; BX_FLOW_URL=""; BX_FLOW_PENDING=(); BX_FLOW_ARCHIVE=""
  [[ -n "$web_state" ]] || web_state=$(bitrix_web_state_probe "$domain")
  local restore_script setup_script
  restore_script=$(bitrix_restore_script_path "$BX_DOC_ROOT")
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if [[ "$web_state" == installed ]]; then
    BX_FLOW_ROUTE="installed"
    [[ -f "$(bitrix_restore_marker_path "$domain")" ]] && BX_FLOW_ROUTE="restore"
    for id in bitrix.docroot-leftovers bitrix.db-session-modes bitrix.db-charset bitrix.timezone; do
      site_check_state "$id" "$domain"
      [[ "$SC_STATE" == needed ]] && BX_FLOW_PENDING+=("$id")
    done
    if (( ${#BX_FLOW_PENDING[@]} > 0 )); then BX_FLOW_STEP="finalize"; else BX_FLOW_STEP="done"; fi
    return 0
  fi
  if [[ -s "$restore_script" ]]; then
    BX_FLOW_ROUTE="restore"
    if ! bitrix_restore_base_archive "$BX_DOC_ROOT" >/dev/null; then
      BX_FLOW_STEP="upload"
    else
      archive=$(bitrix_restore_base_archive "$BX_DOC_ROOT" || true)
      BX_FLOW_ARCHIVE="$(basename "${archive:-}")"
      if [[ -n "$archive" ]] && bitrix_restore_marker_matches "$domain" "$archive"; then
        BX_FLOW_STEP="run_restore"
        BX_FLOW_URL="$(site_primary_url "$domain")/restore.php"
      else
        BX_FLOW_STEP="validate"
      fi
    fi
    return 0
  fi
  if [[ -s "$setup_script" ]]; then
    BX_FLOW_ROUTE="setup"
    BX_FLOW_STEP="run_setup"
    BX_FLOW_URL=$(bitrix_installer_open_url "$domain" "$BX_DOC_ROOT")
  fi
  return 0
}

bitrix_status_json() {
  local db_state web_state
  db_state=$(bitrix_db_state_probe "$BX_DOMAIN")
  web_state=$(bitrix_web_state_probe "$BX_DOMAIN")
  bitrix_flow_state "$BX_DOMAIN" "$web_state"
  local settings="no" core="$BX_HAS_CORE"
  [[ -f "$BX_SETTINGS_FILE" ]] && settings="yes"
  local next=""
  case "$BX_FLOW_STEP" in
    upload) next="file:upload" ;;
    validate) next="bitrix:restore-ready" ;;
    run_restore|run_setup) next="open_url" ;;
    finalize) next="bitrix:finalize" ;;
    prepare) next="bitrix:restore-ready" ;;
  esac
  python3 -c '
import json, sys
domain, route, step, url, archive, db, web, settings, core, nxt = sys.argv[1:11]
print(json.dumps({"schema": "simai-bitrix-status/1", "domain": domain, "route": route, "step": step,
                  "restore_url": url if step == "run_restore" else None,
                  "installer_url": url if step == "run_setup" else None,
                  "next": nxt or None, "archive": archive or None,
                  "pending": [p for p in sys.argv[11:] if p],
                  "db_state": db, "web_state": web, "settings": settings == "yes", "core": core == "yes"}, indent=2))' \
    "$BX_DOMAIN" "$BX_FLOW_ROUTE" "$BX_FLOW_STEP" "$BX_FLOW_URL" "$BX_FLOW_ARCHIVE" "$db_state" "$web_state" "$settings" "$core" "$next" "${BX_FLOW_PENDING[@]}"
}

bitrix_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    bitrix_status_json
    return
  fi

  ui_header "SIMAI ENV · Bitrix status"
  local settings_present="no"
  local dbconn_present="no"
  local bx_crontab="unknown"
  local bx_crontab_support="unknown"
  local short_install="unknown"
  local setup_script=""
  local setup_state="missing"
  local setup_kind="missing"
  local archives="none"
  local cron_entrypoint="missing"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local db_state="unknown"
  local web_state="unknown"
  local install_stage="unknown"
  local open_url=""

  [[ -f "$BX_SETTINGS_FILE" ]] && settings_present="yes"
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if [[ -s "$setup_script" ]]; then
    setup_kind=$(bitrix_setup_script_kind "$setup_script")
    case "$setup_kind" in
      site-management) setup_state="ready" ;;
      bitrix24-loader) setup_state="generic-loader" ;;
      *) setup_state="present" ;;
    esac
  fi
  archives=$(bitrix_detect_distribution_archives "$BX_DOC_ROOT")
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_present="yes"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
  fi
  [[ -f "$BX_CRON_ENTRYPOINT" ]] && cron_entrypoint="present"
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    if [[ "${BX_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  db_state=$(bitrix_db_state_probe "$BX_DOMAIN")
  web_state=$(bitrix_web_state_probe "$BX_DOMAIN")
  install_stage=$(bitrix_perf_install_stage "$short_install" "$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "${BX_CRON_ENTRY_MATCH:-no}" "$bx_crontab" "$bx_crontab_support" "${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}")" "$web_state")
  open_url=$(bitrix_installer_open_url "$BX_DOMAIN" "$BX_DOC_ROOT")

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Database state|${db_state}" \
    "Web state|${web_state}" \
    "Install stage|${install_stage}" \
    "Core files|${BX_HAS_CORE}" \
    ".settings.php|${settings_present}" \
    "dbconn.php|${dbconn_present}" \
    "bitrixsetup.php|${setup_script} (${setup_state})" \
    "Setup kind|${setup_kind}" \
    "Archives|${archives}" \
    "BX_CRONTAB|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT|${bx_crontab_support}" \
    "SHORT_INSTALL|${short_install}" \
    "Scheduler script|${cron_entrypoint}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry|${cron_line_state}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}"
  ui_next_steps
  case "$web_state" in
    installer)
      ui_kv "Open installer" "$open_url"
      ui_kv "Finalize setup" "simai-admin.sh bitrix finalize --domain ${BX_DOMAIN}"
      ;;
    installed)
      ui_kv "Open admin" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/"
      ui_kv "Finalize setup" "simai-admin.sh bitrix finalize --domain ${BX_DOMAIN}"
      ;;
    *)
      ui_kv "Prepare installer" "simai-admin.sh bitrix installer-ready --domain ${BX_DOMAIN}"
      ui_kv "Open installer" "$open_url"
      ;;
  esac
  ui_kv "Doctor" "simai-admin.sh site doctor --domain ${BX_DOMAIN}"
  ui_kv "Agents status" "simai-admin.sh bitrix agents-status --domain ${BX_DOMAIN}"
}

bitrix_cron_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · Bitrix scheduler status"
  local cron_file_state="missing"
  local cron_line_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local cron_short_open_tag_match="no"
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_short_open_tag_match="${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}"
    if [[ "${BX_CRON_ENTRY_MATCH:-no}" == "yes" ]]; then
      cron_line_state="present"
    fi
  fi
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Scheduler entry (cron_events.php)|${cron_line_state}" \
    "CLI short_open_tag|${cron_short_open_tag_match}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}"
  ui_next_steps
  ui_kv "Sync scheduler" "simai-admin.sh bitrix cron-sync --domain ${BX_DOMAIN}"
}

bitrix_cron_sync_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ -z "$BX_PHP_VERSION" || "$BX_PHP_VERSION" == "none" ]]; then
    error "Bitrix site PHP version is missing for ${domain}."
    return 1
  fi
  ui_header "SIMAI ENV · Bitrix scheduler sync"
  cron_site_write "$BX_DOMAIN" "$BX_SLUG" "bitrix" "$BX_ROOT" "$BX_PHP_VERSION"
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Scheduler file|${BX_CRON_FILE}" \
    "Profile|bitrix" \
    "PHP|${BX_PHP_VERSION}"
  ui_next_steps
  ui_kv "Check scheduler" "simai-admin.sh bitrix cron-status --domain ${BX_DOMAIN}"
}

bitrix_agents_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  ui_header "SIMAI ENV · Bitrix agents status"
  local dbconn_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  local cron_file_state="missing"
  local cron_entry_match="no"
  local cron_short_open_tag_match="no"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"

  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_state="present"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
    cron_short_open_tag_match="${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}"
  fi
  local ready
  ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support" "$cron_short_open_tag_match")

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn.php|${dbconn_state}" \
    "BX_CRONTAB|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT|${bx_crontab_support}" \
    "Scheduler file|${BX_CRON_FILE} (${cron_file_state})" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "Scheduler entry (cron_events.php)|${cron_entry_match}" \
    "CLI short_open_tag|${cron_short_open_tag_match}" \
    "Agents via scheduler|${ready}"
  ui_next_steps
  ui_kv "Plan sync" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN}"
  ui_kv "Apply sync" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN} --apply yes --confirm yes"
}

bitrix_agents_sync_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${apply,,}" == "yes" ]] || apply="no"
  [[ "${confirm,,}" == "yes" ]] || confirm="no"

  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  if [[ -z "$BX_PHP_VERSION" || "$BX_PHP_VERSION" == "none" ]]; then
    error "Bitrix site PHP version is missing for ${domain}."
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix agents sync"
  local dbconn_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_state="present"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi

  ui_section "Plan"
  print_kv_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn.php|${BX_DBCONN_FILE} (${dbconn_state})" \
    "BX_CRONTAB current|${bx_crontab}" \
    "BX_CRONTAB_SUPPORT current|${bx_crontab_support}" \
    "Scheduler target|${BX_CRON_FILE}" \
    "Apply mode|${apply}"

  if [[ "$apply" != "yes" ]]; then
    info "Plan only. No changes applied."
    ui_next_steps
    ui_kv "Apply" "simai-admin.sh bitrix agents-sync --domain ${BX_DOMAIN} --apply yes --confirm yes"
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply Bitrix agents sync in CLI mode."
    return 1
  fi
  if [[ ! -f "$BX_DBCONN_FILE" ]]; then
    error "dbconn.php not found: ${BX_DBCONN_FILE}"
    return 1
  fi

  local ts backup
  ts=$(date +%Y%m%d-%H%M%S)
  backup="${BX_DBCONN_FILE}.bak.${ts}"
  cp -a "$BX_DBCONN_FILE" "$backup"
  if ! bitrix_dbconn_drop_const "$BX_DBCONN_FILE" "BX_CRONTAB"; then
    error "Failed to sanitize BX_CRONTAB in ${BX_DBCONN_FILE}"
    cp -a "$backup" "$BX_DBCONN_FILE" || true
    return 1
  fi
  if ! bitrix_dbconn_set_const_true "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT"; then
    error "Failed to update BX_CRONTAB_SUPPORT in ${BX_DBCONN_FILE}"
    cp -a "$backup" "$BX_DBCONN_FILE" || true
    return 1
  fi

  cron_site_write "$BX_DOMAIN" "$BX_SLUG" "bitrix" "$BX_ROOT" "$BX_PHP_VERSION"
  local cron_managed="no" cron_domain_match="no" cron_slug_match="no" cron_entry_match="no" cron_short_open_tag_match="no"
  if [[ -f "$BX_CRON_FILE" ]]; then
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
    cron_short_open_tag_match="${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}"
  fi

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "dbconn backup|${backup}" \
    "BX_CRONTAB|$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")" \
    "BX_CRONTAB_SUPPORT|$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")" \
    "Scheduler file|${BX_CRON_FILE}" \
    "Managed file|${cron_managed}" \
    "Domain marker|${cron_domain_match}" \
    "Site marker|${cron_slug_match}" \
    "Scheduler entry (cron_events.php)|${cron_entry_match}" \
    "CLI short_open_tag|${cron_short_open_tag_match}"
  ui_next_steps
  ui_kv "Verify" "simai-admin.sh bitrix agents-status --domain ${BX_DOMAIN}"
}

bitrix_cache_clear_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi
  ui_header "SIMAI ENV · Bitrix cache clear"
  local -a dirs=(
    "${BX_DOC_ROOT}/bitrix/cache"
    "${BX_DOC_ROOT}/bitrix/managed_cache"
    "${BX_DOC_ROOT}/bitrix/stack_cache"
  )
  local cleared=0 missing=0 dir
  for dir in "${dirs[@]}"; do
    if [[ -d "$dir" ]]; then
      # Runs as the site user: the site tree is writable by PHP, so a planted
      # symlink must not let root delete files outside the site.
      runuser -u "$SIMAI_USER" -- find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} + >/dev/null 2>&1 || true
      cleared=$((cleared + 1))
    else
      missing=$((missing + 1))
    fi
  done
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Cache dirs cleared|${cleared}" \
    "Cache dirs missing|${missing}"
  ui_next_steps
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_list_sites() {
  local domain profile
  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    if read_site_metadata "$domain"; then
      profile="${SITE_META[profile]:-}"
      if [[ "$profile" == "bitrix" ]]; then
        echo "$domain"
      fi
    fi
  done < <(list_sites)
}

bitrix_db_preseed_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local short_install="${PARSED_ARGS[short-install]:-yes}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"

  local rc=0
  if bitrix_prepare_site "$domain"; then
    rc=0
  else
    rc=$?
    return $rc
  fi

  if ! read_site_db_env "$BX_DOMAIN" >/dev/null 2>&1; then
    error "db.env not found or incomplete for ${BX_DOMAIN}"
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix DB preseed"
  local status="failed"
  if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "$overwrite" "$short_install"; then
    status="ready"
  else
    error "Failed to generate Bitrix DB preseed files"
    return 1
  fi

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Overwrite|${overwrite}" \
    "SHORT_INSTALL|${short_install}" \
    ".settings.php|${BX_SETTINGS_FILE}" \
    "dbconn.php|${BX_DBCONN_FILE}" \
    "Status|${status}"
  ui_next_steps
  ui_kv "Open installer" "https://${BX_DOMAIN}/bitrixsetup.php"
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_installer_ready_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local short_install="${PARSED_ARGS[short-install]:-yes}"
  local setup_overwrite="${PARSED_ARGS[setup-overwrite]:-no}"
  local archive="${PARSED_ARGS[archive]:-yes}"
  local edition="${PARSED_ARGS[edition]:-standard}"
  local archive_overwrite="${PARSED_ARGS[archive-overwrite]:-no}"
  local unpack="${PARSED_ARGS[unpack]:-yes}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"
  [[ "${setup_overwrite,,}" == "yes" ]] || setup_overwrite="no"
  [[ "${archive,,}" == "yes" ]] && archive="yes" || archive="no"
  [[ "${archive_overwrite,,}" == "yes" ]] || archive_overwrite="no"
  [[ "${unpack,,}" == "yes" ]] && unpack="yes" || unpack="no"
  edition=$(bitrix_distribution_edition_normalize "$edition") || {
    error "Unsupported Bitrix edition '${edition}'. Use: start, standard, small-business, business"
    return 1
  }

  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc
  if ! read_site_db_env "$BX_DOMAIN" >/dev/null 2>&1; then
    error "db.env not found or incomplete for ${BX_DOMAIN}"
    return 1
  fi

  ui_header "SIMAI ENV · Bitrix installer ready"
  local preseed_state="failed"
  if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "$overwrite" "$short_install"; then
    preseed_state="ready"
  fi
  local setup_state="failed"
  local setup_script
  local setup_kind="missing"
  local archive_state="skipped"
  local archive_path="n/a"
  local unpack_state="skipped"
  setup_script=$(bitrix_setup_script_path "$BX_DOC_ROOT")
  if bitrix_download_setup_script "$BX_DOC_ROOT" "$setup_overwrite"; then
    setup_kind=$(bitrix_setup_script_kind "$setup_script")
    case "$setup_kind" in
      site-management) setup_state="ready" ;;
      bitrix24-loader) setup_state="generic-loader" ;;
      *) setup_state="downloaded" ;;
    esac
  fi
  if [[ "$archive" == "yes" ]]; then
    archive_path=$(bitrix_distribution_archive_path "$BX_DOC_ROOT" "$edition") || archive_path="n/a"
    if bitrix_download_distribution_archive "$BX_DOC_ROOT" "$edition" "$archive_overwrite"; then
      archive_state="ready"
    else
      archive_state="failed"
    fi
  fi
  if [[ "$archive_state" == "ready" && "$unpack" == "yes" ]]; then
    if bitrix_unpack_distribution_archive "$BX_DOC_ROOT" "$edition"; then
      unpack_state="ready"
      if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "yes" "$short_install"; then
        preseed_state="ready"
      else
        preseed_state="failed"
      fi
    else
      unpack_state="failed"
    fi
  fi
  local status="ready"
  if [[ "$preseed_state" != "ready" ]]; then
    status="partial"
  elif [[ "$unpack_state" == "ready" ]]; then
    status="ready"
  elif [[ "$setup_state" == "ready" ]]; then
    status="ready"
  elif [[ "$setup_kind" == "bitrix24-loader" && "$archive_state" == "ready" ]]; then
    status="ready"
  else
    status="partial"
  fi

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "DB preseed|${preseed_state}" \
    "SHORT_INSTALL|${short_install}" \
    "Setup script|${setup_state}" \
    "Setup kind|${setup_kind}" \
    "Edition|${edition}" \
    "Archive|${archive_state}" \
    "Archive path|${archive_path}" \
    "Unpack|${unpack_state}" \
    "bitrixsetup.php|${setup_script}" \
    "Status|${status}"
  if [[ "$status" != "ready" ]]; then
    warn "Installer ready is partial. Check network access, db.env values, and whether the setup script plus local distro archive form a valid Site Management installer flow."
    return 1
  fi
  ui_next_steps
  if [[ "$unpack_state" == "ready" ]]; then
    ui_kv "Open installer" "$(site_primary_url "$BX_DOMAIN")/"
  else
    ui_kv "Open installer" "$(site_primary_url "$BX_DOMAIN")/bitrixsetup.php?test=1"
  fi
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

bitrix_restore_ready_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  local preseed="${PARSED_ARGS[preseed]:-auto}"
  local short_install="${PARSED_ARGS[short-install]:-no}"
  local archive="${PARSED_ARGS[archive]:-auto}"
  [[ "${overwrite,,}" == "yes" ]] || overwrite="no"
  case "${preseed,,}" in
    yes|no|auto) preseed="${preseed,,}" ;;
    *)
      error "Unsupported preseed value '${preseed}'. Use: auto, yes, no"
      return 1
      ;;
  esac
  [[ "${short_install,,}" == "yes" ]] && short_install="yes" || short_install="no"

  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc

  ui_header "SIMAI ENV · Bitrix restore ready"

  local writable_state="ready"
  if ! bitrix_prepare_restore_writable_paths "$BX_DOC_ROOT"; then
    writable_state="failed"
  fi

  local preseed_state="skipped"
  if [[ "$preseed" == "yes" || "$preseed" == "auto" ]]; then
    if read_site_db_env "$BX_DOMAIN" >/dev/null 2>&1; then
      if bitrix_write_db_preseed_files "$BX_DOMAIN" "$BX_DOC_ROOT" "$overwrite" "$short_install" "no"; then
        preseed_state="ready"
      else
        preseed_state="failed"
      fi
    elif [[ "$preseed" == "yes" ]]; then
      error "db.env not found or incomplete for ${BX_DOMAIN}; use site db-create first or run with --preseed no"
      return 1
    else
      preseed_state="skipped (no db.env)"
    fi
  fi

  local restore_state="failed"
  local restore_script
  restore_script=$(bitrix_restore_script_path "$BX_DOC_ROOT")
  if bitrix_download_restore_script "$BX_DOC_ROOT" "$overwrite"; then
    restore_state="ready"
  fi

  local archive_state="not uploaded"
  local archive_path="n/a"
  local archive_parts="0"
  local archive_detail="Upload the archive, then run restore-ready again"
  local archive_rc=0
  bitrix_restore_archive_validate "$BX_DOC_ROOT" "$archive" || archive_rc=$?
  archive_state="$BITRIX_RESTORE_ARCHIVE_STATE"
  archive_parts="$BITRIX_RESTORE_ARCHIVE_PARTS"
  archive_detail="$BITRIX_RESTORE_ARCHIVE_DETAIL"
  [[ -n "$BITRIX_RESTORE_ARCHIVE_PATH" ]] && archive_path="$BITRIX_RESTORE_ARCHIVE_PATH"

  local status="ready"
  if [[ "$writable_state" != "ready" || "$restore_state" != "ready" || "$preseed_state" == "failed" || $archive_rc -eq 1 ]]; then
    status="partial"
  elif [[ $archive_rc -eq 2 ]]; then
    status="waiting for archive"
  fi
  # bitrix status shows run_restore only for the archive validated here.
  if [[ "$status" == ready && -n "$BITRIX_RESTORE_ARCHIVE_PATH" && -f "$BITRIX_RESTORE_ARCHIVE_PATH" ]]; then
    bitrix_restore_marker_write "$BX_DOMAIN" "$BITRIX_RESTORE_ARCHIVE_PATH" "$archive_parts"
  fi

  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Writable paths|${writable_state}" \
    "DB preseed|${preseed_state}" \
    "SHORT_INSTALL|${short_install}" \
    "restore.php|${restore_script} (${restore_state})" \
    "Archive|${archive_state}" \
    "Archive path|${archive_path}" \
    "Archive parts|${archive_parts}" \
    "Archive check|${archive_detail}" \
    "Status|${status}"

  if [[ "$status" == "partial" ]]; then
    warn "Restore ready is partial. Check network access, restore.php download, db.env, and writable path permissions."
    return 1
  fi

  ui_next_steps
  if [[ "$status" == "waiting for archive" ]]; then
    ui_kv "Upload archive" "Copy every archive volume into ${BX_DOC_ROOT}"
    ui_kv "Validate archive" "simai-admin.sh bitrix restore-ready --domain ${BX_DOMAIN}"
  else
    ui_kv "Open restore wizard" "$(site_primary_url "$BX_DOMAIN")/restore.php"
  fi
  ui_kv "After restore" "simai-admin.sh bitrix finalize --domain ${BX_DOMAIN} --confirm yes"
  ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
}

# Host-wide part of the Bitrix PHP baseline: OPcache memory and the realpath
# cache are set per PHP version (PHP_INI_SYSTEM), not per pool.
bitrix_php_host_baseline_sync() {
  local d ver
  local -A seen=()
  for d in "$@"; do
    bitrix_prepare_site "$d" >/dev/null 2>&1 || continue
    ver="${BX_PHP_VERSION:-}"
    [[ -n "$ver" && "$ver" != none && -z "${seen[$ver]:-}" ]] || continue
    seen[$ver]=1
    if [[ "$(php_fpm_opcache_baseline_ensure "$ver")" == changed ]]; then
      info "PHP ${ver}: OPcache baseline written to $(php_fpm_opcache_baseline_path "$ver")"
    fi
  done
  return 0
}

bitrix_php_baseline_sync_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local all="${PARSED_ARGS[all]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local include_recommended="${PARSED_ARGS[include-recommended]:-yes}"
  [[ "${all,,}" == "yes" ]] && all="yes" || all="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${include_recommended,,}" == "yes" ]] && include_recommended="yes" || include_recommended="no"

  local -a targets=()
  if [[ "$all" == "yes" ]]; then
    mapfile -t targets < <(bitrix_list_sites)
    if [[ ${#targets[@]} -eq 0 ]]; then
      warn "No bitrix sites found"
      return 0
    fi
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
      error "Bulk sync requires --confirm yes"
      return 1
    fi
  else
    if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
      local candidates=()
      mapfile -t candidates < <(bitrix_list_sites)
      if [[ ${#candidates[@]} -eq 0 ]]; then
        warn "No bitrix sites found"
        return 0
      fi
      domain=$(select_from_list "Select Bitrix site" "" "${candidates[@]}")
      if [[ -z "$domain" ]]; then
        command_cancelled
        return $?
      fi
    fi
    require_args "domain" || return 1
    bitrix_prepare_site "$domain"
    local rc=$?
    (( rc == 0 )) || return $rc
    targets=("$domain")
  fi

  ui_header "SIMAI ENV · Bitrix PHP baseline sync"
  bitrix_php_host_baseline_sync "${targets[@]}"
  local ok=0 fail=0 d
  local -a failed=()
  for d in "${targets[@]}"; do
    info "Applying PHP INI baseline for ${d}"
    if run_command site fix --domain "$d" --apply php-ini --include-recommended "$include_recommended" --confirm yes; then
      # Enforce critical Bitrix runtime keys in FPM pool regardless of CLI ini defaults.
      if bitrix_prepare_site "$d"; then
        local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$(project_slug_from_domain "$d")}}"
        if [[ -n "${BX_PHP_VERSION:-}" && "${BX_PHP_VERSION:-none}" != "none" ]]; then
          # Keep the site's other overrides; the baseline keys win.
          local -A ini_kv=()
          local ini_entry ini_key
          while IFS= read -r ini_entry; do
            [[ -z "$ini_entry" ]] && continue
            ini_kv["${ini_entry%%|*}"]="${ini_entry#*|}"
          done < <(read_site_php_ini_overrides "$d")
          for ini_entry in \
            "short_open_tag|1" \
            "memory_limit|512M" \
            "max_input_vars|10000" \
            "max_execution_time|300" \
            "max_input_time|300" \
            "post_max_size|64M" \
            "upload_max_filesize|64M" \
            "opcache.validate_timestamps|1" \
            "opcache.revalidate_freq|0"; do
            ini_kv["${ini_entry%%|*}"]="${ini_entry#*|}"
          done
          # PHP without date.timezone runs in UTC while MySQL uses the system
          # zone; an existing site override is left as it is.
          if [[ -z "${ini_kv[date.timezone]:-}" ]]; then
            ini_kv["date.timezone"]=$(bitrix_host_timezone "$(resolve_php_bin "$BX_PHP_VERSION")")
          fi
          local -a ini_out=()
          for ini_key in "${!ini_kv[@]}"; do
            ini_out+=("${ini_key}|${ini_kv[$ini_key]}")
          done
          write_site_php_ini_overrides "$d" "${ini_out[@]}"
          unset ini_kv
          if apply_site_php_ini_overrides_to_pool "$d" "$BX_PHP_VERSION" "$socket_project" "yes"; then
            ok=$((ok + 1))
          else
            fail=$((fail + 1))
            failed+=("$d")
          fi
        else
          fail=$((fail + 1))
          failed+=("$d")
        fi
      else
        fail=$((fail + 1))
        failed+=("$d")
      fi
    else
      fail=$((fail + 1))
      failed+=("$d")
    fi
  done

  ui_result_table \
    "Scope|$([[ "$all" == "yes" ]] && echo all bitrix sites || echo single site)" \
    "Targets|${#targets[@]}" \
    "Applied|${ok}" \
    "Failed|${fail}" \
    "Include recommended|${include_recommended}"
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed sites: ${failed[*]}"
    return 1
  fi
  ui_next_steps
  ui_kv "Verify one site" "simai-admin.sh site doctor --domain <bitrix-domain>"
  return 0
}

bitrix_ownership_scan_roots() {
  local doc_root="$1"
  local target real
  printf '%s|%s\n' "$doc_root" "web"

  for target in "${doc_root}/local/modules"/* "${doc_root}/bitrix/modules"/*; do
    [[ -L "$target" ]] || continue
    real=$(readlink -f "$target" 2>/dev/null || true)
    [[ -n "$real" && -e "$real" ]] || continue
    case "$real" in
      "$doc_root"/*|"${SIMAI_HOME}"/git/*|"${WWW_ROOT}"/*)
        printf '%s|%s\n' "$real" "linked"
        ;;
    esac
  done | awk -F'|' '!seen[$1]++'
}

bitrix_ownership_count_root_owned() {
  local path="$1"
  [[ -e "$path" ]] || {
    echo 0
    return 0
  }
  find "$path" -xdev \( -user root -o -group root \) -printf . 2>/dev/null | wc -c | tr -d ' '
}

bitrix_ownership_fix_path() {
  local path="$1" group="$2"
  [[ -e "$path" ]] || return 0
  find "$path" -xdev \( -user root -o -group root \) -exec chown -h "${SIMAI_USER:-simai}:${group}" {} + 2>/dev/null || return 1
  find "$path" -xdev -type d -exec chmod u+rwx,g+rwx {} + 2>/dev/null || true
}

bitrix_ownership_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${apply,,}" == "yes" ]] && apply="yes" || apply="no"

  if [[ "$apply" == "yes" && "${SIMAI_ADMIN_MENU:-0}" != "1" && "${confirm,,}" != "yes" ]]; then
    error "Ownership repair requires --confirm yes in CLI mode."
    return 1
  fi

  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc

  ui_header "SIMAI ENV · Bitrix ownership"

  local rows=()
  local total_before=0 total_after=0 fixed_count=0 failure_count=0
  local root kind count_before count_after group status
  while IFS='|' read -r root kind; do
    [[ -n "$root" ]] || continue
    count_before=$(bitrix_ownership_count_root_owned "$root")
    total_before=$((total_before + count_before))
    status="ok"
    count_after="$count_before"
    if [[ "$apply" == "yes" && "$count_before" -gt 0 ]]; then
      group="${SIMAI_WEB_GROUP:-www-data}"
      [[ "$root" == "${SIMAI_HOME}"/git/* ]] && group="${SIMAI_USER:-simai}"
      if bitrix_ownership_fix_path "$root" "$group"; then
        count_after=$(bitrix_ownership_count_root_owned "$root")
        fixed_count=$((fixed_count + count_before - count_after))
        [[ "$count_after" -eq 0 ]] || status="partial"
      else
        failure_count=$((failure_count + 1))
        status="failed"
      fi
    fi
    total_after=$((total_after + count_after))
    rows+=("${kind}: ${root}|${count_before} -> ${count_after} (${status})")
  done < <(bitrix_ownership_scan_roots "$BX_DOC_ROOT")

  echo "Ownership scan:"
  local row
  for row in "${rows[@]}"; do
    printf "  %-80s %s\n" "${row%%|*}" "${row#*|}"
  done
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Docroot|${BX_DOC_ROOT}" \
    "Apply|${apply}" \
    "Root-owned before|${total_before}" \
    "Root-owned after|${total_after}" \
    "Fixed|${fixed_count}" \
    "Failures|${failure_count}"

  if [[ "$apply" != "yes" && "$total_before" -gt 0 ]]; then
    ui_next_steps
    ui_kv "Repair" "simai-admin.sh bitrix ownership --domain ${BX_DOMAIN} --apply yes --confirm yes"
  fi
  if [[ "$apply" == "yes" ]]; then
    [[ "$failure_count" -eq 0 && "$total_after" -eq 0 ]]
    return $?
  fi
  return 0
}

bitrix_perf_status_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc

  local managed_mode="none"
  managed_mode=$(bitrix_perf_read_mode "$domain")
  local settings_present="no"
  local dbconn_present="no"
  local after_connect_state="missing"
  local settings_init_state="missing"
  local bx_crontab="missing"
  local bx_crontab_support="missing"
  local short_install="unknown"
  local install_stage="unknown"
  local web_state="unknown"
  local cron_file_state="missing"
  local cron_managed="no"
  local cron_domain_match="no"
  local cron_slug_match="no"
  local cron_entry_match="no"
  local agents_ready="no"
  local db_state="unknown"
  local cache_dirs="0/3 present"
  local php_bin=""
  local redis_ext="no"
  local redis_service="n/a"
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$BX_SLUG}}"
  local pool_file="/etc/php/${BX_PHP_VERSION}/fpm/pool.d/${socket_project}.conf"
  local memory_limit="n/a"
  local upload_max="n/a"
  local post_max="n/a"
  local max_input_vars="n/a"
  local max_execution_time="n/a"
  local short_open_tag="n/a"
  local opcache_revalidate="n/a"
  local opcache_memory="n/a"

  [[ -f "$BX_SETTINGS_FILE" ]] && settings_present="yes"
  if [[ -f "$BX_SETTINGS_FILE" ]]; then
    settings_init_state=$(bitrix_perf_settings_init_state "$BX_SETTINGS_FILE")
  fi
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    dbconn_present="yes"
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
  fi
  after_connect_state=$(bitrix_perf_after_connect_state "${BX_DOC_ROOT}/bitrix/php_interface/after_connect_d7.php")
  # A restored .settings.php has no init_commands; the session modes in
  # after_connect_d7.php cover them.
  if [[ "$settings_present" == "yes" && "$settings_init_state" != "ready" && "$after_connect_state" == "ready" ]]; then
    settings_init_state="ready (via after_connect_d7.php)"
  fi
  if [[ -f "$BX_CRON_FILE" ]]; then
    cron_file_state="present"
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi
  agents_ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support" "${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}")
  db_state=$(bitrix_db_state_probe "$BX_DOMAIN")
  web_state=$(bitrix_web_state_probe "$BX_DOMAIN")
  install_stage=$(bitrix_perf_install_stage "$short_install" "$agents_ready" "$web_state")
  cache_dirs=$(bitrix_perf_cache_dirs_state "$BX_DOC_ROOT")

  if [[ -f "$pool_file" ]]; then
    memory_limit=$(doctor_php_pool_ini_get "$pool_file" "memory_limit" || true)
    upload_max=$(doctor_php_pool_ini_get "$pool_file" "upload_max_filesize" || true)
    post_max=$(doctor_php_pool_ini_get "$pool_file" "post_max_size" || true)
    max_input_vars=$(doctor_php_pool_ini_get "$pool_file" "max_input_vars" || true)
    max_execution_time=$(doctor_php_pool_ini_get "$pool_file" "max_execution_time" || true)
    short_open_tag=$(doctor_php_pool_ini_get "$pool_file" "short_open_tag" || true)
    opcache_revalidate=$(doctor_php_pool_ini_get "$pool_file" "opcache.revalidate_freq" || true)
    opcache_memory=$(doctor_php_pool_ini_get "$pool_file" "opcache.memory_consumption" || true)
  fi
  php_bin=$(resolve_php_bin "$BX_PHP_VERSION")
  if [[ -n "$php_bin" ]] && "$php_bin" -m 2>/dev/null | grep -i '^redis$' >/dev/null; then
    redis_ext="yes"
  fi
  if os_svc_has_unit "redis-server"; then
    if os_svc_is_active "redis-server"; then
      redis_service="active"
    else
      redis_service="inactive"
    fi
  fi

  ui_header "SIMAI ENV · Bitrix optimization"
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Optimization mode|${managed_mode}" \
    "Database state|${db_state}" \
    "Web state|${web_state}" \
    "Install stage|${install_stage}" \
    "PHP|${BX_PHP_VERSION:-none}" \
    "Core files|${BX_HAS_CORE}" \
    ".settings.php|${settings_present}" \
    "dbconn.php|${dbconn_present}" \
    "Settings init_commands|${settings_init_state}" \
    "after_connect_d7.php|${after_connect_state}" \
    "Agents via cron ready|${agents_ready}" \
    "Cache dirs|${cache_dirs}" \
    "memory_limit|${memory_limit:-n/a}" \
    "upload_max_filesize|${upload_max:-n/a}" \
    "post_max_size|${post_max:-n/a}" \
    "max_input_vars|${max_input_vars:-n/a}" \
    "max_execution_time|${max_execution_time:-n/a}" \
    "short_open_tag|${short_open_tag:-n/a}" \
    "opcache.revalidate_freq|${opcache_revalidate:-n/a}" \
    "opcache.memory_consumption|${opcache_memory:-n/a}" \
    "Redis extension|${redis_ext}" \
    "Redis service|${redis_service}"
  ui_next_steps
  if [[ "$web_state" == "installer" ]]; then
    ui_kv "Open installer" "$(bitrix_installer_open_url "$BX_DOMAIN" "$BX_DOC_ROOT")"
  else
    ui_kv "Finalize setup" "simai-admin.sh bitrix finalize --domain ${BX_DOMAIN}"
    ui_kv "Checker" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/site_checker.php"
    ui_kv "Perfmon" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/perfmon_panel.php"
  fi
  ui_kv "Apply standard optimization" "simai-admin.sh bitrix perf-apply --domain ${BX_DOMAIN} --mode standard --confirm yes"
}

bitrix_perf_apply_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local mode="${PARSED_ARGS[mode]:-standard}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local include_recommended="${PARSED_ARGS[include-recommended]:-yes}"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${include_recommended,,}" == "yes" ]] && include_recommended="yes" || include_recommended="no"
  mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
  case "$mode" in
    standard|high-load) ;;
    *)
      error "Unsupported Bitrix performance mode: ${mode}"
      return 1
      ;;
  esac
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to apply Bitrix optimization changes"
    return 1
  fi
  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc

  local site_mode=""
  site_mode=$(bitrix_perf_site_mode_for_apply "$mode") || return 1
  local socket_project="${SITE_META[php_socket_project]:-${SITE_META[project]:-$BX_SLUG}}"
  if ! validate_project_slug "$socket_project"; then
    socket_project="$(project_slug_from_domain "$domain")"
  fi
  local -a settings=()
  mapfile -t settings < <(site_perf_mode_defaults "bitrix" "$site_mode")
  write_site_perf_settings "$domain" "${settings[@]}"
  apply_site_perf_settings_to_pool "$domain" "$BX_PHP_VERSION" "$socket_project" || return 1

  local php_status="ok"
  local agents_status="skipped"
  local cache_status="skipped"
  if ! run_command bitrix php-baseline-sync --domain "$domain" --include-recommended "$include_recommended"; then
    php_status="failed"
    error "Bitrix PHP baseline sync failed for ${domain}"
    return 1
  fi

  local short_install="unknown"
  local cron_managed="no" cron_domain_match="no" cron_slug_match="no" cron_entry_match="no"
  local bx_crontab="missing" bx_crontab_support="missing"
  if [[ -f "$BX_DBCONN_FILE" ]]; then
    short_install=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "SHORT_INSTALL")
    bx_crontab=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB")
    bx_crontab_support=$(bitrix_dbconn_const_state "$BX_DBCONN_FILE" "BX_CRONTAB_SUPPORT")
  fi
  if [[ -f "$BX_CRON_FILE" ]]; then
    bitrix_cron_markers "$BX_CRON_FILE" "$BX_DOMAIN" "$BX_SLUG"
    cron_managed="${BX_CRON_MANAGED:-no}"
    cron_domain_match="${BX_CRON_DOMAIN_MATCH:-no}"
    cron_slug_match="${BX_CRON_SLUG_MATCH:-no}"
    cron_entry_match="${BX_CRON_ENTRY_MATCH:-no}"
  fi
  local agents_ready="no"
  agents_ready=$(bitrix_agents_ready_state "$cron_managed" "$cron_domain_match" "$cron_slug_match" "$cron_entry_match" "$bx_crontab" "$bx_crontab_support" "${BX_CRON_SHORT_OPEN_TAG_MATCH:-no}")
  if [[ ("$short_install" != "true" || "$agents_ready" == "yes") && -f "$BX_DBCONN_FILE" ]]; then
    if run_command bitrix agents-sync --domain "$domain" --apply yes --confirm yes; then
      agents_status="applied"
    else
      agents_status="failed"
      error "Bitrix agents sync failed for ${domain}"
      return 1
    fi
  else
    agents_status="skipped (installer)"
  fi

  if [[ "$BX_HAS_CORE" == "yes" && ("$short_install" != "true" || "$agents_ready" == "yes") ]]; then
    if run_command bitrix cache-clear --domain "$domain"; then
      cache_status="cleared"
    else
      cache_status="failed"
      error "Bitrix cache clear failed for ${domain}"
      return 1
    fi
  else
    cache_status="skipped (installer)"
  fi

  ui_header "SIMAI ENV · Apply Bitrix optimization"
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Mode|${mode}" \
    "Site tune|applied (${site_mode})" \
    "PHP baseline|${php_status}" \
    "Agents sync|${agents_status}" \
    "Cache clear|${cache_status}"
  ui_next_steps
  ui_kv "Review Bitrix status" "simai-admin.sh bitrix perf-status --domain ${BX_DOMAIN}"
}

bitrix_finalize_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local ssl_mode="${PARSED_ARGS[ssl]:-no}"
  local email="${PARSED_ARGS[email]:-}"
  local redirect="${PARSED_ARGS[redirect]:-}"
  local hsts="${PARSED_ARGS[hsts]:-}"
  local staging="${PARSED_ARGS[staging]:-}"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${ssl_mode,,}" == "yes" ]] && ssl_mode="yes" || ssl_mode="no"

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to finalize Bitrix setup in CLI mode."
    return 1
  fi
  bitrix_prepare_site "$domain"
  local rc=$?
  (( rc == 0 )) || return $rc

  local web_state="unknown"
  local db_state="unknown"
  db_state=$(bitrix_db_state_probe "$BX_DOMAIN")
  web_state=$(bitrix_web_state_probe "$BX_DOMAIN")
  if [[ "$web_state" != "installed" ]]; then
    ui_header "SIMAI ENV · Bitrix finalize setup"
    ui_result_table \
      "Domain|${BX_DOMAIN}" \
      "Database state|${db_state}" \
      "Web state|${web_state}" \
      "Status|blocked"
    ui_next_steps
    ui_kv "Open installer" "$(bitrix_installer_open_url "$BX_DOMAIN" "$BX_DOC_ROOT")"
    ui_kv "Check status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
    error "Bitrix web installation is not complete for ${BX_DOMAIN}."
    return 1
  fi

  local php_status="failed"
  local agents_status="failed"
  local ssl_status="skipped"
  local step_failures=0

  # Restore leftovers first: archive volumes, restore.php and the dump are
  # downloadable from the docroot until they are moved out.
  if ! bitrix_restore_leftovers_move "$BX_ROOT" "$BX_DOC_ROOT"; then
    step_failures=$((step_failures + 1))
    warn "Restore leftovers: ${BX_LEFTOVERS_RESULT}"
  fi
  local leftovers_status="$BX_LEFTOVERS_RESULT"

  local php_bin
  php_bin=$(resolve_php_bin "$BX_PHP_VERSION")
  if ! bitrix_after_connect_session_modes_ensure "${BX_DOC_ROOT}/bitrix/php_interface/after_connect_d7.php" "$php_bin"; then
    step_failures=$((step_failures + 1))
    warn "after_connect_d7.php: ${BX_AFTER_CONNECT_RESULT}"
  fi
  local after_connect_status="$BX_AFTER_CONNECT_RESULT"

  local db_charset="utf8mb4" db_collation="utf8mb4_unicode_ci"
  if load_profile "bitrix" >/dev/null 2>&1; then
    db_charset="${PROFILE_DB_CHARSET:-utf8mb4}"
    db_collation="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
  fi
  if ! bitrix_db_default_charset_ensure "$BX_DOMAIN" "$db_charset" "$db_collation"; then
    step_failures=$((step_failures + 1))
    warn "Database default charset: ${BX_DB_CHARSET_RESULT}"
  fi
  local db_charset_status="$BX_DB_CHARSET_RESULT"
  local db_tables_status="$BX_DB_UTF8MB3_TABLES"
  if [[ "$db_tables_status" =~ ^[0-9]+$ ]] && (( db_tables_status > 0 )); then
    info "${db_tables_status} table(s) still use utf8mb3; they are not converted (only the database default changed)."
    db_tables_status="${db_tables_status} (not converted)"
  fi

  local tz_before="" tz_after="" entry
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == "date.timezone" ]] && tz_before="${entry#*|}"
  done < <(read_site_php_ini_overrides "$BX_DOMAIN")
  if run_command bitrix php-baseline-sync --domain "$BX_DOMAIN"; then
    php_status="ok"
  else
    error "Bitrix PHP baseline sync failed for ${BX_DOMAIN}"
    return 1
  fi
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == "date.timezone" ]] && tz_after="${entry#*|}"
  done < <(read_site_php_ini_overrides "$BX_DOMAIN")
  local tz_status="not set"
  if [[ -n "$tz_after" && -n "$tz_before" ]]; then
    tz_status="${tz_after} (kept site override)"
  elif [[ -n "$tz_after" ]]; then
    tz_status="${tz_after} (set from host)"
  fi

  if run_command bitrix agents-sync --domain "$BX_DOMAIN" --apply yes --confirm yes; then
    agents_status="applied"
  else
    error "Bitrix agents sync failed for ${BX_DOMAIN}"
    return 1
  fi

  if [[ "$ssl_mode" == "yes" ]]; then
    if [[ -z "$email" ]]; then
      error "Use --email with --ssl yes to issue Let's Encrypt during finalize."
      return 1
    fi
    local -a ssl_args=(--domain "$BX_DOMAIN" --email "$email")
    [[ -n "$redirect" ]] && ssl_args+=(--redirect "$redirect")
    [[ -n "$hsts" ]] && ssl_args+=(--hsts "$hsts")
    [[ -n "$staging" ]] && ssl_args+=(--staging "$staging")
    if run_command ssl letsencrypt "${ssl_args[@]}"; then
      ssl_status="issued"
    else
      error "Let's Encrypt issuance failed for ${BX_DOMAIN}"
      return 1
    fi
  fi

  ui_header "SIMAI ENV · Bitrix finalize setup"
  ui_result_table \
    "Domain|${BX_DOMAIN}" \
    "Web state|${web_state}" \
    "Restore leftovers|${leftovers_status}" \
    "after_connect_d7.php|${after_connect_status}" \
    "Database default charset|${db_charset_status}" \
    "Tables still utf8mb3|${db_tables_status}" \
    "PHP date.timezone|${tz_status}" \
    "PHP baseline|${php_status}" \
    "Agents sync|${agents_status}" \
    "SSL|${ssl_status}"
  ui_next_steps
  ui_kv "Bitrix status" "simai-admin.sh bitrix status --domain ${BX_DOMAIN}"
  ui_kv "Checker" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/site_checker.php"
  ui_kv "Perfmon" "$(site_primary_url "$BX_DOMAIN")/bitrix/admin/perfmon_panel.php"
  if (( step_failures > 0 )); then
    error "Bitrix finalize finished with ${step_failures} failed step(s) for ${BX_DOMAIN}; see the table above."
    return 1
  fi
}

register_cmd "bitrix" "status" "Show Bitrix status" "bitrix_status_handler" "domain" "" "effects:read"
register_cmd "bitrix" "cron-status" "Show Bitrix scheduler status" "bitrix_cron_status_handler" "domain" "" "effects:read"
register_cmd "bitrix" "cron-sync" "Write/rewrite Bitrix scheduler file" "bitrix_cron_sync_handler" "domain" "" "menu:confirm"
register_cmd "bitrix" "agents-status" "Show Bitrix agents-over-cron status" "bitrix_agents_status_handler" "domain" "" "effects:read"
register_cmd "bitrix" "agents-sync" "Plan/apply Bitrix agents-over-cron baseline" "bitrix_agents_sync_handler" "domain" "apply= confirm="
register_cmd "bitrix" "cache-clear" "Clear Bitrix cache directories" "bitrix_cache_clear_handler" "domain" "" "menu:confirm"
register_cmd "bitrix" "db-preseed" "Generate Bitrix DB config files from db.env" "bitrix_db_preseed_handler" "domain" "overwrite= short-install=" "menu:confirm"
register_cmd "bitrix" "installer-ready" "Prepare Bitrix installer files (db preseed + setup script)" "bitrix_installer_ready_handler" "domain" "overwrite= short-install= setup-overwrite= archive= edition= archive-overwrite= unpack=" "menu:confirm"
register_cmd "bitrix" "restore-ready" "Prepare Bitrix restore.php flow" "bitrix_restore_ready_handler" "domain" "overwrite= preseed= short-install= archive=" "menu:confirm"
register_cmd "bitrix" "php-baseline-sync" "Apply Bitrix PHP INI baseline via site fix (single/all)" "bitrix_php_baseline_sync_handler" "" "domain= all= confirm= include-recommended=" "menu:confirm menu:bulk"
register_cmd "bitrix" "ownership" "Check/repair Bitrix file ownership drift" "bitrix_ownership_handler" "domain" "apply= confirm="
register_cmd "bitrix" "perf-status" "Show Bitrix optimization status" "bitrix_perf_status_handler" "domain" "" "effects:read"
register_cmd "bitrix" "perf-apply" "Apply Bitrix optimization baseline" "bitrix_perf_apply_handler" "domain" "mode= confirm= include-recommended="
register_cmd "bitrix" "finalize" "Finalize Bitrix post-install baseline" "bitrix_finalize_handler" "domain" "confirm= ssl= email= redirect= hsts= staging=" "menu:confirm"
