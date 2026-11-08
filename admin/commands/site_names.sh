#!/usr/bin/env bash
set -euo pipefail

# A site's extra names (www, other domains): lib/site_names.py keeps the list;
# here nginx and the certificate follow it.

SIMAI_SITE_NAMES_PY="${SIMAI_ENV_ROOT}/lib/site_names.py"
site_names_py() { python3 -I "$SIMAI_SITE_NAMES_PY" "$@"; }
site_names_nginx() { echo "/etc/nginx/conf.d/simai-site-names-${1}.conf"; }

site_names_site_ok() {
  local domain="$1"
  [[ -n "$domain" ]] || { error "--domain is required"; return 1; }
  validate_domain "$domain" || return 1
  [[ -f "/etc/nginx/sites-available/${domain}.conf" ]] || { error "Site ${domain} not found"; return 1; }
  read_site_metadata "$domain" >/dev/null 2>&1 || { error "Failed to read site metadata for ${domain}"; return 1; }
  [[ "${SITE_META[profile]:-}" != alias ]] || { error "An alias site has no names of its own; add the name to ${SITE_META[target]:-its target}"; return 1; }
}

# The site's ACME folder, from its own nginx file (created when missing).
site_names_webroot() {
  local conf="/etc/nginx/sites-available/${1}.conf" webroot
  webroot=$(sed -n 's#^[[:space:]]*alias \(.*\)/\.well-known/acme-challenge/;#\1#p' "$conf" | head -n1)
  [[ -n "$webroot" ]] || return 1
  mkdir -p "${webroot}/.well-known/acme-challenge" && chmod 755 "$webroot" "${webroot}/.well-known" "${webroot}/.well-known/acme-challenge" || return 1
  echo "$webroot"
}

# Writes the site's server_name lines and the redirect file from the list;
# on an nginx refusal everything goes back as it was.
site_names_apply() {
  local domain="$1" conf="/etc/nginx/sites-available/${1}.conf" extra_file value text conf_backup extra_backup="" tmp
  extra_file=$(site_names_nginx "$domain")
  read_site_metadata "$domain" >/dev/null 2>&1 || return 1
  value=$(site_server_name_value "$domain" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}")
  conf_backup=$(mktemp) && cp -p "$conf" "$conf_backup"
  [[ -f "$extra_file" ]] && { extra_backup=$(mktemp); cp -p "$extra_file" "$extra_backup"; }
  tmp=$(mktemp "${conf}.XXXXXX")
  sed -E "s#^([[:space:]]*server_name)[[:space:]]+[^;]+;#\\1 ${value};#" "$conf" >"$tmp" && chmod --reference="$conf" "$tmp" && mv -f "$tmp" "$conf"
  text=$(site_names_py render "$domain" "$conf") || text=""
  if [[ -n "$text" ]]; then
    printf '%s\n' "$text" >"${extra_file}.tmp" && chmod 0644 "${extra_file}.tmp" && mv -f "${extra_file}.tmp" "$extra_file"
  else
    rm -f -- "$extra_file"
  fi
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    mv -f "$conf_backup" "$conf"
    if [[ -n "$extra_backup" ]]; then mv -f "$extra_backup" "$extra_file"; else rm -f -- "$extra_file"; fi
    error "nginx refused the names of ${domain}; nothing changed. See ${LOG_FILE}"
    return 1
  fi
  rm -f -- "$conf_backup" "${extra_backup:-/nonexistent}"
  os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1 || { error "nginx did not reload"; return 1; }
}

# The site's Let's Encrypt certificate for the main domain and every extra
# name (one certificate). Nothing to do for a site without one.
site_names_has_le() { [[ -d "/etc/letsencrypt/live/${1}" && -f "/etc/letsencrypt/renewal/${1}.conf" ]]; }

