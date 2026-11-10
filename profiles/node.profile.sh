# shellcheck disable=SC2034 # profile metadata variables are sourced by admin scripts
# Identification
PROFILE_ID="node"
PROFILE_TITLE="Node.js service (long-running, behind nginx)"

# Filesystem / bootstrap. public/ stays outside releases: it only serves
# ACME challenges; every other request goes to the service (see site deploy).
PROFILE_PUBLIC_DIR="public"
PROFILE_BOOTSTRAP_FILES=()
PROFILE_WRITABLE_PATHS=()
PROFILE_HEALTHCHECK_ENABLED="yes"
PROFILE_NGINX_TEMPLATE="nginx-node.conf"
PROFILE_REQUIRED_MARKERS=()
PROFILE_HEALTHCHECK_MODE="nginx"

# PHP runtime
PROFILE_REQUIRES_PHP="no"
PROFILE_ALLOWED_PHP_VERSIONS=()
PROFILE_PHP_EXTENSIONS_REQUIRED=()
PROFILE_PHP_EXTENSIONS_RECOMMENDED=()
PROFILE_PHP_EXTENSIONS_OPTIONAL=()
PROFILE_PHP_INI_REQUIRED=()
PROFILE_PHP_INI_RECOMMENDED=()
PROFILE_PHP_INI_FORBIDDEN=()

# Database
PROFILE_REQUIRES_DB="no"
PROFILE_DB_ENGINE="mysql"
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
PROFILE_ALLOW_PHP_SWITCH="no"
PROFILE_ALLOW_SHARED_POOL="no"
PROFILE_ALLOW_DB_REMOVAL="no"

# Site creation routes of the panel wizard (self profiles; format in
# lib/site_profiles.py). Step ids are the steps site status answers.
PROFILE_ROUTES=("repo|yes|Deploy the service from a Git repository")
PROFILE_ROUTE_REPO_INPUTS=("domain|yes|text" "app-port|no|text" "git|yes|url" "ref|yes|text")
PROFILE_ROUTE_REPO_STEPS=("add|site:add||Create the site and its service" "deploy|site:deploy||Deploy the release from Git" "done|site:doctor||Check the site")

# Server resources: memory below the minimum refuses site add and restore
# plans, below the recommendation warns (MB, 0: no need).
PROFILE_MIN_RAM_MB="512"
PROFILE_RECOMMENDED_RAM_MB="1024"

# Hooks (declarative placeholders)
PROFILE_HOOKS_PRE_CREATE=()
PROFILE_HOOKS_POST_CREATE=()
PROFILE_HOOKS_PRE_REMOVE=()
PROFILE_HOOKS_POST_REMOVE=()
