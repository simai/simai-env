#!/usr/bin/env bash
set -euo pipefail

ssl_site_env_file() {
  local domain="$1"
  echo "/etc/simai-env/sites/${domain}/ssl.env"
}

ssl_site_write_state() {
  local domain="$1"
  shift
  local file dir tmp
  file=$(ssl_site_env_file "$domain")
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp=$(mktemp)
  local entry
  for entry in "$@"; do
    [[ -z "$entry" ]] && continue
    printf "%s=%s\n" "${entry%%|*}" "${entry#*|}" >>"$tmp"
  done
  if [[ -s "$tmp" ]]; then
    mv "$tmp" "$file"
    chmod 0600 "$file"
    chown root:root "$file" 2>/dev/null || true
  else
    rm -f "$tmp"
  fi
}

ssl_site_read_var() {
  local domain="$1" key="$2"
  local file
  file=$(ssl_site_env_file "$domain")
  [[ -f "$file" ]] || return 1
  awk -F= -v target="$key" '
    $1 == target {
      val=substr($0, index($0, "=")+1)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      print val
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

ssl_dns_provider_normalize() {
  local provider="${1:-}"
  provider=$(echo "$provider" | tr '[:upper:]' '[:lower:]')
  case "$provider" in
    cloudflare|manual) echo "$provider" ;;
    *) return 1 ;;
  esac
}

ssl_dns_provider_package() {
  local provider="$1"
  case "$provider" in
    cloudflare) echo "python3-certbot-dns-cloudflare" ;;
    manual) echo "" ;;
    *) return 1 ;;
  esac
}

ssl_dns_provider_flag() {
  local provider="$1"
  case "$provider" in
    cloudflare) echo "--dns-cloudflare" ;;
    manual) echo "--manual" ;;
    *) return 1 ;;
  esac
}

ssl_dns_provider_credentials_flag() {
  local provider="$1"
  case "$provider" in
    cloudflare) echo "--dns-cloudflare-credentials" ;;
    manual) echo "" ;;
    *) return 1 ;;
  esac
}

ssl_ensure_dns_credentials_file() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    error "DNS credentials file not found: ${file}"
    return 1
  fi
  chmod 0600 "$file" 2>/dev/null || true
  return 0
}

ssl_dns_resolve_ipv4() {
  local host="$1"
  local ip=""
  if command -v getent >/dev/null 2>&1; then
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
  fi
  if [[ -z "$ip" && "$(command -v dig 2>/dev/null || true)" != "" ]]; then
    ip=$(dig +short A "$host" 2>/dev/null | awk 'NF {print; exit}')
  fi
  echo "$ip"
}

ssl_wildcard_probe_host() {
  local domain="$1"
  echo "wildcard-check.${domain}"
}

ssl_wildcard_preflight_show() {
  local domain="$1"
  local wildcard_domain="$2"
  local dns_provider="$3"
  local dns_credentials="$4"
  local provider_pkg plugin_flag probe_host primary_ip main_ip wildcard_ip
  local host_mode_ok="PASS"
  local main_status="PASS"
  local wildcard_status="PASS"
  local plugin_status="PASS"
  local credentials_status="PASS"
  local hard_fail=0 dns_warn=0

  probe_host=$(ssl_wildcard_probe_host "$domain")
  primary_ip=$(site_best_effort_primary_ip)
  main_ip=$(ssl_dns_resolve_ipv4 "$domain")
  wildcard_ip=$(ssl_dns_resolve_ipv4 "$probe_host")

  if [[ "${SITE_META[host_mode]:-standard}" != "wildcard" ]]; then
    host_mode_ok="FAIL (site is not in wildcard host mode)"
    hard_fail=1
  fi

  if [[ -z "$main_ip" ]]; then
    main_status="WARN (DNS A record not found)"
    dns_warn=1
  elif [[ -n "$primary_ip" && "$main_ip" != "$primary_ip" ]]; then
    main_status="WARN (${main_ip}; expected ${primary_ip})"
    dns_warn=1
  else
    main_status="PASS (${main_ip})"
  fi

  if [[ -z "$wildcard_ip" ]]; then
    wildcard_status="WARN (${probe_host} does not resolve yet)"
    dns_warn=1
  elif [[ -n "$primary_ip" && "$wildcard_ip" != "$primary_ip" ]]; then
    wildcard_status="WARN (${wildcard_ip}; expected ${primary_ip})"
    dns_warn=1
  else
    wildcard_status="PASS (${wildcard_ip})"
  fi

  if ! plugin_flag=$(ssl_dns_provider_flag "$dns_provider" 2>/dev/null); then
    plugin_status="FAIL (unsupported provider: ${dns_provider})"
    hard_fail=1
  elif [[ "$dns_provider" == "manual" ]]; then
    plugin_status="N/A (manual DNS challenge)"
    credentials_status="N/A (you will add TXT records yourself)"
  else
    provider_pkg=$(ssl_dns_provider_package "$dns_provider")
    if ! certbot plugins 2>/dev/null | grep -qi "${plugin_flag#--}"; then
      plugin_status="FAIL (install ${provider_pkg})"
      hard_fail=1
    fi
  fi

  if [[ "$dns_provider" != "manual" ]]; then
    if [[ -z "$dns_credentials" || ! -f "$dns_credentials" ]]; then
      credentials_status="FAIL (${dns_credentials:-missing})"
      hard_fail=1
    else
      credentials_status="PASS (${dns_credentials})"
    fi
  fi

  ui_section "Wildcard HTTPS"
  echo "One certificate will cover:"
  echo "- ${domain}"
  echo "- ${wildcard_domain}"
  echo
  echo "Required DNS records:"
  if [[ -n "$primary_ip" ]]; then
    echo "- ${domain} -> A -> ${primary_ip}"
    echo "- ${wildcard_domain} -> A -> ${primary_ip}"
  else
    echo "- ${domain} -> A -> <server-ip>"
    echo "- ${wildcard_domain} -> A -> <server-ip>"
  fi
  echo
  echo "TXT verification:"
  if [[ "$dns_provider" == "manual" ]]; then
    echo "- You WILL add temporary _acme-challenge TXT records manually."
    echo "- Certbot will show the exact TXT name and value during the next step."
  else
    echo "- You do NOT add TXT records manually when using Cloudflare API."
    echo "- SIMAI ENV / Certbot will create temporary _acme-challenge TXT records automatically."
  fi

  ui_section "Wildcard SSL preflight"
  print_kv_table \
    "Site host mode|${host_mode_ok}" \
    "Main domain DNS (${domain})|${main_status}" \
    "Wildcard DNS (${probe_host})|${wildcard_status}" \
    "$([[ "$dns_provider" == "manual" ]] && echo "Manual challenge" || echo "Cloudflare plugin")|${plugin_status}" \
    "Credentials file|${credentials_status}"

  if (( hard_fail != 0 )); then
    ui_next_steps
    if [[ "${SITE_META[host_mode]:-standard}" != "wildcard" ]]; then
      ui_kv "Site mode" "Recreate the site with wildcard host mode first."
    fi
    if [[ "$plugin_status" == FAIL* ]]; then
      ui_kv "Install plugin" "apt-get install -y ${provider_pkg:-python3-certbot-dns-cloudflare}"
    fi
    if [[ "$credentials_status" == FAIL* ]]; then
      ui_kv "Credentials file" "/root/.secrets/certbot/cloudflare.ini"
    fi
    return 1
  fi

  if (( dns_warn != 0 )); then
    ui_next_steps
    ui_kv "DNS records" "Create/update the A records shown above before requesting the certificate."
    if [[ "$dns_provider" == "manual" ]]; then
      ui_kv "Re-run later" "simai-admin.sh ssl letsencrypt --domain ${domain} --email <email> --wildcard yes --dns-provider manual"
    else
      ui_kv "Re-run later" "simai-admin.sh ssl letsencrypt --domain ${domain} --email <email> --wildcard yes --dns-provider ${dns_provider} --dns-credentials ${dns_credentials}"
    fi
    return 2
  fi

  return 0
}

