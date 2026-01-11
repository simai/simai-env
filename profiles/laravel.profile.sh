# shellcheck disable=SC2034 # profile metadata variables are sourced by admin scripts
# Identification
PROFILE_ID="laravel"
PROFILE_TITLE="Laravel application"

# Filesystem / bootstrap
PROFILE_PUBLIC_DIR="public"
PROFILE_BOOTSTRAP_FILES=("public/index.php" "artisan" "bootstrap/app.php")
PROFILE_WRITABLE_PATHS=("storage" "bootstrap/cache")
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_NGINX_TEMPLATE="nginx-laravel.conf"
PROFILE_REQUIRED_MARKERS=("artisan" "bootstrap/app.php")
PROFILE_HEALTHCHECK_MODE="php"

# PHP runtime
PROFILE_REQUIRES_PHP="yes"
PROFILE_ALLOWED_PHP_VERSIONS=("8.1" "8.2" "8.3")
PROFILE_PHP_EXTENSIONS_REQUIRED=("bcmath" "ctype" "curl" "dom" "fileinfo" "mbstring" "openssl" "pdo" "pdo_mysql" "tokenizer" "xml")
PROFILE_PHP_EXTENSIONS_RECOMMENDED=("intl" "gd" "zip" "opcache" "redis")
PROFILE_PHP_EXTENSIONS_OPTIONAL=()
PROFILE_PHP_INI_REQUIRED=()
PROFILE_PHP_INI_RECOMMENDED=()
PROFILE_PHP_INI_FORBIDDEN=()

# Database
PROFILE_REQUIRES_DB="required"
PROFILE_DB_ENGINE="mysql"
PROFILE_DB_CHARSET="utf8mb4"
PROFILE_DB_COLLATION="utf8mb4_unicode_ci"
PROFILE_DB_REQUIRED_PRIVILEGES=()

# Background processes
PROFILE_SUPPORTS_CRON="yes"
PROFILE_CRON_RECOMMENDED=("* * * * * php artisan schedule:run")
PROFILE_SUPPORTS_QUEUE="yes"
PROFILE_QUEUE_SYSTEM="laravel"

# Security constraints
PROFILE_ALLOW_ALIAS="no"
PROFILE_ALLOW_PHP_SWITCH="yes"
PROFILE_ALLOW_SHARED_POOL="no"
PROFILE_ALLOW_DB_REMOVAL="yes"

# Hooks (declarative placeholders)
PROFILE_HOOKS_PRE_CREATE=()
PROFILE_HOOKS_POST_CREATE=()
PROFILE_HOOKS_PRE_REMOVE=()
PROFILE_HOOKS_POST_REMOVE=()
