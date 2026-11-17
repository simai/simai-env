#!/usr/bin/env bash

# A temporary database browser for one site (site db-browser /
# db-browser-close / db-browser-status, 1.58.0).
#
# Adminer (a single PHP file, pinned by version and SHA-256) runs in the
# site's own PHP-FPM pool, as the site's user, behind a secret path on the
# site's own HTTPS address: https://<domain>/.simai-db/<token>/. It is signed
# in to the site's database only: a small wrapper fixes the driver, server,
# user and database and never shows the password. Opening it again gives a
# new address; the old one stops working.
#
# Files:
#   /etc/nginx/simai-tools/<project>.conf      the location (every PHP site
#                                               template includes it)
#   /etc/simai-env/db-browser/<project>.php    the wrapper, readable by the
#                                               site's user only (it holds the
#                                               site's own database password)
#   /etc/simai-env/db-browser/<project>.env    domain, token, expiry (root)
#
# It closes by itself: a systemd timer at the deadline, the five-minute
# status refresh after a reboot, and the wrapper refuses to work past the
# deadline even if both were missed.

SIMAI_TOOLS_NGINX_DIR="${SIMAI_TOOLS_NGINX_DIR:-/etc/nginx/simai-tools}"
SIMAI_DB_BROWSER_DIR="${SIMAI_DB_BROWSER_DIR:-/etc/simai-env/db-browser}"
SIMAI_ADMINER_VERSION="6.3.0"
SIMAI_ADMINER_SHA256="641e1a31e8cc333a309e202ef9446e1fd38c2069ed5f9ee509b80d70089d0503"
SIMAI_ADMINER_URL="https://github.com/vrana/adminer/releases/download/v${SIMAI_ADMINER_VERSION}/adminer-${SIMAI_ADMINER_VERSION}.php"
SIMAI_ADMINER_DIR="${SIMAI_ADMINER_DIR:-/usr/local/share/simai-env/adminer}"

db_browser_adminer_path() {
  printf '%s/adminer-%s.php\n' "$SIMAI_ADMINER_DIR" "$SIMAI_ADMINER_VERSION"
}

# Downloads Adminer once and keeps it only when the checksum matches.
# SIMAI_ADMINER_FILE: a local copy to use instead (offline servers, tests);
# it must match the same checksum.
db_browser_adminer_ensure() {
  local dest tmp
  dest=$(db_browser_adminer_path)
  if [[ -f "$dest" ]] && [[ "$(sha256sum "$dest" | awk '{print $1}')" == "$SIMAI_ADMINER_SHA256" ]]; then
    return 0
  fi
  install -d -m 0755 -o root -g root "$SIMAI_ADMINER_DIR"
  tmp=$(mktemp)
  if [[ -n "${SIMAI_ADMINER_FILE:-}" ]]; then
    cp -- "$SIMAI_ADMINER_FILE" "$tmp" || { rm -f "$tmp"; error "Cannot read ${SIMAI_ADMINER_FILE}"; return 1; }
  elif ! curl -fsSL --max-time 60 -o "$tmp" "$SIMAI_ADMINER_URL" >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
    rm -f "$tmp"
    error "Could not download Adminer ${SIMAI_ADMINER_VERSION} from github.com"
    return 1
  fi
  if [[ "$(sha256sum "$tmp" | awk '{print $1}')" != "$SIMAI_ADMINER_SHA256" ]]; then
    rm -f "$tmp"
    error "Adminer ${SIMAI_ADMINER_VERSION} does not match its checksum; nothing installed"
    return 1
  fi
  install -m 0644 -o root -g root "$tmp" "$dest"
  rm -f "$tmp"
}

db_browser_state_file() { printf '%s/%s.env\n' "$SIMAI_DB_BROWSER_DIR" "$1"; }
db_browser_wrapper_file() { printf '%s/%s.php\n' "$SIMAI_DB_BROWSER_DIR" "$1"; }
db_browser_nginx_file() { printf '%s/%s.conf\n' "$SIMAI_TOOLS_NGINX_DIR" "$1"; }

db_browser_state_get() {
  local project="$1" key="$2" file
  file=$(db_browser_state_file "$project")
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=//p" "$file" | head -n1
}

