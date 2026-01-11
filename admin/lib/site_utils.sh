#!/usr/bin/env bash
set -euo pipefail

SIMAI_USER=${SIMAI_USER:-simai}
WWW_ROOT=${WWW_ROOT:-/home/${SIMAI_USER}/www}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-${SCRIPT_DIR}/templates/nginx-laravel.conf}
NGINX_TEMPLATE_GENERIC=${NGINX_TEMPLATE_GENERIC:-${SCRIPT_DIR}/templates/nginx-generic.conf}
NGINX_TEMPLATE_STATIC=${NGINX_TEMPLATE_STATIC:-${SCRIPT_DIR}/templates/nginx-static.conf}
HEALTHCHECK_TEMPLATE=${HEALTHCHECK_TEMPLATE:-${SCRIPT_DIR}/templates/healthcheck.php}
MYSQL_ROOT_PWD="${MYSQL_ROOT_PWD:-}"
source "${SIMAI_ENV_ROOT}/lib/site_metadata.sh"

project_slug_from_domain() {
  local domain="$1"
  local slug
  slug=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\\+/-/g' -e 's/^-//' -e 's/-$//')
  [[ -z "$slug" ]] && slug="site"
  echo "$slug"
}

regex_escape_literal() {
  local text="$1"
  printf '%s' "$text" | sed 's/[][^$.*/\\|+?(){}]/\\&/g'
}

site_php_ini_dir() {
  site_sites_config_dir
}

site_php_ini_file() {
  local domain="$1"
  echo "$(site_php_ini_dir)/${domain}/php.ini"
}

site_sites_config_dir() {
  echo "/etc/simai-env/sites"
}

validate_ini_key() {
  local name="$1"
  if [[ "$name" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]; then
    return 0
  fi
  error "Invalid INI key '${name}'"
  return 1
}

validate_ini_value() {
  local value="$1"
  if [[ -z "$value" ]]; then
    error "INI value must not be empty"
    return 1
  fi
  if [[ "$value" =~ [^[:print:]] ]]; then
    error "INI value contains control characters"
    return 1
  fi
  return 0
}

cron_site_file_path() {
  local slug="$1"
  echo "/etc/cron.d/${slug}"
}

cron_site_render() {
  local domain="$1" slug="$2" profile="$3" project_path="$4" php_version="$5"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  cat <<EOF
# simai-managed: yes
# simai-domain: ${domain}
# simai-slug: ${slug}
# simai-profile: ${profile}

EOF
  if [[ "$profile" == "laravel" ]]; then
    local php_bin
    php_bin=$(resolve_php_bin "$php_version")
    echo "* * * * * ${SIMAI_USER} cd ${project_path} && ${php_bin} artisan schedule:run >> /dev/null 2>&1"
  fi
}

cron_site_write() {
  local domain="$1" slug="$2" profile="$3" project_path="$4" php_version="$5"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  local file
  file=$(cron_site_file_path "$slug")
  local content
  content=$(cron_site_render "$domain" "$slug" "$profile" "$project_path" "$php_version")
  local tmp
  tmp=$(mktemp)
  printf "%s\n" "$content" >"$tmp"
  chmod 644 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
  reload_cron_daemon
}

cron_legacy_markers() {
  local domain="$1"
  local esc_domain
  esc_domain=$(regex_escape_literal "$domain")
  echo "begin_end_v1|^#[[:space:]]*BEGIN[[:space:]]+SIMAI[[:space:]]+${esc_domain}[[:space:]]*\$|^#[[:space:]]*END[[:space:]]+SIMAI[[:space:]]+${esc_domain}[[:space:]]*\$"
  echo "begin_end_v2|^#[[:space:]]*SIMAI[[:space:]]+BEGIN[[:space:]]+${esc_domain}[[:space:]]*\$|^#[[:space:]]*SIMAI[[:space:]]+END[[:space:]]+${esc_domain}[[:space:]]*\$"
}

cron_legacy_detect_marked() {
  local domain="$1" user="$2"
  LEGACY_FOUND=0
  LEGACY_FORMAT="none"
  LEGACY_BEGIN_LINE=0
  LEGACY_END_LINE=0
  LEGACY_BEGIN_RE=""
  LEGACY_END_RE=""
  LEGACY_SUSPECT=0
  if ! command -v crontab >/dev/null 2>&1; then
    return 0
  fi
  local dump=""
  if [[ "$user" == "root" ]]; then
    dump=$(crontab -l 2>/dev/null || true)
  else
    dump=$(crontab -l -u "$user" 2>/dev/null || true)
  fi
  [[ -z "$dump" ]] && return 0
  if echo "$dump" | grep -qF "SIMAI ${domain}"; then
    LEGACY_SUSPECT=1
  fi
  local fmt
  while IFS= read -r fmt; do
    [[ -z "$fmt" ]] && continue
    IFS="|" read -r fmt_id begin_re end_re <<<"$fmt"
    local begin_line=0 end_line=0 nr=0
    while IFS= read -r line; do
      ((nr++))
      if [[ $begin_line -eq 0 && $line =~ $begin_re ]]; then
        begin_line=$nr
        continue
      fi
      if [[ $begin_line -gt 0 && $line =~ $end_re ]]; then
        end_line=$nr
        break
      fi
    done <<<"$dump"
    if (( begin_line > 0 && end_line > begin_line )); then
      LEGACY_FOUND=1
      LEGACY_FORMAT="$fmt_id"
      LEGACY_BEGIN_LINE=$begin_line
      LEGACY_END_LINE=$end_line
      LEGACY_BEGIN_RE="$begin_re"
      LEGACY_END_RE="$end_re"
      break
    fi
  done < <(cron_legacy_markers "$domain")
  return 0
}

cron_legacy_remove_marked() {
  local domain="$1" user="$2"
  if ! command -v crontab >/dev/null 2>&1; then
    return 2
  fi
  cron_legacy_detect_marked "$domain" "$user"
  if [[ "${LEGACY_FOUND:-0}" -ne 1 ]]; then
    return 2
  fi
  local dump=""
  if [[ "$user" == "root" ]]; then
    dump=$(crontab -l 2>/dev/null || true)
  else
    dump=$(crontab -l -u "$user" 2>/dev/null || true)
  fi
  [[ -z "$dump" ]] && return 2
  local begin_re="$LEGACY_BEGIN_RE"
  local end_re="$LEGACY_END_RE"
  if [[ -z "$begin_re" || -z "$end_re" ]]; then
    return 2
  fi
  local tmp
  tmp=$(mktemp)
  awk -v b="$begin_re" -v e="$end_re" '
    BEGIN { skip=0 }
    {
      if (skip==0 && $0 ~ b) { skip=1; next }
      if (skip==1 && $0 ~ e) { skip=0; next }
      if (skip==0) { print }
    }
  ' <<<"$dump" >"$tmp"
  if [[ "$user" == "root" ]]; then
    crontab "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  else
    crontab -u "$user" "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
  fi
  rm -f "$tmp"
  return 0
}

cron_legacy_detect_any() {
  local domain="$1"
  local users=("$SIMAI_USER" root)
  local suspect_state="none"
  local suspect_user=""
  local u
  for u in "${users[@]}"; do
    cron_legacy_detect_marked "$domain" "$u"
    if [[ "${LEGACY_FOUND:-0}" -eq 1 ]]; then
      echo "marked|$u|${LEGACY_FORMAT:-none}|${LEGACY_BEGIN_LINE:-0}|${LEGACY_END_LINE:-0}"
      return 0
    fi
    if [[ "${LEGACY_SUSPECT:-0}" -eq 1 && "$suspect_state" == "none" ]]; then
      suspect_state="suspect"
      suspect_user="$u"
    fi
  done
  echo "${suspect_state}|${suspect_user}|none|0|0"
}

read_site_php_ini_overrides() {
  local domain="$1"
  local file
  file=$(site_php_ini_file "$domain")
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ $line =~ ^[[:space:]]*';' ]] && continue
    if [[ "$line" == *"="* ]]; then
      local key="${line%%=*}"
      local value="${line#*=}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ -z "$key" ]] && continue
      echo "${key}|${value}"
    fi
  done < "$file"
}

