#!/usr/bin/env bash

# Pause and resume a site (site suspend / site resume; runtime-suspend and
# runtime-resume are the older names of the same commands).
#
# Paused: nginx answers every request with a 503 page and Retry-After (the
# ACME challenge still works, so certificates renew); the scheduler file,
# the user cron jobs, the queue workers / app service and the site's own
# PHP-FPM pool are stopped. Files and databases are not touched.
#
# The page lives in /etc/nginx/simai-suspend/<project>.conf, which every
# site template includes at server level, so commands that render the
# site's nginx again (set-php, ssl, names, nginx-custom, apache) keep it.
# What was stopped is recorded in /etc/simai-env/sites/<domain>/runtime.env;
# resume starts exactly that again. Everything lives in files and in
# systemd's enabled state, so a pause survives a reboot and self migrate.

SIMAI_SUSPEND_NGINX_DIR="${SIMAI_SUSPEND_NGINX_DIR:-/etc/nginx/simai-suspend}"
SITE_SUSPEND_RETRY_AFTER="${SITE_SUSPEND_RETRY_AFTER:-3600}"

site_is_suspended() {
  [[ "$(site_runtime_state "$1")" == suspended ]]
}

site_suspend_stub_file() {
  printf '%s/%s.conf\n' "$SIMAI_SUSPEND_NGINX_DIR" "$1"
}

site_suspend_stub_render() {
  local domain="$1"
  cat <<EOF
# simai-env: ${domain} is paused; managed by: simai-admin.sh site suspend|resume
error_page 503 @simai_suspended;
if (\$request_uri !~ "^/[.]well-known/acme-challenge/") { return 503; }
location @simai_suspended {
    internal;
    default_type text/html;
    charset utf-8;
    add_header Retry-After ${SITE_SUSPEND_RETRY_AFTER} always;
    add_header Cache-Control "no-store" always;
    add_header X-Robots-Tag "noindex" always;
    return 503 '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="robots" content="noindex"><title>503 Service Unavailable</title><style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;font-family:system-ui,-apple-system,Segoe UI,Roboto,sans-serif;background:#f5f6f8;color:#222}main{text-align:center;padding:24px;max-width:560px}h1{font-size:24px;margin:0 0 12px}p{margin:6px 0;color:#555}</style></head><body><main><h1>Сайт временно недоступен</h1><p>Идут технические работы. Пожалуйста, зайдите позже.</p><h1 style="margin-top:28px">Site temporarily unavailable</h1><p>Maintenance is in progress. Please try again later.</p></main></body></html>\n';
}
EOF
}

# Sites rendered before 1.57.0 lack the include; it goes right after the
# access include (before the site's own directives), else after error_log.
site_suspend_include_ensure() {
  local conf="$1" project="$2"
  grep -qF "simai-suspend/${project}[.]conf" "$conf" && return 0
  if grep -qF "simai-access/${project}[.]conf" "$conf"; then
    sed -i -E "s#^([[:space:]]*)(include [^;]*simai-access/${project}\[\.\]conf;)#\1\2\n\1include ${SIMAI_SUSPEND_NGINX_DIR}/${project}[.]conf;#" "$conf"
  elif grep -qE "^[[:space:]]*error_log /var/log/nginx/${project}\.error\.log;" "$conf"; then
    sed -i -E "s#^([[:space:]]*)(error_log /var/log/nginx/${project}\.error\.log;)#\1\2\n\1include ${SIMAI_SUSPEND_NGINX_DIR}/${project}[.]conf;#" "$conf"
  fi
  grep -qF "simai-suspend/${project}[.]conf" "$conf"
}

# Strips the 503 block that runtime-suspend wrote into the config before 1.57.0.
site_suspend_legacy_strip() {
  local conf="$1" tmp
  grep -q "# simai-runtime-suspend-begin" "$conf" || return 0
  tmp=$(mktemp)
  awk '
    $0 ~ /# simai-runtime-suspend-begin/ { skip=1; next }
    $0 ~ /# simai-runtime-suspend-end/ { skip=0; next }
    !skip { print }
  ' "$conf" >"$tmp"
  cat "$tmp" >"$conf"
  rm -f "$tmp"
}

