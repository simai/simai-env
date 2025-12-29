#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LOG_FILE=${LOG_FILE:-/var/log/simai-env.log}
SILENT=0
ACTION=install
DEPLOY_MODE=new
SIMAI_USER=simai
SIMAI_HOME=/home/${SIMAI_USER}
WWW_ROOT=${SIMAI_HOME}/www
PROJECT_NAME=""
PROJECT_PATH=""
DOMAIN=""
DB_NAME=""
DB_USER="simai"
DB_PASS=""
DB_HOST="127.0.0.1"
DB_PORT="3306"
PHP_VERSION="8.2"
MYSQL_FLAVOR="mysql"
NODE_VERSION="20"
RUN_MIGRATIONS=0
RUN_OPTIMIZE=0
REMOVE_FILES=0
DROP_DB=0
DROP_DB_USER=0
CONFIRM=0
FORCE=0
APT_UPDATED=0
PHP_BIN=""
QUEUE_TEMPLATE="${SCRIPT_DIR}/systemd/laravel-queue.service"
NGINX_TEMPLATE="${SCRIPT_DIR}/templates/nginx-laravel.conf"

usage() {
  cat <<USAGE
Usage:
  simai-env.sh [install] --domain example.com --project-name myapp [options]
  simai-env.sh --existing --path /home/simai/www/myapp --domain example.com [options]
  simai-env.sh clean --project-name myapp --domain example.com [clean options]

Install options:
  --domain <fqdn>            Server name for nginx
  --project-name <name>      Project name (used for paths and services)
  --path <dir>               Existing project path (sets --existing automatically)
  --existing                 Configure an existing Laravel project
  --db-name <name>           Database name (default: simai_<project>)
  --db-user <name>           Database user (default: simai)
  --db-pass <pass>           Database password (generated if empty)
  --db-host <host>           Database host (default: 127.0.0.1)
  --db-port <port>           Database port (default: 3306)
  --php <8.1|8.2|8.3>        PHP version (default: 8.2)
  --mysql <mysql|percona>    MySQL implementation (default: mysql)
  --node-version <N>         Node.js major version (default: 20)
  --run-migrations           Run php artisan migrate --force
  --optimize                 Run artisan caches (config/route/view)
  --silent                   Minimize console output
  --force                    Continue when non-critical checks fail
  --log-file <path>          Path for install log (default: /var/log/simai-env.log)

Clean options:
  clean                      Run cleanup mode
  --remove-files             Delete project files
  --drop-db                  Drop MySQL database
  --drop-db-user             Drop MySQL user
  --confirm                  Confirm destructive clean operations
  --php <version>            PHP version used for pool cleanup

Examples:
  simai-env.sh --domain example.com --project-name blog --db-name blogdb --php 8.3
  simai-env.sh --existing --path /home/simai/www/app --domain app.local --php 8.1
  simai-env.sh clean --project-name blog --domain example.com --remove-files --drop-db --confirm
USAGE
}

log() {
  local level="$1"; shift
  local message="$*"
  local timestamp
  timestamp=$(date +"%Y-%m-%dT%H:%M:%S")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "${timestamp} [${level}] ${message}" >> "$LOG_FILE"
  if [[ $SILENT -eq 0 || $level == "ERROR" ]]; then
    echo "${timestamp} [${level}] ${message}"
  fi
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

fail() {
  error "$*"
  exit 1
}

require_root() {
  if [[ $EUID -ne 0 ]]; then
    fail "Run this script as root"
  fi
}

require_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    fail "Cannot detect OS"
  fi
  . /etc/os-release
  if [[ ${ID} != "ubuntu" ]]; then
    fail "Supported only on Ubuntu 20.04/22.04/24.04"
  fi
  case ${VERSION_ID} in
    "20.04"|"22.04"|"24.04") ;;
    *) fail "Unsupported Ubuntu version ${VERSION_ID}";;
  esac
}

