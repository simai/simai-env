#!/usr/bin/env bash
set -euo pipefail

SIMAI_USER=${SIMAI_USER:-simai}
WWW_ROOT=${WWW_ROOT:-/home/${SIMAI_USER}/www}
NGINX_TEMPLATE=${NGINX_TEMPLATE:-${SCRIPT_DIR}/templates/nginx-laravel.conf}

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
  local domain="$1" project="$2" project_path="$3" php_version="$4"
  if [[ ! -f "$NGINX_TEMPLATE" ]]; then
    error "nginx template not found at ${NGINX_TEMPLATE}"
    exit 1
  fi
  local site_available="/etc/nginx/sites-available/${domain}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  sed -e "s#{{SERVER_NAME}}#${domain}#g" \
      -e "s#{{PROJECT_ROOT}}#${project_path}#g" \
      -e "s#{{PROJECT_NAME}}#${project}#g" \
      -e "s#{{PHP_VERSION}}#${php_version}#g" "$NGINX_TEMPLATE" > "$site_available"
  ln -sf "$site_available" "$site_enabled"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
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
