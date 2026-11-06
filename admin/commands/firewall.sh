#!/usr/bin/env bash
set -euo pipefail

# Firewall rules, address blocks and panel access by address. Every change is
# timed: the previous files are saved, the change is applied, and unless
# `change confirm` comes within the window (default 120 s) a timer puts the
# saved files back. A change that locks its author out therefore undoes
# itself. SSH, HTTP and HTTPS stay open whatever a single call asks.
# State: lib/timed_change.py (changes), lib/firewall_state.py (rules, blocks).

TIMED_CHANGE_PY="${SIMAI_ENV_ROOT}/lib/timed_change.py"
FIREWALL_STATE_PY="${SIMAI_ENV_ROOT}/lib/firewall_state.py"
FIREWALL_FILES=(/etc/ufw/user.rules /etc/ufw/user6.rules /etc/simai-env/firewall/blocks.json)
SIMAI_ACCESS_NGINX_DIR="${SIMAI_ACCESS_NGINX_DIR:-/etc/nginx/simai-access}"

firewall_require_ufw() {
  command -v ufw >/dev/null 2>&1 && return 0
  error "ufw is not installed; set up the firewall first: simai-admin.sh self firewall-ensure --confirm yes"
  return 1
}

firewall_ssh_csv() { self_firewall_ssh_ports | paste -sd ',' -; }

firewall_window() {
  local window="${1:-120}"
  [[ "$window" =~ ^[0-9]{2,3}$ ]] && (( window >= 30 && window <= 600 )) || { error "--window must be 30-600 seconds"; return 1; }
  printf '%s\n' "$window"
}

# Saves the files, prints "<change_id> <expires_at>".
timed_change_begin() {
  local kind="$1" domain="$2" window="$3" summary="$4"; shift 4
  python3 -I "$TIMED_CHANGE_PY" begin "$kind" "$domain" "$window" "$summary" "$@"
}

# Puts the saved files of a pending change back and reloads what reads them.
timed_change_undo() {
  local id="$1" kind
  kind=$(python3 -I "$TIMED_CHANGE_PY" restore "$id") || return 1
  systemctl stop "simai-change-${id}.timer" >/dev/null 2>&1 || true
  case "$kind" in
    firewall) ufw reload >>"$LOG_FILE" 2>&1 || { error "ufw reload failed after restoring ${id}"; return 1; } ;;
    geo) security_geo_load >>"$LOG_FILE" 2>&1 || { error "country rules did not reload after restoring ${id}"; return 1; } ;;
    panel_access|nginx_custom) nginx -t >>"$LOG_FILE" 2>&1 && os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1 || { error "nginx did not reload after restoring ${id}"; return 1; } ;;
  esac
  printf '%s\n' "$kind"
}

# After a change is applied: start the undo timer, tell the panel job its id.
timed_change_arm() {
  local id="$1" expires="$2" window="$3" kind="$4"
  if ! systemd-run --unit="simai-change-${id}" --on-active="${window}s" --timer-property=AccuracySec=1s --collect --quiet \
      --setenv=SIMAI_ADMIN_MENU=0 "${SIMAI_ENV_ROOT}/simai-admin.sh" change restore --id "$id" --confirm yes >>"$LOG_FILE" 2>&1; then
    # Without a timer nothing would undo it; the five-minute status refresh
    # still does, so say so instead of failing an applied change.
    warn "The undo timer did not start; the change is undone by the next status refresh unless confirmed"
  fi
  if [[ -n "${SIMAI_JOB_RESULT:-}" ]]; then
    printf '{"change_id":"%s","kind":"%s","expires_at":"%s"}\n' "$id" "$kind" "$expires" >"$SIMAI_JOB_RESULT"
  fi
  ui_result_table "Change|${id}" "Kind|${kind}" "Undone at|${expires} unless confirmed" \
    "Confirm|simai-admin.sh change confirm --id ${id} --confirm yes"
}

