#!/usr/bin/env bash
set -euo pipefail

ssl_select_domain() {
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=() filtered=()
    mapfile -t sites < <(list_sites)
    filtered=("${sites[@]}")
    domain=$(select_from_list "Select domain" "" "${filtered[@]}")
  fi
  if [[ -z "$domain" ]]; then
    domain=$(prompt "domain")
  fi
  [[ -z "$domain" ]] && return 1
  PARSED_ARGS[domain]="$domain"
  echo "$domain"
}

ssl_site_context() {
  local domain="$1"
  read_site_metadata "$domain"
  SITE_SSL_PROJECT="${SITE_META[project]}"
  SITE_SSL_ROOT="${SITE_META[root]}"
  SITE_SSL_PROFILE="${SITE_META[profile]}"
  SITE_SSL_PHP="${SITE_META[php]}"
  SITE_SSL_SOCKET_PROJECT="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
  [[ -z "$SITE_SSL_PHP" ]] && SITE_SSL_PHP="8.2"
}

ssl_apply_nginx() {
  local domain="$1" cert="$2" key="$3" chain="$4" redirect="$5" hsts="$6"
  ssl_site_context "$domain" || return 1
  local template="$NGINX_TEMPLATE"
  [[ "$SITE_SSL_PROFILE" == "generic" ]] && template="$NGINX_TEMPLATE_GENERIC"
  create_nginx_site "$domain" "$SITE_SSL_PROJECT" "$SITE_SSL_ROOT" "$SITE_SSL_PHP" "$template" "$SITE_SSL_PROFILE" "" "$SITE_SSL_SOCKET_PROJECT" "$cert" "$key" "$chain" "$redirect" "$hsts"
}

ssl_issue_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(ssl_select_domain)
  local domain="${PARSED_ARGS[domain]:-$domain}"
  local email="${PARSED_ARGS[email]:-}"
  local redirect="${PARSED_ARGS[redirect]:-}"
  local hsts="${PARSED_ARGS[hsts]:-}"
  local staging="${PARSED_ARGS[staging]:-}"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    if [[ -z "$domain" ]]; then
      local sites=()
      mapfile -t sites < <(list_sites)
      domain=$(select_from_list "Select domain" "" "${sites[@]}")
      PARSED_ARGS[domain]="$domain"
    fi
    if [[ -z "$email" ]]; then
      email=$(prompt "email")
      PARSED_ARGS[email]="$email"
    fi
    [[ -z "$redirect" ]] && redirect=$(select_from_list "Redirect HTTP to HTTPS?" "no" "no" "yes")
    [[ -z "$hsts" ]] && hsts=$(select_from_list "Enable HSTS?" "no" "no" "yes")
    [[ -z "$staging" ]] && staging=$(select_from_list "Use Let's Encrypt staging?" "no" "no" "yes")
  fi
  [[ -z "$redirect" ]] && redirect="no"
  [[ -z "$hsts" ]] && hsts="no"
  [[ -z "$staging" ]] && staging="no"

  PARSED_ARGS[domain]="$domain"
  PARSED_ARGS[email]="$email"
  require_args "domain email"

  if [[ -z "$domain" || -z "$email" ]]; then
    error "domain and email are required"
    return 1
  fi
  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot is not installed"
    return 1
  fi
  ssl_site_context "$domain" || return 1
  local webroot="${SITE_SSL_ROOT}/public"
  mkdir -p "$webroot"

  local cmd=(certbot certonly --webroot -w "$webroot" -d "$domain" --non-interactive --agree-tos -m "$email" --keep-until-expiring)
  [[ "$staging" == "yes" ]] && cmd+=(--staging)
  info "Issuing Let's Encrypt certificate for ${domain} via webroot ${webroot}"
  if ! "${cmd[@]}" >>"$LOG_FILE" 2>&1; then
    error "certbot failed for ${domain}; see ${LOG_FILE}"
    return 1
  fi
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local chain="/etc/letsencrypt/live/${domain}/chain.pem"
  ssl_apply_nginx "$domain" "$cert" "$key" "$chain" "$redirect" "$hsts"
  ensure_certbot_cron
  echo "===== SSL issue summary ====="
  echo "Domain   : ${domain}"
  echo "Type     : Let's Encrypt"
  echo "Cert     : ${cert}"
  echo "Key      : ${key}"
  echo "Chain    : ${chain}"
  echo "Redirect : ${redirect}"
  echo "HSTS     : ${hsts}"
}

