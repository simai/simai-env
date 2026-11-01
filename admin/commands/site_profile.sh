#!/usr/bin/env bash

# Changes the profile of an existing site between static and node without
# touching its releases. static -> node gives the site a port and the node
# nginx template; until the first node release nginx keeps serving current
# the way the static profile does (STATIC_RELEASES=yes in service.env, see
# lib/app_routes.py). node -> static undoes it while current is a static
# release. Every step is undone if a later one fails.

site_set_profile_ssl() {
  local cfg="$1"
  SITE_PROFILE_CERT=$(awk '/^[[:space:]]*ssl_certificate[[:space:]]/ {print $2; exit}' "$cfg" | sed 's/;$//')
  SITE_PROFILE_KEY=$(awk '/^[[:space:]]*ssl_certificate_key[[:space:]]/ {print $2; exit}' "$cfg" | sed 's/;$//')
  SITE_PROFILE_CHAIN=$(awk '/^[[:space:]]*ssl_trusted_certificate[[:space:]]/ {print $2; exit}' "$cfg" | sed 's/;$//')
  SITE_PROFILE_REDIRECT=no SITE_PROFILE_HSTS=no
  [[ -n "$SITE_PROFILE_CERT" && -n "$SITE_PROFILE_KEY" ]] || { SITE_PROFILE_CERT="" SITE_PROFILE_KEY="" SITE_PROFILE_CHAIN=""; return 0; }
  [[ "$(site_nginx_ssl_redirect_enabled "$SITE_PROFILE_DOMAIN")" == yes ]] && SITE_PROFILE_REDIRECT=yes
  [[ "$(site_nginx_hsts_enabled "$SITE_PROFILE_DOMAIN")" == yes ]] && SITE_PROFILE_HSTS=yes
  return 0
}

site_set_profile_ssl_label() {
  [[ -n "$SITE_PROFILE_CERT" ]] || { echo "HTTP only"; return; }
  echo "HTTPS kept (${SITE_PROFILE_CERT}, redirect ${SITE_PROFILE_REDIRECT}, HSTS ${SITE_PROFILE_HSTS})"
}

# Renders the vhost of <profile> with the site's SSL, host mode and frame policy.
site_set_profile_render() {
  local domain="$1" profile="$2" project="$3" root="$4" template
  template=$(site_nginx_template_path_for_id "$profile") || return 1
  create_nginx_site "$domain" "$project" "$root" none "$template" "$profile" "" "$project" \
    "$SITE_PROFILE_CERT" "$SITE_PROFILE_KEY" "$SITE_PROFILE_CHAIN" "$SITE_PROFILE_REDIRECT" "$SITE_PROFILE_HSTS" "$profile" public \
    "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" "${SITE_META[frame_policy]:-same-origin}" || return 1
  local ssl_type=none
  if [[ -n "$SITE_PROFILE_CERT" ]]; then
    ssl_type=custom
    [[ "$SITE_PROFILE_CERT" == "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] && ssl_type=letsencrypt
  fi
  site_nginx_metadata_upsert "/etc/nginx/sites-available/${domain}.conf" "$domain" "$project" "$profile" "$root" "$project" none "$ssl_type" "" "" "$project" "$profile" public \
    "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" >/dev/null 2>&1 || true
}

# Puts back what site_set_profile_handler saved in $1 and reloads nginx.
site_set_profile_restore() {
  local tx="$1" domain="$2" project="$3" root="$4" public_was="$5" f
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  cp -p "${tx}/site.conf" "$cfg"
  ln -sf "$cfg" "/etc/nginx/sites-enabled/${domain}.conf"
  for f in service.env routes.conf maps.conf; do
    local dst
    case "$f" in
      service.env) dst=$(app_service_env_file "$domain") ;;
      routes.conf) dst=$(app_routes_file "$domain") ;;
      maps.conf) dst=$(app_routes_maps_file "$project") ;;
    esac
    if [[ -f "${tx}/${f}" ]]; then cp -p "${tx}/${f}" "$dst"; else rm -f -- "$dst"; fi
  done
  if [[ "$public_was" == link && ! -L "${root}/public" ]]; then
    find "${root}/public" -depth -type d -empty -delete 2>/dev/null || true
    [[ -e "${root}/public" ]] || { ln -sfn current "${root}/public.tmp" && mv -Tf "${root}/public.tmp" "${root}/public"; }
  elif [[ "$public_was" == dir && -L "${root}/public" ]]; then
    rm -f -- "${root}/public"
    install -d -m 0750 -o "$(site_effective_user "$project")" -g "$(site_effective_group "$project")" "${root}/public"
  fi
  if nginx -t >>"$LOG_FILE" 2>&1; then
    os_svc_reload nginx >/dev/null 2>&1 || warn "Reload nginx manually"
  else
    warn "nginx -t still fails after the restore (see ${LOG_FILE}); the running nginx keeps its previous configuration"
  fi
}