validate_domain() {
  local domain="$1"
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

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 1
  fi
  local CONFIRM_VALUE=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      install|deploy)
        ACTION=install
        shift
        ;;
      clean)
        ACTION=clean
        shift
        ;;
      --existing)
        DEPLOY_MODE=existing
        shift
        ;;
      --path)
        PROJECT_PATH="$2"
        DEPLOY_MODE=existing
        shift 2
        ;;
      --project-name)
        PROJECT_NAME="$2"
        shift 2
        ;;
      --domain)
        DOMAIN="$2"
        shift 2
        ;;
      --db-name)
        DB_NAME="$2"
        shift 2
        ;;
      --db-user)
        DB_USER="$2"
        shift 2
        ;;
      --db-pass)
        DB_PASS="$2"
        shift 2
        ;;
      --db-host)
        DB_HOST="$2"
        shift 2
        ;;
      --db-port)
        DB_PORT="$2"
        shift 2
        ;;
      --php)
        PHP_VERSION="$2"
        shift 2
        ;;
      --mysql)
        MYSQL_FLAVOR="$2"
        shift 2
        ;;
      --node-version)
        NODE_VERSION="$2"
        shift 2
        ;;
      --run-migrations)
        RUN_MIGRATIONS=1
        shift
        ;;
      --optimize)
        RUN_OPTIMIZE=1
        shift
        ;;
      --remove-files)
        REMOVE_FILES=1
        shift
        ;;
      --drop-db)
        DROP_DB=1
        shift
        ;;
      --drop-db-user)
        DROP_DB_USER=1
        shift
        ;;
      --confirm)
        CONFIRM=1
        if [[ "${2:-}" =~ ^(yes|true|1)$ ]]; then
          shift 2
        else
          shift
        fi
        ;;
      --confirm=*)
        CONFIRM_VALUE="${1#*=}"
        if [[ "${CONFIRM_VALUE,,}" =~ ^(yes|true|1)$ ]]; then
          CONFIRM=1
        fi
        shift
        ;;
      --silent)
        SILENT=1
        shift
        ;;
      --force)
        FORCE=1
        shift
        ;;
      --log-file)
        LOG_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "Unknown argument: $1"
        ;;
    esac
  done
}

ensure_defaults() {
  if [[ -z $PROJECT_NAME && -n $PROJECT_PATH ]]; then
    PROJECT_NAME=$(basename "$PROJECT_PATH")
  fi
  if [[ -z $PROJECT_NAME ]]; then
    fail "--project-name is required"
  fi
  if [[ -z $DOMAIN ]]; then
    fail "--domain is required for install and clean"
  fi
  if [[ -z $PROJECT_PATH ]]; then
    PROJECT_PATH="${WWW_ROOT}/${PROJECT_NAME}"
  fi
  if ! validate_domain "$DOMAIN"; then
    return 1
  fi
  if ! validate_path "$PROJECT_PATH"; then
    return 1
  fi
  if [[ -z $DB_NAME ]]; then
    DB_NAME="simai_${PROJECT_NAME}"
  fi
  if [[ -z $DB_PASS ]]; then
    DB_PASS=$(head -c 32 /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20 || true)
    if [[ -z $DB_PASS ]]; then
      DB_PASS="simai$(date +%s)"
    fi
  fi
  if [[ $ACTION == "clean" && $CONFIRM -ne 1 ]]; then
    fail "--confirm flag is required for clean operations"
  fi
}

apt_update_once() {
  if [[ $APT_UPDATED -eq 0 ]]; then
    info "Running apt-get update"
    apt-get update -y >>"$LOG_FILE" 2>&1
    APT_UPDATED=1
  fi
}

install_packages() {
  apt_update_once
  info "Installing base utilities"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    software-properties-common ca-certificates curl gnupg lsb-release sudo cron \
    git unzip htop rsyslog logrotate certbot >>"$LOG_FILE" 2>&1
  systemctl enable --now cron >>"$LOG_FILE" 2>&1 || true
}

install_php_stack() {
  apt_update_once
  if ! grep -R "ondrej/php" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | grep -q ondrej; then
    info "Adding ondrej/php PPA"
    DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:ondrej/php >>"$LOG_FILE" 2>&1 || fail "Failed to add ondrej/php"
    APT_UPDATED=0
  fi
  apt_update_once
  local pkgs=(
    "php${PHP_VERSION}" "php${PHP_VERSION}-cli" "php${PHP_VERSION}-fpm" "php${PHP_VERSION}-mbstring"
    "php${PHP_VERSION}-intl" "php${PHP_VERSION}-curl" "php${PHP_VERSION}-zip" "php${PHP_VERSION}-xml"
    "php${PHP_VERSION}-gd" "php${PHP_VERSION}-imagick" "php${PHP_VERSION}-mysql" "php${PHP_VERSION}-opcache"
  )
  info "Installing PHP ${PHP_VERSION} stack"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" >>"$LOG_FILE" 2>&1 || fail "Failed to install PHP ${PHP_VERSION}"
  PHP_BIN=$(command -v "php${PHP_VERSION}" || true)
  if [[ -z $PHP_BIN ]]; then
    warn "php${PHP_VERSION} binary not found; falling back to php"
    PHP_BIN=$(command -v php || echo "/usr/bin/php")
  fi
  systemctl enable --now "php${PHP_VERSION}-fpm" >>"$LOG_FILE" 2>&1 || true
}