ssl_menu_prepare_dns_wildcard() {
  local domain="$1"
  local email_default="$2"
  local wildcard_domain="${SITE_META[wildcard_domain]:-$(site_default_wildcard_domain "$domain")}"
  info "Wildcard HTTPS needs DNS challenge. Supported providers: Cloudflare API or manual DNS challenge."
  local provider=""
  provider=$(select_from_list "DNS provider for wildcard certificate" "cloudflare" "cloudflare" "manual")
  if [[ -z "$provider" ]]; then
    command_cancelled
    return $?
  fi
  local credentials=""
  if [[ "$provider" == "cloudflare" ]]; then
    credentials=$(prompt "Cloudflare credentials file" "/root/.secrets/certbot/cloudflare.ini")
    if [[ -z "$credentials" ]]; then
      command_cancelled
      return $?
    fi
  fi
  local email=""
  email=$(prompt "Let's Encrypt email" "$email_default")
  if [[ -z "$email" ]]; then
    command_cancelled
    return $?
  fi

  local preflight_rc=0
  ssl_wildcard_preflight_show "$domain" "$wildcard_domain" "$provider" "$credentials" || preflight_rc=$?
  case "$preflight_rc" in
    0) ;;
    1)
      error "Wildcard SSL preflight failed. Fix the items above and run the command again."
      return 1
      ;;
    2)
      local proceed=""
      proceed=$(select_from_list "DNS is not ready yet. Continue with certificate request anyway?" "no" "no" "yes")
      if [[ -z "$proceed" || "$proceed" == "no" ]]; then
        command_cancelled "Wildcard certificate request cancelled until DNS is ready."
        return $?
      fi
      ;;
    *)
      return "$preflight_rc"
      ;;
  esac

  # shellcheck disable=SC2154 # PARSED_ARGS is a shared global associative array.
  PARSED_ARGS[dns-provider]="$provider"
  PARSED_ARGS[dns-credentials]="$credentials"
  PARSED_ARGS[wildcard]="yes"
  PARSED_ARGS[email]="$email"
  PARSED_ARGS[domain]="$domain"
  PARSED_ARGS[wildcard-domain]="$wildcard_domain"
  return 0
}

ssl_issue_mode_value() {
  local wildcard="$1"
  local dns_provider="$2"
  if [[ "$wildcard" == "yes" && "$dns_provider" == "manual" ]]; then
    echo "manual-dns"
  elif [[ "$wildcard" == "yes" ]]; then
    echo "dns"
  else
    echo "webroot"
  fi
}