site_set_profile_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" to="${PARSED_ARGS[profile]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain profile" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  SITE_PROFILE_DOMAIN="$domain"
  local from="${SITE_META[profile]:-}" root="${SITE_META[root]:-}" project="${SITE_META[project]:-}"
  local public_dir="${SITE_META[public_dir]-public}" cfg="/etc/nginx/sites-available/${domain}.conf"
  validate_project_slug "$project" || return 1
  if [[ "$from" == "$to" ]]; then
    info "${domain} already has profile ${to}"
    return 0
  fi
  [[ "${from}>${to}" == "static>node" || "${from}>${to}" == "node>static" ]] || { error "Supported: static -> node, and node -> static for a site converted by this command (${domain} is ${from})"; return 1; }
  is_profile_enabled "$to" || { error "Profile ${to} is disabled; enable it: simai-admin.sh profile enable --id ${to} --confirm yes"; return 1; }
  [[ "$public_dir" == public ]] || { error "${domain} serves ${public_dir:-the project root}; only sites with public/ are supported"; return 1; }
  [[ -n "$root" && -d "$root" && ! -L "$root" ]] && site_path_is_allowed_root "$root" || { error "Project root ${root:-unknown} is missing or outside the managed web roots"; return 1; }
  deploy_layout_active "$root" || { error "${domain} has no releases; deploy it once as a static site (site deploy) so its files become a release, then switch"; return 1; }
  local current
  current=$(basename "$(readlink "${root}/current")")
  [[ -d "${root}/releases/${current}" ]] || { error "current points to a missing release (${current})"; return 1; }
  local svc_env port="" public_was
  svc_env=$(app_service_env_file "$domain")
  if [[ "$to" == node ]]; then
    [[ ! -e "$svc_env" ]] || { error "${svc_env} already exists; inspect it before switching"; return 1; }
    [[ -L "${root}/public" && "$(readlink "${root}/public")" == current ]] || { error "${root}/public is not the symlink to current a static deploy creates"; return 1; }
    port=$(app_port_allocate "${PARSED_ARGS[app-port]:-}") || return 1
    public_was="link"
  else
    app_static_releases_enabled "$domain" || { error "${domain} was not converted from profile static by site set-profile; refusing to guess its static layout"; return 1; }
    if app_release_runs_service "${root}/current"; then
      error "current (${current}) runs a service; switch to a static release first: simai-admin.sh site deploy-rollback --domain ${domain} --release <id> --confirm yes"
      return 1
    fi
    [[ -d "${root}/public" && ! -L "${root}/public" ]] || { error "${root}/public is not the directory of a node site"; return 1; }
    [[ -z "$(find "${root}/public" -mindepth 1 ! -type d -print -quit)" ]] || { error "${root}/public holds files; move them away before switching (nothing is deleted)"; return 1; }
    port=$(app_port_get "$domain")
    public_was="dir"
  fi
  site_set_profile_ssl "$cfg"

  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan for ${domain}: profile ${from} -> ${to}"
    if [[ "$to" == node ]]; then
      echo "  - port 127.0.0.1:${port} recorded in ${svc_env} (STATIC_RELEASES=yes)"
      echo "  - nginx ${cfg} from nginx-node.conf; $(site_set_profile_ssl_label); redirects and path rules kept"
      echo "  - routes $(app_routes_file "$domain"): until the first node release nginx serves current (releases/${current}) the way the static profile does; no service runs"
      echo "  - ${root}/public (symlink to current) becomes a directory for ACME challenges, after the nginx reload"
    else
      echo "  - nginx ${cfg} from nginx-static.conf; $(site_set_profile_ssl_label); redirects and path rules kept"
      echo "  - ${root}/public (empty directory) becomes the symlink to current (releases/${current}) again"
      echo "  - port ${port}, routes and $(app_service_unit_name "$project") (not running a static release) are removed"
    fi
    echo "  - current, releases/ and every file in them stay as they are"
    echo "  - nginx -t, then one reload; any failure restores the previous configuration"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  ui_header "SIMAI ENV · Set site profile"
  local tx failed="" routes maps
  routes=$(app_routes_file "$domain"); maps=$(app_routes_maps_file "$project")
  tx=$(mktemp -d) || return 1
  cp -p "$cfg" "${tx}/site.conf" || { rm -rf -- "$tx"; return 1; }
  [[ -f "$svc_env" ]] && cp -p "$svc_env" "${tx}/service.env"
  [[ -f "$routes" ]] && cp -p "$routes" "${tx}/routes.conf"
  [[ -f "$maps" ]] && cp -p "$maps" "${tx}/maps.conf"
  info "Switching ${domain}: ${from} -> ${to} (backup of the previous configuration in ${tx})"
  ensure_nginx_static_maps

  if [[ "$to" == node ]]; then
    install -d -m 0750 "$(dirname "$svc_env")" && printf 'APP_PORT=%s\nSTATIC_RELEASES=yes\n' "$port" >"$svc_env" && chmod 0640 "$svc_env" || failed="service.env"
    [[ -z "$failed" ]] && { app_routes_render "$domain" "$project" "$port" "$root" "${root}/current" "$current" || failed="routes"; }
    [[ -z "$failed" ]] && { SITE_APP_PORT="$port" site_set_profile_render "$domain" node "$project" "$root" || failed="nginx config"; }
    [[ -z "$failed" ]] && { nginx -t >>"$LOG_FILE" 2>&1 || failed="nginx -t"; }
    [[ -z "$failed" ]] && { os_svc_reload nginx >/dev/null 2>&1 || failed="nginx reload"; }
    if [[ -z "$failed" ]]; then
      rm -f -- "${root}/public" && install -d -m 0750 -o "$(site_effective_user "$project")" -g "$(site_effective_group "$project")" "${root}/public" || failed="public directory"
    fi
  else
    find "${root}/public" -depth -type d -empty -delete 2>/dev/null || true
    [[ ! -e "${root}/public" ]] && ln -sfn current "${root}/public.tmp" && mv -Tf "${root}/public.tmp" "${root}/public" || failed="public symlink"
    chown -h "$(site_effective_user "$project"):$(site_effective_group "$project")" "${root}/public" 2>/dev/null || true
    [[ -z "$failed" ]] && { site_set_profile_render "$domain" static "$project" "$root" || failed="nginx config"; }
    [[ -z "$failed" ]] && { nginx -t >>"$LOG_FILE" 2>&1 || failed="nginx -t"; }
    [[ -z "$failed" ]] && { os_svc_reload nginx >/dev/null 2>&1 || failed="nginx reload"; }
    if [[ -z "$failed" ]]; then
      rm -f -- "$routes" "$maps" "$svc_env"
      rmdir "$(dirname "$routes")" 2>/dev/null || true
      app_service_remove "$project"
    fi
  fi

  if [[ -n "$failed" ]]; then
    error "Switching ${domain} to ${to} failed at: ${failed}. Restoring the previous configuration."
    site_set_profile_restore "$tx" "$domain" "$project" "$root" "$public_was"
    rm -rf -- "$tx"
    return 1
  fi
  rm -rf -- "$tx"
  local rows=("Domain|${domain}" "Profile|${from} -> ${to}" "Current|releases/${current} (unchanged)")
  [[ "$to" == node ]] && rows+=("Port|127.0.0.1:${port} (service starts with the first node release)")
  ui_result_table "${rows[@]}"
  ui_next_steps
  if [[ "$to" == node ]]; then
    ui_kv "Deploy the first node release" "simai-admin.sh site deploy --domain ${domain} --git <url> --ref <tag> --confirm yes"
    ui_kv "Back to static" "simai-admin.sh site set-profile --domain ${domain} --profile static --confirm yes"
  fi
  ui_kv "Check the site" "simai-admin.sh site doctor --domain ${domain}"
}

register_cmd "site" "set-profile" "Change a site's profile between static and node, keeping its releases (plan unless --confirm yes)" "site_set_profile_handler" "domain profile" "app-port= confirm=" "tier:advanced plan:handler"