# Runs a firewall change as a timed change. $1: summary; the rest: ufw words.
firewall_timed_apply() {
  local summary="$1" window="$2"; shift 2
  local begun id expires
  begun=$(timed_change_begin firewall "" "$window" "$summary" "${FIREWALL_FILES[@]}") || return 1
  read -r id expires <<<"$begun"
  if ! "$@" >>"$LOG_FILE" 2>&1; then
    timed_change_undo "$id" >/dev/null || true
    error "The firewall change failed and was undone: ${summary}"
    return 1
  fi
  timed_change_arm "$id" "$expires" "$window" firewall
}

firewall_status_handler() {
  parse_kv_args "$@"
  local active="" incoming="" added="" domain="" access_file="" pending=""
  if command -v ufw >/dev/null 2>&1; then
    active=$(ufw status 2>/dev/null | sed -n 's/^Status: //p')
    incoming=$(ufw status verbose 2>/dev/null | sed -n 's/^Default: \([a-z]*\) (incoming).*/\1/p')
    added=$(ufw show added 2>/dev/null || true)
  fi
  domain=$(panel_state_get PANEL_DOMAIN 2>/dev/null || true)
  [[ -n "$domain" ]] && access_file=$(panel_access_file "$domain" 2>/dev/null || true)
  pending=$(python3 -I "$TIMED_CHANGE_PY" pending firewall)
  [[ -n "$pending" ]] || pending=$(python3 -I "$TIMED_CHANGE_PY" pending panel_access)
  python3 -I "$FIREWALL_STATE_PY" status "${SIMAI_COMMAND_OUTPUT:-human}" "$(firewall_ssh_csv)" "${active:-absent}" \
    "$incoming" "$domain" "$access_file" "$pending" <<<"$added"
}

firewall_rule_add_handler() {
  parse_kv_args "$@"
  require_args "port proto" || return 1
  local port="${PARSED_ARGS[port]}" proto="${PARSED_ARGS[proto]}" from="${PARSED_ARGS[from]:-any}"
  local action="${PARSED_ARGS[action]:-allow}" window
  firewall_require_ufw || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( port <= 65535 )) || { error "--port must be 1-65535"; return 1; }
  [[ "$proto" =~ ^(tcp|udp)$ ]] || { error "--proto must be tcp or udp"; return 1; }
  [[ "$action" =~ ^(allow|deny)$ ]] || { error "--action must be allow or deny"; return 1; }
  if [[ "$from" != any ]]; then
    from=$(python3 -I "$FIREWALL_STATE_PY" addresses "$from") || return 1
    [[ "$from" != *$'\n'* ]] || { error "--from takes one address or CIDR block"; return 1; }
  fi
  if [[ "$action" == deny && "$from" == any ]] && grep -qx "$port" <(firewall_ssh_csv | tr ',' '\n'; printf '80\n443\n'); then
    error "Port ${port} keeps SSH or the sites reachable and cannot be closed for everyone"
    return 1
  fi
  local -a words=(ufw)
  # Deny rules go first: ufw stops at the first rule that matches.
  [[ "$action" == deny ]] && words+=(prepend)
  if [[ "$from" == any ]]; then
    words+=("$action" "${port}/${proto}")
  else
    words+=("$action" from "$from" to any port "$port" proto "$proto")
  fi
  firewall_timed_apply "${action} ${port}/${proto} from ${from}" "$window" "${words[@]}"
}

firewall_rule_remove_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  local id="${PARSED_ARGS[id]}" rule window rc=0
  firewall_require_ufw || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  [[ "$id" =~ ^[a-f0-9]{8}$ ]] || { error "--id must be a rule id from firewall status"; return 1; }
  rule=$(ufw show added 2>/dev/null | python3 -I "$FIREWALL_STATE_PY" find "$id") || { error "Unknown firewall rule: ${id}"; return 1; }
  ufw show added 2>/dev/null | python3 -I "$FIREWALL_STATE_PY" protected "$id" "$(firewall_ssh_csv)" || rc=$?
  if (( rc == 0 )); then
    error "Rule ${id} (${rule}) keeps SSH or the sites reachable and cannot be removed"
    return 1
  fi
  local -a words
  read -r -a words <<<"$rule"
  firewall_timed_apply "remove ${rule}" "$window" ufw delete "${words[@]}"
}

