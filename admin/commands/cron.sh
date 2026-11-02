#!/usr/bin/env bash
set -euo pipefail

cron_add_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -A meta=()
  if ! site_nginx_metadata_parse "$cfg" meta; then
    error "Nginx metadata not found for ${domain}."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  local profile="${meta[profile]:-}"
  local slug="${meta[slug]:-}"
  local root="${meta[root]:-}"
  local php="${meta[php]:-}"
  if [[ -z "$slug" || -z "$profile" || -z "$root" || -z "$php" ]]; then
    error "Site metadata incomplete for ${domain}. Refusing to guess."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  if [[ "$profile" != "laravel" ]]; then
    error "Cron add is supported for laravel profile only (got ${profile})."
    return 1
  fi
  local user="${PARSED_ARGS[user]:-${SIMAI_USER:-simai}}"
  local user_uid=""
  if [[ ! "$user" =~ ^[a-z_][a-z0-9_-]*$ ]] || ! user_uid=$(id -u "$user" 2>/dev/null); then
    error "Scheduler user ${user} does not exist."
    return 1
  fi
  if [[ "$user" != "${SIMAI_USER:-simai}" ]] && (( user_uid < 1000 )); then
    error "Scheduler must run as a regular site user, not ${user} (uid ${user_uid})."
    return 1
  fi
  local prev_user="${SIMAI_USER:-simai}"
  SIMAI_USER="$user"
  ui_header "SIMAI ENV · Enable Laravel scheduler"
  cron_site_write "$domain" "$slug" "$profile" "$root" "$php"
  SIMAI_USER="$prev_user"
  ui_result_table \
    "Domain|${domain}" \
    "Scheduler file|/etc/cron.d/${slug}" \
    "PHP|${php}" \
    "User|${user}"
  ui_next_steps
  ui_kv "Disable scheduler" "simai-admin.sh cron remove --domain ${domain}"
  ui_kv "Review worker status" "simai-admin.sh queue status --domain ${domain}"
}

cron_remove_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -A meta=()
  if ! site_nginx_metadata_parse "$cfg" meta; then
    error "Nginx metadata not found for ${domain}. Refusing to guess slug."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  local slug="${meta[slug]:-}"
  if [[ -z "$slug" ]]; then
    error "Metadata slug missing for ${domain}. Refusing to guess."
    echo "Run: simai-admin.sh site doctor --domain ${domain} (diagnostics)"
    echo "Then add/restore the # simai-* metadata header in ${cfg} (recreate site config if needed)."
    return 1
  fi
  ui_header "SIMAI ENV · Disable Laravel scheduler"
  remove_cron_file "$slug" "$domain"
  ui_result_table \
    "Domain|${domain}" \
    "Scheduler file|/etc/cron.d/${slug}" \
    "State|removed"
  ui_next_steps
  ui_kv "Enable scheduler" "simai-admin.sh cron add --domain ${domain}"
  ui_kv "Review site status" "simai-admin.sh site info --domain ${domain}"
}

# User cron jobs (cron job-*): any command of a site's owner, on a 5-field
# schedule, run as the site user in the site directory through a wrapper
# that records each run. State and records: lib/cron_jobs.py.
CRON_JOBS_PY="${SIMAI_ENV_ROOT}/lib/cron_jobs.py"

# Loads CRON_SITE_USER, CRON_SITE_DIR and CRON_SITE_SLUG for a site.
cron_jobs_site() {
  local domain="$1"
  validate_domain "$domain" || return 1
  require_site_exists "$domain" || return 1
  declare -A meta=()
  site_nginx_metadata_parse "/etc/nginx/sites-available/${domain}.conf" meta || { error "Nginx metadata not found for ${domain}"; return 1; }
  [[ -n "${meta[slug]:-}" && -n "${meta[root]:-}" ]] || { error "Site metadata incomplete for ${domain}"; return 1; }
  [[ "${meta[profile]:-}" != alias ]] || { error "An alias site has no cron jobs of its own; use its target site"; return 1; }
  CRON_SITE_SLUG="${meta[slug]}"
  CRON_SITE_USER=$(site_effective_user "${meta[project]:-${meta[slug]}}")
  CRON_SITE_DIR="${meta[root]}"
  [[ -d "${meta[root]}/current" ]] && CRON_SITE_DIR="${meta[root]}/current"
  return 0
}

