#!/usr/bin/env bash

# Host baseline that every server needs before sites: swap and a firewall.
# Both commands are idempotent and print their plan without --confirm yes.

SELF_SWAP_FILE="/swapfile"
SELF_SWAP_SYSCTL="/etc/sysctl.d/60-simai-swap.conf"

self_swap_total_mb() {
  awk '/^SwapTotal:/ {print int($2 / 1024)}' /proc/meminfo
}

self_swap_status_handler() {
  local active
  active=$(swapon --show=NAME,SIZE,USED --noheadings 2>/dev/null | awk '{print $1" "$2" (used "$3")"}' | paste -sd ';' -)
  ui_header "SIMAI ENV · Swap"
  ui_result_table \
    "Memory|$(awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo) MB" \
    "Swap|$(self_swap_total_mb) MB" \
    "Devices|${active:-none}" \
    "Swappiness|$(cat /proc/sys/vm/swappiness 2>/dev/null || echo unknown)" \
    "Managed file|$([[ -f $SELF_SWAP_FILE ]] && echo "$SELF_SWAP_FILE" || echo none)"
}

self_swap_ensure_handler() {
  parse_kv_args "$@"
  local size="${PARSED_ARGS[size]:-2G}" swappiness="${PARSED_ARGS[swappiness]:-10}"
  [[ "$size" =~ ^([1-9][0-9]?)G$ ]] || { error "--size must be 1G..99G"; return 1; }
  [[ "$swappiness" =~ ^[0-9]{1,3}$ ]] && (( swappiness <= 100 )) || { error "--swappiness must be 0..100"; return 1; }
  local size_mb=$(( ${size%G} * 1024 )) current_mb
  current_mb=$(self_swap_total_mb)
  local free_mb confirm="${PARSED_ARGS[confirm]:-no}"
  free_mb=$(df -Pm / | awk 'NR == 2 {print $4}')
  if [[ "${confirm,,}" != yes ]]; then
    echo "Swap plan:"
    if (( current_mb > 0 )); then
      echo "  - swap already present (${current_mb} MB); no file is added"
    else
      echo "  - create ${SELF_SWAP_FILE} of ${size} (free disk ${free_mb} MB), enable it and add it to /etc/fstab"
    fi
    echo "  - vm.swappiness = ${swappiness} in ${SELF_SWAP_SYSCTL}"
    echo "Rerun with --confirm yes to apply. Undo: swapoff ${SELF_SWAP_FILE}, remove its /etc/fstab line and the file."
    return 0
  fi

  if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$SELF_SWAP_FILE"; then
    info "Swap file ${SELF_SWAP_FILE} is already active (${current_mb} MB)"
  elif (( current_mb > 0 )); then
    info "Swap is already provided by another device (${current_mb} MB); no file added"
  else
    (( free_mb > size_mb + 2048 )) || { error "Not enough disk space for ${size} of swap (free ${free_mb} MB, keeping 2 GB spare)"; return 1; }
    [[ ! -e "$SELF_SWAP_FILE" ]] || { error "${SELF_SWAP_FILE} exists but is not active swap; inspect it first"; return 1; }
    info "Creating ${size} swap at ${SELF_SWAP_FILE}"
    fallocate -l "$size" "$SELF_SWAP_FILE" 2>/dev/null || dd if=/dev/zero of="$SELF_SWAP_FILE" bs=1M count="$size_mb" status=none || return 1
    chmod 0600 "$SELF_SWAP_FILE"
    mkswap "$SELF_SWAP_FILE" >>"$LOG_FILE" 2>&1 || { rm -f -- "$SELF_SWAP_FILE"; error "mkswap failed"; return 1; }
    swapon "$SELF_SWAP_FILE" || { rm -f -- "$SELF_SWAP_FILE"; error "swapon failed"; return 1; }
  fi
  if [[ -f "$SELF_SWAP_FILE" ]] && ! grep -qE "^${SELF_SWAP_FILE}[[:space:]]" /etc/fstab; then
    cp -p /etc/fstab "/etc/fstab.simai-bak.$(date +%Y%m%d%H%M%S)"
    printf '%s none swap sw 0 0\n' "$SELF_SWAP_FILE" >>/etc/fstab
  fi
  printf 'vm.swappiness = %s\n' "$swappiness" >"$SELF_SWAP_SYSCTL"
  sysctl -q -p "$SELF_SWAP_SYSCTL" >/dev/null 2>&1 || warn "Could not apply vm.swappiness now; it applies after reboot"
  self_swap_status_handler
}

# --- firewall -------------------------------------------------------------

# SSH ports to keep open: sshd's effective configuration, ports sshd listens
# on, and 22 when neither can be read. Never empty.
self_firewall_ssh_ports() {
  local ports=""
  if command -v sshd >/dev/null 2>&1; then
    ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}') || ports=""
  fi
  ports+=$'\n'$(ss -ltnpH 2>/dev/null | awk '/"sshd/ {n = split($4, a, ":"); print a[n]}') || true
  ports=$(grep -E '^[0-9]+$' <<<"$ports" | sort -un) || ports=""
  printf '%s\n' "${ports:-22}"
}