# Puts the stub in place (on = pause, off = resume); nginx must accept the
# result or the previous config and stub come back.
site_suspend_nginx() {
  local domain="$1" project="$2" mode="$3"
  local conf="/etc/nginx/sites-available/${domain}.conf" stub backup stub_backup="" out
  stub=$(site_suspend_stub_file "$project")
  [[ -f "$conf" ]] || { error "nginx config not found for ${domain}"; return 1; }
  backup=$(mktemp)
  cp -p "$conf" "$backup"
  if [[ -f "$stub" ]]; then
    stub_backup=$(mktemp)
    cp -p "$stub" "$stub_backup"
  fi
  site_suspend_legacy_strip "$conf"
  if [[ "$mode" == on ]]; then
    install -d -m 0755 "$SIMAI_SUSPEND_NGINX_DIR"
    if ! site_suspend_include_ensure "$conf" "$project"; then
      cp -p "$backup" "$conf"
      rm -f "$backup" "$stub_backup"
      error "Cannot find where to include ${stub} in ${conf}"
      return 1
    fi
    site_suspend_stub_render "$domain" >"${stub}.tmp"
    chmod 0644 "${stub}.tmp"
    mv -f "${stub}.tmp" "$stub"
  else
    rm -f -- "$stub"
  fi
  if ! out=$(nginx -t 2>&1); then
    echo "$out" >>"${LOG_FILE:-/var/log/simai-admin.log}"
    cp -p "$backup" "$conf"
    if [[ -n "$stub_backup" ]]; then cp -p "$stub_backup" "$stub"; else rm -f -- "$stub"; fi
    rm -f "$backup" "$stub_backup"
    error "nginx refused the configuration of ${domain}; nothing changed"
    return 1
  fi
  rm -f "$backup" "$stub_backup"
  os_svc_reload_or_restart nginx >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || true
  return 0
}

# Worker units of the site: queue workers (manifest workers included) and
# the app service of node/service sites.
site_suspend_units() {
  local project="$1"
  app_project_worker_units "$project"
  [[ -f "/etc/systemd/system/simai-app-${project}.service" ]] && echo "simai-app-${project}.service"
  return 0
}

site_suspend_unit_running() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl is-enabled --quiet "$unit" 2>/dev/null || systemctl is-active --quiet "$unit" 2>/dev/null
}

# Loads SUSPEND_* for a site from its metadata.
site_suspend_context() {
  local domain="$1"
  read_site_metadata "$domain" || { error "Failed to read site metadata for ${domain}"; return 1; }
  SUSPEND_PROJECT="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  SUSPEND_SLUG="${SITE_META[slug]:-$SUSPEND_PROJECT}"
  SUSPEND_PHP="${SITE_META[php]:-none}"
  SUSPEND_SOCKET="${SITE_META[php_socket_project]:-$SUSPEND_PROJECT}"
  validate_project_slug "$SUSPEND_PROJECT" || return 1
  validate_project_slug "$SUSPEND_SLUG" || return 1
}

