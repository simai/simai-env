#!/usr/bin/env bash
set -euo pipefail

LOGS_DEFAULT_LINES=200
ADMIN_LOG=${ADMIN_LOG:-/var/log/simai-admin.log}
ENV_LOG=${ENV_LOG:-/var/log/simai-env.log}
AUDIT_LOG=${AUDIT_LOG_FILE:-/var/log/simai-audit.log}
LETSENCRYPT_LOG=${LETSENCRYPT_LOG:-/var/log/letsencrypt/letsencrypt.log}

logs_tail_file() {
  local file="$1" lines="$2"
  if [[ ! -f "$file" ]]; then
    warn "Log file not found, creating empty file: ${file}"
    mkdir -p "$(dirname "$file")"
    touch "$file"
  fi
  info "Showing last ${lines} lines of ${file}"
  tail -n "$lines" "$file"
}

logs_admin_handler() {
  parse_kv_args "$@"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"
  logs_tail_file "$ADMIN_LOG" "$lines"
}

logs_env_handler() {
  parse_kv_args "$@"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"
  logs_tail_file "$ENV_LOG" "$lines"
}

logs_audit_handler() {
  parse_kv_args "$@"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"
  logs_tail_file "$AUDIT_LOG" "$lines"
}

logs_letsencrypt_handler() {
  parse_kv_args "$@"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"
  logs_tail_file "$LETSENCRYPT_LOG" "$lines"
}

logs_nginx_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local kind="${PARSED_ARGS[kind]:-access}"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$domain" ]]; then
    mapfile -t _sites < <(list_sites)
    domain=$(select_from_list "Select domain" "" "${_sites[@]}")
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain"
  case "$kind" in
    access|error) ;;
    *) kind="access" ;;
  esac
  local file="/var/log/nginx/${domain}.$kind.log"
  logs_tail_file "$file" "$lines"
}

register_cmd "logs" "admin" "Tail simai-admin log" "logs_admin_handler" "" "lines=${LOGS_DEFAULT_LINES}"
register_cmd "logs" "env" "Tail installer log" "logs_env_handler" "" "lines=${LOGS_DEFAULT_LINES}"
register_cmd "logs" "audit" "Tail audit log" "logs_audit_handler" "" "lines=${LOGS_DEFAULT_LINES}"
register_cmd "logs" "nginx" "Tail nginx access/error for a domain" "logs_nginx_handler" "" "domain= kind= lines=${LOGS_DEFAULT_LINES}"
register_cmd "logs" "letsencrypt" "Tail Let's Encrypt log" "logs_letsencrypt_handler" "" "lines=${LOGS_DEFAULT_LINES}"
