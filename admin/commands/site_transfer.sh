#!/usr/bin/env bash

# Hands a site to another owner. A site of an owner runs as the owner's
# account (files <owner>:<owner>, PHP-FPM pool, cron, workers) and appears in
# /home/<owner>/sites, which is what the owner sees over SSH/SFTP. Transfer
# makes an existing site look exactly like one made by `site add --owner O`;
# the moving itself is `site isolate --owner` (with rollback). The database
# and its credentials stay as they are: they live in the site's .env, which
# moves with the files and is readable only by the new owner afterwards.

# Sets TRANSFER_* for the plan and the handler; prints the refusal.
site_transfer_check() {
  local domain="$1" owner="$2"
  TRANSFER_REFUSAL=""
  [[ -n "$domain" && -n "$owner" ]] || { require_args "domain owner"; return 1; }
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  TRANSFER_PROJECT="${SITE_META[project]:-}"
  TRANSFER_ROOT="${SITE_META[root]:-}"
  validate_project_slug "$TRANSFER_PROJECT" || return 1
  if [[ "${SITE_META[profile]:-}" == "alias" ]]; then
    error "Alias sites run as their target site; transfer the target site instead."
    return 1
  fi
  local panel_domain
  panel_domain=$(panel_state_get PANEL_DOMAIN 2>/dev/null || true)
  if [[ -n "$panel_domain" && "${domain,,}" == "${panel_domain,,}" ]]; then
    TRANSFER_REFUSAL="panel_site"
    error "${domain} is the panel's own site; it cannot be transferred to an owner."
    return 1
  fi
  if ! site_is_owner "$owner"; then
    TRANSFER_REFUSAL="owner_missing"
    error "Owner ${owner} does not exist. Create it first: simai-admin.sh owner create --name ${owner}"
    return 1
  fi
  if [[ -f "$(owner_blocks_dir)/${owner}" ]]; then
    TRANSFER_REFUSAL="owner_blocked"
    error "Owner ${owner} is blocked; unblock it first: simai-admin.sh owner unblock --name ${owner}"
    return 1
  fi
  TRANSFER_FROM=$(site_user_for_project "$TRANSFER_PROJECT" 2>/dev/null) || TRANSFER_FROM="$SIMAI_BASE_USER"
  if [[ "$TRANSFER_FROM" == "$owner" ]]; then
    TRANSFER_REFUSAL="same_owner"
    error "${domain} already belongs to owner ${owner}"
    return 1
  fi
  TRANSFER_FROM_OWNER=""
  site_is_owner "$TRANSFER_FROM" && TRANSFER_FROM_OWNER="$TRANSFER_FROM"
  [[ -n "$TRANSFER_ROOT" && -d "$TRANSFER_ROOT" && ! -L "$TRANSFER_ROOT" ]] || { error "Project root not found: ${TRANSFER_ROOT:-unknown}"; return 1; }
  return 0
}

site_transfer_from_text() {
  if [[ -n "$TRANSFER_FROM_OWNER" ]]; then
    printf 'owner %s\n' "$TRANSFER_FROM_OWNER"
  elif [[ "$TRANSFER_FROM" == "$SIMAI_BASE_USER" ]]; then
    printf 'the shared user %s (no owner)\n' "$TRANSFER_FROM"
  else
    printf 'its own user %s (no owner)\n' "$TRANSFER_FROM"
  fi
}

site_transfer_db_name() {
  local file="/etc/simai-env/sites/${1}/db.env"
  [[ -f "$file" ]] || return 0
  sed -n 's/^DB_NAME=//p' "$file" | head -n1 | tr -d "\"'"
}

