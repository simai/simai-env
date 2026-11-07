#!/usr/bin/env bash
set -euo pipefail

# Where the panel answers (lib/panel_address.py): the server's address on the
# panel port (8500 by default, self-signed certificate), and a domain
# attached later with its Let's Encrypt certificate. Both are copies of the
# panel site's server block in one nginx file outside the site list, kept in
# step by `self status-refresh`.

SIMAI_PANEL_ADDRESS_PY="${SIMAI_ENV_ROOT}/lib/panel_address.py"
SIMAI_PANEL_ADDRESS_NGINX="${SIMAI_PANEL_ADDRESS_NGINX:-/etc/nginx/conf.d/simai-panel-address.conf}"
SIMAI_PANEL_ADDRESS_STATE="${SIMAI_PANEL_ADDRESS_STATE:-/etc/simai-env/panel-address.json}"
SIMAI_PANEL_TLS_DIR="${SIMAI_PANEL_TLS_DIR:-/etc/simai-env/panel-tls}"
SIMAI_PANEL_INTERNAL_DOMAIN="panel.internal"
export SIMAI_PANEL_ADDRESS_STATE

panel_address_py() { python3 -I "$SIMAI_PANEL_ADDRESS_PY" "$@"; }

# The self-signed certificate of the panel port, for the server's addresses.
# Made again when an address is missing from it.
panel_address_cert_ensure() {
  local cert="${SIMAI_PANEL_TLS_DIR}/cert.pem" key="${SIMAI_PANEL_TLS_DIR}/key.pem" san="DNS:${SIMAI_PANEL_INTERNAL_DOMAIN}" addr have
  while IFS= read -r addr; do
    [[ -n "$addr" ]] && san+=",IP:${addr}"
  done < <(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import panel_address; print("\n".join(panel_address.addresses()))' "${SIMAI_ENV_ROOT}/lib" 2>/dev/null)
  if [[ -s "$cert" && -s "$key" ]]; then
    have=$(openssl x509 -in "$cert" -noout -ext subjectAltName 2>/dev/null | tr -d ' \n' | sed 's/IPAddress:/IP:/g; s/^X509v3SubjectAlternativeName://')
    local missing=0 part
    IFS=',' read -r -a parts <<<"$san"
    for part in "${parts[@]}"; do [[ ",${have}," == *",${part},"* ]] || missing=1; done
    (( missing == 0 )) && return 0
  fi
  install -d -m 0700 -o root -g root "$SIMAI_PANEL_TLS_DIR" || return 1
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
    -subj "/CN=SIMAI Panel" -addext "subjectAltName=${san}" \
    -keyout "${key}.new" -out "${cert}.new" >>"$LOG_FILE" 2>&1 || { error "Cannot make the panel certificate"; return 1; }
  chmod 0600 "${key}.new"; chmod 0644 "${cert}.new"
  mv -f "${key}.new" "$key" && mv -f "${cert}.new" "$cert"
}

# The nginx text for the panel addresses, empty when no panel is installed.
panel_address_render() {
  local domain conf http2=no
  domain=$(panel_state_get PANEL_DOMAIN)
  [[ -n "$domain" ]] || return 0
  conf="/etc/nginx/sites-available/${domain}.conf"
  [[ -f "$conf" ]] || return 0
  panel_address_cert_ensure || return 1
  nginx_supports_http2_directive && http2=yes
  SIMAI_NGINX_HTTP2_DIRECTIVE="$http2" panel_address_py render "$conf" "${SIMAI_PANEL_TLS_DIR}/cert.pem" "${SIMAI_PANEL_TLS_DIR}/key.pem"
}

panel_address_ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; }

# Opens the panel port in ufw (when ufw is on); `close` removes the rule.
panel_address_port_rule() {
  local verb="$1" port="$2"
  panel_address_ufw_active || return 0
  if [[ "$verb" == open ]]; then
    ufw status 2>/dev/null | grep -E "^${port}/tcp +ALLOW +Anywhere( |$)" >/dev/null && return 0
    ufw allow "${port}/tcp" comment simai-panel >>"$LOG_FILE" 2>&1
  else
    ufw delete allow "${port}/tcp" >>"$LOG_FILE" 2>&1 || true
  fi
}