ssl_select_domain() {
  local policy="${1:-block}"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=() filtered=()
    mapfile -t sites < <(list_sites)
    if [[ ${#sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 1
    fi
    filtered=("${sites[@]}")
    domain=$(select_from_list "Select domain" "" "${filtered[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
  fi
  if [[ -z "$domain" ]]; then
    domain=$(prompt "domain")
  fi
  [[ -z "$domain" ]] && return 1
  if ! validate_domain "$domain" "$policy"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  PARSED_ARGS[domain]="$domain"
  echo "$domain"
}

ssl_site_context() {
  local domain="$1"
  if ! read_site_metadata "$domain"; then
    error "Failed to read site metadata for ${domain}"
    return 1
  fi
  SITE_SSL_PROJECT="${SITE_META[project]}"
  SITE_SSL_ROOT="${SITE_META[root]}"
  SITE_SSL_PROFILE="${SITE_META[profile]}"
  SITE_SSL_PHP="${SITE_META[php]}"
  SITE_SSL_SOCKET_PROJECT="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then
    SITE_SSL_PUBLIC_DIR="public"
  else
    SITE_SSL_PUBLIC_DIR="${SITE_META[public_dir]}"
  fi
  if [[ "$SITE_SSL_PROFILE" == "static" ]]; then
    if [[ -z "$SITE_SSL_PHP" ]]; then
      SITE_SSL_PHP="none"
    fi
  else
    if [[ -z "$SITE_SSL_PHP" ]]; then
      SITE_SSL_PHP="8.2"
    fi
  fi
  return 0
}

ssl_apply_nginx() {
  local domain="$1" cert="$2" key="$3" chain="$4" redirect="$5" hsts="$6"
  ssl_site_context "$domain" || return 1
  local template_id="${SITE_META[nginx_template]:-${SITE_SSL_PROFILE}}"
  local template=""
  if [[ "$SITE_SSL_PROFILE" == "alias" ]]; then
    if [[ -z "$template_id" || "$template_id" == "unknown" ]]; then
      error "Alias nginx template is unknown; refusing to regenerate nginx config safely."
      echo "Fix target metadata first: simai-admin.sh site drift --domain ${SITE_META[target]:-<target>} --fix yes (or restore # simai-* header manually)"
      return 1
    fi
  fi
  if [[ "$template_id" == "alias" ]]; then
    error "Alias nginx template id is insufficient to regenerate config; template for target site is required."
    echo "Fix target metadata first: simai-admin.sh site drift --domain ${SITE_META[target]:-<target>} --fix yes (or restore # simai-* header manually)"
    return 1
  fi
  template=$(site_nginx_template_path_for_id "$template_id") || return 1

  local pd_val
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then
    pd_val="public"
  else
    pd_val="${SITE_META[public_dir]}"
  fi
  if ! create_nginx_site "$domain" "$SITE_SSL_PROJECT" "$SITE_SSL_ROOT" "$SITE_SSL_PHP" "$template" "$SITE_SSL_PROFILE" "${SITE_META[target]:-}" "$SITE_SSL_SOCKET_PROJECT" "$cert" "$key" "$chain" "$redirect" "$hsts" "$template_id" "$pd_val" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}"; then
    return 1
  fi
  local ssl_type="custom"
  if [[ "$cert" == "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
    ssl_type="letsencrypt"
  fi
  site_nginx_metadata_upsert "/etc/nginx/sites-available/${domain}.conf" "$domain" "${SITE_META[project]}" "${SITE_META[profile]}" "${SITE_META[root]}" "${SITE_META[project]}" "${SITE_META[php]}" "$ssl_type" "" "${SITE_META[target]:-}" "${SITE_META[php_socket_project]:-${SITE_META[project]}}" "$template_id" "${pd_val}" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" >/dev/null 2>&1 || true
  return 0
}

ssl_issue_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Issue Let's Encrypt certificate"
  local is_advanced=0
  local advanced_flag="${SIMAI_MENU_SHOW_ADVANCED:-0}"
  advanced_flag="${advanced_flag,,}"
  case "$advanced_flag" in
    1|yes|true|on) is_advanced=1 ;;
    *) is_advanced=0 ;;
  esac
  local staging_warned=0
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" ]]; then
    local rc=0
    ssl_select_domain || rc=$?
    (( rc == 0 )) || return $rc
    domain="${PARSED_ARGS[domain]:-}"
  fi
  progress_init 6
  domain="${PARSED_ARGS[domain]:-$domain}"
  local email="${PARSED_ARGS[email]:-}"
  local redirect="${PARSED_ARGS[redirect]:-}"
  local hsts="${PARSED_ARGS[hsts]:-}"
  local staging="${PARSED_ARGS[staging]:-}"
  local wildcard="${PARSED_ARGS[wildcard]:-no}"
  local dns_provider="${PARSED_ARGS[dns-provider]:-}"
  local dns_credentials="${PARSED_ARGS[dns-credentials]:-}"
  local wildcard_domain="${PARSED_ARGS[wildcard-domain]:-}"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    if [[ -z "$domain" ]]; then
      local sites=()
      mapfile -t sites < <(list_sites)
      domain=$(select_from_list "Select domain" "" "${sites[@]}")
      PARSED_ARGS[domain]="$domain"
    fi
    if [[ -n "$domain" ]]; then
      read_site_metadata "$domain" >/dev/null 2>&1 || true
    fi
    if [[ -z "$email" ]]; then
      email=$(prompt "email")
      if [[ -z "$email" ]]; then
        command_cancelled
        return $?
      fi
      PARSED_ARGS[email]="$email"
    fi
    if [[ "${SITE_META[host_mode]:-standard}" == "wildcard" && -z "${PARSED_ARGS[wildcard]:-}" ]]; then
      local cert_scope=""
      cert_scope=$(select_from_list "Certificate scope" "standard" "standard" "wildcard")
      if [[ -z "$cert_scope" ]]; then
        command_cancelled
        return $?
      fi
      if [[ "$cert_scope" == "wildcard" ]]; then
        ssl_menu_prepare_dns_wildcard "$domain" "$email" || return $?
        wildcard="yes"
        dns_provider="${PARSED_ARGS[dns-provider]:-}"
        dns_credentials="${PARSED_ARGS[dns-credentials]:-}"
        wildcard_domain="${PARSED_ARGS[wildcard-domain]:-}"
        email="${PARSED_ARGS[email]:-$email}"
      fi
    fi
    if [[ -z "$redirect" ]]; then
      redirect=$(select_from_list "Redirect HTTP to HTTPS?" "no" "no" "yes")
      if [[ -z "$redirect" ]]; then
        command_cancelled
        return $?
      fi
    fi
    if [[ -z "$staging" ]]; then
      if [[ $is_advanced -eq 1 ]]; then
        staging=$(select_from_list "Use Let's Encrypt staging? (testing/diagnostics; avoids rate limits)" "no" "no" "yes")
        if [[ -z "$staging" ]]; then
          command_cancelled
          return $?
        fi
      else
        info "Staging mode is hidden in Advanced; defaulting to production Let's Encrypt."
        staging="no"
      fi
    fi
    if [[ "$staging" == "yes" ]]; then
      warn "Let's Encrypt STAGING issues certificates that are NOT trusted by browsers. Use only for testing/diagnostics."
      warn "HSTS will be forced to NO in staging mode."
      hsts="no"
      staging_warned=1
    else
      if [[ -z "$hsts" ]]; then
        hsts=$(select_from_list "Enable HSTS?" "no" "no" "yes")
        if [[ -z "$hsts" ]]; then
          command_cancelled
          return $?
        fi
      fi
    fi
  fi
  [[ -z "$redirect" ]] && redirect="no"
  [[ -z "$staging" ]] && staging="no"
  [[ -z "$wildcard" ]] && wildcard="no"
  if [[ "$staging" == "yes" && $staging_warned -eq 0 ]]; then
    warn "Let's Encrypt STAGING issues certificates that are NOT trusted by browsers. Use only for testing/diagnostics."
    warn "HSTS will be forced to NO in staging mode."
    hsts="no"
  fi
  [[ -z "$hsts" ]] && hsts="no"

  PARSED_ARGS[domain]="$domain"
  PARSED_ARGS[email]="$email"
  PARSED_ARGS[wildcard]="$wildcard"
  require_args "domain email" || return 1
  domain="${PARSED_ARGS[domain]:-}"
  email="${PARSED_ARGS[email]:-}"
  wildcard="${PARSED_ARGS[wildcard]:-no}"
  wildcard=$(echo "$wildcard" | tr '[:upper:]' '[:lower:]')
  if [[ "$wildcard" == "yes" ]]; then
    wildcard_domain="${PARSED_ARGS[wildcard-domain]:-${SITE_META[wildcard_domain]:-$(site_default_wildcard_domain "$domain")}}"
    dns_provider=$(ssl_dns_provider_normalize "${PARSED_ARGS[dns-provider]:-$dns_provider}") || {
      error "Wildcard certificate requires --dns-provider cloudflare or --dns-provider manual"
      return 1
    }
    dns_credentials="${PARSED_ARGS[dns-credentials]:-$dns_credentials}"
    if [[ "$dns_provider" != "manual" && -z "$dns_credentials" ]]; then
      error "Wildcard certificate requires --dns-credentials <file>"
      return 1
    fi
    if [[ "$dns_provider" != "manual" ]] && ! ssl_ensure_dns_credentials_file "$dns_credentials"; then
      return 1
    fi
  fi
  progress_step "Validating domain and loading site metadata"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  progress_step "Checking certbot availability"
  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot is not installed"
    return 1
  fi
  if ! ssl_site_context "$domain"; then
    error "Failed to read site context for ${domain}. Check nginx config metadata headers (simai-*)."
    return 1
  fi
  if [[ "$wildcard" == "yes" && "${SITE_META[host_mode]:-standard}" != "wildcard" ]]; then
    error "Wildcard certificate requires a site created with host mode wildcard"
    return 1
  fi
  local webroot=""
  local pd="${SITE_SSL_PUBLIC_DIR}"
  webroot=$(site_compute_doc_root "$SITE_SSL_ROOT" "$pd") || return 1
  if ! validate_path "$webroot"; then
    return 1
  fi
  mkdir -p "$webroot"
  progress_step "Preparing ACME webroot at ${webroot}"

  local -a cmd=()
  if [[ "$wildcard" == "yes" ]]; then
    if [[ "$dns_provider" == "manual" ]]; then
      cmd=(certbot certonly --manual --preferred-challenges dns --manual-public-ip-logging-ok -d "$domain" -d "$wildcard_domain" --agree-tos -m "$email" --keep-until-expiring)
    else
      local plugin_flag credentials_flag pkg
      plugin_flag=$(ssl_dns_provider_flag "$dns_provider")
      credentials_flag=$(ssl_dns_provider_credentials_flag "$dns_provider")
      pkg=$(ssl_dns_provider_package "$dns_provider")
      if ! certbot plugins 2>/dev/null | grep -qi "dns-${dns_provider}"; then
        error "Certbot DNS plugin for ${dns_provider} is not available. Install package: ${pkg}"
        return 1
      fi
      cmd=(certbot certonly "$plugin_flag" "$credentials_flag" "$dns_credentials" -d "$domain" -d "$wildcard_domain" --non-interactive --agree-tos -m "$email" --keep-until-expiring)
    fi
  else
    cmd=(certbot certonly --webroot -w "$webroot" -d "$domain" --non-interactive --agree-tos -m "$email" --keep-until-expiring)
  fi
  [[ "$staging" == "yes" ]] && cmd+=(--staging)
  progress_step "Requesting certificate from Let's Encrypt (staging=${staging}, wildcard=${wildcard})"
  if [[ "$wildcard" == "yes" && "$dns_provider" == "manual" ]]; then
    ui_section "Manual DNS challenge"
    echo "Certbot will now show one or more _acme-challenge TXT records."
    echo "Add them at your DNS provider, wait until they resolve, then continue in the same terminal."
    if ! "${cmd[@]}"; then
      error "Manual DNS challenge failed or was cancelled."
      return 1
    fi
  else
    if ! run_long "Requesting certificate from Let's Encrypt (staging=${staging}, wildcard=${wildcard})" "${cmd[@]}"; then
      error "Certbot failed. Check: simai-admin.sh logs letsencrypt"
      return 1
    fi
  fi
  local cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local chain="/etc/letsencrypt/live/${domain}/chain.pem"
  progress_step "Applying nginx SSL configuration (redirect=${redirect}, hsts=${hsts})"
  if ! ssl_apply_nginx "$domain" "$cert" "$key" "$chain" "$redirect" "$hsts"; then
    error "Failed to apply nginx SSL config for ${domain}. Restored previous config if available."
    return 1
  fi
  ensure_certbot_cron
  local le_mode
  le_mode=$(ssl_issue_mode_value "$wildcard" "$dns_provider")
  ssl_site_write_state "$domain" \
    "SITE_SSL_LE_MODE|${le_mode}" \
    "SITE_SSL_LE_WILDCARD|${wildcard}" \
    "SITE_SSL_LE_WILDCARD_DOMAIN|${wildcard_domain}" \
    "SITE_SSL_LE_DNS_PROVIDER|${dns_provider}" \
    "SITE_SSL_LE_DNS_CREDENTIALS|${dns_credentials}" \
    "SITE_SSL_LE_EMAIL|${email}"
  progress_step "Reloading nginx"
  local hsts_display="${hsts}"
  if [[ "$staging" == "yes" ]]; then
    hsts_display="${hsts} (forced)"
  fi
  ui_result_table \
    "Domain|${domain}" \
    "Type|Let's Encrypt" \
    "Scope|$([[ "$wildcard" == "yes" ]] && echo "${domain}, ${wildcard_domain}" || echo "${domain}")" \
    "Cert|${cert}" \
    "Key|${key}" \
    "Chain|${chain}" \
    "Staging|${staging}" \
    "Redirect|${redirect}" \
    "HSTS|${hsts_display}"
  ui_next_steps
  ui_kv "Check status" "simai-admin.sh ssl status --domain ${domain}"
  if [[ "$wildcard" == "yes" && "$dns_provider" == "manual" ]]; then
    ui_kv "Renew cert" "Run the same manual wildcard command again when renewal is needed."
  else
    ui_kv "Renew cert" "simai-admin.sh ssl renew --domain ${domain}"
  fi
  progress_done "Done"
}

ssl_install_custom_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Install custom certificate"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" ]]; then
    local rc=0
    ssl_select_domain || rc=$?
    (( rc == 0 )) || return $rc
    domain="${PARSED_ARGS[domain]:-}"
  fi
  progress_init 6
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
  require_args "domain" || return 1
  domain="${PARSED_ARGS[domain]:-}"
  progress_step "Validating domain and loading site metadata"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  if ! ssl_site_context "$domain"; then
    error "Failed to read site context for ${domain}. Check nginx config metadata headers (simai-*)."
    return 1
  fi
  local dest_dir
  dest_dir=$(ensure_ssl_dir "$domain")
  local cert_dst="${dest_dir}/fullchain.pem"
  local raw_cert_dst="${dest_dir}/certificate.crt"
  local raw_chain_dst="${dest_dir}/certificate_ca.crt"
  local key_dst="${dest_dir}/privkey.pem"
  local chain_dst="${dest_dir}/chain.pem"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    cert_src=${cert_src:-$raw_cert_dst}
    chain_src=${chain_src:-$raw_chain_dst}
    key_src=${key_src:-${dest_dir}/private.key}
    cert_src=$(prompt "Path to certificate (certificate.crt)" "$cert_src")
    if [[ -z "$cert_src" ]]; then
      command_cancelled
      return $?
    fi
    chain_src=$(prompt "Path to CA bundle (certificate_ca.crt, optional)" "$chain_src")
    key_src=$(prompt "Path to private key (private.key)" "$key_src")
    if [[ -z "$key_src" ]]; then
      command_cancelled
      return $?
    fi
    redirect=$(select_from_list "Redirect HTTP to HTTPS?" "no" "no" "yes")
    if [[ -z "$redirect" ]]; then
      command_cancelled
      return $?
    fi
    hsts=$(select_from_list "Enable HSTS?" "no" "no" "yes")
    if [[ -z "$hsts" ]]; then
      command_cancelled
      return $?
    fi
  fi

  if [[ -z "$cert_src" || -z "$key_src" ]]; then
    error "cert and key paths are required"
    return 1
  fi

  progress_step "Copying certificate and key files"
  progress_step "Preparing SSL directory at ${dest_dir}"
  if [[ "$cert_src" != "$raw_cert_dst" ]]; then
    cp -f "$cert_src" "$raw_cert_dst"
  fi
  if [[ "$key_src" != "$key_dst" ]]; then
    cp -f "$key_src" "$key_dst"
  fi
  if [[ -n "$chain_src" && -f "$chain_src" && "$chain_src" != "$raw_chain_dst" ]]; then
    cp -f "$chain_src" "$raw_chain_dst"
  fi

  # build fullchain
  progress_step "Building fullchain bundle"
  if [[ -f "$raw_chain_dst" && -s "$raw_chain_dst" ]]; then
    cat "$raw_cert_dst" "$raw_chain_dst" >"$cert_dst"
  else
    cp -f "$raw_cert_dst" "$cert_dst"
  fi
  [[ -f "$raw_chain_dst" ]] && cp -f "$raw_chain_dst" "$chain_dst" || rm -f "$chain_dst" 2>/dev/null || true

  chmod 640 "$cert_dst" "$key_dst" "$raw_cert_dst" 2>/dev/null || true
  [[ -f "$raw_chain_dst" ]] && chmod 640 "$raw_chain_dst" 2>/dev/null || true
  [[ -f "$chain_dst" ]] && chmod 640 "$chain_dst" 2>/dev/null || true

  local chain_arg=""
  [[ -f "$chain_dst" ]] && chain_arg="$chain_dst"
  progress_step "Applying nginx SSL configuration (redirect=${redirect}, hsts=${hsts})"
  if ! ssl_apply_nginx "$domain" "$cert_dst" "$key_dst" "$chain_arg" "$redirect" "$hsts"; then
    error "Failed to apply nginx SSL config for ${domain}. Restored previous config if available."
    return 1
  fi
  progress_step "Reloading nginx"
  local -a rows=(
    "Domain|${domain}"
    "Type|custom"
    "Cert|${cert_dst}"
    "Key|${key_dst}"
    "Redirect|${redirect}"
    "HSTS|${hsts}"
  )
  if [[ -n "$chain_arg" ]]; then
    rows+=("Chain|${chain_arg}")
  fi
  ui_result_table "${rows[@]}"
  ui_next_steps
  ui_kv "Check status" "simai-admin.sh ssl status --domain ${domain}"
  ui_kv "Renew cert" "simai-admin.sh ssl renew --domain ${domain}"
  progress_done "Done"
}

