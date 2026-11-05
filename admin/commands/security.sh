#!/usr/bin/env bash
set -euo pipefail

# Security center: a passive check of the server and its sites with a score,
# recommendations and one-click fixes (lib/security_audit.py). The status
# refresh keeps the report current every five minutes; vulnerability
# databases are asked once a day.

SIMAI_SECURITY_STATE="${SIMAI_SECURITY_STATE:-/var/lib/simai-env/security}"
SIMAI_FAIL2BAN_JAIL="${SIMAI_FAIL2BAN_JAIL:-/etc/fail2ban/jail.d/simai.conf}"

security_panel_access_file() {
  local domain
  domain=$(sed -n 's/^PANEL_DOMAIN=//p' /etc/simai-env/panel.env 2>/dev/null | tail -n1)
  [[ -n "$domain" ]] || return 0
  panel_access_file "$domain" 2>/dev/null || true
}

security_audit() {
  SIMAI_PANEL_ACCESS_FILE="$(security_panel_access_file)" SIMAI_SECURITY_ONLINE="${SIMAI_SECURITY_ONLINE:-yes}" \
    python3 -I "${SIMAI_ENV_ROOT}/lib/security_audit.py" "$@"
}

security_status_handler() {
  parse_kv_args "$@"
  security_audit status "${SIMAI_COMMAND_OUTPUT:-human}"
}

# Asks the vulnerability databases now (normally once a day by itself).
security_scan_handler() {
  parse_kv_args "$@"
  install -d -m 0700 "$SIMAI_SECURITY_STATE"
  exec 7>"${SIMAI_SECURITY_STATE}/.lock"
  flock -w 120 7 || { error "Another security scan is running"; return 1; }
  info "Checking the server and asking the vulnerability databases"
  security_audit refresh online || { error "The security scan failed"; return 1; }
  security_audit status human
}

# Called by self status-refresh: local checks every run, the online part
# when the last one is a day old; detached so the refresh never waits.
security_refresh_background() {
  install -d -m 0700 "$SIMAI_SECURITY_STATE" 2>/dev/null || return 0
  (
    exec 7>"${SIMAI_SECURITY_STATE}/.lock"
    flock -n 7 || exit 0
    security_audit refresh auto >/dev/null 2>&1 || true
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

security_ssh_keys_present() {
  local f
  for f in /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys; do
    [[ -s "$f" ]] && grep -qE '^(ssh-|ecdsa-|sk-)' "$f" && return 0
  done
  return 1
}

security_fix_auto_updates() {
  if ! dpkg -s unattended-upgrades >/dev/null 2>&1; then
    run_long "Installing unattended-upgrades" env DEBIAN_FRONTEND=noninteractive apt-get install -y unattended-upgrades || return 1
  fi
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
// simai-env: install security updates every day (security center)
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
  os_svc_enable_now unattended-upgrades >>"$LOG_FILE" 2>&1 || true
  apt_cache_warm
}

security_fix_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    run_long "Installing Fail2ban" env DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban python3-systemd || return 1
  fi
  install -d -m 0755 "$(dirname "$SIMAI_FAIL2BAN_JAIL")"
  cat >"$SIMAI_FAIL2BAN_JAIL" <<'EOF'
# simai-env: block addresses that guess SSH passwords (security center)
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
backend = systemd
EOF
  os_svc_enable_now fail2ban >>"$LOG_FILE" 2>&1 || true
  os_svc_restart fail2ban >>"$LOG_FILE" 2>&1 || true
  local _
  for _ in {1..20}; do
    fail2ban-client status sshd >/dev/null 2>&1 && { apt_cache_warm; return 0; }
    sleep 0.5
  done
  error "Fail2ban did not start its SSH jail (journalctl -u fail2ban)"
  return 1
}

security_fix_handler() {
  parse_kv_args "$@"
  require_args "check" || return 1
  local name="${PARSED_ARGS[check]}" confirm="${PARSED_ARGS[confirm]:-no}" plan
  case "$name" in
    auto_updates) plan="install unattended-upgrades and let it install security updates every day" ;;
    fail2ban) plan="install Fail2ban and ban an address for an hour after 5 failed SSH logins in 10 minutes" ;;
    ssh_password)
      security_ssh_keys_present || { error "No SSH key is set for root or any user: add one first (owner add-key), or you would be locked out"; return 1; }
      plan="allow SSH login with keys only (root by key only); SFTP accesses with passwords keep working"
      ;;
    *) error "--check must be auto_updates, fail2ban or ssh_password (others are fixed by the command in security status)"; return 1 ;;
  esac
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: ${plan}"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  case "$name" in
    auto_updates) security_fix_auto_updates || return 1 ;;
    fail2ban) security_fix_fail2ban || return 1 ;;
    ssh_password) self_ssh_hardening_ensure_handler --confirm yes >>"$LOG_FILE" 2>&1 || { error "sshd rejected the change (sshd -t)"; return 1; } ;;
  esac
  security_audit refresh >/dev/null 2>&1 || true
  ui_result_table "Fixed|${name}" "Done|${plan}"
}

register_cmd "security" "status" "Security check of the server and sites: score, problems and how to fix them" "security_status_handler" "" "" "tier:advanced effects:read"
register_cmd "security" "scan" "Ask the vulnerability databases about site components now (daily by itself)" "security_scan_handler" "" "" "tier:advanced lock:none"
register_cmd "security" "fix" "Fix a security problem: auto_updates, fail2ban or ssh_password" "security_fix_handler" "check" "confirm=" "tier:advanced plan:handler"
