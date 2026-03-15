# shellcheck disable=SC2034 # profile metadata variables are sourced by admin scripts
# Identification
PROFILE_ID="bitrix"
PROFILE_TITLE="1C-Bitrix site"

# Filesystem / bootstrap
PROFILE_PUBLIC_DIR="public"
PROFILE_BOOTSTRAP_FILES=("public/index.php" "public/bitrix/.settings.php")
PROFILE_WRITABLE_PATHS=("public/upload" "public/bitrix/cache" "public/bitrix/managed_cache" "public/bitrix/stack_cache")
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_NGINX_TEMPLATE="nginx-bitrix.conf"
PROFILE_REQUIRED_MARKERS=()
PROFILE_HEALTHCHECK_MODE="php"

# PHP runtime
PROFILE_REQUIRES_PHP="yes"
PROFILE_ALLOWED_PHP_VERSIONS=("8.2" "8.3" "8.4")
PROFILE_PHP_EXTENSIONS_REQUIRED=("curl" "dom" "fileinfo" "gd" "intl" "json" "mbstring" "mysqli" "opcache" "xml" "zip")
PROFILE_PHP_EXTENSIONS_RECOMMENDED=()
PROFILE_PHP_EXTENSIONS_OPTIONAL=()
PROFILE_PHP_INI_REQUIRED=("short_open_tag=1" "memory_limit=512M" "max_input_vars=10000" "opcache.revalidate_freq=0" "opcache.validate_timestamps=1")
PROFILE_PHP_INI_RECOMMENDED=("max_execution_time=300" "max_input_time=300" "post_max_size=64M" "upload_max_filesize=64M" "realpath_cache_size=4096K" "realpath_cache_ttl=600" "opcache.enable=1" "opcache.memory_consumption=256" "opcache.interned_strings_buffer=16" "opcache.max_accelerated_files=20000")
PROFILE_PHP_INI_FORBIDDEN=()
PROFILE_BITRIX_SHORT_INSTALL_DEFAULT="yes"

# Database
PROFILE_REQUIRES_DB="required"
PROFILE_DB_ENGINE="mysql"
PROFILE_DB_CHARSET="utf8mb4"
PROFILE_DB_COLLATION="utf8mb4_unicode_ci"
PROFILE_DB_REQUIRED_PRIVILEGES=()

# Background processes
PROFILE_SUPPORTS_CRON="yes"
PROFILE_CRON_RECOMMENDED=("* * * * * php public/bitrix/modules/main/tools/cron_events.php >/dev/null 2>&1")
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