ssl_install_custom_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(ssl_select_domain)
  local redirect="${PARSED_ARGS[redirect]:-no}"
  local hsts="${PARSED_ARGS[hsts]:-no}"
  local cert_src="${PARSED_ARGS[cert]:-}"
  local key_src="${PARSED_ARGS[key]:-}"
  local chain_src="${PARSED_ARGS[chain]:-}"
  [[ -n "$domain" ]] && PARSED_ARGS[domain]="$domain"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    if [[ -z "$domain" ]]; then
      local sites=()
      mapfile -t sites < <(list_sites)
      domain=$(select_from_list "Select domain" "" "${sites[@]}")
      PARSED_ARGS[domain]="$domain"
    fi
  fi
  domain="${PARSED_ARGS[domain]:-$domain}"
  require_args "domain"
  domain="${PARSED_ARGS[domain]}"
  local dest_dir
  dest_dir=$(ensure_ssl_dir "$domain")
  local cert_dst="${dest_dir}/fullchain.pem"
  local key_dst="${dest_dir}/privkey.pem"
  local chain_dst="${dest_dir}/chain.pem"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    cert_src=${cert_src:-$cert_dst}
    key_src=${key_src:-$key_dst}
    chain_src=${chain_src:-}
    cert_src=$(prompt "Path to certificate" "$cert_src")
    key_src=$(prompt "Path to private key" "$key_src")
    if [[ -n "$chain_src" ]]; then
      chain_src=$(prompt "Path to chain (optional)" "$chain_src")
    fi
    redirect=$(select_from_list "Redirect HTTP to HTTPS?" "no" "no" "yes")
    hsts=$(select_from_list "Enable HSTS?" "no" "no" "yes")
  fi

  if [[ -z "$cert_src" || -z "$key_src" ]]; then
    error "cert and key paths are required"
    return 1
  fi

  if [[ "$cert_src" != "$cert_dst" ]]; then
    cp -f "$cert_src" "$cert_dst"
  fi
  if [[ "$key_src" != "$key_dst" ]]; then
    cp -f "$key_src" "$key_dst"
  fi
  if [[ -n "$chain_src" && -f "$chain_src" && "$chain_src" != "$chain_dst" ]]; then
    cp -f "$chain_src" "$chain_dst"
  fi
  chmod 640 "$cert_dst" "$key_dst" 2>/dev/null || true
  [[ -f "$chain_dst" ]] && chmod 640 "$chain_dst" 2>/dev/null || true

  local chain_arg=""
  [[ -f "$chain_dst" ]] && chain_arg="$chain_dst"
  ssl_apply_nginx "$domain" "$cert_dst" "$key_dst" "$chain_arg" "$redirect" "$hsts"
  echo "===== SSL install summary ====="
  echo "Domain   : ${domain}"
  echo "Type     : custom"
  echo "Cert     : ${cert_dst}"
  echo "Key      : ${key_dst}"
  [[ -n "$chain_arg" ]] && echo "Chain    : ${chain_arg}"
  echo "Redirect : ${redirect}"
  echo "HSTS     : ${hsts}"
}