# Writes the nginx file when it differs and reloads nginx; a configuration
# nginx refuses is put back. Prints "changed" when it wrote.
panel_address_sync() {
  local text tmp backup=""
  text=$(panel_address_render) || return 1
  if [[ -z "$text" ]]; then
    [[ -f "$SIMAI_PANEL_ADDRESS_NGINX" ]] || return 0
    rm -f -- "$SIMAI_PANEL_ADDRESS_NGINX"
    nginx -t >>"$LOG_FILE" 2>&1 && os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1
    echo changed
    return 0
  fi
  if [[ "$(panel_address_py get ip_access)" == yes ]]; then
    panel_address_port_rule open "$(panel_address_py get port)" || warn "Could not open the panel port in the firewall"
  fi
  [[ -f "$SIMAI_PANEL_ADDRESS_NGINX" && "$(cat "$SIMAI_PANEL_ADDRESS_NGINX")" == "$text" ]] && return 0
  if [[ -f "$SIMAI_PANEL_ADDRESS_NGINX" ]]; then
    backup=$(mktemp) && cp -p "$SIMAI_PANEL_ADDRESS_NGINX" "$backup"
  fi
  tmp=$(mktemp "${SIMAI_PANEL_ADDRESS_NGINX}.XXXXXX") || return 1
  printf '%s\n' "$text" >"$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$SIMAI_PANEL_ADDRESS_NGINX"
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    if [[ -n "$backup" ]]; then mv -f "$backup" "$SIMAI_PANEL_ADDRESS_NGINX"; else rm -f -- "$SIMAI_PANEL_ADDRESS_NGINX"; fi
    error "nginx refused the panel address configuration; nothing changed. See ${LOG_FILE}"
    return 1
  fi
  [[ -n "$backup" ]] && rm -f -- "$backup"
  os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1 || { error "nginx did not reload"; return 1; }
  echo changed
}

# The address the panel should call itself: the domain once it has a
# certificate, otherwise the server's address and port.
panel_address_url() {
  panel_address_py describe "$(panel_state_get PANEL_DOMAIN)" "${SIMAI_PANEL_TLS_DIR}/cert.pem" json \
    | python3 -I -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "${1:-url}"
}

panel_address_app_url() {
  local domain url
  domain=$(panel_state_get PANEL_DOMAIN)
  [[ -n "$domain" && "$(panel_state_get SOURCE)" == build ]] || return 0
  url=$(panel_address_url) || return 0
  [[ -n "$url" ]] && panel_env_set "$domain" APP_URL "$url"
  return 0
}

panel_address_require() {
  [[ -n "$(panel_state_get PANEL_DOMAIN)" ]] || { error "The panel is not installed (panel install)"; return 1; }
}

panel_address_handler() {
  parse_kv_args "$@"
  local out=human
  [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]] && out=json
  if [[ "$out" == json ]]; then
    panel_address_py describe "$(panel_state_get PANEL_DOMAIN)" "${SIMAI_PANEL_TLS_DIR}/cert.pem" json
  else
    panel_address_py describe "$(panel_state_get PANEL_DOMAIN)" "${SIMAI_PANEL_TLS_DIR}/cert.pem"
  fi
}

# A timed change: undone in --window seconds unless `change confirm` comes,
# so a port the provider's network blocks does not lock anyone out.
panel_address_timed() {
  local summary="$1" window="$2"; shift 2
  local begun id expires
  local -a files=("$SIMAI_PANEL_ADDRESS_STATE" "$SIMAI_PANEL_ADDRESS_NGINX")
  panel_address_ufw_active && files+=(/etc/ufw/user.rules /etc/ufw/user6.rules)
  [[ -f "$SIMAI_PANEL_ADDRESS_STATE" ]] || panel_address_py set port "$(panel_address_py get port)" || return 1
  begun=$(timed_change_begin panel_address "" "$window" "$summary" "${files[@]}") || return 1
  read -r id expires <<<"$begun"
  if ! "$@"; then
    timed_change_undo "$id" >/dev/null || true
    error "The panel address was not changed: ${summary}"
    return 1
  fi
  timed_change_arm "$id" "$expires" "$window" panel_address
}

panel_port_apply() {
  local port="$1" old="$2"
  panel_address_py set port "$port" || return 1
  panel_address_sync >/dev/null || return 1
  [[ "$old" == "$port" ]] || panel_address_port_rule close "$old"
  panel_address_app_url
}

panel_port_handler() {
  parse_kv_args "$@"
  require_args "port" || return 1
  local port="${PARSED_ARGS[port]}" old window
  panel_address_require || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-300}") || return 1
  panel_address_py port-ok "$port" || return 1
  old=$(panel_address_py get port)
  panel_address_timed "panel port ${old} -> ${port}" "$window" panel_port_apply "$port" "$old"
  ui_result_table "Panel address|$(panel_address_url ip_url)" "Previous port|${old}"
}

panel_ip_access_apply() {
  local enabled="$1" port
  port=$(panel_address_py get port)
  panel_address_py set ip_access "$enabled" || return 1
  panel_address_sync >/dev/null || return 1
  [[ "$enabled" == yes ]] || panel_address_port_rule close "$port"
  panel_address_app_url
}

panel_ip_access_handler() {
  parse_kv_args "$@"
  require_args "enabled" || return 1
  local enabled="${PARSED_ARGS[enabled]}" window
  panel_address_require || return 1
  [[ "$enabled" =~ ^(yes|no)$ ]] || { error "--enabled must be yes or no"; return 1; }
  window=$(firewall_window "${PARSED_ARGS[window]:-300}") || return 1
  if [[ "$enabled" == no && "$(panel_address_url domain_ssl)" != True ]]; then
    error "The panel has no domain with a certificate yet; attach one first (panel domain), or the panel would be reachable only over plain HTTP"
    return 1
  fi
  panel_address_timed "panel address by IP: ${enabled}" "$window" panel_ip_access_apply "$enabled"
}