ssl_renew_handler() {
  parse_kv_args "$@"
  local domain
  if ! domain=$(ssl_select_domain); then
    return 1
  fi
  progress_init 5
  domain="${PARSED_ARGS[domain]:-$domain}"
  require_args "domain" || return 1
  domain="${PARSED_ARGS[domain]:-}"
  progress_step "Validating domain and loading site metadata"
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  progress_step "Checking certbot availability"
  if ! command -v certbot >/dev/null 2>&1; then
    error "certbot is not installed"
    return 1
  fi
  ssl_site_context "$domain" || return 1
  local le_mode wildcard dns_provider dns_credentials wildcard_domain le_email
  le_mode=$(ssl_site_read_var "$domain" "SITE_SSL_LE_MODE" 2>/dev/null || true)
  wildcard=$(ssl_site_read_var "$domain" "SITE_SSL_LE_WILDCARD" 2>/dev/null || true)
  dns_provider=$(ssl_site_read_var "$domain" "SITE_SSL_LE_DNS_PROVIDER" 2>/dev/null || true)
  dns_credentials=$(ssl_site_read_var "$domain" "SITE_SSL_LE_DNS_CREDENTIALS" 2>/dev/null || true)
  wildcard_domain=$(ssl_site_read_var "$domain" "SITE_SSL_LE_WILDCARD_DOMAIN" 2>/dev/null || true)
  le_email=$(ssl_site_read_var "$domain" "SITE_SSL_LE_EMAIL" 2>/dev/null || true)
  [[ -z "$le_mode" ]] && le_mode="webroot"
  progress_step "Preparing ACME webroot"
  local pd="${SITE_SSL_PUBLIC_DIR}"
  local webroot=""
  webroot=$(site_compute_doc_root "$SITE_SSL_ROOT" "$pd") || return 1
  if ! validate_path "$webroot"; then
    return 1
  fi
  progress_step "Requesting renewal from Let's Encrypt"
  local -a renew_cmd=()
  if [[ "$le_mode" == "manual-dns" || "$dns_provider" == "manual" ]]; then
    error "This certificate was issued with manual DNS challenge. Automatic renewal is not available."
    echo "Re-run manually:"
    echo "  simai-admin.sh ssl letsencrypt --domain ${domain} --email ${le_email:-<email>} --wildcard yes --dns-provider manual"
    return 1
  elif [[ "$le_mode" == "dns" || "$wildcard" == "yes" ]]; then
    dns_provider=$(ssl_dns_provider_normalize "$dns_provider") || {
      error "Stored wildcard renewal provider is unsupported"
      return 1
    }
    if ! ssl_ensure_dns_credentials_file "$dns_credentials"; then
      return 1
    fi
    local plugin_flag credentials_flag
    plugin_flag=$(ssl_dns_provider_flag "$dns_provider")
    credentials_flag=$(ssl_dns_provider_credentials_flag "$dns_provider")
    renew_cmd=(certbot certonly "$plugin_flag" "$credentials_flag" "$dns_credentials" --keep-until-expiring --force-renewal --non-interactive --agree-tos -m "$le_email" -d "$domain" -d "${wildcard_domain:-$(site_default_wildcard_domain "$domain")}")
  else
    renew_cmd=(certbot certonly --keep-until-expiring --force-renewal --non-interactive --agree-tos --webroot -w "$webroot" -d "$domain")
  fi
  if ! run_long "Renewing certificate for ${domain}" "${renew_cmd[@]}"; then
    error "Renew failed for ${domain}; see ${LOG_FILE}"
    return 1
  fi
  progress_step "Reloading nginx"
  os_svc_reload nginx >>"$LOG_FILE" 2>&1 || true
  echo "Renewed certificate for ${domain}"
  progress_done "Done"
}