# Rewrites the site's /etc/cron.d/simai-jobs-<slug> from the stored jobs.
cron_jobs_apply() {
  local domain="$1"
  cron_jobs_site "$domain" || return 1
  install -D -m 0755 -o root -g root "${SIMAI_ENV_ROOT}/lib/cron_job_run.sh" /usr/local/lib/simai-env/cron-job-run || return 1
  python3 -I "$CRON_JOBS_PY" render "$domain" "$CRON_SITE_USER" "$CRON_SITE_DIR" "$CRON_SITE_SLUG"
}

cron_list_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  cron_jobs_site "${PARSED_ARGS[domain]}" || return 1
  python3 -I "$CRON_JOBS_PY" list "${PARSED_ARGS[domain]}" "${SIMAI_COMMAND_OUTPUT:-human}"
}

cron_job_add_handler() {
  parse_kv_args "$@"
  require_args "domain schedule command" || return 1
  local domain="${PARSED_ARGS[domain]}" id
  cron_jobs_site "$domain" || return 1
  id=$(python3 -I "$CRON_JOBS_PY" add "$domain" "${PARSED_ARGS[schedule]}" "${PARSED_ARGS[command]}") || return 1
  cron_jobs_apply "$domain" || return 1
  ui_result_table "Domain|${domain}" "Job|${id}" "Schedule|${PARSED_ARGS[schedule]}" "Runs as|${CRON_SITE_USER}" "In|${CRON_SITE_DIR}"
}

cron_job_set() {
  local id="$1" state="$2" domain
  [[ "$id" =~ ^[a-f0-9]{8}$ ]] || { error "--id must be a job id from cron list"; return 1; }
  domain=$(python3 -I "$CRON_JOBS_PY" set "$id" "$state") || return 1
  cron_jobs_apply "$domain" || return 1
  ui_result_table "Domain|${domain}" "Job|${id}" "State|${state}"
}

cron_job_remove_handler() { parse_kv_args "$@"; require_args "id" || return 1; cron_job_set "${PARSED_ARGS[id]}" removed; }
cron_job_enable_handler() { parse_kv_args "$@"; require_args "id" || return 1; cron_job_set "${PARSED_ARGS[id]}" enabled; }
cron_job_disable_handler() { parse_kv_args "$@"; require_args "id" || return 1; cron_job_set "${PARSED_ARGS[id]}" disabled; }

cron_job_runs_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  local id="${PARSED_ARGS[id]}" limit="${PARSED_ARGS[limit]:-20}"
  [[ "$id" =~ ^[a-f0-9]{8}$ ]] || { error "--id must be a job id from cron list"; return 1; }
  [[ "$limit" =~ ^[1-9][0-9]?$ ]] && (( limit <= 50 )) || { error "--limit must be 1-50"; return 1; }
  python3 -I "$CRON_JOBS_PY" runs "$id" "$limit" "${SIMAI_COMMAND_OUTPUT:-human}"
}

register_cmd "cron" "list" "List a site's own cron jobs with their last run" "cron_list_handler" "domain" "" "tier:advanced effects:read"
register_cmd "cron" "job-add" "Add a cron job: a command run as the site user on a 5-field schedule" "cron_job_add_handler" "domain schedule command" "" "tier:advanced"
register_cmd "cron" "job-remove" "Remove a cron job and its run records" "cron_job_remove_handler" "id" "" "tier:advanced"
register_cmd "cron" "job-enable" "Enable a cron job" "cron_job_enable_handler" "id" "" "tier:advanced"
register_cmd "cron" "job-disable" "Disable a cron job (kept, not run)" "cron_job_disable_handler" "id" "" "tier:advanced"
register_cmd "cron" "job-runs" "Show a cron job's last runs: start, end, exit code, last output lines" "cron_job_runs_handler" "id" "limit=" "tier:advanced effects:read"
register_cmd "cron" "add" "Enable schedule:run scheduler entry for site" "cron_add_handler" "domain" "user=" "menu:confirm"
register_cmd "cron" "remove" "Disable schedule:run scheduler entry for site" "cron_remove_handler" "domain" "" "menu:confirm"
