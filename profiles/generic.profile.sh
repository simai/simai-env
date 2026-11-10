# shellcheck disable=SC2034 # profile metadata variables are sourced by admin scripts
# Identification
PROFILE_ID="generic"
PROFILE_TITLE="Generic PHP site"

# Filesystem / bootstrap
PROFILE_PUBLIC_DIR="public"
PROFILE_BOOTSTRAP_FILES=("public/index.php")
PROFILE_WRITABLE_PATHS=()
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_NGINX_TEMPLATE="nginx-generic.conf"
PROFILE_REQUIRED_MARKERS=()
PROFILE_HEALTHCHECK_MODE="php"

# PHP runtime
PROFILE_REQUIRES_PHP="yes"
PROFILE_ALLOWED_PHP_VERSIONS=()
PROFILE_ALLOWED_PHP_MIN_VERSION="8.1"
PROFILE_PHP_EXTENSIONS_REQUIRED=("curl" "mbstring" "xml" "zip" "pdo" "pdo_mysql")
PROFILE_PHP_EXTENSIONS_RECOMMENDED=("intl" "gd" "opcache")
PROFILE_PHP_EXTENSIONS_OPTIONAL=()
PROFILE_PHP_INI_REQUIRED=()
PROFILE_PHP_INI_RECOMMENDED=()
PROFILE_PHP_INI_FORBIDDEN=()

# Database
PROFILE_REQUIRES_DB="optional"
PROFILE_DB_ENGINE="mysql"
# Engines a site of this profile may use (site add --db-engine).
PROFILE_DB_ENGINES_ALLOWED=("mysql" "pgsql")
PROFILE_DB_CHARSET="utf8mb4"
PROFILE_DB_COLLATION="utf8mb4_unicode_ci"
PROFILE_DB_REQUIRED_PRIVILEGES=()

# Background processes
PROFILE_SUPPORTS_CRON="no"
PROFILE_CRON_RECOMMENDED=()
PROFILE_SUPPORTS_QUEUE="no"
PROFILE_QUEUE_SYSTEM="none"

# Security constraints
PROFILE_ALLOW_ALIAS="no"
PROFILE_ALLOW_PHP_SWITCH="yes"
PROFILE_ALLOW_SHARED_POOL="no"
PROFILE_ALLOW_DB_REMOVAL="yes"

# Site creation routes of the panel wizard (self profiles; format in
# lib/site_profiles.py). restore (files archive and SQL dump) is planned:
# no command restores them yet.
PROFILE_ROUTES=("new|yes|New site: PHP and a database, upload the code yourself" "restore|no|Restore from a files archive and an SQL dump")
PROFILE_ROUTE_NEW_INPUTS=("domain|yes|text" "php|no|choice" "create-db|no|choice" "db-engine|no|choice")
PROFILE_ROUTE_NEW_STEPS=("add|site:add||Create the site: PHP and a database" "done|site:doctor||Check the site")
PROFILE_ROUTE_RESTORE_INPUTS=("domain|yes|text" "php|no|choice" "archive|yes|file_on_server" "dump|yes|file_on_server")
PROFILE_ROUTE_RESTORE_STEPS=("add|site:add||Create the site: PHP and a database" "upload|file:upload||Upload the files archive and the SQL dump" "done|site:doctor||Check the site")

# Server resources: memory below the minimum refuses site add and restore
# plans, below the recommendation warns (MB, 0: no need).
PROFILE_MIN_RAM_MB="256"
PROFILE_RECOMMENDED_RAM_MB="512"

# Hooks (declarative placeholders)
PROFILE_HOOKS_PRE_CREATE=()
PROFILE_HOOKS_POST_CREATE=()
PROFILE_HOOKS_PRE_REMOVE=()
PROFILE_HOOKS_POST_REMOVE=()