# Sites rendered before 1.58.0 lack the include; it goes after the site's
# own directives (or the pause page, or the access rules).
db_browser_include_ensure() {
  local conf="$1" project="$2" anchor
  grep -qF "simai-tools/${project}[.]conf" "$conf" && return 0
  for anchor in simai-custom simai-suspend simai-access; do
    if grep -qF "${anchor}/${project}[.]conf" "$conf"; then
      sed -i -E "s#^([[:space:]]*)(include [^;]*${anchor}/${project}\[\.\]conf;)#\1\2\n\1include ${SIMAI_TOOLS_NGINX_DIR}/${project}[.]conf;#" "$conf"
      break
    fi
  done
  grep -qF "simai-tools/${project}[.]conf" "$conf"
}

# Loads DBB_* for a site and refuses what cannot have a browser.
db_browser_context() {
  local domain="$1" key val
  read_site_metadata "$domain" || { error "Failed to read site metadata for ${domain}"; return 1; }
  DBB_DOMAIN="$domain"
  DBB_PROJECT="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  DBB_PHP="${SITE_META[php]:-none}"
  DBB_SOCKET_PROJECT="${SITE_META[php_socket_project]:-$DBB_PROJECT}"
  validate_project_slug "$DBB_PROJECT" || return 1
  DBB_ENGINE="" DBB_NAME="" DBB_USER="" DBB_PASS="" DBB_HOST=""
  while IFS='|' read -r key val; do
    case "$key" in
      DB_ENGINE) DBB_ENGINE="$val" ;;
      DB_NAME) DBB_NAME="$val" ;;
      DB_USER) DBB_USER="$val" ;;
      DB_PASS) DBB_PASS="$val" ;;
      DB_HOST) DBB_HOST="$val" ;;
    esac
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  [[ -n "$DBB_ENGINE" ]] || DBB_ENGINE=$(site_db_engine "$domain" 2>/dev/null || echo mysql)
  return 0
}

db_browser_check() {
  local domain="$1" ext
  if [[ -z "$DBB_NAME" || -z "$DBB_USER" || -z "$DBB_PASS" ]]; then
    error "${domain} has no database of its own (site db-create --domain ${domain} creates one)"
    return 1
  fi
  [[ "$DBB_ENGINE" == mysql || "$DBB_ENGINE" == pgsql ]] || { error "Database engine ${DBB_ENGINE} is not supported"; return 1; }
  if [[ "$DBB_PHP" == none || -z "$DBB_PHP" ]]; then
    error "${domain} has no PHP; the database browser runs in the site's PHP pool"
    return 1
  fi
  if [[ "$DBB_SOCKET_PROJECT" != "$DBB_PROJECT" ]]; then
    error "${domain} shares the PHP pool of another site; open the browser on that site"
    return 1
  fi
  if ! site_ssl_meta_is_enabled "${SITE_META[ssl]:-none}"; then
    error "${domain} has no HTTPS certificate; the browser opens only over HTTPS (ssl letsencrypt --domain ${domain})"
    return 1
  fi
  if declare -F site_is_suspended >/dev/null && site_is_suspended "$domain"; then
    error "${domain} is paused (site resume --domain ${domain})"
    return 1
  fi
  [[ -S "/run/php/php${DBB_PHP}-fpm-${DBB_PROJECT}.sock" || -f "/etc/php/${DBB_PHP}/fpm/pool.d/${DBB_PROJECT}.conf" ]] \
    || { error "The PHP pool of ${domain} is missing (site doctor --domain ${domain})"; return 1; }
  if [[ "$DBB_ENGINE" == pgsql ]]; then ext='^(pgsql|pdo_pgsql)$'; else ext='^(mysqli|pdo_mysql)$'; fi
  if command -v "php${DBB_PHP}" >/dev/null 2>&1 && ! "php${DBB_PHP}" -m 2>/dev/null | grep -Eq "$ext"; then
    error "PHP ${DBB_PHP} has no ${DBB_ENGINE} driver (package php${DBB_PHP}-${DBB_ENGINE})"
    return 1
  fi
  return 0
}

# Refusals a plan can already name (command_plan_check).
db_browser_plan_check() {
  local domain minutes
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  minutes=$(command_arg minutes "$@")
  if [[ -n "$minutes" ]] && ! [[ "$minutes" =~ ^[0-9]{1,3}$ && "$minutes" -ge 5 && "$minutes" -le 480 ]]; then
    error "--minutes must be between 5 and 480"
    return 1
  fi
  db_browser_context "$domain" || return 1
  db_browser_check "$domain"
}

