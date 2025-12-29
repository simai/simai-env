#!/usr/bin/env bash
set -euo pipefail

SIMAI_USER=${SIMAI_USER:-simai}
WWW_ROOT=${WWW_ROOT:-/home/${SIMAI_USER}/www}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-${SCRIPT_DIR}/templates/nginx-laravel.conf}
NGINX_TEMPLATE_GENERIC=${NGINX_TEMPLATE_GENERIC:-${SCRIPT_DIR}/templates/nginx-generic.conf}
NGINX_TEMPLATE_STATIC=${NGINX_TEMPLATE_STATIC:-${SCRIPT_DIR}/templates/nginx-static.conf}
HEALTHCHECK_TEMPLATE=${HEALTHCHECK_TEMPLATE:-${SCRIPT_DIR}/templates/healthcheck.php}

project_slug_from_domain() {
  local domain="$1"
  local slug
  slug=$(echo "$domain" | tr '[:upper:]' '[:lower:]' | sed -e 's/[^a-z0-9]/-/g' -e 's/-\\+/-/g' -e 's/^-//' -e 's/-$//')
  [[ -z "$slug" ]] && slug="site"
  echo "$slug"
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
  local pools=(/etc/php/*/fpm/pool.d/${project}.conf)
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
    error "Domain must contain at least one dot (e.g. example.com)"
    return 1
  fi
  case "$domain_lc" in
    example.com|example.net|example.org)
      if [[ "$policy" == "allow" ]]; then
        warn "Domain ${domain_lc} is reserved; proceeding (cleanup/status)."
        return 0
      fi
      if [[ "${ALLOW_RESERVED_DOMAIN:-no}" == "yes" ]]; then
        warn "Domain ${domain_lc} is reserved; proceeding because ALLOW_RESERVED_DOMAIN=yes."
      else
        warn "Domain ${domain_lc} is reserved for documentation/tests. Set ALLOW_RESERVED_DOMAIN=yes to proceed."
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

create_mysql_db_user() {
  local db_name="$1" db_user="$2" db_pass="$3"
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not found; skip DB creation"
    return 1
  fi
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >>"$LOG_FILE" 2>&1 || warn "Failed to create database ${db_name}"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${db_user}'@'127.0.0.1' IDENTIFIED BY '${db_pass}';" >>"$LOG_FILE" 2>&1 || warn "Failed to create user ${db_user}@127.0.0.1"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}';" >>"$LOG_FILE" 2>&1 || warn "Failed to create user ${db_user}@localhost"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'127.0.0.1';" >>"$LOG_FILE" 2>&1 || warn "Failed to grant privileges to ${db_user}@127.0.0.1"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'localhost'; FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1 || warn "Failed to grant privileges to ${db_user}@localhost"
}

create_php_pool() {
  local project="$1" php_version="$2" project_path="$3"
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
  systemctl reload "php${php_version}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${php_version}-fpm" >>"$LOG_FILE" 2>&1 || true
}

create_nginx_site() {
  local domain="$1" project="$2" project_path="$3" php_version="$4" template_path="${5:-$NGINX_TEMPLATE}" profile="${6:-}" target="${7:-}" php_socket_project="${8:-$project}" ssl_cert="${9:-}" ssl_key="${10:-}" ssl_chain="${11:-}" ssl_redirect="${12:-no}" ssl_hsts="${13:-no}"
  if [[ ! -f "$template_path" ]]; then
    error "nginx template not found at ${template_path}"
    return 1
  fi
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  local ssl_flag="off"
  [[ -n "$ssl_cert" && -n "$ssl_key" ]] && ssl_flag="on"
  if [[ -f "$site_available" ]]; then
    local ts backup
    ts=$(date +%Y%m%d%H%M%S)
    backup="${site_available}.bak.${ts}"
    if cp -p "$site_available" "$backup" >>"$LOG_FILE" 2>&1; then
      info "Backed up existing nginx config to ${backup}"
    else
      warn "Failed to backup existing nginx config ${site_available}"
    fi
  fi

  {
    echo "# simai-domain: ${domain}"
    echo "# simai-profile: ${profile}"
    echo "# simai-project: ${project}"
    echo "# simai-root: ${project_path}"
    echo "# simai-php: ${php_version}"
    echo "# simai-target: ${target}"
    echo "# simai-php-socket-project: ${php_socket_project}"
    echo "# simai-ssl: ${ssl_flag}"
    sed -e "s#{{SERVER_NAME}}#${domain}#g" \
      -e "s#{{PROJECT_ROOT}}#${project_path}#g" \
      -e "s#{{PROJECT_NAME}}#${project}#g" \
      -e "s#{{PHP_VERSION}}#${php_version}#g" \
      -e "s#{{PHP_SOCKET_PROJECT}}#${php_socket_project}#g" "$template_path"
  } > "$site_available"
  ln -sf "$site_available" "$site_enabled"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  if [[ -n "$ssl_cert" && -n "$ssl_key" ]]; then
    perl -0pi -e 'if ($_ !~ /listen 443 ssl;/) { s/^(\\s*listen 80;.*)$/\\1\n    listen 443 ssl;/m }' "$site_available"
    perl -0pi -e "if ($_ !~ /ssl_certificate /) { s/^(\\s*server_name\\s+.*;)/\\1\\n    ssl_certificate ${ssl_cert};\\n    ssl_certificate_key ${ssl_key};/m }" "$site_available"
    [[ -n "$ssl_chain" ]] && perl -0pi -e "if ($_ !~ /ssl_trusted_certificate /) { s/^(\\s*ssl_certificate_key.*;)/\\1\\n    ssl_trusted_certificate ${ssl_chain};/m }" "$site_available"
    if [[ "$ssl_hsts" == "yes" ]]; then
      perl -0pi -e 's/^}\\s*$//m; print "    add_header Strict-Transport-Security \"max-age=31536000\" always;\\n}\n" unless /Strict-Transport-Security/' "$site_available"
    fi
    if [[ "$ssl_redirect" == "yes" ]]; then
      perl -0pi -e 's/^}\\s*$//m; print "    # simai-ssl-redirect-start\n    if ($scheme != \"https\") { return 301 https://$host$request_uri; }\n    # simai-ssl-redirect-end\n}\n" unless /simai-ssl-redirect/' "$site_available"
    fi
  fi
  ensure_nginx_catchall
  nginx -t >>"$LOG_FILE" 2>&1 || { error "nginx config test failed"; return 1; }
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || systemctl restart nginx >>"$LOG_FILE" 2>&1 || true
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
  rm -f "$site_enabled" "$site_available"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >>"$LOG_FILE" 2>&1 || warn "nginx test failed after removing ${domain}"
    systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
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
  shopt -s nullglob
  local pools=(/etc/php/*/fpm/pool.d/${project}.conf)
  local versions=()
  for pool in "${pools[@]:-}"; do
    rm -f "$pool"
    local ver
    ver=$(echo "$pool" | awk -F'/' '{print $4}')
    versions+=("$ver")
  done
  shopt -u nullglob
  for v in $(printf "%s\n" "${versions[@]}" | sort -u); do
    systemctl reload "php${v}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${v}-fpm" >>"$LOG_FILE" 2>&1 || true
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

reload_cron_daemon() {
  ensure_cron_service
  systemctl reload cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || service cron reload >>"$LOG_FILE" 2>&1 || true
}

ensure_cron_service() {
  if ! command -v systemctl >/dev/null 2>&1; then
    warn "cron service check skipped (systemctl not available)"
    return
  fi
  if ! systemctl list-unit-files | grep -q '^cron\\.service'; then
    warn "cron service not found. Install: apt-get install cron; then: systemctl enable --now cron"
    return
  fi
  if systemctl is-active --quiet cron; then
    return
  fi
  systemctl enable --now cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || true
  if ! systemctl is-active --quiet cron; then
    warn "cron service is inactive; ensure cron is installed and run: systemctl enable --now cron"
  fi
}

ensure_project_cron() {
  local project="$1" profile="$2" project_path="$3" php_version="$4"
  if [[ "$profile" != "laravel" ]]; then
    return
  fi
  local cron_file="/etc/cron.d/${project}"
  local php_cli
  php_cli=$(command -v "php${php_version}" || true)
  [[ -z "$php_cli" ]] && php_cli="/usr/bin/php"
  cat >"$cron_file" <<EOF
# simai-project: ${project}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
* * * * * ${SIMAI_USER} cd ${project_path} && ${php_cli} artisan schedule:run >> /dev/null 2>&1
EOF
  chmod 644 "$cron_file" 2>/dev/null || true
  chown root:root "$cron_file" 2>/dev/null || true
  reload_cron_daemon
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
  local project="$1"
  local cron_file="/etc/cron.d/${project}"
  if [[ -f "$cron_file" ]]; then
    rm -f "$cron_file"
    reload_cron_daemon
    info "Removed cron file ${cron_file}"
  fi
}

remove_queue_unit() {
  local project="$1"
  local unit="/etc/systemd/system/laravel-queue-${project}.service"
  if [[ -f "$unit" ]]; then
    systemctl disable --now "laravel-queue-${project}.service" >>"$LOG_FILE" 2>&1 || true
    rm -f "$unit"
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
    info "Removed queue unit laravel-queue-${project}.service"
  fi
}

remove_php_pool_version() {
  local project="$1" version="$2"
  local pool="/etc/php/${version}/fpm/pool.d/${project}.conf"
  if [[ -f "$pool" ]]; then
    rm -f "$pool"
    systemctl reload "php${version}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${version}-fpm" >>"$LOG_FILE" 2>&1 || true
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
  local project_path="$1"
  if [[ ! -f "$HEALTHCHECK_TEMPLATE" ]]; then
    warn "Healthcheck template not found at ${HEALTHCHECK_TEMPLATE}"
    return
  fi
  mkdir -p "$project_path/public"
  cp "$HEALTHCHECK_TEMPLATE" "$project_path/public/healthcheck.php"
}

write_generic_env() {
  local project_path="$1" db_name="$2" db_user="$3" db_pass="$4"
  local env_file="${project_path}/.env"
  cat >"$env_file" <<EOF
DB_CONNECTION=mysql
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=${db_name}
DB_USERNAME=${db_user}
DB_PASSWORD=${db_pass}
EOF
  chown "$SIMAI_USER":www-data "$env_file" 2>/dev/null || true
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
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || systemctl restart nginx >>"$LOG_FILE" 2>&1 || true

  if [[ "$profile" == "laravel" ]]; then
    ensure_project_cron "$project" "$profile" "$root" "$new_php"
    local unit="/etc/systemd/system/laravel-queue-${project}.service"
    if [[ -f "$unit" ]]; then
      backup_file "$unit"
      local php_bin
      php_bin=$(resolve_php_bin "$new_php")
      perl -pi -e "s#^(ExecStart=)\\S+(\\s+.*)#\\1${php_bin}\\2#" "$unit"
      systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
      systemctl restart "laravel-queue-${project}.service" >>"$LOG_FILE" 2>&1 || warn "Failed to restart queue service laravel-queue-${project}.service"
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
    ["root"]="${WWW_ROOT}/$(project_slug_from_domain "$domain")"
    ["php"]=""
    ["target"]=""
    ["php_socket_project"]=""
    ["ssl"]="off"
  )
  if [[ -f "$cfg" ]]; then
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
          ssl) SITE_META["ssl"]="$val" ;;
        esac
      fi
    done <"$cfg"
  fi
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