ssl_remove_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Remove SSL"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" ]]; then
    local rc=0
    ssl_select_domain "allow" || rc=$?
    (( rc == 0 )) || return $rc
    domain="${PARSED_ARGS[domain]:-}"
  fi
  if [[ -z "${PARSED_ARGS[domain]:-}" ]]; then
    PARSED_ARGS[domain]="$domain"
  fi
  local delete_cert="${PARSED_ARGS[delete-cert]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-}"
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "${delete_cert,,}" == "yes" ]]; then
    case "${confirm,,}" in
      yes|true|1) ;;
      *) error "Deleting certificate requires --confirm yes"; return 1 ;;
    esac
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local proceed
    proceed=$(select_from_list "Disable HTTPS for this site now?" "no" "no" "yes")
    if [[ "$proceed" != "yes" ]]; then
      command_cancelled
      return $?
    fi
  fi
  ssl_site_context "$domain" || return 1
  local template_id="${SITE_META[nginx_template]:-${SITE_SSL_PROFILE}}"
  local template
  template=$(site_nginx_template_path_for_id "$template_id") || return 1
  info "Removing SSL config for ${domain}"
  create_nginx_site "$domain" "$SITE_SSL_PROJECT" "$SITE_SSL_ROOT" "$SITE_SSL_PHP" "$template" "$SITE_SSL_PROFILE" "" "$SITE_SSL_SOCKET_PROJECT" "" "" "" "no" "no" "$template_id" "${SITE_SSL_PUBLIC_DIR}" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}"
  site_nginx_metadata_upsert "/etc/nginx/sites-available/${domain}.conf" "$domain" "${SITE_META[project]}" "${SITE_META[profile]}" "${SITE_META[root]}" "${SITE_META[project]}" "${SITE_META[php]}" "none" "" "${SITE_META[target]:-}" "${SITE_META[php_socket_project]:-${SITE_META[project]}}" "${SITE_META[nginx_template]:-${SITE_META[profile]}}" "${SITE_SSL_PUBLIC_DIR}" "${SITE_META[host_mode]:-standard}" "${SITE_META[wildcard_domain]:-}" >/dev/null 2>&1 || true
  local ssl_kind="${SITE_META[ssl]:-none}"
  if [[ "$delete_cert" == "yes" ]]; then
    if [[ "$ssl_kind" == "letsencrypt" ]] && command -v certbot >/dev/null 2>&1; then
      run_long "Deleting certbot certificate for ${domain}" certbot delete --cert-name "$domain" --non-interactive || true
    fi
    rm -rf "/etc/nginx/ssl/${domain}" >>"$LOG_FILE" 2>&1 || true
  fi
  ui_result_table \
    "Domain|${domain}" \
    "SSL|disabled" \
    "Cert|$([[ "$delete_cert" == "yes" ]] && echo deleted || echo kept)"
  ui_next_steps
  ui_kv "Check status" "simai-admin.sh ssl status --domain ${domain}"
  ui_kv "Issue LE cert" "simai-admin.sh ssl letsencrypt --domain ${domain} --email <email>"
}

