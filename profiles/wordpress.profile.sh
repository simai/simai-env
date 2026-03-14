# shellcheck disable=SC2034 # profile metadata variables are sourced by admin scripts
# Identification
PROFILE_ID="wordpress"
PROFILE_TITLE="WordPress site"

# Filesystem / bootstrap
PROFILE_PUBLIC_DIR="public"
PROFILE_BOOTSTRAP_FILES=("public/index.php" "public/wp-config.php")
PROFILE_WRITABLE_PATHS=("public/wp-content/uploads")
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_NGINX_TEMPLATE="nginx-wordpress.conf"
PROFILE_REQUIRED_MARKERS=()
PROFILE_HEALTHCHECK_MODE="php"

# PHP runtime
PROFILE_REQUIRES_PHP="yes"
PROFILE_ALLOWED_PHP_VERSIONS=("8.1" "8.2" "8.3")
PROFILE_PHP_EXTENSIONS_REQUIRED=("curl" "dom" "exif" "fileinfo" "gd" "intl" "mbstring" "mysqli" "opcache" "xml" "zip")
PROFILE_PHP_EXTENSIONS_RECOMMENDED=()
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
PROFILE_CRON_RECOMMENDED=("*/5 * * * * php public/wp-cron.php >/dev/null 2>&1")
PROFILE_SUPPORTS_QUEUE="no"
PROFILE_QUEUE_SYSTEM="none"

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
