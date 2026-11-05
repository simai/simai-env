#!/usr/bin/env bash
set -euo pipefail

# site apache: switch a PHP site between plain nginx + PHP-FPM and Apache mode
# (nginx in front, Apache behind it on 127.0.0.1 reading .htaccess). See
# admin/lib/apache_utils.sh. If the site answered before and stops answering
# after the switch, everything is put back.

site_apache_plan() {
  local domain="$1" enable="$2" profile="$3"
  local -a rows=("Domain|${domain}" "Profile|${profile}")
  if [[ "$enable" == yes ]]; then
    apache_installed || rows+=("Install|apache2 (listens on 127.0.0.1:${SIMAI_APACHE_PORT} only)")
    rows+=("nginx|stays in front: HTTPS, access rules, own directives; passes every request to Apache"
      "Apache|reads the site's .htaccess files, runs PHP through the same PHP-FPM pool"
      "Note|static files are also served through Apache, so .htaccess rules apply to them")
  else
    rows+=("nginx|serves the site again directly with PHP-FPM; .htaccess files are ignored"
      "Apache|the site's Apache vhost is removed (Apache itself stays installed)")
  fi
  rows+=("Check|undone if the site stops answering")
  ui_result_table "${rows[@]}"
}

# Re-renders the nginx vhost (and the Apache one in Apache mode) keeping SSL,
# host mode and frame policy.
site_apache_render() {
  local domain="$1" cfg template_id template
  cfg="/etc/nginx/sites-available/${domain}.conf"
  template_id="${SITE_META[nginx_template]:-${SITE_META[profile]}}"
  template=$(site_nginx_template_path_for_id "$template_id") || return 1
  SITE_PROFILE_DOMAIN="$domain" site_set_profile_ssl "$cfg"
  create_nginx_site "$domain" "${SITE_META[project]}" "${SITE_META[root]}" "${SITE_META[php]}" "$template" "${SITE_META[profile]}" "" \
    "${SITE_META[php_socket_project]:-${SITE_META[project]}}" "$SITE_PROFILE_CERT" "$SITE_PROFILE_KEY" "$SITE_PROFILE_CHAIN" \
    "$SITE_PROFILE_REDIRECT" "$SITE_PROFILE_HSTS" "$template_id" "${SITE_META[public_dir]}" \
    "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" "${SITE_META[frame_policy]:-same-origin}" || return 1
  site_nginx_metadata_upsert "$cfg" "$domain" "${SITE_META[project]}" "${SITE_META[profile]}" "${SITE_META[root]}" "${SITE_META[project]}" \
    "${SITE_META[php]}" "${SITE_META[ssl]:-none}" "" "${SITE_META[target]:-}" "${SITE_META[php_socket_project]:-${SITE_META[project]}}" \
    "$template_id" "${SITE_META[public_dir]}" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" >/dev/null 2>&1 || true
}

site_apache_handler() {
  parse_kv_args "$@"
  require_args "domain enable" || return 1
  local domain="${PARSED_ARGS[domain]}" enable="${PARSED_ARGS[enable],,}" confirm="${PARSED_ARGS[confirm]:-}"
  [[ "$enable" == yes || "$enable" == no ]] || { error "--enable must be yes or no"; return 1; }
  validate_domain "$domain" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]}" project="${SITE_META[project]}"
  local template_id="${SITE_META[nginx_template]:-$profile}"
  if ! apache_profile_supported "$template_id"; then
    error "Apache mode is for PHP sites (profiles: ${APACHE_PROFILES}); ${domain} is ${profile}"
    return 1
  fi
  local want=nginx current
  [[ "$enable" == yes ]] && want=apache
  current=$(site_web_backend "$domain")
  if [[ "$current" == "$want" && ( "$want" == nginx || -f "$(apache_site_file "$project")" ) ]]; then
    info "${domain} already runs on ${want}"
    return 0
  fi
  site_apache_plan "$domain" "$enable" "$profile"
  case "${confirm,,}" in
    yes|true|1) ;;
    *) info "Plan only. Run again with --confirm yes to apply."; return 0 ;;
  esac

  if [[ "$want" == apache ]]; then
    if ! apache_installed; then
      apache_install || { error "Apache could not be installed; nothing changed"; return 1; }
    else
      apache_configure
    fi
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf" tx before
  tx=$(mktemp -d)
  cp -p "$cfg" "${tx}/nginx.conf"
  [[ -f "$(apache_site_file "$project")" ]] && cp -p "$(apache_site_file "$project")" "${tx}/apache.conf"
  before=$(nginx_custom_answers "$domain")

  site_web_backend_set "$domain" "$want"
  local ok=1
  site_apache_render "$domain" || ok=0
  if (( ok )); then
    sleep 1  # reload returns before the workers have the new configuration
    if [[ "$before" == yes ]]; then
      local _ now=""
      for _ in 1 2 3; do
        now=$(nginx_custom_answers "$domain"); [[ "$now" == yes ]] && break; sleep 2
      done
      [[ "$now" == yes ]] || { ok=0; error "${domain} stopped answering on ${want}; putting it back"; }
    fi
  fi
  if (( ! ok )); then
    site_web_backend_set "$domain" "$current"
    cp -p "${tx}/nginx.conf" "$cfg"
    ln -sf "$cfg" "/etc/nginx/sites-enabled/${domain}.conf"
    if [[ -f "${tx}/apache.conf" ]]; then
      cp -p "${tx}/apache.conf" "$(apache_site_file "$project")"
      apache_reload >/dev/null 2>&1 || true
    else
      apache_site_remove "$project"
    fi
    nginx -t >>"$LOG_FILE" 2>&1 && os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1 || true
    rm -rf -- "$tx"
    error "Nothing changed for ${domain}"
    return 1
  fi
  rm -rf -- "$tx"
  ui_result_table "Domain|${domain}" "Web server|${want}" \
    "Apache error log|$([[ "$want" == apache ]] && echo "/var/log/apache2/${project}.error.log" || echo -)"
}

register_cmd "site" "apache" "Serve a PHP site through Apache behind nginx (.htaccess), or back on nginx only" "site_apache_handler" "domain enable" "confirm=" "tier:advanced plan:handler"