write_site_php_ini_overrides() {
  local domain="$1"
  shift
  local entries=("$@")
  if [[ ${#entries[@]} -eq 0 ]]; then
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      entries+=("$line")
    done
  fi
  local dir
  dir=$(site_php_ini_dir)
  local domain_dir="${dir}/${domain}"
  mkdir -p "$domain_dir"
  local file="${domain_dir}/php.ini"
  local tmp
  tmp="$(mktemp)"
  declare -A kv=()
  local entry
  for entry in "${entries[@]}"; do
    [[ -z "$entry" ]] && continue
    local key="${entry%%|*}"
    local val="${entry#*|}"
    kv["$key"]="$val"
  done
  local key
  for key in $(printf "%s\n" "${!kv[@]}" | sort); do
    printf "%s=%s\n" "$key" "${kv[$key]}" >>"$tmp"
  done
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$file"
    chmod 0644 "$file"
    chown root:root "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
    rm -f "$file"
  fi
}

apply_site_php_ini_overrides_to_pool() {
  local domain="$1" php_version="$2" socket_project="$3" reload_flag="${4:-yes}"
  local pool_file="/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
  if [[ ! -f "$pool_file" ]]; then
    error "Pool file not found for ${socket_project} (php ${php_version})"
    return 1
  fi

  declare -A kv=()
  local entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local key="${entry%%|*}"
    local val="${entry#*|}"
    if ! validate_ini_key "$key"; then
      error "Invalid ini key in file for ${domain}: ${key}"
      return 1
    fi
    if ! validate_ini_value "$val"; then
      error "Invalid ini value for key ${key} in ${domain}"
      return 1
    fi
    kv["$key"]="$val"
  done < <(read_site_php_ini_overrides "$domain")

  local site_block=""
  if [[ ${#kv[@]} -gt 0 ]]; then
    site_block=$'; simai-site-ini-begin\n'
    local key
    for key in $(printf "%s\n" "${!kv[@]}" | sort); do
      local val="${kv[$key]}"
      local lower="${val,,}"
      case "$lower" in
        1|true|on|yes)
          site_block+=$'php_admin_flag['"$key"$'] = on\n'
          ;;
        0|false|off|no)
          site_block+=$'php_admin_flag['"$key"$'] = off\n'
          ;;
        *)
          site_block+=$'php_admin_value['"$key"$'] = '"$val"$'\n'
          ;;
      esac
    done
    site_block+=$'; simai-site-ini-end\n'
  fi

  local profile_block=""
  profile_block=$(awk '/; simai-profile-ini-begin/{flag=1}flag{print}/; simai-profile-ini-end/{flag=0}' "$pool_file")

  local base_content
  base_content=$(sed '/; simai-profile-ini-begin/,/; simai-profile-ini-end/d;/; simai-site-ini-begin/,/; simai-site-ini-end/d' "$pool_file")

  local new_content=""
  new_content+="$base_content"
  [[ -n "$base_content" && "${base_content: -1}" != $'\n' ]] && new_content+=$'\n'
  if [[ -n "$site_block" ]]; then
    new_content+="$site_block"
    [[ "${new_content: -1}" != $'\n' ]] && new_content+=$'\n'
  fi
  if [[ -n "$profile_block" ]]; then
    new_content+="$profile_block"
    [[ "${new_content: -1}" != $'\n' ]] && new_content+=$'\n'
  fi

  local current_content
  current_content=$(cat "$pool_file")
  if [[ "$current_content" == "$new_content" ]]; then
    info "No changes to apply for ${domain} (pool already up to date)."
    return 0
  fi

  local backup
  backup=$(mktemp)
  cp -p "$pool_file" "$backup" >>"$LOG_FILE" 2>&1 || backup=""
  local tmp_out
  tmp_out=$(mktemp)
  printf "%s" "$new_content" >"$tmp_out"
  chmod --reference="$pool_file" "$tmp_out" 2>/dev/null || true
  chown --reference="$pool_file" "$tmp_out" 2>/dev/null || true
  mv "$tmp_out" "$pool_file"

  local fpm_bin
  fpm_bin=$(command -v "php-fpm${php_version}" 2>/dev/null || true)
  if [[ -z "$fpm_bin" && -x "/usr/sbin/php-fpm${php_version}" ]]; then
    fpm_bin="/usr/sbin/php-fpm${php_version}"
  fi
  if [[ -z "$fpm_bin" ]]; then
    error "php-fpm${php_version} binary not found for config test"
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -p "$backup" "$pool_file" >>"$LOG_FILE" 2>&1 || true
      rm -f "$backup"
    fi
    return 1
  fi
  if ! "$fpm_bin" -t >>"$LOG_FILE" 2>&1; then
    error "php-fpm${php_version} config test failed; restoring previous pool"
    if [[ -n "$backup" && -f "$backup" ]]; then
      cp -p "$backup" "$pool_file" >>"$LOG_FILE" 2>&1 || true
      rm -f "$backup"
    fi
    return 1
  fi
  [[ -n "$backup" && -f "$backup" ]] && rm -f "$backup"

  if [[ "${reload_flag,,}" != "no" ]]; then
    if ! os_svc_reload "php${php_version}-fpm"; then
      warn "Failed to reload php${php_version}-fpm after applying site ini; please reload manually"
    fi
  fi
  return 0
}

list_sites() {
  shopt -s nullglob
  for cfg in /etc/nginx/sites-available/*.conf; do
    local name
    name=$(basename "$cfg" .conf)
    [[ "$name" == "000-catchall" ]] && continue
    echo "$name"
  done | sort
  shopt -u nullglob
}

list_simai_sites() {
  shopt -s nullglob
  local cfg name
  for cfg in /etc/nginx/sites-available/*.conf; do
    name=$(basename "$cfg" .conf)
    [[ "$name" == "000-catchall" ]] && continue
    if grep -qE '^[[:space:]]*# simai-domain:' "$cfg"; then
      echo "$name"
    fi
  done | sort -u
  shopt -u nullglob
}

has_simai_sites() {
  [[ -n "$(list_simai_sites | head -n 1)" ]]
}

require_site_exists() {
  local domain="$1"
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  if [[ "$domain" == "000-catchall" ]]; then
    error "Domain 000-catchall is reserved"
    return 1
  fi
  if [[ ! -f "$cfg" ]]; then
    error "Domain is not configured as a site. Create it first: simai-admin.sh site add --domain ${domain} ..."
    return 1
  fi
  return 0
}

detect_pool_for_project() {
  local project="$1"
  shopt -s nullglob
  local pools=(/etc/php/*/fpm/pool.d/"${project}.conf")
  if [[ ${#pools[@]} -gt 0 ]]; then
    echo "${pools[0]}"
  fi
  shopt -u nullglob
}

ensure_user() {
  if ! id -u "$SIMAI_USER" >/dev/null 2>&1; then
    info "Creating user ${SIMAI_USER}"
    useradd -m -s /bin/bash "$SIMAI_USER"
  fi
  usermod -a -G www-data "$SIMAI_USER" || true
  mkdir -p "$WWW_ROOT"
  chown -R "$SIMAI_USER":www-data "$(dirname "$WWW_ROOT")"
}

resolve_php_bin() {
  local php_version="$1"
  local php_bin
  php_bin=$(command -v "php${php_version}" || true)
  if [[ -z "$php_bin" ]]; then
    php_bin=$(command -v php || echo "/usr/bin/php")
  fi
  echo "$php_bin"
}

resolve_php_bin_strict() {
  local php_version="$1"
  [[ -z "$php_version" || "$php_version" == "none" ]] && return 1
  local php_bin
  php_bin=$(command -v "php${php_version}" || true)
  [[ -z "$php_bin" ]] && return 2
  echo "$php_bin"
}

queue_unit_name() {
  local project="$1"
  if ! validate_project_slug "$project"; then
    return 1
  fi
  echo "laravel-queue-${project}.service"
}

queue_unit_path() {
  local project="$1"
  local name
  name=$(queue_unit_name "$project") || return 1
  echo "/etc/systemd/system/${name}"
}

installed_php_versions() {
  local versions=()
  shopt -s nullglob
  for d in /etc/php/*; do
    [[ -d "$d" ]] && versions+=("$(basename "$d")")
  done
  shopt -u nullglob
  printf "%s\n" "${versions[@]}"
}

generate_password() {
  head -c 24 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20
}

env_set_kv() {
  local file="$1" key="$2" value="$3"
  local dir
  dir=$(dirname "$file")
  mkdir -p "$dir"
  [[ -f "$file" ]] || touch "$file"
  chmod 0640 "$file"
  chown "${SIMAI_USER}:${SIMAI_USER}" "$file" 2>/dev/null || true
  local encoded="$value"
  if [[ "$encoded" =~ [[:space:]\'\"] ]]; then
    encoded=${encoded//\\/\\\\}
    encoded=${encoded//\"/\\\"}
    encoded="\"${encoded}\""
  fi
  if grep -q "^${key}=" "$file"; then
    perl -pi -e "s/^${key}=.*/${key}=${encoded}/" "$file"
  else
    printf "%s=%s\n" "$key" "$encoded" >>"$file"
  fi
}

validate_domain() {
  local domain="$1" policy="${2:-block}"
  local domain_lc
  domain_lc=$(echo "$domain" | tr '[:upper:]' '[:lower:]')
  if [[ -z "$domain_lc" ]]; then
    error "Domain is required"
    return 1
  fi
  if [[ "$domain_lc" =~ [[:space:]] ]]; then
    error "Domain must not contain whitespace"
    return 1
  fi
  if [[ "$domain_lc" =~ [^a-z0-9.-] ]]; then
    error "Domain contains invalid characters"
    return 1
  fi
  if [[ "$domain_lc" =~ \.\. ]]; then
    error "Domain must not contain consecutive dots"
    return 1
  fi
  if [[ "$domain_lc" == *"/"* || "$domain_lc" == *"\\"* || "$domain_lc" == *"\""* || "$domain_lc" == *"'"* || "$domain_lc" == *"$"* || "$domain_lc" == *";"* || "$domain_lc" == *"&"* || "$domain_lc" == *"|"* ]]; then
    error "Domain contains forbidden characters"
    return 1
  fi
  if [[ "$domain_lc" != *.* ]]; then
    error "Domain must contain at least one dot (e.g. your-domain.tld)"
    return 1
  fi
  case "$domain_lc" in
    example.com|example.net|example.org)
      if [[ "$policy" == "allow" ]]; then
        warn "Domain ${domain_lc} is reserved (RFC 2606); proceeding (cleanup/status)."
        return 0
      fi
      if [[ "${ALLOW_RESERVED_DOMAIN:-no}" == "yes" ]]; then
        warn "Domain ${domain_lc} is reserved (RFC 2606); proceeding because ALLOW_RESERVED_DOMAIN=yes."
      else
        warn "Domain ${domain_lc} is reserved for documentation/tests (RFC 2606). Set ALLOW_RESERVED_DOMAIN=yes to proceed."
        return 1
      fi
      ;;
  esac
  return 0
}

validate_path() {
  local path="$1"
  if [[ -z "$path" || "$path" == "/" ]]; then
    error "Path must not be empty or root"
    return 1
  fi
  if [[ "$path" != /* ]]; then
    error "Path must be absolute"
    return 1
  fi
  if [[ "$path" =~ [[:space:]] || "$path" =~ [[:cntrl:]] ]]; then
    error "Path must not contain whitespace or control characters"
    return 1
  fi
  if [[ "$path" == *".."* ]]; then
    error "Path must not contain '..'"
    return 1
  fi
  if [[ "$path" == *"//"* ]]; then
    error "Path must not contain double slashes"
    return 1
  fi
  if [[ ! "$path" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
    error "Path contains invalid characters; allowed: A-Za-z0-9._/-"
    return 1
  fi
  if command -v realpath >/dev/null 2>&1; then
    local normalized
    normalized=$(realpath -m "$path" 2>/dev/null || true)
    if [[ -z "$normalized" || "$normalized" == "/" || "$normalized" != /* ]]; then
      error "Path normalization failed for ${path}"
      return 1
    fi
    if [[ "$normalized" == *".."* ]]; then
      error "Normalized path is unsafe: ${normalized}"
      return 1
    fi
  fi
  return 0
}

validate_project_slug() {
  local slug="$1"
  if [[ -z "$slug" ]]; then
    error "Project slug must not be empty"
    return 1
  fi
  if [[ ! "$slug" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    error "Invalid project slug '${slug}'. Use lowercase letters, numbers, and dashes only (1-63 chars, must start with alphanumeric)."
    return 1
  fi
  return 0
}

validate_public_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" == "." ]]; then
    return 0
  fi
  if [[ "$dir" == /* ]]; then
    error "public_dir must be relative (got absolute: ${dir})"
    return 1
  fi
  if [[ "$dir" == *".."* ]]; then
    error "public_dir must not contain '..' (${dir})"
    return 1
  fi
  if [[ "$dir" =~ [[:space:]] || "$dir" =~ [[:cntrl:]] ]]; then
    error "public_dir must not contain whitespace/control characters (${dir})"
    return 1
  fi
  if [[ "$dir" == *"\\"* ]]; then
    error "public_dir must not contain backslashes (${dir})"
    return 1
  fi
  if [[ "$dir" == *"//"* ]]; then
    error "public_dir must not contain double slashes (${dir})"
    return 1
  fi
  if [[ "$dir" == */ ]]; then
    error "public_dir must not end with '/' (${dir})"
    return 1
  fi
  if [[ "$dir" == *:* ]]; then
    error "public_dir must not contain ':' (${dir})"
    return 1
  fi
  if [[ ! "$dir" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    error "public_dir contains invalid characters (${dir}); allowed: A-Za-z0-9._/-"
    return 1
  fi
  return 0
}

site_compute_doc_root() {
  local project_root="$1" public_dir="$2"
  if ! validate_path "$project_root"; then
    return 1
  fi
  if ! validate_public_dir "$public_dir"; then
    return 1
  fi
  if [[ -z "$public_dir" || "$public_dir" == "." ]]; then
    echo "$project_root"
  else
    echo "${project_root}/${public_dir}"
  fi
}

site_compute_acme_root() {
  local doc_root="$1"
  echo "$doc_root"
}

create_mysql_db_user() {
  local db_name="$1" db_user="$2" db_pass="$3"
  if ! db_validate_db_name "$db_name"; then return 1; fi
  if ! db_validate_db_user "$db_user"; then return 1; fi
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not found; skip DB creation"
    return 1
  fi
  mysql_root_detect_cli || { warn "Cannot connect to MySQL as root"; return 1; }
  local esc_pass
  esc_pass=$(db_sql_escape "$db_pass")
  mysql_root_exec "CREATE DATABASE IF NOT EXISTS \\\`${db_name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql_root_exec "CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "ALTER USER '${db_user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "GRANT ALL PRIVILEGES ON \\\`${db_name}\\\`.* TO '${db_user}'@'127.0.0.1';"
  mysql_root_exec "GRANT ALL PRIVILEGES ON \\\`${db_name}\\\`.* TO '${db_user}'@'localhost';"
  mysql_root_exec "FLUSH PRIVILEGES;"
}

create_php_pool() {
  local project="$1" php_version="$2" project_path="$3"
  if ! validate_project_slug "$project"; then
    return 1
  fi
  local pool_dir="/etc/php/${php_version}/fpm/pool.d"
  local pool_file="${pool_dir}/${project}.conf"
  mkdir -p "$pool_dir"
  cat >"$pool_file" <<EOF
[${project}]
user = ${SIMAI_USER}
group = www-data
listen = /run/php/php${php_version}-fpm-${project}.sock
listen.owner = ${SIMAI_USER}
listen.group = www-data
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
request_terminate_timeout = 120s
chdir = ${project_path}
php_admin_value[error_log] = /var/log/php${php_version}-fpm-${project}.log
php_admin_flag[log_errors] = on
EOF
  os_svc_reload_or_restart "php${php_version}-fpm" || true
}

create_nginx_site() {
  local domain="$1"
  local project="$2"
  local project_path="$3"
  local php_version="$4"
  local template_path="${5:-$NGINX_TEMPLATE}"
  local profile="${6:-}"
  local target="${7:-}"
  local php_socket_project="${8:-$project}"
  local template_id="unknown"
  local ssl_cert="${9:-}"
  local ssl_key="${10:-}"
  local ssl_chain="${11:-}"
  local ssl_redirect="${12:-no}"
  local ssl_hsts="${13:-no}"
  local template_override="${14:-}"
  local public_dir="${15-public}"
  if [[ ! -f "$template_path" ]]; then
    error "nginx template not found at ${template_path}"
    return 1
  fi
  if ! validate_public_dir "$public_dir"; then
    return 1
  fi
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  local ssl_flag="off"
  local backup=""
  [[ -n "$ssl_cert" && -n "$ssl_key" ]] && ssl_flag="on"
  local ssl_meta="none"
  [[ "$ssl_flag" == "on" ]] && ssl_meta="custom"
  local slug="$project"
  if ! validate_project_slug "$slug"; then
    slug="$(project_slug_from_domain "$domain")"
  fi
  if [[ -z "$php_socket_project" ]] || ! validate_project_slug "$php_socket_project"; then
    php_socket_project="$slug"
  fi
  case "$template_path" in
    *nginx-laravel.conf) template_id="laravel" ;;
    *nginx-generic.conf) template_id="generic" ;;
    *nginx-static.conf) template_id="static" ;;
    *nginx-alias.conf) template_id="alias" ;;
    *) template_id="${profile:-unknown}" ;;
  esac
  if [[ -n "$template_override" ]]; then
    template_id="$template_override"
  fi
  case "$template_id" in
    static|generic|laravel|alias) ;;
    *)
      error "Unknown nginx template id: ${template_id}"
      return 1
      ;;
  esac
  local doc_root
  doc_root=$(site_compute_doc_root "$project_path" "$public_dir") || return 1
  local acme_root
  acme_root=$(site_compute_acme_root "$doc_root")
  if ! validate_path "$doc_root"; then
    return 1
  fi
  mkdir -p "$doc_root"
  chown -R "$SIMAI_USER":www-data "$doc_root" 2>/dev/null || true
  local meta_block
  meta_block=$(site_nginx_metadata_render "$domain" "$slug" "$profile" "$project_path" "$project" "$php_version" "$ssl_meta" "" "$target" "$php_socket_project" "$template_id" "$public_dir")
  if [[ -f "$site_available" ]]; then
    local ts
    ts=$(date +%Y%m%d%H%M%S)
    backup="${site_available}.bak.${ts}"
    if cp -p "$site_available" "$backup" >>"$LOG_FILE" 2>&1; then
      info "Backed up existing nginx config to ${backup}"
    else
      warn "Failed to backup existing nginx config ${site_available}"
      backup=""
    fi
  fi

  {
    printf "%s\n" "$meta_block"
    sed -e "s#{{SERVER_NAME}}#${domain}#g" \
      -e "s#{{PROJECT_ROOT}}#${project_path}#g" \
      -e "s#{{DOC_ROOT}}#${doc_root}#g" \
      -e "s#{{ACME_ROOT}}#${acme_root}#g" \
      -e "s#{{PROJECT_NAME}}#${project}#g" \
      -e "s#{{PHP_VERSION}}#${php_version}#g" \
      -e "s#{{PHP_SOCKET_PROJECT}}#${php_socket_project}#g" "$template_path"
  } > "$site_available"
  ln -sf "$site_available" "$site_enabled"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  if [[ -n "$ssl_cert" && -n "$ssl_key" ]]; then
    SSL_CERT="$ssl_cert" SSL_KEY="$ssl_key" SSL_CHAIN="$ssl_chain" SSL_HSTS="$ssl_hsts" SSL_REDIRECT="$ssl_redirect" perl -0pi -e '
      my $cert     = $ENV{SSL_CERT} // "";
      my $key      = $ENV{SSL_KEY} // "";
      my $chain    = $ENV{SSL_CHAIN} // "";
      my $hsts     = lc($ENV{SSL_HSTS} // "no");
      my $redirect = lc($ENV{SSL_REDIRECT} // "no");

      sub insert_before_server_closing {
        my ($block) = @_;
        $block .= "\n" unless $block =~ /\n\z/;
        if ($_ =~ s/(\n}\s*\z)/"\n$block$1"/se) {
          return;
        }
        $_ .= "\n$block\n";
      }

      if ($cert && $key) {
        if ($_ !~ /listen\s+443\s+ssl;/) {
          if ($_ =~ s/(^[ \t]*listen\s+80[^\n]*;\s*\n)/$1    listen 443 ssl;\n/m) {
          } elsif ($_ =~ s/(^[ \t]*server_name\s+.*;\s*\n)/$1    listen 443 ssl;\n/m) {
          } else {
            insert_before_server_closing("    listen 443 ssl;");
          }
        }

        if ($_ =~ /ssl_certificate\s+/) {
          s/(ssl_certificate\s+).*/${1}$cert;/;
        } else {
          insert_before_server_closing("    ssl_certificate $cert;");
        }

        if ($_ =~ /ssl_certificate_key\s+/) {
          s/(ssl_certificate_key\s+).*/${1}$key;/;
        } else {
          insert_before_server_closing("    ssl_certificate_key $key;");
        }

        if (length $chain) {
          if ($_ =~ /ssl_trusted_certificate\s+/) {
            s/(ssl_trusted_certificate\s+).*/${1}$chain;/;
          } else {
            insert_before_server_closing("    ssl_trusted_certificate $chain;");
          }
        }

        if ($hsts eq "yes" && $_ !~ /Strict-Transport-Security/) {
          insert_before_server_closing("    add_header Strict-Transport-Security \"max-age=31536000\" always;");
        }

        if ($redirect eq "yes" && $_ !~ /simai-ssl-redirect/) {
          my $block = "    # simai-ssl-redirect-start\n    if (\$scheme != \"https\") { return 301 https://\$host\$request_uri; }\n    # simai-ssl-redirect-end";
          insert_before_server_closing($block);
        }
      }
    ' "$site_available" || { restore_nginx_backup "$site_available" "$site_enabled" "$backup"; return 1; }
    if grep -q '\\\$scheme' "$site_available" || grep -q '\\"https\\"' "$site_available"; then
      error "nginx SSL config contains escaped literals; aborting"
      restore_nginx_backup "$site_available" "$site_enabled" "$backup"
      return 1
    fi
  fi
  ensure_nginx_catchall
  local nginx_test_output
  if ! nginx_test_output=$(nginx -t 2>&1); then
    echo "$nginx_test_output" >>"$LOG_FILE"
    local failure_ts
    failure_ts=$(date +%Y%m%d%H%M%S)
    if [[ -n "$backup" && -f "$site_available" ]]; then
      cp -p "$site_available" "${site_available}.failed.${failure_ts}" >>"$LOG_FILE" 2>&1 || true
    fi
    error "$(printf "nginx config test failed:\n%s" "$(echo "$nginx_test_output" | tail -n 8)")"
    restore_nginx_backup "$site_available" "$site_enabled" "$backup"
    return 1
  fi
  echo "$nginx_test_output" >>"$LOG_FILE"
  os_svc_reload_or_restart nginx || true
}

ensure_project_permissions() {
  local project_path="$1"
  chown -R "$SIMAI_USER":www-data "$project_path"
  if [[ -d "$project_path/storage" || -d "$project_path/bootstrap/cache" ]]; then
    find "$project_path/storage" "$project_path/bootstrap/cache" -type d -print0 2>/dev/null | xargs -0 -r chmod 775 || true
  fi
}

require_laravel_structure() {
  local project_path="$1"
  if [[ ! -f "$project_path/artisan" ]]; then
    error "artisan not found in ${project_path}; is this a Laravel project?"
    return 1
  fi
}

create_placeholder_if_missing() {
  local project_path="$1"
  local public_index="${project_path}/public/index.php"
  if [[ -f "$public_index" ]]; then
    return
  fi
  mkdir -p "${project_path}/public"
  cat >"$public_index" <<'EOF'
<?php
http_response_code(200);
echo "Placeholder: site is configured.";
EOF
}

create_static_placeholder_if_missing() {
  local project_path="$1"
  local public_index="${project_path}/public/index.html"
  if [[ -f "$public_index" ]]; then
    return
  fi
  mkdir -p "${project_path}/public"
  cat >"$public_index" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Static site</title>
</head>
<body>
  <h1>It works</h1>
  <p>Static site is configured.</p>
</body>
</html>
EOF
}

remove_nginx_site() {
  local domain="$1"
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  local backup=""
  if [[ -f "$site_available" ]]; then
    backup=$(mktemp "/tmp/simai-nginx-${domain}.XXXX.conf")
    cp -p "$site_available" "$backup" >>"$LOG_FILE" 2>&1 || backup=""
  fi
  rm -f "$site_enabled" "$site_available"
  if command -v nginx >/dev/null 2>&1; then
    if ! nginx -t >>"$LOG_FILE" 2>&1; then
      warn "nginx test failed after removing ${domain}"
      if [[ -n "$backup" && -f "$backup" ]]; then
        cp -p "$backup" "$site_available" >>"$LOG_FILE" 2>&1 || true
        ln -sf "$site_available" "$site_enabled"
      fi
      return 1
    fi
  os_svc_reload nginx || true
  fi
}

ensure_nginx_catchall() {
  local catchall_avail="/etc/nginx/sites-available/000-catchall.conf"
  local catchall_enabled="/etc/nginx/sites-enabled/000-catchall.conf"
  if [[ -f "$catchall_avail" && -L "$catchall_enabled" ]]; then
    return
  fi
  cat >"$catchall_avail" <<'EOF'
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
EOF
  ln -sf "$catchall_avail" "$catchall_enabled"
}

remove_php_pools() {
  local project="$1"
  if ! validate_project_slug "$project"; then
    return 1
  fi
  shopt -s nullglob
  local pools=(/etc/php/*/fpm/pool.d/"${project}.conf")
  local versions=()
  for pool in "${pools[@]:-}"; do
    rm -f "$pool"
    local ver
    ver=$(echo "$pool" | awk -F'/' '{print $4}')
    versions+=("$ver")
  done
  shopt -u nullglob
  for v in $(printf "%s\n" "${versions[@]}" | sort -u); do
  os_svc_reload_or_restart "php${v}-fpm" || true
  done
}

backup_file() {
  local path="$1"
  if [[ -f "$path" ]]; then
    local ts backup
    ts=$(date +%Y%m%d%H%M%S)
    backup="${path}.bak.${ts}"
    if cp -p "$path" "$backup" >>"$LOG_FILE" 2>&1; then
      info "Backed up ${path} to ${backup}"
    else
      warn "Failed to backup ${path}"
    fi
  fi
}

restore_nginx_backup() {
  local site_available="$1" site_enabled="$2" backup="$3"
  if [[ -n "$backup" && -f "$backup" ]]; then
    if cp -p "$backup" "$site_available" >>"$LOG_FILE" 2>&1; then
      info "Restored nginx config from backup ${backup}"
      ln -sf "$site_available" "$site_enabled"
      if nginx -t >>"$LOG_FILE" 2>&1; then
        os_svc_reload_or_restart nginx || true
      else
        warn "nginx config still invalid after restore; check ${site_available}"
      fi
    else
      warn "Failed to restore nginx config from backup ${backup}"
    fi
  else
    rm -f "$site_available" "$site_enabled"
    warn "Removed generated nginx config due to failure"
  fi
}

reload_cron_daemon() {
  ensure_cron_service
  os_svc_reload_or_restart cron || true
}

ensure_cron_service() {
  if ! os_svc_has_unit cron; then
    warn "cron service not found. Install cron package and enable/start the service."
    return
  fi
  if os_svc_is_active cron; then
    return
  fi
  os_svc_enable_now cron || os_svc_restart cron || true
  if ! os_svc_is_active cron; then
    warn "cron service is inactive; ensure cron is installed and enabled."
  fi
}

ensure_project_cron_entries() {
  local project="$1" project_path="$2" php_version="$3" profile_id="$4"
  shift 4 || true
  local entries=("$@")
  if [[ "${profile_id}" == "static" || "${profile_id}" == "alias" ]]; then
    return 0
  fi
  if [[ ${#entries[@]} -eq 0 ]]; then
    return 0
  fi
  if ! validate_project_slug "$project"; then
    return 1
  fi
  if ! validate_path "$project_path"; then
    return 1
  fi
  if [[ "$php_version" == "none" ]]; then
    warn "Profile ${profile_id} requested cron entries but PHP runtime is none; skipping cron creation"
    return 0
  fi

  cron_site_write "${project}.invalid" "$project" "$profile_id" "$project_path" "$php_version"
}

# Backward compatibility helper for legacy callers
ensure_project_cron() {
  local project="$1" profile="$2" project_path="$3" php_version="$4"
  if [[ "$profile" != "laravel" ]]; then
    return
  fi
  cron_site_write "${project}.invalid" "$project" "$profile" "$project_path" "$php_version"
}

nginx_patch_php_socket() {
  local domain="$1" new_php="$2" socket_project="$3"
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  if [[ ! -f "$cfg" ]]; then
    error "nginx config not found for ${domain} at ${cfg}"
    return 1
  fi
  backup_file "$cfg"
  local new_socket="/run/php/php${new_php}-fpm-${socket_project}.sock"
  local pattern="/run/php/php[0-9.]+-fpm-${socket_project}\\.sock"
  perl -pi -e "s#${pattern}#${new_socket}#g" "$cfg"
  if grep -q "^# simai-php:" "$cfg"; then
    perl -pi -e "s|^(# simai-php: ).*|\\1${new_php}|" "$cfg"
  else
    if grep -q "^# simai-root:" "$cfg"; then
      perl -0pi -e "s/(# simai-root:.*\n)/\\1# simai-php: ${new_php}\n/" "$cfg"
    else
      perl -0pi -e "s/(# simai-project:.*\n)/\\1# simai-php: ${new_php}\n/" "$cfg"
    fi
  fi
  if ! grep -q "${new_socket}" "$cfg"; then
    error "Failed to update PHP socket to ${new_socket} in ${cfg}"
    return 1
  fi
}

remove_cron_file() {
  local slug="$1" domain_check="${2:-}"
  if ! validate_project_slug "$slug"; then
    return 1
  fi
  local cron_file
  cron_file=$(cron_site_file_path "$slug")
  if [[ ! -f "$cron_file" ]]; then
    warn "Cron file not found: ${cron_file}"
    return 0
  fi
  local head
  head=$(head -n 20 "$cron_file" 2>/dev/null || true)
  if ! echo "$head" | grep -q "^# simai-managed: yes"; then
    warn "Refusing to delete non-simai cron file: ${cron_file}"
    return 1
  fi
  if ! echo "$head" | grep -q "^# simai-slug: ${slug}"; then
    warn "Refusing to delete cron file with mismatched slug: ${cron_file}"
    return 1
  fi
  if [[ -n "$domain_check" ]] && ! echo "$head" | grep -q "^# simai-domain: ${domain_check}"; then
    warn "Refusing to delete cron file: domain mismatch for ${cron_file}"
    return 1
  fi
  rm -f "$cron_file"
  reload_cron_daemon
  info "Removed cron file ${cron_file}"
}

remove_queue_unit() {
  local project="$1"
  if ! validate_project_slug "$project"; then
    return 1
  fi
  local unit="/etc/systemd/system/laravel-queue-${project}.service"
  if [[ -f "$unit" ]]; then
    os_svc_disable_now "laravel-queue-${project}.service" || true
    rm -f "$unit"
    os_svc_daemon_reload || true
    info "Removed queue unit laravel-queue-${project}.service"
  fi
}

remove_php_pool_version() {
  local project="$1" version="$2"
  if ! validate_project_slug "$project"; then
    return 1
  fi
  local pool="/etc/php/${version}/fpm/pool.d/${project}.conf"
  if [[ -f "$pool" ]]; then
    rm -f "$pool"
    os_svc_reload_or_restart "php${version}-fpm" || true
  fi
}

remove_project_files() {
  local path="$1"
  if [[ -z "$path" || "$path" == "/" ]]; then
    warn "Skip removing dangerous path: ${path:-<empty>}"
    return
  fi
  rm -rf "$path"
}

install_healthcheck() {
  local doc_root="$1"
  if [[ ! -f "$HEALTHCHECK_TEMPLATE" ]]; then
    warn "Healthcheck template not found at ${HEALTHCHECK_TEMPLATE}"
    return
  fi
  mkdir -p "$doc_root"
  cp "$HEALTHCHECK_TEMPLATE" "$doc_root/healthcheck.php"
}

write_generic_env() {
  local project_path="$1" db_name="$2" db_user="$3" db_pass="$4"
  local env_file="${project_path}/.env"
  env_set_kv "$env_file" "DB_CONNECTION" "mysql"
  env_set_kv "$env_file" "DB_HOST" "127.0.0.1"
  env_set_kv "$env_file" "DB_PORT" "3306"
  env_set_kv "$env_file" "DB_DATABASE" "$db_name"
  env_set_kv "$env_file" "DB_USERNAME" "$db_user"
  env_set_kv "$env_file" "DB_PASSWORD" "$db_pass"
}

# Render canonical nginx metadata block (metadata v1).
# shellcheck disable=SC2154,SC2034 # dynamic assoc keys populated for callers
site_nginx_metadata_parse() {
  local file="$1" out_name="$2"
  [[ ! -f "$file" ]] && return 1
  local -n out="$out_name"
  local found=0
  while IFS= read -r line; do
    [[ "$line" =~ ^\#\ simai-([a-z-]+):[[:space:]]*(.*)$ ]] || continue
    found=1
    local key="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"
    case "$key" in
      managed) out[managed]="$val" ;;
      meta-version) out[meta_version]="$val" ;;
      domain) out[domain]="$val" ;;
      slug) out[slug]="$val" ;;
      profile) out[profile]="$val" ;;
      root) out[root]="$val" ;;
      project) out[project]="$val" ;;
      php) out[php]="$val" ;;
      target) out[target]="$val" ;;
      php-socket-project) out[php_socket_project]="$val" ;;
      nginx-template) out[nginx_template]="$val" ;;
      ssl) out[ssl]="$val" ;;
      public-dir) out[public_dir]="$val" ;;
      updated-at) out[updated_at]="$val" ;;
    esac
  done <"$file"
  [[ $found -eq 1 ]] || return 1
  return 0
}

nginx_safe_write_config() {
  local cfg_path="$1" content="$2"
  local dir backup tmp
  dir=$(dirname "$cfg_path")
  mkdir -p "$dir"
  tmp=$(mktemp)
  printf "%s" "$content" >"$tmp"
  backup=""
  if [[ -f "$cfg_path" ]]; then
    backup="${cfg_path}.bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$cfg_path" "$backup"
  fi
  mv "$tmp" "$cfg_path"
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    error "nginx config test failed; restoring ${backup:-previous} for ${cfg_path}"
    if [[ -n "$backup" && -f "$backup" ]]; then
      mv "$backup" "$cfg_path"
    fi
    return 1
  fi
  os_svc_reload nginx || warn "nginx reload failed after updating ${cfg_path}"
  return 0
}

site_nginx_metadata_upsert() {
  local cfg="$1" domain="$2" slug="$3" profile="$4" root="$5" project="$6" php="$7" ssl="$8" updated_at="$9" target="${10}" socket_project="${11}" template="${12}" public_dir="${13}"
  declare -A parsed=()
  if site_nginx_metadata_parse "$cfg" parsed; then
    [[ -z "$domain" ]] && domain="${parsed[domain]}"
    [[ -z "$slug" ]] && slug="${parsed[slug]}"
    [[ -z "$profile" ]] && profile="${parsed[profile]}"
    [[ -z "$root" ]] && root="${parsed[root]}"
    [[ -z "$project" ]] && project="${parsed[project]}"
    [[ -z "$php" ]] && php="${parsed[php]}"
    [[ -z "$ssl" ]] && ssl="${parsed[ssl]}"
    [[ -z "$target" ]] && target="${parsed[target]}"
    [[ -z "$socket_project" ]] && socket_project="${parsed[php_socket_project]}"
    [[ -z "$template" ]] && template="${parsed[nginx_template]}"
    if [[ -z "${public_dir+x}" ]]; then
      public_dir="${parsed[public_dir]}"
    fi
  fi
  [[ -z "$domain" ]] && domain="$(basename "${cfg%.conf}")"
  [[ -z "$slug" ]] && slug="$(project_slug_from_domain "$domain")"
  [[ -z "$project" ]] && project="$slug"
  [[ -z "$profile" ]] && profile="generic"
  [[ -z "$root" ]] && root="${WWW_ROOT}/${domain}"
  [[ -z "$php" ]] && php="none"
  [[ -z "$ssl" ]] && ssl="unknown"
  [[ -z "$socket_project" ]] && socket_project="$slug"
  [[ -z "$template" ]] && template="$profile"
  if [[ -z "${public_dir+x}" ]]; then
    public_dir="public"
  fi
  local block
  block=$(site_nginx_metadata_render "$domain" "$slug" "$profile" "$root" "$project" "$php" "$ssl" "$updated_at" "$target" "$socket_project" "$template" "$public_dir")
  local body
  body=$(awk 'BEGIN{meta=1}
    {
      if(meta && $0 ~ /^# simai-/) next
      if(meta && $0 ~ /^$/) next
      meta=0
      print
    }' "$cfg" 2>/dev/null || true)
  local new_content="${block}"$'\n'"${body}"
  nginx_safe_write_config "$cfg" "$new_content"
}

ensure_ssl_dir() {
  local domain="$1"
  local dir="/etc/nginx/ssl/${domain}"
  mkdir -p "$dir"
  chmod 750 "$dir"
  chown root:root "$dir"
  echo "$dir"
}

ensure_certbot_cron() {
  local cron_file="/etc/cron.d/simai-certbot"
  if [[ -f "$cron_file" ]]; then
    return
  fi
  cat >"$cron_file" <<'EOF'
SHELL=/bin/bash
0 3,15 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
}

site_ssl_brief() {
  local domain="$1"
  local cert="" key="" type="off" until=""
  local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local le_key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local custom_cert="/etc/nginx/ssl/${domain}/fullchain.pem"
  local custom_key="/etc/nginx/ssl/${domain}/privkey.pem"
  if [[ -f "$le_cert" && -f "$le_key" ]]; then
    cert="$le_cert"; key="$le_key"; type="LE"
  elif [[ -f "$custom_cert" && -f "$custom_key" ]]; then
    cert="$custom_cert"; key="$custom_key"; type="custom"
  fi
  if [[ -n "$cert" ]]; then
    until=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2 || true)
    [[ -n "$until" ]] && until=$(date -d "$until" +%Y-%m-%d 2>/dev/null || echo "$until")
  fi
  if [[ "$type" == "off" ]]; then
    echo "off"
  elif [[ -n "$until" ]]; then
    echo "${type}:${until}"
  else
    echo "${type}"
  fi
}

site_ssl_info() {
  local domain="$1"
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  local enabled="false" type="none"
  if [[ "${SITE_META[ssl]:-off}" == "on" ]]; then
    enabled="true"
    if grep -q "/etc/letsencrypt/live/${domain}/" "$cfg" 2>/dev/null; then
      type="letsencrypt"
    elif grep -q "/etc/nginx/ssl/${domain}/" "$cfg" 2>/dev/null; then
      type="custom"
    else
      type="unknown"
    fi
  fi
  echo "${enabled} ${type}"
}

has_simai_metadata() {
  local domain="$1"
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  [[ -f "$cfg" ]] && grep -q "^# simai-" "$cfg"
}

mysql_root_detect_cli() {
  if [[ -n "${MYSQL_ROOT_CLI:-}" ]]; then
    return 0
  fi
  local cli
  cli=(mysql -uroot)
  if printf "SELECT 1;\n" | "${cli[@]}" >>"$LOG_FILE" 2>&1; then
    MYSQL_ROOT_CLI=("${cli[@]}")
    MYSQL_ROOT_PWD=""
    return 0
  fi
  if [[ -n "${SIMAI_MYSQL_ROOT_PASSWORD:-}" ]]; then
    MYSQL_ROOT_PWD="${SIMAI_MYSQL_ROOT_PASSWORD}"
    if printf "SELECT 1;\n" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${cli[@]}" >>"$LOG_FILE" 2>&1; then
      MYSQL_ROOT_CLI=("${cli[@]}")
      return 0
    fi
    MYSQL_ROOT_PWD=""
  fi
  if [[ -f /root/.my.cnf ]]; then
    cli=(mysql --defaults-extra-file=/root/.my.cnf)
    if printf "SELECT 1;\n" | "${cli[@]}" >>"$LOG_FILE" 2>&1; then
      MYSQL_ROOT_CLI=("${cli[@]}")
      MYSQL_ROOT_PWD=""
      return 0
    fi
  fi
  error "Cannot connect to MySQL as root. Check that Percona/MySQL is installed and root auth is configured."
  return 1
}

mysql_root_exec() {
  local sql="$1"
  mysql_root_detect_cli || return 1
  if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    printf "%s\n" "$sql" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" >>"$LOG_FILE" 2>&1
  else
    printf "%s\n" "$sql" | "${MYSQL_ROOT_CLI[@]}" >>"$LOG_FILE" 2>&1
  fi
}

mysql_root_query() {
  local sql="$1"
  mysql_root_detect_cli || return 1
  if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    printf "%s\n" "$sql" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" -N -B 2>>"$LOG_FILE"
  else
    printf "%s\n" "$sql" | "${MYSQL_ROOT_CLI[@]}" -N -B 2>>"$LOG_FILE"
  fi
}

db_sql_escape() {
  local input="$1"
  input=${input//\\/\\\\}
  input=${input//\'/\\\'}
  echo "$input"
}

db_validate_db_name() {
  local name="$1"
  if [[ -z "$name" || ${#name} -gt 64 || ! "$name" =~ ^[a-z0-9_-]+$ ]]; then
    error "Invalid database name: ${name}"
    return 1
  fi
}

db_validate_db_user() {
  local user="$1"
  if [[ -z "$user" || ${#user} -gt 32 || ! "$user" =~ ^[a-z0-9_-]+$ ]]; then
    error "Invalid database user: ${user}"
    return 1
  fi
}

switch_site_php() {
  local domain="$1" new_php="$2" keep_old="${3:-no}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  if [[ "$profile" == "alias" ]]; then
    error "Cannot change PHP version for alias site ${domain}; update target site instead."
    return 1
  fi
  local project="${SITE_META[project]}"
  local root="${SITE_META[root]}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local old_php="${SITE_META[php]}"
  if [[ ! -d "$root" ]]; then
    warn "Project root ${root} not found; continuing"
  fi

  if [[ "$new_php" == "$old_php" ]]; then
    info "PHP version for ${domain} is already ${new_php}; nothing to do."
    return 0
  fi
  if [[ ! -d "/etc/php/${new_php}" ]]; then
    error "PHP ${new_php} is not installed."
    return 1
  fi

  create_php_pool "$socket_project" "$new_php" "$root"
  if ! nginx_patch_php_socket "$domain" "$new_php" "$socket_project"; then
    return 1
  fi

  nginx -t >>"$LOG_FILE" 2>&1 || { error "nginx config test failed"; return 1; }
  os_svc_reload_or_restart nginx || true

  if [[ "$profile" == "laravel" ]]; then
    local cron_project="$project"
    if ! validate_project_slug "$cron_project"; then
      cron_project="$(project_slug_from_domain "$domain")"
    fi
    cron_site_write "$domain" "$cron_project" "$profile" "$root" "$new_php"
    local unit="/etc/systemd/system/laravel-queue-${project}.service"
    if [[ -f "$unit" ]]; then
      backup_file "$unit"
      local php_bin
      php_bin=$(resolve_php_bin "$new_php")
      perl -pi -e "s#^(ExecStart=)\\S+(\\s+.*)#\\1${php_bin}\\2#" "$unit"
      os_svc_daemon_reload || true
      os_svc_restart "laravel-queue-${project}.service" || warn "Failed to restart queue service laravel-queue-${project}.service"
    fi
  fi

  if [[ "$keep_old" != "yes" && -n "$old_php" && "$old_php" != "$new_php" ]]; then
    remove_php_pool_version "$socket_project" "$old_php"
  fi

  echo "===== PHP switch summary ====="
  echo "Domain      : ${domain}"
  echo "Profile     : ${profile}"
  echo "Socket proj : ${socket_project}"
  echo "PHP         : ${old_php} -> ${new_php}"
  echo "Nginx       : patched in-place (SSL preserved)"
  echo "Pool        : new ${new_php} created; old $([[ "$keep_old" == "yes" ]] && echo kept || echo removed)"
  if [[ "$profile" == "laravel" ]]; then
    echo "Cron        : /etc/cron.d/${project} refreshed"
    if [[ -f "/etc/systemd/system/laravel-queue-${project}.service" ]]; then
      echo "Queue unit  : updated to php ${new_php}"
    fi
  fi
}

read_site_metadata() {
  local domain="$1"
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -gA SITE_META=(
    ["domain"]="$domain"
    ["profile"]="generic"
    ["project"]="$(project_slug_from_domain "$domain")"
    ["root"]="${WWW_ROOT}/${domain}"
    ["php"]=""
    ["target"]=""
    ["php_socket_project"]=""
    ["ssl"]="none"
    ["meta_version"]=""
    ["nginx_template"]=""
    ["public_dir"]="public"
  )
  if [[ -f "$cfg" ]]; then
    declare -A parsed=()
    if site_nginx_metadata_parse "$cfg" parsed; then
      local k
      for k in "${!parsed[@]}"; do
        SITE_META["$k"]="${parsed[$k]}"
      done
    else
      while IFS= read -r line; do
        if [[ "$line" =~ ^\#\ simai-([a-z-]+):[[:space:]]*(.*)$ ]]; then
          local key="${BASH_REMATCH[1]}"
          local val="${BASH_REMATCH[2]}"
          case "$key" in
            domain) SITE_META["domain"]="$val" ;;
            profile) SITE_META["profile"]="$val" ;;
            project) SITE_META["project"]="$val" ;;
            root) SITE_META["root"]="$val" ;;
            php) SITE_META["php"]="$val" ;;
            target) SITE_META["target"]="$val" ;;
            php-socket-project) SITE_META["php_socket_project"]="$val" ;;
            nginx-template) SITE_META["nginx_template"]="$val" ;;
            ssl) SITE_META["ssl"]="$val" ;;
            public-dir) SITE_META["public_dir"]="$val" ;;
          esac
        fi
      done <"$cfg"
    fi
  fi
  if [[ "${SITE_META[profile]}" == "alias" ]]; then
    if [[ -z "${SITE_META[php_socket_project]}" ]]; then
      SITE_META["php_socket_project"]="${SITE_META[project]}"
    fi
    [[ -z "${SITE_META[php]}" ]] && SITE_META["php"]="none"
    return 0
  fi
  [[ -z "${SITE_META[root]}" ]] && SITE_META["root"]="${WWW_ROOT}/${domain}"
  if [[ "${SITE_META[profile]}" == "static" ]]; then
    if [[ -z "${SITE_META[php]}" ]]; then
      SITE_META["php"]="none"
    fi
    if [[ -z "${SITE_META[php_socket_project]}" ]]; then
      SITE_META["php_socket_project"]="${SITE_META[project]}"
    fi
  else
    if [[ -z "${SITE_META[php]}" ]]; then
      local pool
      pool=$(detect_pool_for_project "${SITE_META[php_socket_project]:-${SITE_META[project]}}")
      if [[ -n "$pool" ]]; then
        SITE_META["php"]="$(echo "$pool" | awk -F'/' '{print $4}')"
      fi
    fi
    if [[ -z "${SITE_META[php_socket_project]}" ]]; then
      SITE_META["php_socket_project"]="${SITE_META[project]}"
    fi
    if [[ -z "${SITE_META[php]}" ]]; then
      mapfile -t _vers < <(installed_php_versions)
      SITE_META["php"]="${_vers[0]:-8.2}"
    fi
  fi
  return 0
}