ssl_renew_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(ssl_select_domain)
  local domain="${PARSED_ARGS[domain]:-$domain}"
  require_args "domain"
  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot is not installed"
    return 1
  fi
  ssl_site_context "$domain" || return 1
  local webroot="${SITE_SSL_ROOT}/public"
  info "Renewing certificate for ${domain}"
  if ! certbot certonly --keep-until-expiring --force-renewal --non-interactive --agree-tos --webroot -w "$webroot" -d "$domain" >>"$LOG_FILE" 2>&1; then
    error "Renew failed for ${domain}; see ${LOG_FILE}"
    return 1
  fi
  systemctl reload nginx >>"$LOG_FILE" 2>&1 || true
  echo "Renewed certificate for ${domain}"
}

ssl_remove_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(ssl_select_domain)
  local domain="${PARSED_ARGS[domain]:-$domain}"
  require_args "domain"
  local delete_cert="${PARSED_ARGS[delete-cert]:-no}"
  ssl_site_context "$domain" || return 1
  local template="$NGINX_TEMPLATE"
  [[ "$SITE_SSL_PROFILE" == "generic" ]] && template="$NGINX_TEMPLATE_GENERIC"
  info "Removing SSL config for ${domain}"
  create_nginx_site "$domain" "$SITE_SSL_PROJECT" "$SITE_SSL_ROOT" "$SITE_SSL_PHP" "$template" "$SITE_SSL_PROFILE" "" "$SITE_SSL_SOCKET_PROJECT" "" "" "" "no" "no"
  if [[ "$delete_cert" == "yes" ]]; then
    if command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$domain" --non-interactive >>"$LOG_FILE" 2>&1 || true
    fi
    rm -rf "/etc/nginx/ssl/${domain}" >>"$LOG_FILE" 2>&1 || true
  fi
  echo "===== SSL remove summary ====="
  echo "Domain : ${domain}"
  echo "SSL    : disabled"
  echo "Cert   : $([[ "$delete_cert" == "yes" ]] && echo deleted || echo kept)"
}

ssl_status_handler() {
  parse_kv_args "$@"
  local domain
  domain=$(ssl_select_domain)
  domain="${PARSED_ARGS[domain]:-$domain}"
  if [[ -z "$domain" ]]; then
    error "domain is required"
    return 1
  fi
  local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local le_key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local custom_cert="/etc/nginx/ssl/${domain}/fullchain.pem"
  local custom_key="/etc/nginx/ssl/${domain}/privkey.pem"
  local cert_path="" key_path="" type="none"
  if [[ -f "$le_cert" && -f "$le_key" ]]; then
    cert_path="$le_cert"
    key_path="$le_key"
    type="letsencrypt"
  elif [[ -f "$custom_cert" && -f "$custom_key" ]]; then
    cert_path="$custom_cert"
    key_path="$custom_key"
    type="custom"
  fi
  local not_after="(unknown)" not_before="(unknown)"
  if [[ -n "$cert_path" ]]; then
    not_after=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
    not_before=$(openssl x509 -startdate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
  fi
  local sep="+----------------------+----------------------"
  printf "%s\n" "${sep}+"
  printf "| %-20s | %-20s |\n" "Domain" "$domain"
  printf "| %-20s | %-20s |\n" "Type" "$type"
  printf "| %-20s | %-20s |\n" "Cert" "${cert_path:-none}"
  printf "| %-20s | %-20s |\n" "Key" "${key_path:-none}"
  printf "| %-20s | %-20s |\n" "Not before" "$not_before"
  printf "| %-20s | %-20s |\n" "Not after" "$not_after"
  printf "%s\n" "${sep}+"
}

register_cmd "ssl" "letsencrypt" "Request Let's Encrypt certificate" "ssl_issue_handler" "" "domain= email= redirect= hsts= staging="
register_cmd "ssl" "install" "Install custom certificate" "ssl_install_custom_handler" "" "domain= cert= key= chain= redirect= hsts="
register_cmd "ssl" "renew" "Renew certificate" "ssl_renew_handler" "" "domain="
register_cmd "ssl" "remove" "Disable SSL and optionally delete cert" "ssl_remove_handler" "" "domain= delete-cert="
register_cmd "ssl" "status" "Show SSL status for domain" "ssl_status_handler" "" "domain="
