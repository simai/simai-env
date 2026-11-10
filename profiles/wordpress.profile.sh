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
PROFILE_ALLOWED_PHP_VERSIONS=()
PROFILE_ALLOWED_PHP_MIN_VERSION="8.1"
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

# Site creation routes of the panel wizard (self profiles; format in
# lib/site_profiles.py). Both are planned until the WordPress steps land.
PROFILE_ROUTES=("new|yes|New site: WordPress is installed automatically" "restore|yes|Restore from a files archive and an SQL dump")
PROFILE_ROUTE_NEW_INPUTS=("domain|yes|text" "php|no|choice" "title|yes|text" "admin-user|yes|text" "admin-email|yes|text" "locale|no|text")
PROFILE_ROUTE_NEW_STEPS=("add|site:add||Create the site: PHP, database, scheduler" "prepare|wp:install||Install WordPress: core, configuration, administrator (password shown once)" "finalize|wp:finalize||Finish the setup" "done|site:doctor||Check the site")
PROFILE_ROUTE_RESTORE_INPUTS=("domain|yes|text" "php|no|choice" "files|yes|file_on_server" "dump|yes|file_on_server")
PROFILE_ROUTE_RESTORE_STEPS=("add|site:add||Create the site: PHP, database, scheduler" "upload|file:upload||Put the files archive and the SQL dump into the site directory" "install|wp:restore-ready||Restore files and database, rewrite the site address" "finalize|wp:finalize||Finish the setup" "done|site:doctor||Check the site")

# Server resources: memory below the minimum refuses site add and restore
# plans, below the recommendation warns (MB, 0: no need).
PROFILE_MIN_RAM_MB="512"
PROFILE_RECOMMENDED_RAM_MB="1024"

# Hooks (declarative placeholders)
PROFILE_HOOKS_PRE_CREATE=()
PROFILE_HOOKS_POST_CREATE=()
PROFILE_HOOKS_PRE_REMOVE=()
PROFILE_HOOKS_POST_REMOVE=()