firewall_block_handler() {
  parse_kv_args "$@"
  require_args "address" || return 1
  local addr ttl="${PARSED_ARGS[ttl]:-0}" window
  firewall_require_ufw || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  addr=$(python3 -I "$FIREWALL_STATE_PY" addresses "${PARSED_ARGS[address]}") || return 1
  [[ "$addr" != any && "$addr" != *$'\n'* ]] || { error "--address takes one address or CIDR block"; return 1; }
  [[ "$ttl" =~ ^[0-9]{1,8}$ ]] && (( ttl == 0 || (ttl >= 60 && ttl <= 31536000) )) \
    || { error "--ttl must be 60-31536000 seconds, or 0 to keep the block until it is removed"; return 1; }
  if ufw show added 2>/dev/null | grep -qE "^ufw (prepend )?deny from ${addr//./\\.}\$"; then
    error "${addr} is already blocked"
    return 1
  fi
  firewall_timed_apply "block ${addr}" "$window" firewall_block_apply "$addr" "$ttl"
}

firewall_block_apply() {
  ufw prepend deny from "$1" && python3 -I "$FIREWALL_STATE_PY" block-add "$1" "$2"
}

firewall_unblock_handler() {
  parse_kv_args "$@"
  require_args "address" || return 1
  local addr window
  firewall_require_ufw || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  addr=$(python3 -I "$FIREWALL_STATE_PY" addresses "${PARSED_ARGS[address]}") || return 1
  ufw show added 2>/dev/null | grep -qE "^ufw (prepend )?deny from ${addr//./\\.}\$" || { error "${addr} is not blocked"; return 1; }
  firewall_timed_apply "unblock ${addr}" "$window" firewall_unblock_apply "$addr"
}

firewall_unblock_apply() {
  ufw delete deny from "$1" && { python3 -I "$FIREWALL_STATE_PY" block-remove "$1" || true; }
}

# Ends blocks whose ttl ran out and undoes changes nobody confirmed (a reboot
# drops the undo timers). Run by the five-minute status refresh.
change_expire_handler() {
  parse_kv_args "$@"
  local id addr
  while IFS= read -r id; do
    [[ -n "$id" ]] && timed_change_undo "$id" >/dev/null 2>&1 || true
  done < <(python3 -I "$TIMED_CHANGE_PY" expired 2>/dev/null || true)
  command -v ufw >/dev/null 2>&1 || return 0
  while IFS= read -r addr; do
    [[ -n "$addr" ]] || continue
    ufw delete deny from "$addr" >>"$LOG_FILE" 2>&1 || true
    python3 -I "$FIREWALL_STATE_PY" block-remove "$addr" || true
  done < <(python3 -I "$FIREWALL_STATE_PY" blocks-expired 2>/dev/null || true)
}

# --- panel access by address ----------------------------------------------

panel_access_file() {
  local domain="$1"
  declare -A meta=()
  site_nginx_metadata_parse "/etc/nginx/sites-available/${domain}.conf" meta || return 1
  [[ -n "${meta[project]:-${meta[slug]:-}}" ]] || return 1
  printf '%s/%s.conf\n' "$SIMAI_ACCESS_NGINX_DIR" "${meta[project]:-${meta[slug]}}"
}

# Sites rendered before 1.35.0 lack the include of their access file.
panel_access_include_ensure() {
  local conf="$1" file="$2" project
  project=$(basename "$file" .conf)
  grep -qF "simai-access/${project}[.]conf" "$conf" && return 0
  grep -qE "^[[:space:]]*error_log /var/log/nginx/${project}\.error\.log;" "$conf" || return 1
  sed -i -E "s#^([[:space:]]*)(error_log /var/log/nginx/${project}\.error\.log;)#\1\2\n\1include ${SIMAI_ACCESS_NGINX_DIR}/${project}[.]conf;#" "$conf"
}