ssl_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" ]]; then
    local rc=0
    ssl_select_domain "allow" || rc=$?
    (( rc == 0 )) || return $rc
    domain="${PARSED_ARGS[domain]:-}"
  fi
  PARSED_ARGS[domain]="$domain"
  require_args "domain" || return 1
  domain="${PARSED_ARGS[domain]:-}"
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  ui_header "SIMAI ENV · SSL status"
  local le_cert="/etc/letsencrypt/live/${domain}/fullchain.pem"
  local le_key="/etc/letsencrypt/live/${domain}/privkey.pem"
  local custom_cert="/etc/nginx/ssl/${domain}/fullchain.pem"
  local custom_key="/etc/nginx/ssl/${domain}/privkey.pem"
  local cert_path="" key_path="" type="none"
  local not_after="(unknown)" not_before="(unknown)"
  local issuer="(none)" staging="n/a" san="unknown"
  local nginx_cert="" nginx_key=""
  local cfg="/etc/nginx/sites-available/${domain}.conf"

  if [[ -f "$cfg" ]]; then
    nginx_cert=$(awk '/^\s*ssl_certificate\s+/ {print $2; exit}' "$cfg" | sed 's/;$//')
    nginx_key=$(awk '/^\s*ssl_certificate_key\s+/ {print $2; exit}' "$cfg" | sed 's/;$//')
  fi

  if [[ -n "$nginx_cert" && -n "$nginx_key" && -f "$nginx_cert" && -f "$nginx_key" ]]; then
    cert_path="$nginx_cert"
    key_path="$nginx_key"
    if [[ "$cert_path" == "/etc/letsencrypt/live/${domain}/"* ]]; then
      type="letsencrypt"
    else
      type="custom"
    fi
  elif [[ -f "$le_cert" && -f "$le_key" ]]; then
    cert_path="$le_cert"
    key_path="$le_key"
    type="letsencrypt"
  elif [[ -f "$custom_cert" && -f "$custom_key" ]]; then
    cert_path="$custom_cert"
    key_path="$custom_key"
    type="custom"
  fi

  if [[ -n "$cert_path" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      not_after=$(openssl x509 -enddate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
      not_before=$(openssl x509 -startdate -noout -in "$cert_path" 2>/dev/null | cut -d= -f2 || true)
      issuer=$(openssl x509 -issuer -noout -in "$cert_path" 2>/dev/null | sed 's/^issuer= *//')
      [[ -z "$issuer" ]] && issuer="(unknown)"
      san=$(openssl x509 -in "$cert_path" -noout -ext subjectAltName 2>/dev/null | tr '\n' ' ')
      if [[ -n "$san" ]]; then
        san=$(echo "$san" | sed -n 's/.*Subject Alternative Name: *//p' | sed 's/DNS://g; s/IP Address://g; s/ *, */, /g' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      fi
      [[ -z "$san" ]] && san="unknown"
    else
      issuer="(unavailable)"
      san="unknown"
    fi
    if [[ "$type" == "letsencrypt" ]]; then
      if ssl_cert_is_staging "$cert_path"; then
        staging="yes"
      else
        staging="no"
      fi
    fi
  fi

  local -a rows=(
    "Domain|${domain}"
    "Type|${type}"
  )
  if [[ -n "$nginx_cert" ]]; then
    rows+=("Nginx cert|${nginx_cert}")
  fi
  if [[ -n "$nginx_key" ]]; then
    rows+=("Nginx key|${nginx_key}")
  fi
  rows+=(
    "Cert|${cert_path:-none}"
    "Key|${key_path:-none}"
    "Not before|${not_before}"
    "Not after|${not_after}"
    "Issuer|${issuer}"
    "SAN|${san}"
    "Staging|${staging}"
  )
  if [[ "$staging" == "yes" ]]; then
    rows+=("Note|staging cert is NOT trusted by browsers")
  fi

  ui_result_table "${rows[@]}"
  ui_next_steps
  ui_kv "Renew cert" "simai-admin.sh ssl renew --domain ${domain}"
  ui_kv "Remove SSL" "simai-admin.sh ssl remove --domain ${domain}"
  ui_kv "Site info" "simai-admin.sh site info --domain ${domain}"
}

ssl_list_handler() {
  ui_header "SIMAI ENV · SSL list"
  local sites=()
  mapfile -t sites < <(list_sites)
  if [[ ${#sites[@]} -eq 0 ]]; then
    warn "No sites found"
    return 0
  fi
  local -a rows=()
  local domain ssl_info type expires staging days redirect hsts
  for domain in "${sites[@]}"; do
    read_site_metadata "$domain" >/dev/null 2>&1 || true
    ssl_info=$(site_ssl_brief "$domain")
    type="$ssl_info"
    expires="n/a"
    if [[ "$ssl_info" == *:* ]]; then
      type="${ssl_info%%:*}"
      expires="${ssl_info#*:}"
    fi
    days="n/a"
    if [[ "$expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      local exp_ts now_ts
      exp_ts=$(date -d "$expires" +%s 2>/dev/null || echo "")
      now_ts=$(date +%s)
      if [[ -n "$exp_ts" ]]; then
        days=$(( (exp_ts - now_ts) / 86400 ))
      fi
    fi
    case "$type" in
      LE-stg)
        type="LE"
        staging="yes"
        ;;
      LE)
        staging="no"
        ;;
      *)
        staging="n/a"
        ;;
    esac
    redirect=$(site_nginx_ssl_redirect_enabled "$domain")
    hsts=$(site_nginx_hsts_enabled "$domain")
    rows+=("${domain}|${type}|${expires}|${days}|${staging}|${redirect}|${hsts}")
  done

  local domain_w=6 type_w=4 exp_w=7 days_w=4 staging_w=7 redirect_w=8 hsts_w=4
  local row
  for row in "${rows[@]}"; do
    IFS='|' read -r domain type expires days staging redirect hsts <<<"$row"
    [[ ${#domain} -gt $domain_w ]] && domain_w=${#domain}
    [[ ${#type} -gt $type_w ]] && type_w=${#type}
    [[ ${#expires} -gt $exp_w ]] && exp_w=${#expires}
    [[ ${#days} -gt $days_w ]] && days_w=${#days}
    [[ ${#staging} -gt $staging_w ]] && staging_w=${#staging}
    [[ ${#redirect} -gt $redirect_w ]] && redirect_w=${#redirect}
    [[ ${#hsts} -gt $hsts_w ]] && hsts_w=${#hsts}
  done
  local sep
  ui_section "Result"
  sep="+$(printf '%*s' "$((domain_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((type_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((exp_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((days_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((staging_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((redirect_w+2))" "" | tr ' ' '-')+$(printf '%*s' "$((hsts_w+2))" "" | tr ' ' '-')+"
  printf "%s\n" "$sep"
  printf "| %-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %-*s |\n" \
    "$domain_w" "Domain" "$type_w" "Type" "$exp_w" "Expires" "$days_w" "Days" "$staging_w" "Staging" "$redirect_w" "Redirect" "$hsts_w" "HSTS"
  printf "%s\n" "$sep"
  for row in "${rows[@]}"; do
    IFS='|' read -r domain type expires days staging redirect hsts <<<"$row"
    printf "| %-*s | %-*s | %-*s | %-*s | %-*s | %-*s | %-*s |\n" \
      "$domain_w" "$domain" "$type_w" "$type" "$exp_w" "$expires" "$days_w" "$days" "$staging_w" "$staging" "$redirect_w" "$redirect" "$hsts_w" "$hsts"
  done
  printf "%s\n" "$sep"
  ui_next_steps
  ui_kv "Check domain" "simai-admin.sh ssl status --domain <domain>"
  ui_kv "Issue LE cert" "simai-admin.sh ssl letsencrypt --domain <domain> --email <email>"
}

register_cmd "ssl" "letsencrypt" "Request Let's Encrypt certificate" "ssl_issue_handler" "" "domain= email= redirect= hsts= staging= wildcard= dns-provider= dns-credentials= wildcard-domain="
register_cmd "ssl" "install" "Install custom certificate" "ssl_install_custom_handler" "" "domain= cert= key= chain= redirect= hsts="
register_cmd "ssl" "renew" "Renew certificate" "ssl_renew_handler" "" "domain="
register_cmd "ssl" "remove" "Disable SSL and optionally delete cert" "ssl_remove_handler" "" "domain= delete-cert= confirm="
register_cmd "ssl" "status" "Show SSL status for domain" "ssl_status_handler" "" "domain="
register_cmd "ssl" "list" "List SSL status for sites" "ssl_list_handler" "" ""