# What moves, one line each (plan text and the JSON plan).
site_transfer_moves() {
  local domain="$1" owner="$2" project="$TRANSFER_PROJECT" pool unit db
  echo "files: ${TRANSFER_ROOT} becomes ${owner}:${owner}, closed to others"
  for pool in /etc/php/*/fpm/pool.d/"${SITE_META[php_socket_project]:-$project}".conf; do
    [[ -f "$pool" ]] && echo "PHP-FPM pool ${pool}: runs as ${owner}"
  done
  [[ -f "$(cron_site_file_path "${SITE_META[slug]:-$project}")" ]] && echo "scheduler $(cron_site_file_path "${SITE_META[slug]:-$project}"): runs as ${owner}"
  [[ -f "/etc/simai-env/cron-jobs/${domain}/jobs.json" ]] && echo "cron jobs (cron list): run as ${owner}"
  for unit in $(app_project_worker_units "$project"); do
    echo "worker ${unit}: runs as ${owner}"
  done
  echo "SSH/SFTP: /home/${owner}/sites/${domain} appears"
  [[ -n "$TRANSFER_FROM_OWNER" ]] && echo "SSH/SFTP: /home/${TRANSFER_FROM_OWNER}/sites/${domain} is removed; ${TRANSFER_FROM_OWNER} loses access"
  db=$(site_transfer_db_name "$domain")
  [[ -n "$db" ]] && echo "database ${db}: unchanged; its credentials (site .env) are readable only by ${owner}"
  return 0
}

site_transfer_plan_data() {
  local domain="$1" owner="$2"
  site_plan_data_write "$(python3 -c 'import json,sys; d,f,fo,t=sys.argv[1:5]; print(json.dumps({"schema":"simai-site-transfer-plan/1","domain":d,"from":f,"from_owner":fo or None,"to_owner":t,"backup":"backup data (database and files) first","moves":sys.argv[5:]}))' \
    "$domain" "$TRANSFER_FROM" "$TRANSFER_FROM_OWNER" "$owner" "$@")"
}

site_transfer_plan_check() {
  local domain owner
  domain=$(command_arg domain "$@")
  owner=$(command_arg owner "$@")
  if ! site_transfer_check "$domain" "$owner"; then
    # The gateway answers these by name (admin/panel_gate.py PLAN_REFUSALS).
    [[ -z "$TRANSFER_REFUSAL" ]] || site_plan_data_write "{\"refusal\": \"${TRANSFER_REFUSAL}\"}"
    return 1
  fi
  local -a moves=()
  mapfile -t moves < <(site_transfer_moves "$domain" "$owner")
  site_transfer_plan_data "$domain" "$owner" "${moves[@]}"
  return 0
}

site_transfer_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" owner="${PARSED_ARGS[owner]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  site_transfer_check "$domain" "$owner" || return 1
  local from_text line
  from_text=$(site_transfer_from_text)
  if [[ "${confirm,,}" != "yes" ]]; then
    echo "Plan for ${domain}: transfer from ${from_text} to owner ${owner}"
    echo "  - backup data (database and files) first"
    while IFS= read -r line; do echo "  - ${line}"; done < <(site_transfer_moves "$domain" "$owner")
    echo "  - site SFTP accounts (access list) keep their access"
    echo "The site keeps serving: PHP-FPM reloads gracefully, workers restart."
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  ui_header "SIMAI ENV · Transfer site"
  info "Backing up ${domain} before the transfer"
  local with_db=no
  [[ -n "$(site_transfer_db_name "$domain")" ]] && with_db=yes
  run_command backup data --domain "$domain" --db "$with_db" --files yes --confirm yes || { error "Backup failed; nothing transferred"; return 1; }
  local rc=0
  site_isolate_handler --domain "$domain" --owner "$owner" --confirm yes || rc=$?
  if (( rc != 0 )); then
    error "Transfer of ${domain} failed; it still belongs to ${from_text}"
    return "$rc"
  fi
  [[ -n "$TRANSFER_FROM_OWNER" && -L "/home/${TRANSFER_FROM_OWNER}/sites/${domain}" ]] && rm -f -- "/home/${TRANSFER_FROM_OWNER}/sites/${domain}"
  ui_result_table \
    "Domain|${domain}" \
    "From|${from_text}" \
    "Owner|${owner}" \
    "Backup|taken (backup data)"
  ui_next_steps
  ui_kv "Check the site" "simai-admin.sh site doctor --domain ${domain}"
}

register_cmd "site" "transfer" "Transfer a site to another owner: files, PHP pool, cron, workers and SSH/SFTP access (backup first)" "site_transfer_handler" "domain owner" "confirm=" "tier:advanced plan:handler"