# Stops what runs for the site and records it. Idempotent: called again
# while paused (after set-php, a deploy of worker units or cron jobs) it stops
# what came back and adds it to the record.
site_suspend_backends() {
  local domain="$1" reassert="${2:-no}"
  local units_before="" units="" unit pool="n/a" cron jobs suspended_at
  if [[ "$reassert" == yes ]]; then
    units_before=$(site_runtime_read_var "$domain" SITE_RUNTIME_UNITS 2>/dev/null || true)
    pool=$(site_runtime_read_var "$domain" SITE_RUNTIME_POOL 2>/dev/null || echo "n/a")
    suspended_at=$(site_runtime_read_var "$domain" SITE_RUNTIME_SUSPENDED_AT 2>/dev/null || true)
  fi
  [[ -n "${suspended_at:-}" ]] || suspended_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  units="$units_before"
  while IFS= read -r unit; do
    [[ -n "$unit" ]] || continue
    if site_suspend_unit_running "$unit"; then
      os_svc_disable_now "$unit" >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || true
      [[ " $units " == *" $unit "* ]] || units="${units:+$units }${unit}"
    fi
  done < <(site_suspend_units "$SUSPEND_PROJECT")
  cron=$(site_runtime_disable_cron "$SUSPEND_SLUG")
  jobs=$(site_runtime_disable_cron "simai-jobs-${SUSPEND_SLUG}")
  # Only the site's own pool: an alias shares its target's.
  if [[ "$SUSPEND_PHP" != none && "$SUSPEND_SOCKET" == "$SUSPEND_PROJECT" ]]; then
    local now
    now=$(site_runtime_disable_pool "$SUSPEND_PHP" "$SUSPEND_SOCKET")
    [[ "$reassert" == yes && "$pool" == disabled ]] || pool="$now"
  fi
  write_site_runtime_state "$domain" \
    "SITE_RUNTIME_STATE|suspended" \
    "SITE_RUNTIME_SUSPENDED_AT|${suspended_at}" \
    "SITE_RUNTIME_CRON|${cron}" \
    "SITE_RUNTIME_JOBS|${jobs}" \
    "SITE_RUNTIME_UNITS|${units}" \
    "SITE_RUNTIME_POOL|${pool}"
  SUSPEND_SUMMARY_UNITS="${units:-none}" SUSPEND_SUMMARY_CRON="$cron" SUSPEND_SUMMARY_JOBS="$jobs" SUSPEND_SUMMARY_POOL="$pool"
}

# Called by commands that write the site's runtime files again (set-php,
# cron job-*): a paused site stays paused.
site_suspend_reassert() {
  local domain="$1"
  site_is_suspended "$domain" || return 0
  site_suspend_context "$domain" || return 0
  site_suspend_backends "$domain" yes || true
  if [[ ! -f "$(site_suspend_stub_file "$SUSPEND_PROJECT")" ]]; then
    site_suspend_nginx "$domain" "$SUSPEND_PROJECT" on || true
  fi
  return 0
}

# cron job-* rewrote the site's job file: while paused the new list waits
# under the disabled name (an emptied list leaves nothing to restore).
site_suspend_cron_jobs_sync() {
  local domain="$1" slug="$2" live disabled
  site_is_suspended "$domain" || return 0
  live=$(cron_site_file_path "simai-jobs-${slug}")
  disabled=$(site_runtime_cron_disabled_path "simai-jobs-${slug}")
  if [[ -f "$live" ]]; then
    mv -f "$live" "$disabled"
    reload_cron_daemon
  else
    rm -f -- "$disabled"
  fi
  return 0
}

# Refusals a plan can already name (command_plan_check).
site_suspend_plan_check() {
  local want="$1" domain panel
  shift
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  if [[ "$want" == suspend ]]; then
    if site_is_suspended "$domain"; then
      error "${domain} is already paused (site resume --domain ${domain} starts it again)"
      return 1
    fi
    panel=$(panel_state_get PANEL_DOMAIN 2>/dev/null || true)
    if [[ -n "$panel" && "$panel" == "$domain" ]]; then
      error "${domain} is the panel's own site; it cannot be paused"
      return 1
    fi
  elif ! site_is_suspended "$domain"; then
    error "${domain} is not paused"
    return 1
  fi
  return 0
}

site_suspend_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_pick_existing_domain "${PARSED_ARGS[domain]:-}") || return $?
  [[ -z "$domain" ]] && return 0
  site_suspend_plan_check suspend --domain "$domain" || return 1
  site_suspend_context "$domain" || return 1
  site_suspend_nginx "$domain" "$SUSPEND_PROJECT" on || return 1
  local rc=0
  site_suspend_backends "$domain" no || rc=$?
  if (( rc != 0 )); then
    error "Stopping the workers of ${domain} failed; the site answers 503, run site suspend again or site resume"
    return 1
  fi
  ui_header "SIMAI ENV · Pause site"
  ui_result_table \
    "Domain|${domain}" \
    "Availability|suspended (HTTP 503, Retry-After ${SITE_SUSPEND_RETRY_AFTER})" \
    "Scheduler|${SUSPEND_SUMMARY_CRON}" \
    "Cron jobs|${SUSPEND_SUMMARY_JOBS}" \
    "Workers stopped|${SUSPEND_SUMMARY_UNITS}" \
    "PHP pool|${SUSPEND_SUMMARY_POOL}"
  ui_next_steps
  ui_kv "Resume" "simai-admin.sh site resume --domain ${domain} --confirm yes"
}