# PHP string literal for a value (single quotes, backslashes and quotes escaped).
db_browser_php_str() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\'/\\\'}"
  printf "'%s'" "$v"
}

db_browser_wrapper_render() {
  local expires="$1" drv="server" host="${DBB_HOST:-localhost}"
  [[ "$DBB_ENGINE" == pgsql ]] && drv="pgsql"
  cat <<EOF
<?php
// simai-env: database browser of ${DBB_DOMAIN}; managed by: simai-admin.sh site db-browser
// Signed in to this site's database only; closes at $(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ).
if (time() > ${expires}) { http_response_code(410); header('Cache-Control: no-store'); echo "Closed.\n"; exit; }
const SIMAI_DBB = [
    'driver' => $(db_browser_php_str "$drv"),
    'server' => $(db_browser_php_str "$host"),
    'username' => $(db_browser_php_str "$DBB_USER"),
    'password' => $(db_browser_php_str "$DBB_PASS"),
    'db' => $(db_browser_php_str "$DBB_NAME"),
    'title' => $(db_browser_php_str "$DBB_DOMAIN"),
];
// One driver, one server, one user, one database: whatever the address says.
foreach (['server', 'sqlite', 'pgsql', 'oracle', 'mssql', 'mongo', 'elastic', 'clickhouse', 'firebird', 'simpledb', 'ext'] as \$k) {
    unset(\$_GET[\$k]);
}
\$_GET[SIMAI_DBB['driver']] = SIMAI_DBB['driver'] === 'server' ? '' : SIMAI_DBB['server'];
\$_GET['username'] = SIMAI_DBB['username'];
\$_GET['db'] = SIMAI_DBB['db'];
unset(\$_POST['auth']);

function adminer_object() {
    // The session holds a marker, never the password: credentials() gives it.
    \$_SESSION['pwds'][SIMAI_DBB['driver']][\$_GET[SIMAI_DBB['driver']]][SIMAI_DBB['username']] = 'simai';
    class SimaiDbBrowser extends \Adminer\Adminer {
        function name() { return 'Adminer · ' . htmlspecialchars(SIMAI_DBB['title']); }
        function credentials() { return [SIMAI_DBB['server'], SIMAI_DBB['username'], SIMAI_DBB['password']]; }
        function login(\$login, \$password) { return true; }
        function database() { return SIMAI_DBB['db']; }
        function databases(\$flush = true) { return [SIMAI_DBB['db']]; }
        function permanentLogin(\$create = false) { return ''; }
        function loginForm() {}
    }
    return new SimaiDbBrowser;
}
include $(db_browser_php_str "$(db_browser_adminer_path)");
EOF
}

db_browser_nginx_render() {
  local token="$1" wrapper="$2"
  cat <<EOF
# simai-env: database browser of ${DBB_DOMAIN}; managed by: simai-admin.sh site db-browser
location ^~ /.simai-db/ {
    return 404;
}
location ^~ /.simai-db/${token}/ {
    if (\$scheme != "https") { return 404; }
    access_log off;
    client_max_body_size 256m;
    fastcgi_read_timeout 600s;
    fastcgi_hide_header Referrer-Policy;
    fastcgi_hide_header Cache-Control;
    fastcgi_hide_header X-Content-Type-Options;
    add_header Referrer-Policy "no-referrer" always;
    add_header Cache-Control "no-store" always;
    add_header X-Robots-Tag "noindex, nofollow" always;
    add_header X-Content-Type-Options "nosniff" always;
    include fastcgi_params;
    fastcgi_param SCRIPT_FILENAME ${wrapper};
    fastcgi_param SCRIPT_NAME /.simai-db/${token}/;
    fastcgi_param HTTPS on;
    fastcgi_pass unix:/run/php/php${DBB_PHP}-fpm-${DBB_PROJECT}.sock;
}
EOF
}

