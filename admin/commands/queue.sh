#!/usr/bin/env bash
set -euo pipefail

queue_prepare_site() {
  local domain="$1"
  if ! validate_domain "$domain"; then
    return 1
  fi
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  if [[ "$profile" != "laravel" ]]; then
    error "Queue commands are supported for laravel profile only."
    echo "Use: simai-admin.sh site doctor --domain ${domain} to see profile and setup."
    return 2
  fi
  local project="${SITE_META[project]}"
  local php_version="${SITE_META[php]}"
  local safe_project="$project"
  if ! validate_project_slug "$safe_project"; then
    safe_project=$(project_slug_from_domain "$domain")
  fi
  local unit_name
  unit_name=$(queue_unit_name "$safe_project") || return 1
  queue_unit_path "$safe_project" >/dev/null || return 1
  QUEUE_UNIT_NAME="$unit_name"
  QUEUE_PHP_VERSION="$php_version"
}

queue_collect_status() {
  local unit="$1"
  if ! command -v systemctl >/dev/null 2>&1; then
    error "systemctl not available; cannot inspect queue unit status"
    return 1
  fi
  local status_out
  status_out=$(systemctl status "$unit" --no-pager 2>&1 || true)
  local show_out active sub main_pid exit_status load_state
  show_out=$(systemctl show -p LoadState -p ActiveState -p SubState -p ExecMainStatus -p ExecMainPID "$unit" 2>/dev/null || true)
  load_state="unknown"; active="unknown"; sub="unknown"; main_pid="-"; exit_status="-"
  while IFS='=' read -r key val; do
    case "$key" in
      LoadState) load_state="$val" ;;
      ActiveState) active="$val" ;;
      SubState) sub="$val" ;;
      ExecMainStatus) exit_status="$val" ;;
      ExecMainPID) main_pid="$val" ;;
    esac
  done <<<"$show_out"
  if [[ "$status_out" == *"could not be found"* || "$status_out" == *"Loaded: not-found"* || "$load_state" == "not-found" ]]; then
    return 3
  fi
  QUEUE_ENABLED=$(systemctl is-enabled "$unit" 2>/dev/null || echo "unknown")
  [[ -z "$main_pid" ]] && main_pid="-"
  [[ -z "$exit_status" ]] && exit_status="-"
  QUEUE_ACTIVE_STATE="$active"
  QUEUE_SUB_STATE="$sub"
  QUEUE_MAIN_PID="$main_pid"
  QUEUE_EXIT_STATUS="$exit_status"
  return 0
}

queue_status_handler() {
  parse_kv_args "$@"
  require_args "domain"
  local domain="${PARSED_ARGS[domain]}"
  if ! queue_prepare_site "$domain"; then
    return $?
  fi
  if ! queue_collect_status "$QUEUE_UNIT_NAME"; then
    local rc=$?
    if [[ $rc -eq 3 ]]; then
      error "Queue unit not found for ${domain}: ${QUEUE_UNIT_NAME}"
      echo "Queue unit not found. Recreate site wiring: simai-admin.sh site set-php --domain ${domain} --php ${QUEUE_PHP_VERSION:-<php>} (or site fix)."
    fi
    return $rc
  fi
  local border="+----------------+------------------+"
  printf "%s\n" "$border"
  printf "| %-14s | %-16s |\n" "Field" "Value"
  printf "%s\n" "$border"
  printf "| %-14s | %-16s |\n" "Unit" "$QUEUE_UNIT_NAME"
  printf "| %-14s | %-16s |\n" "Enabled" "$QUEUE_ENABLED"
  printf "| %-14s | %-16s |\n" "ActiveState" "$QUEUE_ACTIVE_STATE"
  printf "| %-14s | %-16s |\n" "SubState" "$QUEUE_SUB_STATE"
  printf "| %-14s | %-16s |\n" "MainPID" "$QUEUE_MAIN_PID"
  printf "| %-14s | %-16s |\n" "ExitStatus" "$QUEUE_EXIT_STATUS"
  printf "%s\n" "$border"
  return 0
}

queue_restart_handler() {
  parse_kv_args "$@"
  require_args "domain"
  local domain="${PARSED_ARGS[domain]}"
  if ! queue_prepare_site "$domain"; then
    return $?
  fi
  if ! queue_collect_status "$QUEUE_UNIT_NAME"; then
    local rc=$?
    if [[ $rc -eq 3 ]]; then
      error "Queue unit not found for ${domain}: ${QUEUE_UNIT_NAME}"
      echo "Queue unit not found. Recreate site wiring: simai-admin.sh site set-php --domain ${domain} --php ${QUEUE_PHP_VERSION:-<php>} (or site fix)."
    fi
    return $rc
  fi
  if ! os_svc_restart "$QUEUE_UNIT_NAME"; then
    error "Failed to restart ${QUEUE_UNIT_NAME}"
    journalctl -u "$QUEUE_UNIT_NAME" -n 30 --no-pager 2>&1 | sed 's/^/log: /'
    return 1
  fi
  if ! queue_collect_status "$QUEUE_UNIT_NAME"; then
    return $?
  fi
  info "Queue unit restarted: ActiveState=${QUEUE_ACTIVE_STATE}, SubState=${QUEUE_SUB_STATE}"
  return 0
}

queue_logs_handler() {
  parse_kv_args "$@"
  require_args "domain"
  local domain="${PARSED_ARGS[domain]}"
  local lines="${PARSED_ARGS[lines]:-100}"
  if [[ -n "$lines" && ! "$lines" =~ ^[0-9]+$ ]]; then
    error "Invalid --lines value: ${lines} (must be numeric)"
    return 1
  fi
  if ! queue_prepare_site "$domain"; then
    return $?
  fi
  if ! queue_collect_status "$QUEUE_UNIT_NAME"; then
    local rc=$?
    if [[ $rc -eq 3 ]]; then
      error "Queue unit not found for ${domain}: ${QUEUE_UNIT_NAME}"
      echo "Queue unit not found. Recreate site wiring: simai-admin.sh site set-php --domain ${domain} --php ${QUEUE_PHP_VERSION:-<php>} (or site fix)."
    fi
    return $rc
  fi
  info "Last ${lines} lines for ${QUEUE_UNIT_NAME}"
  journalctl -u "$QUEUE_UNIT_NAME" -n "$lines" --no-pager
}

register_cmd "queue" "status" "Show Laravel queue worker status (laravel-only)" "queue_status_handler" "domain" ""
register_cmd "queue" "restart" "Restart Laravel queue worker (laravel-only)" "queue_restart_handler" "domain" ""
register_cmd "queue" "logs" "Tail Laravel queue worker logs (laravel-only)" "queue_logs_handler" "domain" "lines=100"