panel_domain_webroot() {
  local conf="$1"
  sed -n 's#^[[:space:]]*alias \(.*\)/\.well-known/acme-challenge/;#\1#p' "$conf" | head -n1
}

panel_domain_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" email="${PARSED_ARGS[email]:-}" remove="${PARSED_ARGS[remove]:-no}"
  local check="${PARSED_ARGS[check-dns]:-yes}" site conf webroot got
  panel_address_require || return 1
  site=$(panel_state_get PANEL_DOMAIN)
  conf="/etc/nginx/sites-available/${site}.conf"
  if [[ "$remove" == yes ]]; then
    [[ -n "$(panel_address_py get domain)" ]] || { info "No domain is attached to the panel"; return 0; }
    [[ "$(panel_address_py get ip_access)" == yes ]] || { error "Turn on the address by IP first (panel ip-access --enabled yes): the panel would have no address"; return 1; }
    panel_address_py set domain "" && panel_address_sync >/dev/null && panel_address_app_url || return 1
    ui_result_table "Panel domain|removed" "Panel address|$(panel_address_url)"
    return 0
  fi
  require_args "domain" || return 1
  domain=$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')
  [[ "$site" == "$SIMAI_PANEL_INTERNAL_DOMAIN" ]] || { error "The panel was installed at its own domain ${site}"; return 1; }
  validate_domain "$domain" || return 1
  [[ ! -f "/etc/nginx/sites-available/${domain}.conf" ]] || { error "${domain} is a site on this server; the panel needs a domain of its own"; return 1; }
  [[ -z "$email" || "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { error "--email is not an email address"; return 1; }
  command -v certbot >/dev/null 2>&1 || { error "certbot is not installed"; return 1; }
  webroot=$(panel_domain_webroot "$conf")
  [[ -n "$webroot" ]] || { error "The panel site has no ACME challenge location; cannot request a certificate"; return 1; }
  if [[ "$check" != no ]]; then
    progress_init 3
    progress_step "Checking that ${domain} points to this server"
    if ! got=$(panel_address_py resolves "$domain"); then
      error "${domain} does not point to this server ($(panel_address_py ip)); it resolves to: ${got:-nothing}. Add an A record and try again in a few minutes"
      return 1
    fi
  else
    progress_init 2
  fi
  progress_step "Serving the panel at http://${domain}"
  panel_address_py set domain "$domain" && panel_address_sync >/dev/null || { panel_address_py set domain "" || true; return 1; }
  progress_step "Requesting a Let's Encrypt certificate for ${domain}"
  # A panel with releases serves current/public; the ACME location points to
  # <root>/public, which only exists once something creates it.
  mkdir -p "${webroot}/.well-known/acme-challenge" && chmod 755 "$webroot" "${webroot}/.well-known" "${webroot}/.well-known/acme-challenge" \
    || { error "Cannot prepare ${webroot} for the certificate check"; panel_address_py set domain "" || true; panel_address_sync >/dev/null || true; return 1; }
  local -a cmd=(certbot certonly --cert-name "$domain" --webroot -w "$webroot" -d "$domain" --non-interactive --agree-tos --keep-until-expiring)
  if [[ -n "$email" ]]; then cmd+=(-m "$email"); else cmd+=(--register-unsafely-without-email); fi
  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    panel_address_py set domain "" || true
    panel_address_sync >/dev/null || true
    error "Let's Encrypt did not issue a certificate for ${domain} (port 80 must be reachable from the internet); nothing changed. See ${LOG_FILE}"
    return 1
  fi
  panel_address_py set domain "$domain" && panel_address_py set domain_ssl yes && panel_address_sync >/dev/null || return 1
  panel_address_app_url
  ui_result_table "Panel domain|${domain}" "Panel address|$(panel_address_url)" \
    "By IP|$(panel_address_url ip_url)" "Renewal|automatic (ssl renew-due)"
}

register_cmd "panel" "address" "Show where the panel answers: the server's address and port, and its domain" "panel_address_handler" "" "" "effects:read"
register_cmd "panel" "port" "Move the panel to another port (undone in --window seconds unless confirmed)" "panel_port_handler" "port" "window=" "tier:advanced"
register_cmd "panel" "ip-access" "Turn the panel's address by IP and port on or off (undone unless confirmed)" "panel_ip_access_handler" "enabled" "window=" "tier:advanced"
register_cmd "panel" "domain" "Attach a domain to the panel with a Let's Encrypt certificate, or --remove yes" "panel_domain_handler" "" "domain= email= remove= check-dns=" "tier:advanced"