site_names_certificate() {
  local domain="$1" webroot name
  site_names_has_le "$domain" || return 0
  webroot=$(site_names_webroot "$domain") || { error "The site has no ACME location; cannot extend its certificate"; return 1; }
  local -a cmd=(certbot certonly --cert-name "$domain" --webroot -w "$webroot" --non-interactive --agree-tos --expand --keep-until-expiring)
  for name in $(site_names_py cert-names "$domain"); do cmd+=(-d "$name"); done
  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    error "Let's Encrypt did not issue the certificate for $(site_names_py cert-names "$domain") (each name must point to this server and port 80 must be reachable). See ${LOG_FILE}"
    return 1
  fi
}

site_names_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  site_names_site_ok "$domain" || return 1
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    site_names_py describe "$domain" json
  else
    site_names_py describe "$domain"
  fi
}

site_name_add_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" name="${PARSED_ARGS[name]:-}" mode="${PARSED_ARGS[mode]:-redirect}" check="${PARSED_ARGS[check-dns]:-yes}" owner got
  name="${name,,}"
  site_names_site_ok "$domain" || return 1
  [[ "$mode" == serve || "$mode" == redirect ]] || { error "--mode must be serve or redirect"; return 1; }
  validate_domain "$name" || return 1
  [[ "$name" != "$domain" ]] || { error "${name} is the site's main domain"; return 1; }
  if owner=$(site_names_py taken "$name" "$domain"); then
    error "${name} already belongs to ${owner}"
    return 1
  fi
  # A name already listed may change its mode; the old mode comes back on failure.
  local was
  was=$(site_names_py list "$domain" | awk -v n="$name" '$1 == n {print $2}')
  [[ "$was" == "$mode" ]] && { info "${name} is already a name of ${domain} (${mode})"; return 0; }
  progress_init 3
  progress_step "Checking that ${name} points to this server"
  if [[ "$check" != no ]] && ! got=$(python3 -I "${SIMAI_ENV_ROOT}/lib/panel_address.py" resolves "$name"); then
    error "${name} does not point to this server ($(python3 -I "${SIMAI_ENV_ROOT}/lib/panel_address.py" ip)); it resolves to: ${got:-nothing}. Add an A record and try again in a few minutes"
    return 1
  fi
  site_name_undo() {
    if [[ -n "$was" ]]; then site_names_py add "$domain" "$name" "$was" || true; else site_names_py remove "$domain" "$name" || true; fi
  }
  progress_step "Adding ${name} to ${domain} (${mode})"
  site_names_py add "$domain" "$name" "$mode" || return 1
  if ! site_names_apply "$domain"; then
    site_name_undo
    return 1
  fi
  progress_step "Extending the certificate"
  if ! site_names_certificate "$domain"; then
    # Nothing is left of the new name: the certificate keeps the names it had.
    site_name_undo
    site_names_apply "$domain" || true
    return 1
  fi
  site_names_apply "$domain" || return 1  # the redirect file gains its HTTPS block once the certificate covers the name
  ui_result_table "Site|${domain}" "Name|${name}" "Mode|${mode}" \
    "HTTPS|$(site_names_has_le "$domain" && echo "covered by the site's certificate" || echo "no certificate on the site")"
}

site_name_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" name="${PARSED_ARGS[name]:-}"
  name="${name,,}"
  site_names_site_ok "$domain" || return 1
  site_names_py list "$domain" | awk '{print $1}' | grep -x -- "$name" >/dev/null || { error "${name} is not an extra name of ${domain}"; return 1; }
  progress_init 2
  progress_step "Removing ${name} from ${domain}"
  site_names_py remove "$domain" "$name" || return 1
  site_names_apply "$domain" || return 1
  progress_step "Reissuing the certificate without ${name}"
  site_names_certificate "$domain" || warn "The certificate still holds ${name}; it is renewed with the other names next time"
  ui_result_table "Site|${domain}" "Removed|${name}"
}

register_cmd "site" "names" "Show a site's names: main domain, extra names (www, aliases), DNS and HTTPS" "site_names_handler" "domain" "" "effects:read"
register_cmd "site" "name-add" "Add an extra name (www, another domain) that shows the site or redirects to it; the certificate follows" "site_name_add_handler" "domain name" "mode= check-dns=" "tier:advanced"
register_cmd "site" "name-remove" "Remove an extra name of a site; the certificate is reissued without it" "site_name_remove_handler" "domain name" "" "tier:advanced"
