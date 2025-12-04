#!/usr/bin/env bash
set -euo pipefail

SIMAI_USER=${SIMAI_USER:-simai}
WWW_ROOT=${WWW_ROOT:-/home/${SIMAI_USER}/www}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-${SCRIPT_DIR}/templates/nginx-laravel.conf}
NGINX_TEMPLATE_GENERIC=${NGINX_TEMPLATE_GENERIC:-${SCRIPT_DIR}/templates/nginx-generic.conf}
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
    echo "$name"
  done | sort
  shopt -u nullglob
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

create_mysql_db_user() {
  local db_name="$1" db_user="$2" db_pass="$3"
  if ! command -v mysql >/dev/null 2>&1; then
    warn "mysql client not found; skip DB creation"
    return 1
  fi
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS \`${db_name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" >>"$LOG_FILE" 2>&1 || warn "Failed to create database ${db_name}"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${db_user}'@'%' IDENTIFIED BY '${db_pass}';" >>"$LOG_FILE" 2>&1 || warn "Failed to create user ${db_user}"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${db_name}\`.* TO '${db_user}'@'%'; FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1 || warn "Failed to grant privileges to ${db_user}"
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
  local domain="$1" project="$2" project_path="$3" php_version="$4" template_path="${5:-$NGINX_TEMPLATE}" profile="${6:-}" target="${7:-}" php_socket_project="${8:-$project}"
  if [[ ! -f "$template_path" ]]; then
    error "nginx template not found at ${template_path}"
    exit 1
  fi
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  {
    echo "# simai-domain: ${domain}"
    echo "# simai-profile: ${profile}"
    echo "# simai-project: ${project}"
    echo "# simai-root: ${project_path}"
    echo "# simai-php: ${php_version}"
    echo "# simai-target: ${target}"
    echo "# simai-php-socket-project: ${php_socket_project}"
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
  ensure_nginx_catchall
  nginx -t >>"$LOG_FILE" 2>&1 || { error "nginx config test failed"; exit 1; }
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

switch_site_php() {
  local domain="$1" new_php="$2" keep_old="${3:-no}"
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

  if [[ "$new_php" == "$old_php" ]]; then
    info "PHP version for ${domain} is already ${new_php}; nothing to do."
    return 0
  fi
  if [[ ! -d "/etc/php/${new_php}" ]]; then
    error "PHP ${new_php} is not installed."
    return 1
  fi

  local template="$NGINX_TEMPLATE"
  if [[ "$profile" == "generic" ]]; then
    template="$NGINX_TEMPLATE_GENERIC"
  fi

  create_php_pool "$project" "$new_php" "$root"
  create_nginx_site "$domain" "$project" "$root" "$new_php" "$template" "$profile" "" "$socket_project"

  if [[ "$keep_old" != "yes" && -n "$old_php" && "$old_php" != "$new_php" ]]; then
    remove_php_pool_version "$project" "$old_php"
  fi

  info "PHP version switched for ${domain}: ${old_php} -> ${new_php}"
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
        esac
      fi
    done <"$cfg"
  fi
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
}