panel_access_handler() {
  parse_kv_args "$@"
  require_args "allow" || return 1
  local domain conf file list window begun id expires
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  domain=$(panel_state_get PANEL_DOMAIN 2>/dev/null || true)
  [[ -n "$domain" ]] || { error "The panel is not installed"; return 1; }
  conf="/etc/nginx/sites-available/${domain}.conf"
  file=$(panel_access_file "$domain") || { error "Nginx metadata not found for ${domain}"; return 1; }
  list=$(python3 -I "$FIREWALL_STATE_PY" addresses "${PARSED_ARGS[allow]}") || return 1
  begun=$(timed_change_begin panel_access "$domain" "$window" "panel ${domain}: ${list//$'\n'/, }" "$conf" "$file") || return 1
  read -r id expires <<<"$begun"
  if ! panel_access_write "$conf" "$file" "$list" || ! nginx -t >>"$LOG_FILE" 2>&1 || ! os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1; then
    timed_change_undo "$id" >/dev/null || true
    error "Panel access was not changed (nginx refused the configuration)"
    return 1
  fi
  timed_change_arm "$id" "$expires" "$window" panel_access
}

panel_access_write() {
  local conf="$1" file="$2" list="$3" addr
  install -d -m 0755 "$SIMAI_ACCESS_NGINX_DIR" || return 1
  panel_access_include_ensure "$conf" "$file" || { error "Cannot find where to include ${file} in ${conf}"; return 1; }
  if [[ "$list" == any ]]; then
    rm -f -- "$file"
    return 0
  fi
  {
    echo "# simai-env panel access; managed by: simai-admin.sh panel access"
    echo "allow 127.0.0.1;  # local checks"
    echo "allow ::1;  # local checks"
    while IFS= read -r addr; do printf 'allow %s;\n' "$addr"; done <<<"$list"
    echo "deny all;"
  } >"${file}.tmp" && mv -f "${file}.tmp" "$file"
}

# --- confirm and undo -------------------------------------------------------

change_confirm_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  local id="${PARSED_ARGS[id]}"
  [[ "$id" =~ ^[a-f0-9]{12}$ ]] || { error "--id must be a change id"; return 1; }
  python3 -I "$TIMED_CHANGE_PY" confirm "$id" >/dev/null || return 1
  systemctl stop "simai-change-${id}.timer" >/dev/null 2>&1 || true
  python3 -I "$TIMED_CHANGE_PY" status "$id"
}

change_status_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  [[ "${PARSED_ARGS[id]}" =~ ^[a-f0-9]{12}$ ]] || { error "--id must be a change id"; return 1; }
  python3 -I "$TIMED_CHANGE_PY" status "${PARSED_ARGS[id]}" "${SIMAI_COMMAND_OUTPUT:-human}"
}

change_restore_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  [[ "${PARSED_ARGS[id]}" =~ ^[a-f0-9]{12}$ ]] || { error "--id must be a change id"; return 1; }
  timed_change_undo "${PARSED_ARGS[id]}" >/dev/null || return 1
  python3 -I "$TIMED_CHANGE_PY" status "${PARSED_ARGS[id]}"
}

register_cmd "firewall" "status" "Show firewall rules, blocked addresses, panel access and a change waiting for confirmation" "firewall_status_handler" "" "" "tier:advanced effects:read"
register_cmd "firewall" "rule-add" "Open or close a port (undone in --window seconds unless confirmed)" "firewall_rule_add_handler" "port proto" "from= action= window=" "tier:advanced"
register_cmd "firewall" "rule-remove" "Remove a firewall rule by id (undone unless confirmed)" "firewall_rule_remove_handler" "id" "window=" "tier:advanced"
register_cmd "firewall" "block" "Block an address or CIDR block, for --ttl seconds or until unblocked" "firewall_block_handler" "address" "ttl= window=" "tier:advanced"
register_cmd "firewall" "unblock" "Remove a block of an address" "firewall_unblock_handler" "address" "window=" "tier:advanced"
register_cmd "panel" "access" "Let only these addresses open the panel (any, or a comma list; undone unless confirmed)" "panel_access_handler" "allow" "window=" "tier:advanced"
register_cmd "change" "confirm" "Keep a firewall or panel access change before its undo timer runs" "change_confirm_handler" "id" "" "tier:advanced"
register_cmd "change" "status" "Show a timed change: pending, confirmed or restored" "change_status_handler" "id" "" "tier:advanced effects:read"
register_cmd "change" "expire" "Undo changes past their deadline and end expired blocks (status refresh)" "change_expire_handler" "" "" "tier:advanced"
register_cmd "change" "restore" "Undo a pending firewall or panel access change now" "change_restore_handler" "id" "" "tier:advanced"