site_resume_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(site_pick_existing_domain "${PARSED_ARGS[domain]:-}") || return $?
  [[ -z "$domain" ]] && return 0
  site_suspend_plan_check resume --domain "$domain" || return 1
  site_suspend_context "$domain" || return 1
  local units legacy_queue unit started="" pool="n/a" cron jobs
  units=$(site_runtime_read_var "$domain" SITE_RUNTIME_UNITS 2>/dev/null || true)
  legacy_queue=$(site_runtime_read_var "$domain" SITE_RUNTIME_QUEUE 2>/dev/null || true)
  # Paused by runtime-suspend before 1.57.0: only the default queue worker.
  [[ "$legacy_queue" == disabled ]] && units="${units:+$units }laravel-queue-${SUSPEND_PROJECT}.service"
  if [[ "$SUSPEND_PHP" != none && "$SUSPEND_SOCKET" == "$SUSPEND_PROJECT" ]]; then
    pool=$(site_runtime_enable_pool "$SUSPEND_PHP" "$SUSPEND_SOCKET")
  fi
  cron=$(site_runtime_enable_cron "$SUSPEND_SLUG")
  jobs=$(site_runtime_enable_cron "simai-jobs-${SUSPEND_SLUG}")
  for unit in $units; do
    [[ -f "/etc/systemd/system/${unit}" ]] || continue
    os_svc_enable_now "$unit" >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || warn "Could not start ${unit}"
    started="${started:+$started }${unit}"
  done
  site_suspend_nginx "$domain" "$SUSPEND_PROJECT" off || return 1
  write_site_runtime_state "$domain" \
    "SITE_RUNTIME_STATE|active" \
    "SITE_RUNTIME_RESUMED_AT|$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ui_header "SIMAI ENV · Resume site"
  ui_result_table \
    "Domain|${domain}" \
    "Availability|active" \
    "Scheduler|${cron}" \
    "Cron jobs|${jobs}" \
    "Workers started|${started:-none}" \
    "PHP pool|${pool}"
}

# Sites paused by runtime-suspend before 1.57.0 carry the 503 block inside
# their config, which a re-render drops; move them to the include.
self_migrate_suspended_sites() {
  local cfg domain project
  for cfg in /etc/nginx/sites-available/*.conf; do
    [[ -f "$cfg" ]] || continue
    grep -q "# simai-runtime-suspend-begin" "$cfg" || continue
    domain=$(basename "$cfg" .conf)
    site_is_suspended "$domain" || continue
    read_site_metadata "$domain" >/dev/null 2>&1 || continue
    project="${SITE_META[project]:-}"
    validate_project_slug "$project" 2>/dev/null || continue
    if site_suspend_nginx "$domain" "$project" on; then
      SELF_MIGRATE_CHANGES+=("${domain}: paused page moved to ${SIMAI_SUSPEND_NGINX_DIR}/${project}.conf")
    else
      warn "Could not move the paused page of ${domain}; previous configuration kept"
    fi
  done
  return 0
}

register_cmd "site" "suspend" "Pause a site: 503 page with Retry-After, cron and workers stopped, data untouched" "site_suspend_handler" "domain" "" "menu:confirm"
register_cmd "site" "resume" "Resume a paused site: what site suspend stopped starts again" "site_resume_handler" "domain" "" "menu:confirm"
register_cmd "site" "runtime-suspend" "Pause a site (older name of site suspend)" "site_suspend_handler" "domain" "" "menu:confirm"
register_cmd "site" "runtime-resume" "Resume a paused site (older name of site resume)" "site_resume_handler" "domain" "" "menu:confirm"
