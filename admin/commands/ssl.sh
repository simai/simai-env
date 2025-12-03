#!/usr/bin/env bash
set -euo pipefail

ssl_issue_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain" "" "${sites[@]}")
  fi
  require_args "domain email"
  local domain="${PARSED_ARGS[domain]:-$domain}"
  local email="${PARSED_ARGS[email]}"
  local challenge="${PARSED_ARGS[challenge]:-http-01}"

  info "SSL issue (stub): domain=${domain}, email=${email}, challenge=${challenge}"
  info "TODO: integrate ACME client to obtain certificate."
}

ssl_install_custom_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain" "" "${sites[@]}")
  fi
  require_args "domain crt key"
  local domain="${PARSED_ARGS[domain]:-$domain}"
  local crt="${PARSED_ARGS[crt]}"
  local key="${PARSED_ARGS[key]}"
  local chain="${PARSED_ARGS[chain]:-}"

  info "SSL install custom (stub): domain=${domain}, crt=${crt}, key=${key}, chain=${chain}"
  info "TODO: deploy custom certificate and reload nginx."
}

ssl_renew_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain" "" "${sites[@]}")
  fi
  require_args "domain"
  local domain="${PARSED_ARGS[domain]:-$domain}"
  info "SSL renew (stub): domain=${domain}"
  info "TODO: renew certificate and reload nginx."
}

register_cmd "ssl" "issue" "Request Let's Encrypt certificate" "ssl_issue_handler" "domain email" "challenge=http-01"
register_cmd "ssl" "install-custom" "Install custom certificate" "ssl_install_custom_handler" "domain crt key" "chain="
register_cmd "ssl" "renew" "Renew certificate" "ssl_renew_handler" "domain" ""