# Validated entries: <port>/<tcp|udp> or <port>/<proto>@<ipv4[/cidr]>.
self_firewall_parse_allow() {
  local list="$1" item
  local -a items=()
  IFS=',' read -r -a items <<<"$list"
  for item in "${items[@]}"; do
    item="${item// /}"
    [[ -z "$item" ]] && continue
    if [[ ! "$item" =~ ^[0-9]{1,5}/(tcp|udp)(@[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?)?$ ]]; then
      error "Invalid --allow entry: ${item} (expected 10050/tcp@192.0.2.10)"
      return 1
    fi
    printf '%s\n' "$item"
  done
}

# Listening services that the policy would make unreachable from outside.
self_firewall_blocked_listeners() {
  local open=" $1 "
  ss -ltnupH 2>/dev/null | awk '{print $1, $5, $7}' | while read -r proto addr procs; do
    local port="${addr##*:}" host="${addr%:*}"
    case "$host" in 127.*|"[::1]"|::1|"[::ffff:127."*) continue ;; esac
    [[ "$open" == *" ${port}/${proto} "* ]] && continue
    printf '%s/%s %s\n' "$port" "$proto" "$(sed -E 's/.*\(\("([^"]+)".*/\1/' <<<"$procs")"
  done | sort -u
}

self_firewall_status_handler() {
  ui_header "SIMAI ENV · Firewall"
  if ! command -v ufw >/dev/null 2>&1; then
    ui_result_table "Firewall|ufw not installed" "Apply|simai-admin.sh self firewall-ensure --confirm yes"
    return 0
  fi
  local state rules
  state=$(ufw status 2>/dev/null | sed -n 's/^Status: //p')
  rules=$(ufw status 2>/dev/null | awk '/^--/ {on = 1; next} on && NF {print $1" "$2" "$3}' | paste -sd ';' -)
  ui_result_table "Firewall|ufw ${state:-unknown}" "Rules|${rules:-none}" "SSH ports|$(self_firewall_ssh_ports | paste -sd ',' -)"
}

self_firewall_ensure_handler() {
  parse_kv_args "$@"
  local allow="${PARSED_ARGS[allow]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  local -a extra=() ssh_ports=()
  local parsed
  parsed=$(self_firewall_parse_allow "$allow") || return 1
  [[ -z "$parsed" ]] || mapfile -t extra <<<"$parsed"
  mapfile -t ssh_ports < <(self_firewall_ssh_ports)
  [[ ${#ssh_ports[@]} -gt 0 && -n "${ssh_ports[0]}" ]] || { error "Could not determine the SSH port; refusing to enable the firewall"; return 1; }
  local open="" p
  for p in "${ssh_ports[@]}"; do open+="${p}/tcp "; done
  open+="80/tcp 443/tcp"
  local -a blocked=()
  mapfile -t blocked < <(self_firewall_blocked_listeners "$open $(printf '%s ' "${extra[@]%%@*}")")

  if [[ "${confirm,,}" != yes ]]; then
    echo "Firewall plan (ufw):"
    echo "  - deny incoming, allow outgoing"
    echo "  - allow SSH ($(printf '%s ' "${ssh_ports[@]}")), HTTP 80 and HTTPS 443 from anywhere"
    for p in "${extra[@]}"; do echo "  - allow ${p%%@*} from ${p#*@}"; done
    if [[ ${#blocked[@]} -gt 0 ]]; then
      echo "  - these listening services become unreachable from outside:"
      printf '      %s\n' "${blocked[@]}"
      echo "    keep one with --allow <port>/<proto>@<source-ip>"
    fi
    echo "Rerun with --confirm yes to apply. Undo: simai-admin.sh self firewall-disable --confirm yes"
    return 0
  fi

  if ! command -v ufw >/dev/null 2>&1; then
    os_cmd_pkg_install ufw
    run_long "Installing ufw" "${OS_CMD[@]}" || return 1
  fi
  # SSH first, so enabling the policy cannot cut the current session.
  for p in "${ssh_ports[@]}"; do ufw allow "${p}/tcp" >>"$LOG_FILE" 2>&1 || return 1; done
  ufw allow 80/tcp >>"$LOG_FILE" 2>&1 || return 1
  ufw allow 443/tcp >>"$LOG_FILE" 2>&1 || return 1
  for p in "${extra[@]}"; do
    if [[ "$p" == *@* ]]; then
      ufw allow from "${p#*@}" to any port "${p%%/*}" proto "$(cut -d/ -f2 <<<"${p%%@*}")" >>"$LOG_FILE" 2>&1 || return 1
    else
      ufw allow "$p" >>"$LOG_FILE" 2>&1 || return 1
    fi
  done
  for p in "${ssh_ports[@]}"; do
    ufw show added 2>/dev/null | grep -qE "^ufw allow ${p}/tcp\$" || { error "SSH rule for port ${p} is missing; firewall not enabled"; return 1; }
  done
  ufw default deny incoming >>"$LOG_FILE" 2>&1 || return 1
  ufw default allow outgoing >>"$LOG_FILE" 2>&1 || return 1
  ufw --force enable >>"$LOG_FILE" 2>&1 || { error "ufw could not be enabled; see ${LOG_FILE}"; return 1; }
  self_firewall_status_handler
}

self_firewall_disable_handler() {
  command -v ufw >/dev/null 2>&1 || { info "ufw is not installed"; return 0; }
  ufw --force disable >>"$LOG_FILE" 2>&1 || return 1
  self_firewall_status_handler
}

register_cmd "self" "swap-status" "Show memory and swap" "self_swap_status_handler" "" "" "effects:read"
register_cmd "self" "swap-ensure" "Create and enable a swap file (default 2G) with low swappiness" "self_swap_ensure_handler" "" "size= swappiness= confirm=" "tier:advanced plan:handler"
register_cmd "self" "firewall-status" "Show firewall state and rules" "self_firewall_status_handler" "" "" "effects:read"
register_cmd "self" "firewall-ensure" "Allow only SSH, HTTP and HTTPS (plus explicit --allow entries)" "self_firewall_ensure_handler" "" "allow= confirm=" "tier:advanced plan:handler"
register_cmd "self" "firewall-disable" "Disable the firewall (rollback of firewall-ensure)" "self_firewall_disable_handler" "" "" "tier:advanced"

# --- host settings ----------------------------------------------------------
# /etc/simai-env.conf is sourced by every command, so only allowlisted keys
# with validated values are written, inside one managed block.

SELF_SETTINGS_BEGIN="# simai-host-settings-begin"
SELF_SETTINGS_END="# simai-host-settings-end"

self_setting_pattern() {
  case "$1" in
    SIMAI_SITE_ISOLATION) echo '^(yes|no)$' ;;
    SIMAI_LOCK_WAIT) echo '^[0-9]{1,5}$' ;;
    SIMAI_BACKUP_OFFSITE) echo '^([a-z_][a-z0-9_-]{0,31}@[A-Za-z0-9.-]{1,253}:/[A-Za-z0-9._/-]{1,200})?$' ;;
    *) return 1 ;;
  esac
}

self_setting_describe() {
  case "$1" in
    SIMAI_SITE_ISOLATION) echo "yes: each new site gets its own system user; no: new sites run as ${SIMAI_BASE_USER:-simai}" ;;
    SIMAI_LOCK_WAIT) echo "seconds automation waits for a busy site/host lock (interactive callers do not wait)" ;;
    SIMAI_BACKUP_OFFSITE) echo "user@host:/path for off-site copies of backup data" ;;
  esac
}

self_settings_keys() {
  printf '%s\n' SIMAI_SITE_ISOLATION SIMAI_LOCK_WAIT SIMAI_BACKUP_OFFSITE
}

self_settings_handler() {
  local key rows=()
  ui_header "SIMAI ENV · Host settings"
  for key in $(self_settings_keys); do
    rows+=("${key}|${!key:-<default>} — $(self_setting_describe "$key")")
  done
  ui_result_table "${rows[@]}"
  ui_kv "Change" "simai-admin.sh self setting-set --key <KEY> --value <value> --confirm yes"
}

self_setting_set_handler() {
  parse_kv_args "$@"
  local key="${PARSED_ARGS[key]:-}" value="${PARSED_ARGS[value]-}" pattern conf="/etc/simai-env.conf"
  require_args "key" || return 1
  pattern=$(self_setting_pattern "$key") || { error "Unknown setting ${key}; known: $(self_settings_keys | paste -sd ' ' -)"; return 1; }
  [[ "$value" =~ $pattern ]] || { error "Invalid value for ${key}"; return 1; }
  local -A current=()
  local line k
  if [[ -f "$conf" ]]; then
    while IFS= read -r line; do
      k="${line%%=*}"
      self_setting_pattern "$k" >/dev/null && current["$k"]="${line#*=}"
    done < <(awk -v b="$SELF_SETTINGS_BEGIN" -v e="$SELF_SETTINGS_END" '$0 == b {on = 1; next} $0 == e {on = 0} on' "$conf")
  fi
  current["$key"]="$value"
  local content=""
  for k in $(self_settings_keys); do
    [[ -n "${current[$k]+x}" && -n "${current[$k]}" ]] && content+="${k}=${current[$k]}"$'\n'
  done
  [[ -f "$conf" ]] && cp -p "$conf" "${conf}.simai-bak.$(date +%Y%m%d%H%M%S)"
  scheduler_replace_managed_block "$conf" "$SELF_SETTINGS_BEGIN" "$SELF_SETTINGS_END" "${content%$'\n'}" || return 1
  info "${key}=${value:-<default>} written to ${conf}"
  [[ "$key" != SIMAI_SITE_ISOLATION ]] || info "Applies to sites created from now on; existing sites keep their user (see site isolate)"
}

register_cmd "self" "settings" "Show host settings that simai-env reads from /etc/simai-env.conf" "self_settings_handler" "" "" "effects:read"
register_cmd "self" "setting-set" "Set one allowlisted host setting (e.g. SIMAI_SITE_ISOLATION=no for one shared site account)" "self_setting_set_handler" "key" "value=" "tier:advanced"