install_nginx() {
  apt_update_once
  info "Installing nginx"
  DEBIAN_FRONTEND=noninteractive apt-get install -y nginx >>"$LOG_FILE" 2>&1
  systemctl enable --now nginx >>"$LOG_FILE" 2>&1 || true
}

install_mysql() {
  apt_update_once
  if [[ $MYSQL_FLAVOR == "percona" ]]; then
    if [[ ! -f /etc/apt/sources.list.d/percona-release.list ]]; then
      info "Adding Percona repository"
      curl -fsSL -o /tmp/percona-release.deb https://repo.percona.com/apt/percona-release_latest.generic_all.deb >>"$LOG_FILE" 2>&1 || fail "Cannot download Percona release package"
      dpkg -i /tmp/percona-release.deb >>"$LOG_FILE" 2>&1 || fail "Failed to install Percona release package"
      percona-release setup ps80 -y >>"$LOG_FILE" 2>&1 || fail "Failed to configure Percona repo"
      APT_UPDATED=0
    fi
    apt_update_once
    info "Installing Percona Server 8.0"
    DEBIAN_FRONTEND=noninteractive apt-get install -y percona-server-server percona-server-client >>"$LOG_FILE" 2>&1
  else
    info "Installing MySQL Server"
    DEBIAN_FRONTEND=noninteractive apt-get install -y mysql-server >>"$LOG_FILE" 2>&1
  fi
  systemctl enable --now mysql >>"$LOG_FILE" 2>&1 || true
}

install_redis() {
  apt_update_once
  info "Installing redis-server"
  DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server >>"$LOG_FILE" 2>&1
  systemctl enable --now redis-server >>"$LOG_FILE" 2>&1 || true
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    local current
    current=$(node -v | sed 's/v//' | cut -d'.' -f1)
    if [[ $current == "$NODE_VERSION" ]]; then
      info "Node.js $NODE_VERSION already installed"
      return
    fi
  fi
  info "Installing Node.js ${NODE_VERSION} via NodeSource"
  curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash - >>"$LOG_FILE" 2>&1 || fail "Failed to add NodeSource"
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs >>"$LOG_FILE" 2>&1
}