# Writes the location and reloads nginx; on refusal everything goes back.
db_browser_nginx_apply() {
  local conf="/etc/nginx/sites-available/${DBB_DOMAIN}.conf" body="$1"
  local inc backup inc_backup="" out
  inc=$(db_browser_nginx_file "$DBB_PROJECT")
  [[ -f "$conf" ]] || { error "nginx config not found for ${DBB_DOMAIN}"; return 1; }
  backup=$(mktemp); cp -p "$conf" "$backup"
  if [[ -f "$inc" ]]; then inc_backup=$(mktemp); cp -p "$inc" "$inc_backup"; fi
  if [[ -n "$body" ]]; then
    install -d -m 0755 "$SIMAI_TOOLS_NGINX_DIR"
    if ! db_browser_include_ensure "$conf" "$DBB_PROJECT"; then
      cp -p "$backup" "$conf"; rm -f "$backup" "$inc_backup"
      error "Cannot find where to include ${inc} in ${conf}"
      return 1
    fi
    printf '%s\n' "$body" >"${inc}.tmp"
    chmod 0644 "${inc}.tmp"
    mv -f "${inc}.tmp" "$inc"
  else
    rm -f -- "$inc"
  fi
  if ! out=$(nginx -t 2>&1); then
    echo "$out" >>"${LOG_FILE:-/var/log/simai-admin.log}"
    cp -p "$backup" "$conf"
    if [[ -n "$inc_backup" ]]; then cp -p "$inc_backup" "$inc"; else rm -f -- "$inc"; fi
    rm -f "$backup" "$inc_backup"
    error "nginx refused the configuration of ${DBB_DOMAIN}; nothing changed"
    return 1
  fi
  rm -f "$backup" "$inc_backup"
  os_svc_reload_or_restart nginx >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || true
}

# Removes everything of a project's browser (nginx reload included when
# the location existed). Used by close, expiry and site remove.
db_browser_teardown() {
  local project="$1" domain="${2:-}" inc
  inc=$(db_browser_nginx_file "$project")
  systemctl stop "simai-dbbrowser-${project}.timer" >/dev/null 2>&1 || true
  rm -f -- "$(db_browser_wrapper_file "$project")" "$(db_browser_state_file "$project")"
  if [[ -f "$inc" ]]; then
    rm -f -- "$inc"
    if nginx -t >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
      os_svc_reload_or_restart nginx >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || true
    fi
  fi
  return 0
}

db_browser_wait_ready() {
  local domain="$1" token="$2" code
  command -v curl >/dev/null 2>&1 || return 0
  for _ in $(seq 1 20); do
    code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 3 --resolve "${domain}:443:127.0.0.1" \
      "https://${domain}/.simai-db/${token}/?file=logo.svg" 2>/dev/null || true)
    [[ "$code" == 200 ]] && return 0
    sleep 0.5
  done
  warn "The database browser of ${domain} did not answer yet; try the address in a few seconds"
  return 0
}

