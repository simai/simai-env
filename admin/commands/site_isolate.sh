#!/usr/bin/env bash

# Migrates an existing site from the shared SIMAI_BASE_USER to its own Unix
# user: project files, PHP-FPM pool, cron file and queue unit. Every step is
# undone if a later one fails.

site_isolate_rewrite_pool() {
  local pool="$1" user="$2"
  sed -i -E \
    -e "s/^user = .*/user = ${user}/" \
    -e "s/^group = .*/group = ${user}/" \
    -e "s/^listen\\.owner = .*/listen.owner = ${user}/" \
    "$pool"
}

site_isolate_rewrite_cron() {
  local file="$1" from="$2" to="$3" tmp
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  awk -v from="$from" -v to="$to" '
    /^[[:space:]]*#/ || NF < 6 { print; next }
    $6 == from { sub("[[:space:]]" from "[[:space:]]", " " to " ") }
    { print }
  ' "$file" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$file"
}

site_isolate_acl_switch() {
  local root="$1" from="$2" to="$3"
  command -v getfacl >/dev/null 2>&1 || return 0
  getfacl -p "$root" 2>/dev/null | grep -q "^user:${from}:" || return 0
  setfacl -R -x "u:${from}" "$root" 2>/dev/null || true
  find "$root" -type d -print0 | xargs -0 -r setfacl -x "d:u:${from}" 2>/dev/null || true
  setfacl -R -m "u:${to}:rwX" "$root" || return 1
  find "$root" -type d -print0 | xargs -0 -r setfacl -m "d:u:${to}:rwX"
}