install_composer() {
  if command -v composer >/dev/null 2>&1; then
    info "Composer already installed"
    return
  fi
  local php_cmd
  php_cmd=${PHP_BIN:-$(command -v "php${PHP_VERSION}" || true)}
  php_cmd=${php_cmd:-$(command -v php || echo "/usr/bin/php")}
  local sig
  sig=$(curl -fsSL https://composer.github.io/installer.sig)
  info "Installing Composer"
  $php_cmd -r "copy('https://getcomposer.org/installer', 'composer-setup.php');" >>"$LOG_FILE" 2>&1
  $php_cmd -r "if (hash_file('SHA384', 'composer-setup.php') !== '$sig') { echo 'Installer corrupt'; exit(1); }" >>"$LOG_FILE" 2>&1 || fail "Composer installer checksum failed"
  $php_cmd composer-setup.php --install-dir=/usr/local/bin --filename=composer >>"$LOG_FILE" 2>&1 || fail "Composer install failed"
  $php_cmd -r "unlink('composer-setup.php');" >>"$LOG_FILE" 2>&1
}

ensure_user() {
  if ! id -u "$SIMAI_USER" >/dev/null 2>&1; then
    info "Creating user ${SIMAI_USER}"
    useradd -m -s /bin/bash "$SIMAI_USER"
  fi
  usermod -a -G www-data "$SIMAI_USER" || true
  mkdir -p "$WWW_ROOT"
  chown -R "$SIMAI_USER":www-data "$SIMAI_HOME"
}

run_as_simai() {
  local cmd="$1"
  sudo -u "$SIMAI_USER" -H env HOME="$SIMAI_HOME" bash -lc "$cmd"
}

prepare_project_paths() {
  mkdir -p "$PROJECT_PATH"
  chown -R "$SIMAI_USER":www-data "$PROJECT_PATH"
}

create_database() {
  info "Configuring database ${DB_NAME}"
  local sql="CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  mysql -uroot -e "$sql" >>"$LOG_FILE" 2>&1 || warn "Failed to create database ${DB_NAME}"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';" >>"$LOG_FILE" 2>&1 || warn "Failed to create user ${DB_USER}@127.0.0.1"
  mysql -uroot -e "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';" >>"$LOG_FILE" 2>&1 || warn "Failed to create user ${DB_USER}@localhost"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';" >>"$LOG_FILE" 2>&1 || warn "Failed to grant privileges to ${DB_USER}@127.0.0.1"
  mysql -uroot -e "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" >>"$LOG_FILE" 2>&1 || warn "Failed to grant privileges to ${DB_USER}@localhost"
}

copy_env_if_needed() {
  local env_file="$PROJECT_PATH/.env"
  if [[ ! -f $env_file ]]; then
    if [[ -f "$PROJECT_PATH/.env.example" ]]; then
      cp "$PROJECT_PATH/.env.example" "$env_file"
    else
      cat >"$env_file" <<EOF_ENV
APP_NAME=${PROJECT_NAME}
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=http://${DOMAIN}

LOG_CHANNEL=stack

DB_CONNECTION=mysql
DB_HOST=${DB_HOST}
DB_PORT=${DB_PORT}
DB_DATABASE=${DB_NAME}
DB_USERNAME=${DB_USER}
DB_PASSWORD=${DB_PASS}

CACHE_DRIVER=redis
QUEUE_CONNECTION=redis
SESSION_DRIVER=redis
REDIS_HOST=127.0.0.1
EOF_ENV
    fi
  fi
}

set_env_value() {
  local key="$1"; local value="$2"; local file="$PROJECT_PATH/.env"
  if grep -q "^${key}=" "$file"; then
    sed -i "s#^${key}=.*#${key}=${value}#" "$file"
  else
    echo "${key}=${value}" >> "$file"
  fi
}

configure_env() {
  copy_env_if_needed
  set_env_value "APP_URL" "http://${DOMAIN}"
  set_env_value "DB_CONNECTION" "mysql"
  set_env_value "DB_HOST" "$DB_HOST"
  set_env_value "DB_PORT" "$DB_PORT"
  set_env_value "DB_DATABASE" "$DB_NAME"
  set_env_value "DB_USERNAME" "$DB_USER"
  set_env_value "DB_PASSWORD" "$DB_PASS"
}

deploy_new_project() {
  if [[ -f "$PROJECT_PATH/artisan" && $FORCE -eq 0 ]]; then
    warn "Project already exists at ${PROJECT_PATH}; skipping create-project"
    return
  fi
  local base_dir
  base_dir=$(dirname "$PROJECT_PATH")
  info "Creating new Laravel project ${PROJECT_NAME}"
  run_as_simai "cd \"$base_dir\" && composer create-project --no-interaction laravel/laravel \"$PROJECT_NAME\"" >>"$LOG_FILE" 2>&1
}

configure_existing_project() {
  if [[ ! -f "$PROJECT_PATH/artisan" ]]; then
    fail "artisan not found in ${PROJECT_PATH}; is this a Laravel project?"
  fi
  info "Installing composer dependencies"
  run_as_simai "cd \"${PROJECT_PATH}\" && composer install --no-interaction --prefer-dist" >>"$LOG_FILE" 2>&1 || warn "composer install failed"
}

run_artisan() {
  local args="$1"
  if [[ ! -x $PHP_BIN ]]; then
    PHP_BIN=$(command -v php || echo "/usr/bin/php")
  fi
  run_as_simai "cd \"${PROJECT_PATH}\" && ${PHP_BIN} artisan ${args}" >>"$LOG_FILE" 2>&1
}

finalize_laravel() {
  configure_env
  info "Generating APP_KEY"
  run_artisan "key:generate --force"
  info "Linking storage"
  run_artisan "storage:link" || warn "storage:link failed"
  if [[ $RUN_MIGRATIONS -eq 1 ]]; then
    info "Running migrations"
    run_artisan "migrate --force" || warn "migrate failed"
  fi
  if [[ $RUN_OPTIMIZE -eq 1 ]]; then
    info "Caching config/routes/views"
    run_artisan "config:cache" || warn "config:cache failed"
    run_artisan "route:cache" || warn "route:cache failed"
    run_artisan "view:cache" || warn "view:cache failed"
  fi
}

configure_php_pool() {
  local pool_dir="/etc/php/${PHP_VERSION}/fpm/pool.d"
  mkdir -p "$pool_dir"
  local pool_file="${pool_dir}/${PROJECT_NAME}.conf"
  cat >"$pool_file" <<EOF
[${PROJECT_NAME}]
user = ${SIMAI_USER}
group = www-data
listen = /run/php/php${PHP_VERSION}-fpm-${PROJECT_NAME}.sock
listen.owner = ${SIMAI_USER}
listen.group = www-data
pm = ondemand
pm.max_children = 10
pm.process_idle_timeout = 10s
request_terminate_timeout = 120s
chdir = ${PROJECT_PATH}
php_admin_value[error_log] = /var/log/php${PHP_VERSION}-fpm-${PROJECT_NAME}.log
php_admin_flag[log_errors] = on
EOF
  systemctl reload "php${PHP_VERSION}-fpm" >>"$LOG_FILE" 2>&1 || systemctl restart "php${PHP_VERSION}-fpm" >>"$LOG_FILE" 2>&1 || true
}

configure_nginx_site() {
  if [[ ! -f $NGINX_TEMPLATE ]]; then
    fail "nginx template not found at ${NGINX_TEMPLATE}"
  fi
  local site_available="/etc/nginx/sites-available/${DOMAIN}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${DOMAIN}.conf"
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
  local simai_profile="laravel"
  {
    echo "# simai-domain: ${DOMAIN}"
    echo "# simai-profile: ${simai_profile}"
    echo "# simai-project: ${PROJECT_NAME}"
    echo "# simai-root: ${PROJECT_PATH}"
    echo "# simai-php: ${PHP_VERSION}"
    echo "# simai-target: "
    echo "# simai-php-socket-project: ${PROJECT_NAME}"
    echo "# simai-ssl: off"
    sed -e "s#{{SERVER_NAME}}#${DOMAIN}#g" \
        -e "s#{{PROJECT_ROOT}}#${PROJECT_PATH}#g" \
        -e "s#{{PROJECT_NAME}}#${PROJECT_NAME}#g" \
        -e "s#{{PHP_VERSION}}#${PHP_VERSION}#g" \
        -e "s#{{PHP_SOCKET_PROJECT}}#${PROJECT_NAME}#g" "$NGINX_TEMPLATE"
  } > "$site_available"
  ln -sf "$site_available" "$site_enabled"
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    rm -f /etc/nginx/sites-enabled/default
  fi
  nginx -t >>"$LOG_FILE" 2>&1 || fail "nginx config test failed"
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || systemctl restart nginx >>"$LOG_FILE" 2>&1 || true
}

reload_cron_daemon() {
  systemctl reload cron >>"$LOG_FILE" 2>&1 || systemctl restart cron >>"$LOG_FILE" 2>&1 || service cron reload >>"$LOG_FILE" 2>&1 || true
}

configure_cron() {
  local cron_file="/etc/cron.d/${PROJECT_NAME}"
  local php_cli
  php_cli=$(command -v "php${PHP_VERSION}" || true)
  [[ -z "$php_cli" ]] && php_cli="${PHP_BIN:-$(command -v php || echo "/usr/bin/php")}"
  cat >"$cron_file" <<EOF
# simai-project: ${PROJECT_NAME}
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
MAILTO=""
* * * * * ${SIMAI_USER} cd ${PROJECT_PATH} && ${php_cli} artisan schedule:run >> /dev/null 2>&1
EOF
  chmod 644 "$cron_file" 2>/dev/null || true
  chown root:root "$cron_file" 2>/dev/null || true
  reload_cron_daemon
}

configure_queue_service() {
  if [[ ! -f $QUEUE_TEMPLATE ]]; then
    fail "queue template not found at ${QUEUE_TEMPLATE}"
  fi
  local unit_name="laravel-queue-${PROJECT_NAME}.service"
  local unit_path="/etc/systemd/system/${unit_name}"
  sed -e "s#{{PROJECT_NAME}}#${PROJECT_NAME}#g" \
      -e "s#{{PROJECT_ROOT}}#${PROJECT_PATH}#g" \
      -e "s#{{PHP_BIN}}#${PHP_BIN:-/usr/bin/php}#g" \
      -e "s#{{USER}}#${SIMAI_USER}#g" "$QUEUE_TEMPLATE" > "$unit_path"
  systemctl daemon-reload >>"$LOG_FILE" 2>&1
  systemctl enable --now "$unit_name" >>"$LOG_FILE" 2>&1 || warn "Failed to enable ${unit_name}"
}

install_stack() {
  install_packages
  install_php_stack
  install_nginx
  install_mysql
  install_redis
install_node
  install_composer
}

clean_cron() {
  local cron_file="/etc/cron.d/${PROJECT_NAME}"
  if [[ -f "$cron_file" ]]; then
    rm -f "$cron_file"
    reload_cron_daemon
  fi
}

clean_queue() {
  local unit_path="/etc/systemd/system/laravel-queue-${PROJECT_NAME}.service"
  if [[ -f $unit_path ]]; then
    systemctl disable --now "laravel-queue-${PROJECT_NAME}.service" >>"$LOG_FILE" 2>&1 || true
    rm -f "$unit_path"
    systemctl daemon-reload >>"$LOG_FILE" 2>&1 || true
  fi
}

clean_nginx() {
  local site_available="/etc/nginx/sites-available/${DOMAIN}.conf"
  local site_enabled="/etc/nginx/sites-enabled/${DOMAIN}.conf"
  rm -f "$site_enabled" "$site_available"
  if command -v nginx >/dev/null 2>&1; then
    nginx -t >>"$LOG_FILE" 2>&1 || warn "nginx test failed after cleanup"
    systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
  fi
}

clean_php_pool() {
  shopt -s nullglob
  local pools=(/etc/php/*/fpm/pool.d/${PROJECT_NAME}.conf)
  if [[ -n ${pools[*]:-} ]]; then
    rm -f "${pools[@]}"
  fi
  systemctl reload "php${PHP_VERSION}-fpm" >>"$LOG_FILE" 2>&1 || true
  for svc in /etc/init.d/php*fpm; do
    systemctl reload "$(basename "$svc" .service)" >>"$LOG_FILE" 2>&1 || true
  done
  shopt -u nullglob
}

clean_database() {
  if [[ $DROP_DB -eq 1 ]]; then
    mysql -uroot -e "DROP DATABASE IF EXISTS \`${DB_NAME}\`;" >>"$LOG_FILE" 2>&1 || warn "Failed to drop database ${DB_NAME}"
  fi
  if [[ $DROP_DB_USER -eq 1 ]]; then
    mysql -uroot -e "DROP USER IF EXISTS '${DB_USER}'@'127.0.0.1';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop user ${DB_USER}@127.0.0.1"
    mysql -uroot -e "DROP USER IF EXISTS '${DB_USER}'@'localhost';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop user ${DB_USER}@localhost"
    mysql -uroot -e "DROP USER IF EXISTS '${DB_USER}'@'%';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop legacy wildcard user ${DB_USER}@%"
  fi
}

clean_project_files() {
  if [[ $REMOVE_FILES -eq 1 && -n $PROJECT_PATH && $PROJECT_PATH != "/" ]]; then
    if ! validate_path "$PROJECT_PATH"; then
      warn "Skipping project file removal due to unsafe path: ${PROJECT_PATH}"
      return
    fi
    info "Removing project files at ${PROJECT_PATH}"
    rm -rf "$PROJECT_PATH"
  fi
}

install_flow() {
  info "Starting simai environment install"
  ensure_user
  prepare_project_paths
  install_stack
  create_database
  if [[ $DEPLOY_MODE == "existing" ]]; then
    configure_existing_project
  else
    deploy_new_project
  fi
  configure_env
  finalize_laravel
  configure_php_pool
  configure_nginx_site
  configure_cron
  configure_queue_service
  info "Installation complete for ${PROJECT_NAME}"
}

clean_flow() {
  info "Starting cleanup for ${PROJECT_NAME}"
  clean_cron
  clean_queue
  clean_nginx
  clean_php_pool
  clean_database
  clean_project_files
  info "Cleanup complete"
}

main() {
  parse_args "$@"
  ensure_defaults
  require_root
  require_supported_os
  mkdir -p "$(dirname "$LOG_FILE")"
  touch "$LOG_FILE"
  if [[ $ACTION == "clean" ]]; then
    clean_flow
  else
    install_flow
  fi
}

main "$@"