site_db_browser_handler() {
  parse_kv_args "$@"
  local domain minutes token expires wrapper group site_user url
  domain=$(site_pick_existing_domain "${PARSED_ARGS[domain]:-}") || return $?
  [[ -z "$domain" ]] && return 0
  minutes="${PARSED_ARGS[minutes]:-60}"
  db_browser_plan_check --domain "$domain" --minutes "$minutes" || return 1
  db_browser_adminer_ensure || return 1
  token=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  expires=$(( $(date +%s) + minutes * 60 ))
  wrapper=$(db_browser_wrapper_file "$DBB_PROJECT")
  site_user=$(site_effective_user "$DBB_PROJECT")
  group=$(id -gn "$site_user" 2>/dev/null) || { error "Site user ${site_user} not found"; return 1; }
  install -d -m 0711 -o root -g root "$SIMAI_DB_BROWSER_DIR"
  (umask 077; db_browser_wrapper_render "$expires" >"${wrapper}.tmp") || return 1
  chown "root:${group}" "${wrapper}.tmp" && chmod 0640 "${wrapper}.tmp" && mv -f "${wrapper}.tmp" "$wrapper" || return 1
  if ! db_browser_nginx_apply "$(db_browser_nginx_render "$token" "$wrapper")"; then
    rm -f -- "$wrapper"
    return 1
  fi
  (umask 077; printf 'DOMAIN=%s\nTOKEN=%s\nEXPIRES=%s\n' "$domain" "$token" "$expires" >"$(db_browser_state_file "$DBB_PROJECT")")
  systemctl stop "simai-dbbrowser-${DBB_PROJECT}.timer" >/dev/null 2>&1 || true
  systemd-run --unit="simai-dbbrowser-${DBB_PROJECT}" --on-active="${minutes}m" --timer-property=AccuracySec=10s \
    --collect --quiet --setenv=SIMAI_ADMIN_MENU=0 \
    "${SIMAI_ENV_ROOT}/simai-admin.sh" site db-browser-close --domain "$domain" --confirm yes >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 \
    || warn "The closing timer did not start; the browser still stops at the deadline and the status refresh removes it"
  url="https://${domain}/.simai-db/${token}/"
  # nginx reloads in the background: wait (up to 10 s) until the new address
  # answers here, so the link works the moment it is handed out.
  db_browser_wait_ready "$domain" "$token"
  local expires_iso
  expires_iso=$(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "${SIMAI_JOB_RESULT:-}" ]]; then
    # The address opens the database: the panel gets it once, the job log never.
    printf '{"browser_url":"%s","expires_at":"%s","engine":"%s","database":"%s"}\n' \
      "$url" "$expires_iso" "$DBB_ENGINE" "$DBB_NAME" >"$SIMAI_JOB_RESULT"
    url="(handed to the panel)"
  fi
  ui_header "SIMAI ENV · Database browser"
  ui_result_table \
    "Domain|${domain}" \
    "Database|${DBB_NAME} (${DBB_ENGINE})" \
    "Address|${url}" \
    "Closes at|${expires_iso}"
  ui_next_steps
  ui_kv "Close now" "simai-admin.sh site db-browser-close --domain ${domain} --confirm yes"
}

site_db_browser_close_handler() {
  parse_kv_args "$@"
  local domain project
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" allow || return 1
  project=$(site_project_for_domain "$domain" 2>/dev/null || true)
  [[ -n "$project" ]] || project=$(project_slug_from_domain "$domain")
  validate_project_slug "$project" || return 1
  local was=no
  [[ -f "$(db_browser_state_file "$project")" || -f "$(db_browser_nginx_file "$project")" ]] && was=yes
  db_browser_teardown "$project" "$domain"
  ui_result_table "Domain|${domain}" "Database browser|$([[ $was == yes ]] && echo closed || echo 'was not open')"
}

site_db_browser_status_handler() {
  parse_kv_args "$@"
  local domain project expires open=false expires_iso=""
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  project=$(site_project_for_domain "$domain" 2>/dev/null || true)
  [[ -n "$project" ]] || project=$(project_slug_from_domain "$domain")
  expires=$(db_browser_state_get "$project" EXPIRES 2>/dev/null || true)
  if [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > $(date +%s) )) && [[ -f "$(db_browser_nginx_file "$project")" ]]; then
    open=true
    expires_iso=$(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ)
  fi
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '{"schema":"simai-db-browser/1","domain":"%s","open":%s,"expires_at":%s}\n' \
      "$domain" "$open" "$([[ -n "$expires_iso" ]] && printf '"%s"' "$expires_iso" || echo null)"
  else
    ui_result_table "Domain|${domain}" "Database browser|$([[ $open == true ]] && echo "open until ${expires_iso}" || echo closed)"
  fi
}

# Status refresh: browsers past their deadline (their timer lost to a reboot).
db_browser_expire_all() {
  local file project expires now
  now=$(date +%s)
  for file in "$SIMAI_DB_BROWSER_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    project=$(basename "$file" .env)
    validate_project_slug "$project" >/dev/null 2>&1 || continue
    expires=$(db_browser_state_get "$project" EXPIRES 2>/dev/null || true)
    [[ "$expires" =~ ^[0-9]+$ ]] && (( expires > now )) && continue
    db_browser_teardown "$project"
  done
  return 0
}

register_cmd "site" "db-browser" "Open a temporary database browser (Adminer) for a site on its HTTPS address" "site_db_browser_handler" "domain" "minutes=" "menu:confirm"
register_cmd "site" "db-browser-close" "Close a site's database browser now" "site_db_browser_close_handler" "domain" "" "menu:confirm"
register_cmd "site" "db-browser-status" "Is a site's database browser open, and until when" "site_db_browser_status_handler" "domain" "" "effects:read"