site_isolate_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local project="${SITE_META[project]:-}" root="${SITE_META[root]:-}" profile="${SITE_META[profile]:-}"
  local socket_project="${SITE_META[php_socket_project]:-$project}" slug="${SITE_META[slug]:-$project}"
  validate_project_slug "$project" || return 1
  if [[ "$profile" == "alias" ]]; then
    error "Alias sites run in their target site's pool; isolate the target site instead."
    return 1
  fi
  local current
  if current=$(site_user_for_project "$project" 2>/dev/null); then
    info "${domain} already runs as ${current}"
    return 0
  fi
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] || { error "Project root not found: ${root:-unknown}"; return 1; }
  site_path_is_allowed_root "$root" || { error "Project root ${root} is outside the managed web roots"; return 1; }

  local base="$SIMAI_BASE_USER" user
  user=$(site_user_name_for_project "$project")
  local -a pools=()
  local pool
  for pool in /etc/php/*/fpm/pool.d/"${socket_project}".conf; do
    [[ -f "$pool" ]] && pools+=("$pool")
  done
  local cron_file queue_unit=""
  cron_file=$(cron_site_file_path "$slug")
  queue_unit=$(queue_unit_path "$project" 2>/dev/null || true)
  [[ -f "$queue_unit" ]] || queue_unit=""

  if [[ "${confirm,,}" != "yes" ]]; then
    echo "Plan for ${domain}:"
    echo "  - create user and group ${user}; add www-data to group ${user}"
    echo "  - chown -R ${user}:${user} ${root}; chmod o-rwx ${root}"
    for pool in "${pools[@]}"; do echo "  - PHP-FPM pool ${pool}: user/group ${user}"; done
    [[ -f "$cron_file" ]] && echo "  - cron ${cron_file}: run as ${user}"
    [[ -n "$queue_unit" ]] && echo "  - queue unit ${queue_unit}: User/Group ${user}"
    echo "PHP-FPM is reloaded; running requests finish on the old workers."
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  ui_header "SIMAI ENV · Isolate site"
  local backup_dir root_mode
  backup_dir=$(mktemp -d) || return 1
  root_mode=$(stat -c '%a' "$root")
  local i=0
  for pool in "${pools[@]}"; do cp -p "$pool" "${backup_dir}/pool.${i}"; i=$((i + 1)); done
  [[ -f "$cron_file" ]] && cp -p "$cron_file" "${backup_dir}/cron"
  [[ -n "$queue_unit" ]] && cp -p "$queue_unit" "${backup_dir}/queue"

  local failed=""
  site_user_create "$project" >/dev/null || failed="create user"
  if [[ -z "$failed" ]]; then
    site_prepare_isolated_parents
    info "Changing ownership of ${root}"
    chown -R "${user}:${user}" "$root" && chmod o-rwx "$root" || failed="file ownership"
  fi
  [[ -z "$failed" ]] && { site_isolate_acl_switch "$root" "$base" "$user" || failed="file ACLs"; }
  if [[ -z "$failed" ]]; then
    local ver
    for pool in "${pools[@]}"; do
      ver=$(awk -F/ '{print $4}' <<<"$pool")
      site_isolate_rewrite_pool "$pool" "$user" || { failed="pool ${pool}"; break; }
      site_ensure_opcache_isolation "$ver"
      if command -v "php-fpm${ver}" >/dev/null 2>&1 && ! "php-fpm${ver}" -t >>"$LOG_FILE" 2>&1; then
        failed="php-fpm${ver} config test"
        break
      fi
    done
  fi
  if [[ -z "$failed" && -f "$cron_file" ]]; then
    site_isolate_rewrite_cron "$cron_file" "$base" "$user" || failed="cron file"
  fi
  if [[ -z "$failed" && -n "$queue_unit" ]]; then
    sed -i -E -e "s/^User=.*/User=${user}/" -e "s/^Group=.*/Group=${user}/" "$queue_unit" || failed="queue unit"
  fi

  if [[ -n "$failed" ]]; then
    error "Isolation of ${domain} failed at: ${failed}. Rolling back."
    i=0
    for pool in "${pools[@]}"; do cp -p "${backup_dir}/pool.${i}" "$pool"; i=$((i + 1)); done
    [[ -f "${backup_dir}/cron" ]] && cp -p "${backup_dir}/cron" "$cron_file"
    [[ -f "${backup_dir}/queue" ]] && cp -p "${backup_dir}/queue" "$queue_unit"
    chown -R "${base}:www-data" "$root" 2>/dev/null || true
    chmod "$root_mode" "$root" 2>/dev/null || true
    site_isolate_acl_switch "$root" "$user" "$base" >/dev/null 2>&1 || true
    site_user_delete "$project" >/dev/null 2>&1 || true
    rm -rf -- "$backup_dir"
    return 1
  fi
  rm -rf -- "$backup_dir"

  local ver
  for pool in "${pools[@]}"; do
    ver=$(awk -F/ '{print $4}' <<<"$pool")
    os_svc_reload_or_restart "php${ver}-fpm" || warn "Reload php${ver}-fpm manually"
  done
  # nginx workers pick up www-data's new supplementary group only on reload.
  if nginx -t >>"$LOG_FILE" 2>&1; then
    os_svc_reload nginx || warn "Reload nginx manually"
  else
    warn "nginx -t failed; reload nginx after fixing its config so it can read ${root}"
  fi
  [[ -f "$cron_file" ]] && reload_cron_daemon
  if [[ -n "$queue_unit" ]]; then
    os_svc_daemon_reload || true
    os_svc_is_active "$(basename "$queue_unit")" && { os_svc_restart "$(basename "$queue_unit")" || warn "Restart $(basename "$queue_unit") manually"; }
  fi
  ui_result_table \
    "Domain|${domain}" \
    "Site user|${user}" \
    "Project|${root} (mode $(stat -c '%a' "$root"))" \
    "PHP pools|${#pools[@]} updated" \
    "Cron|$([[ -f "$cron_file" ]] && echo updated || echo none)" \
    "Queue|$([[ -n "$queue_unit" ]] && echo updated || echo none)"
  ui_next_steps
  ui_kv "Check the site" "simai-admin.sh site doctor --domain ${domain}"
}

register_cmd "site" "isolate" "Move a site to its own Unix user (files, PHP pool, cron, queue)" "site_isolate_handler" "domain" "confirm=" "tier:advanced"
