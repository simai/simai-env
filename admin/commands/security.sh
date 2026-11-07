#!/usr/bin/env bash
set -euo pipefail

# Security center: a passive check of the server and its sites with a score,
# recommendations and one-click fixes (lib/security_audit.py). The status
# refresh keeps the report current every five minutes; vulnerability
# databases are asked once a day.

SIMAI_SECURITY_STATE="${SIMAI_SECURITY_STATE:-/var/lib/simai-env/security}"
SIMAI_FAIL2BAN_JAIL="${SIMAI_FAIL2BAN_JAIL:-/etc/fail2ban/jail.d/simai.conf}"
SIMAI_FAIL2BAN_WEB_JAIL="${SIMAI_FAIL2BAN_WEB_JAIL:-/etc/fail2ban/jail.d/simai-web.conf}"
SIMAI_WEB_PROTECT_CONF="${SIMAI_WEB_PROTECT_CONF:-/etc/nginx/conf.d/simai-protect.conf}"
SIMAI_SECURITY_ENV="${SIMAI_SECURITY_ENV:-/etc/simai-env/security.env}"

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
  security_guard_sync
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
    security_guard_sync >/dev/null 2>&1 || true
    # The country database once a month while country blocking is on.
    local geo_mode geo_at
    geo_mode=$(security_geo_mode)
    geo_at=$(stat -c %Y "$(security_geo_db)" 2>/dev/null || echo 0)
    if [[ -n "$geo_mode" && "$geo_mode" != off ]] && (( $(date +%s) - geo_at > 35 * 86400 )); then
      SIMAI_ADMIN_MENU=0 "${SIMAI_ENV_ROOT}/simai-admin.sh" security geo-update --confirm yes >/dev/null 2>&1 || true
    fi
    # Site files once a day, at night (02:00-05:59), at the lowest priority.
    local last hour
    hour=$(date +%H)
    last=$(stat -c %Y "${SIMAI_SECURITY_STATE}/files.json" 2>/dev/null || echo 0)
    if (( 10#$hour >= 2 && 10#$hour < 6 && $(date +%s) - last > 72000 )); then
      exec 6>"${SIMAI_SECURITY_STATE}/.files.lock"
      flock -n 6 && { security_file_scan "" >/dev/null 2>&1 || true; }
      security_audit refresh >/dev/null 2>&1 || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
}

security_file_scan() {  # domain (empty: every site)
  local engine=none
  command -v clamscan >/dev/null 2>&1 && engine=clamav
  nice -n 19 python3 -I "${SIMAI_ENV_ROOT}/lib/file_scan.py" scan-sites "$1" "$engine"
}

security_files_scan_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  [[ -z "$domain" ]] || { validate_domain "$domain" "allow" && require_site_exists "$domain"; } || return 1
  install -d -m 0700 "$SIMAI_SECURITY_STATE"
  exec 6>"${SIMAI_SECURITY_STATE}/.files.lock"
  flock -n 6 || { error "Another file scan is running"; return 1; }
  info "Checking site files for web shells and malware${domain:+ of ${domain}}"
  security_file_scan "$domain" || { error "The file scan failed"; return 1; }
  security_audit refresh >/dev/null 2>&1 || true
}

security_files_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/file_scan.py" results "${SIMAI_COMMAND_OUTPUT:-human}"
}

security_quarantine_handler() {
  parse_kv_args "$@"
  require_args "domain path" || return 1
  local domain="${PARSED_ARGS[domain]}" path="${PARSED_ARGS[path]}" confirm="${PARSED_ARGS[confirm]:-no}" out
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  [[ "$path" != /* && "$path" != *..* && ${#path} -le 1024 ]] || { error "--path must be a path inside the site, like public/shell.php"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: move ${path} of ${domain} into the quarantine (/var/lib/simai-env/quarantine, root only)"
    echo "      the site stops serving it; security quarantine-restore puts it back"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  out=$(python3 -I "${SIMAI_ENV_ROOT}/lib/file_scan.py" quarantine "$domain" "${SITE_META[root]}" "$path" 2>&1) \
    || { error "Cannot quarantine ${path}: ${out##*$'\n'}"; return 1; }
  security_audit refresh >/dev/null 2>&1 || true
  ui_result_table "Domain|${domain}" "File|${path}" "Quarantine id|$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["id"])' "$out")"
}

security_quarantine_list_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/file_scan.py" quarantine-list "${SIMAI_COMMAND_OUTPUT:-human}"
}

security_quarantine_restore_handler() {
  parse_kv_args "$@"
  require_args "id" || return 1
  local id="${PARSED_ARGS[id]}" confirm="${PARSED_ARGS[confirm]:-no}" out
  [[ "$id" =~ ^[a-f0-9]{12}$ ]] || { error "--id must be an id from security quarantine-list"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: put the quarantined file ${id} back to its place in the site (with its owner and mode)"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  out=$(python3 -I "${SIMAI_ENV_ROOT}/lib/file_scan.py" restore "$id" 2>&1) || { error "Cannot restore ${id}: ${out##*$'\n'}"; return 1; }
  ui_result_table "Restored|${id}"
}

# ClamAV: the scanner and its signature updates. The daemon (about 1.5 GB of
# memory) only on servers with 4 GB or more; otherwise each scan loads the
# signatures itself.
security_fix_antivirus() {
  local mem_kb pkgs=(clamav clamav-freshclam)
  mem_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
  (( mem_kb >= 3900000 )) && pkgs+=(clamav-daemon)
  run_long "Installing ClamAV" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" || return 1
  os_svc_enable_now clamav-freshclam >>"$LOG_FILE" 2>&1 || true
  if [[ " ${pkgs[*]} " == *" clamav-daemon "* ]]; then
    os_svc_enable_now clamav-daemon >>"$LOG_FILE" 2>&1 || true
    # The socket appears once the signatures are loaded; the hourly refresh
    # links the Bitrix sites later if it is not there yet.
    local _
    for _ in $(seq 1 60); do [[ -n "$(security_clamd_socket)" ]] && break; sleep 2; done
    security_guard_sync
  fi
  apt_cache_warm
}

# The SIMAI Guard module (simai.guard) of Bitrix sites checks files with
# ClamAV through clamd when SIMAI_GUARD_CLAMAV_SOCKET names its socket. While
# the daemon runs, every Bitrix site gets it in its PHP-FPM pool and its cron
# file (the agents); when it stops, the setting goes away. Content is sent
# over the socket (INSTREAM), so clamd needs no access to site files.
security_clamd_socket() {
  local sock
  sock=$(awk '$1 == "LocalSocket" {print $2; exit}' /etc/clamav/clamd.conf 2>/dev/null || true)
  if [[ -n "$sock" && -S "$sock" ]]; then printf '%s' "$sock"; fi
  return 0
}

security_guard_sync() {
  local sock domain pool cron changed_php=() line want
  sock=$(security_clamd_socket)
  if [[ -n "$sock" ]] && ! grep -qs '^AlertExceedsMax yes' /etc/clamav/clamd.conf; then
    # Otherwise clamd answers OK for a file over its size limits.
    printf 'AlertExceedsMax yes\n' >>/etc/clamav/clamd.conf
    os_svc_restart clamav-daemon >>"$LOG_FILE" 2>&1 || true
  fi
  for domain in $(list_simai_sites); do
    read_site_metadata "$domain" >/dev/null 2>&1 || continue
    [[ "${SITE_META[profile]:-}" == bitrix ]] || continue
    pool="/etc/php/${SITE_META[php]}/fpm/pool.d/${SITE_META[php_socket_project]:-${SITE_META[project]}}.conf"
    if [[ -f "$pool" ]]; then
      want="${sock:+env[SIMAI_GUARD_CLAMAV_SOCKET] = ${sock}}"
      line=$(grep -m1 '^env\[SIMAI_GUARD_CLAMAV_SOCKET\]' "$pool" || true)
      if [[ "$line" != "$want" ]]; then
        sed -i '/^env\[SIMAI_GUARD_CLAMAV_SOCKET\]/d' "$pool"
        if [[ -n "$want" ]]; then
          [[ -z "$(tail -c1 "$pool")" ]] || printf '\n' >>"$pool"  # the pool may end without a newline
          printf '%s\n' "$want" >>"$pool"
        fi
        [[ " ${changed_php[*]} " == *" ${SITE_META[php]} "* ]] || changed_php+=("${SITE_META[php]}")
      fi
    fi
    cron="/etc/cron.d/${SITE_META[project]}"
    if grep -qs '^# simai-managed: yes' "$cron"; then
      want="${sock:+SIMAI_GUARD_CLAMAV_SOCKET=${sock}}"
      line=$(grep -m1 '^SIMAI_GUARD_CLAMAV_SOCKET=' "$cron" || true)
      if [[ "$line" != "$want" ]]; then
        sed -i '/^SIMAI_GUARD_CLAMAV_SOCKET=/d' "$cron"
        if [[ -n "$want" ]]; then sed -i "0,/^\$/s||${want}\n|" "$cron"; fi
      fi
    fi
  done
  local ver
  for ver in "${changed_php[@]}"; do
    os_svc_reload_or_restart "php${ver}-fpm" >>"$LOG_FILE" 2>&1 || true
  done
  return 0
}

# Web protection for every site and the panel, at the nginx http level:
# requests per address are limited (short bursts pass), known attack
# scanners are slowed to a few requests a minute, and this server's own
# addresses are never limited. Fail2ban then bans addresses that keep
# hitting the limit or probing for admin pages.
security_web_protect_write() {  # rate burst
  local rate="$1" burst="$2"
  cat <<CONF
# simai-env: web protection (security center); managed by security web-protect
geo \$simai_limit_exempt {
    default 0;
    127.0.0.0/8 1;
    ::1 1;
}
map \$http_user_agent \$simai_bad_bot {
    default 0;
    "~*(sqlmap|nikto|nmap|masscan|zgrab|nuclei|wpscan|joomscan|acunetix|netsparker|dirbuster|gobuster|feroxbuster|ffuf|whatweb|httrack|libwww-perl|morfeus|zmeu|jorgee|havij|w3af|openvas)" 1;
}
map "\$simai_limit_exempt:\$simai_bad_bot" \$simai_flood_key {
    default \$binary_remote_addr;
    "~^1:" "";
}
map "\$simai_limit_exempt:\$simai_bad_bot" \$simai_bot_key {
    default "";
    "0:1" \$binary_remote_addr;
}
limit_req_zone \$simai_flood_key zone=simai_flood:20m rate=${rate}r/s;
limit_req_zone \$simai_bot_key zone=simai_bots:5m rate=6r/m;
limit_req zone=simai_flood burst=${burst} nodelay;
limit_req zone=simai_bots burst=3 nodelay;
limit_req_status 429;
limit_req_log_level warn;
CONF
}

security_fail2ban_web_write() {  # bantime maxretry
  local jail
  echo "# simai-env: ban addresses that keep hitting the request limit or probe for admin pages (security web-protect)"
  for jail in nginx-limit-req nginx-botsearch; do
    printf '\n[%s]\nenabled = true\nbackend = auto\nport = http,https\nlogpath = /var/log/nginx/*error.log\nfindtime = 10m\nmaxretry = %s\nbantime = %s\n' \
      "$jail" "$2" "$1"
  done
}

security_web_protect_apply() {  # enabled [rate burst bantime maxretry]
  local enabled="$1" rate="${2:-30}" burst="${3:-300}" bantime="${4:-1h}" maxretry="${5:-10}" saved=""
  if [[ -f "$SIMAI_WEB_PROTECT_CONF" ]]; then
    saved=$(mktemp); cp -p "$SIMAI_WEB_PROTECT_CONF" "$saved"
  fi
  if [[ "$enabled" == yes ]]; then
    security_web_protect_write "$rate" "$burst" >"$SIMAI_WEB_PROTECT_CONF"
  else
    rm -f -- "$SIMAI_WEB_PROTECT_CONF"
  fi
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    if [[ -n "$saved" ]]; then mv -f "$saved" "$SIMAI_WEB_PROTECT_CONF"; else rm -f -- "$SIMAI_WEB_PROTECT_CONF"; fi
    error "nginx rejected the web protection; nothing changed"
    return 1
  fi
  rm -f -- "$saved"
  os_svc_reload nginx >>"$LOG_FILE" 2>&1 || true
  if [[ "$enabled" == yes ]] && command -v fail2ban-client >/dev/null 2>&1; then
    security_fail2ban_web_write "$bantime" "$maxretry" >"$SIMAI_FAIL2BAN_WEB_JAIL"
  else
    rm -f -- "$SIMAI_FAIL2BAN_WEB_JAIL"
  fi
  if command -v fail2ban-client >/dev/null 2>&1; then
    os_svc_restart fail2ban >>"$LOG_FILE" 2>&1 || true
  fi
}

security_env_set() {  # key value
  install -d -m 0755 "$(dirname "$SIMAI_SECURITY_ENV")"
  touch "$SIMAI_SECURITY_ENV"
  chmod 0644 "$SIMAI_SECURITY_ENV"
  sed -i "/^${1}=/d" "$SIMAI_SECURITY_ENV"
  printf '%s=%s\n' "$1" "$2" >>"$SIMAI_SECURITY_ENV"
}

security_web_protect_handler() {
  parse_kv_args "$@"
  require_args "enabled" || return 1
  local enabled="${PARSED_ARGS[enabled]}" rate="${PARSED_ARGS[rate]:-30}" burst="${PARSED_ARGS[burst]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "$enabled" =~ ^(yes|no)$ ]] || { error "--enabled must be yes or no"; return 1; }
  if [[ ! "$rate" =~ ^[0-9]+$ ]] || (( rate < 2 || rate > 1000 )); then error "--rate must be 2-1000 requests a second"; return 1; fi
  burst="${burst:-$(( rate * 10 ))}"
  if [[ ! "$burst" =~ ^[0-9]+$ ]] || (( burst < 10 || burst > 10000 )); then error "--burst must be 10-10000"; return 1; fi
  if [[ "${confirm,,}" != yes ]]; then
    if [[ "$enabled" == yes ]]; then
      echo "Plan: limit every address to ${rate} requests a second (bursts of ${burst} pass) on all sites and the panel; slow known attack scanners to 6 a minute"
      echo "      this server's own addresses are never limited; with Fail2ban, addresses that keep hitting the limit or probe for admin pages are banned for an hour"
    else
      echo "Plan: remove the web request limits and the Fail2ban web jails"
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  security_web_protect_apply "$enabled" "$rate" "$burst" || return 1
  security_env_set WEB_PROTECT "$enabled"
  security_audit refresh >/dev/null 2>&1 || true
  ui_result_table "Web protection|${enabled}" "Limit|$([[ $enabled == yes ]] && echo "${rate}/s per address, burst ${burst}" || echo none)"
}

# Protection levels: a bundle of fixes for people who do not want to pick.
security_level_handler() {
  parse_kv_args "$@"
  require_args "set" || return 1
  local level="${PARSED_ARGS[set]}" confirm="${PARSED_ARGS[confirm]:-no}" rate=0 burst=0 bantime=1h maxretry=10
  [[ "$level" =~ ^(basic|enhanced|strict)$ ]] || { error "--set must be basic, enhanced or strict"; return 1; }
  case "$level" in
    enhanced) rate=30; burst=300 ;;
    strict) rate=10; burst=100; bantime=1d; maxretry=5 ;;
  esac
  local keys=yes
  security_ssh_keys_present || keys=no
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: protection level ${level}:"
    echo "  - firewall on: only SSH, HTTP and HTTPS are open"
    echo "  - security updates installed every day by themselves"
    echo "  - Fail2ban bans addresses that guess SSH passwords"
    if [[ "$level" == basic ]]; then
      echo "  - web request limits off"
    else
      echo "  - web requests limited to ${rate} a second per address (bursts of ${burst}); attack scanners slowed; Fail2ban bans offenders for ${bantime}"
      echo "  - ClamAV antivirus for the nightly file check"
      if [[ "$keys" == yes ]]; then
        echo "  - SSH with keys only (root by key only)"
      else
        echo "  - SSH passwords stay on: no SSH key is set yet (add one, then apply the level again)"
      fi
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  local -a applied=() skipped=()
  if ! ufw status 2>/dev/null | grep 'Status: active' >/dev/null; then
    SIMAI_ADMIN_MENU=0 self_firewall_ensure_handler --confirm yes >>"$LOG_FILE" 2>&1 || { error "The firewall could not be turned on"; return 1; }
  fi
  applied+=(firewall)
  security_fix_auto_updates || return 1; applied+=(auto_updates)
  security_fix_fail2ban || return 1; applied+=(fail2ban)
  if [[ "$level" == basic ]]; then
    security_web_protect_apply no || return 1
    security_env_set WEB_PROTECT no
  else
    security_web_protect_apply yes "$rate" "$burst" "$bantime" "$maxretry" || return 1
    security_env_set WEB_PROTECT yes; applied+=(web_protect)
    if ! command -v clamscan >/dev/null 2>&1; then security_fix_antivirus || return 1; fi
    applied+=(antivirus)
    if [[ "$keys" == yes ]]; then
      self_ssh_hardening_ensure_handler --confirm yes >>"$LOG_FILE" 2>&1 || { error "sshd rejected the change"; return 1; }
      applied+=(ssh_password)
    else
      skipped+=(ssh_password)
    fi
  fi
  security_env_set LEVEL "$level"
  security_env_set LEVEL_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  security_audit refresh >/dev/null 2>&1 || true
  ui_result_table "Level|${level}" "Applied|${applied[*]}" "Skipped|${skipped[*]:-none}"
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
    antivirus) plan="install ClamAV with daily signature updates; site files are then checked by it too (the daemon only with 4 GB of memory or more)" ;;
    auto_updates) plan="install unattended-upgrades and let it install security updates every day" ;;
    fail2ban) plan="install Fail2ban and ban an address for an hour after 5 failed SSH logins in 10 minutes" ;;
    ssh_password)
      security_ssh_keys_present || { error "No SSH key is set for root or any user: add one first (owner add-key), or you would be locked out"; return 1; }
      plan="allow SSH login with keys only (root by key only); SFTP accesses with passwords keep working"
      ;;
    *) error "--check must be antivirus, auto_updates, fail2ban or ssh_password (others are fixed by the command in security status)"; return 1 ;;
  esac
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: ${plan}"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  case "$name" in
    antivirus) security_fix_antivirus || return 1 ;;
    auto_updates) security_fix_auto_updates || return 1 ;;
    fail2ban) security_fix_fail2ban || return 1 ;;
    ssh_password) self_ssh_hardening_ensure_handler --confirm yes >>"$LOG_FILE" 2>&1 || { error "sshd rejected the change (sshd -t)"; return 1; } ;;
  esac
  security_audit refresh >/dev/null 2>&1 || true
  ui_result_table "Fixed|${name}" "Done|${plan}"
}

# Country blocking: nftables rules from the DB-IP Lite database
# (lib/geo_block.py). A change that could lock the administrator out
# (allow mode, or every port) is a timed change: undone unless confirmed.
SIMAI_GEO_DIR="${SIMAI_GEO_DIR:-/etc/simai-env/geo}"
SIMAI_GEO_DATA="${SIMAI_GEO_DATA:-/var/lib/simai-env/geo}"
SIMAI_GEO_UNIT="/etc/systemd/system/simai-geo.service"

security_geo_db() { echo "${SIMAI_GEO_DATA}/dbip-country-lite.csv.gz"; }

security_geo_download() {
  local month url tmp info
  install -d -m 0755 "$SIMAI_GEO_DATA"
  tmp="${SIMAI_GEO_DATA}/.download.csv.gz"
  for month in "$(date -u +%Y-%m)" "$(date -u -d "$(date -u +%Y-%m-15) -1 month" +%Y-%m)"; do
    url="${SIMAI_GEO_DB_URL:-https://download.db-ip.com/free/dbip-country-lite-${month}.csv.gz}"
    curl -fsSL --max-time 300 --retry 2 -o "$tmp" "$url" 2>>"$LOG_FILE" || continue
    if info=$(python3 -I "${SIMAI_ENV_ROOT}/lib/geo_block.py" check-db "$tmp" 2>>"$LOG_FILE") \
        && python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if d["rows"] >= int(sys.argv[2]) else 1)' "$info" "${SIMAI_GEO_MIN_ROWS:-100000}"; then
      mv -f "$tmp" "$(security_geo_db)"
      printf 'MONTH=%s\nAT=%s\nROWS=%s\n' "$month" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(python3 -I -c 'import json,sys; print(json.loads(sys.argv[1])["rows"])' "$info")" >"${SIMAI_GEO_DATA}/dbip-country-lite.csv.meta"
      return 0
    fi
    [[ -z "${SIMAI_GEO_DB_URL:-}" ]] || break
  done
  rm -f -- "$tmp"
  error "Cannot download the country database (db-ip.com)"
  return 1
}

security_geo_mode() { sed -n 's/^MODE=//p' "${SIMAI_GEO_DIR}/geo.env" 2>/dev/null | tail -n1; }

# Loads the rules (or removes them when off) and keeps them across reboots.
security_geo_load() {
  local mode
  mode=$(security_geo_mode)
  if [[ -z "$mode" || "$mode" == off || ! -s "${SIMAI_GEO_DIR}/rules.nft" ]]; then
    nft delete table inet simai_geo >/dev/null 2>&1 || true
    systemctl disable simai-geo.service >/dev/null 2>&1 || true
    return 0
  fi
  nft -f "${SIMAI_GEO_DIR}/rules.nft" || return 1
  if [[ ! -f "$SIMAI_GEO_UNIT" ]]; then
    cat >"$SIMAI_GEO_UNIT" <<UNIT
[Unit]
Description=simai-env country blocking rules
After=network-pre.target
Before=network.target
ConditionPathExists=${SIMAI_GEO_DIR}/rules.nft

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f ${SIMAI_GEO_DIR}/rules.nft

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  systemctl enable simai-geo.service >/dev/null 2>&1 || true
}

# Writes geo.env and rules.nft for a mode; prints the build summary.
security_geo_write() {  # mode countries ports keep
  install -d -m 0700 "$SIMAI_GEO_DIR"
  printf 'MODE=%s\nCOUNTRIES=%s\nPORTS=%s\n' "$1" "$2" "$3" >"${SIMAI_GEO_DIR}/geo.env.new"
  local built
  built=$(python3 -I "${SIMAI_ENV_ROOT}/lib/geo_block.py" build "${SIMAI_GEO_DIR}/geo.env.new" "$(security_geo_db)" \
    "${SIMAI_GEO_DIR}/rules.nft.new" "$4") || return 1
  nft -c -f "${SIMAI_GEO_DIR}/rules.nft.new" >>"$LOG_FILE" 2>&1 || { error "nftables rejected the country rules"; return 1; }
  python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print("RANGES_V4=%s\nRANGES_V6=%s" % (d["ranges_v4"], d["ranges_v6"]))' "$built" \
    >>"${SIMAI_GEO_DIR}/geo.env.new" 2>/dev/null || true
  mv -f "${SIMAI_GEO_DIR}/geo.env.new" "${SIMAI_GEO_DIR}/geo.env"
  mv -f "${SIMAI_GEO_DIR}/rules.nft.new" "${SIMAI_GEO_DIR}/rules.nft"
  printf '%s\n' "$built"
}

security_geo_handler() {
  parse_kv_args "$@"
  require_args "mode" || return 1
  local mode="${PARSED_ARGS[mode]}" countries="${PARSED_ARGS[countries]:-}" ports="${PARSED_ARGS[ports]:-web}"
  local window="${PARSED_ARGS[window]:-120}" confirm="${PARSED_ARGS[confirm]:-no}" keep="${PARSED_ARGS[keep]:-}"
  [[ "$mode" =~ ^(off|deny|allow)$ ]] || { error "--mode must be off, deny or allow"; return 1; }
  [[ "$ports" =~ ^(web|all)$ ]] || { error "--ports must be web or all"; return 1; }
  countries="${countries^^}"; countries="${countries// /}"
  if [[ "$mode" != off ]]; then
    [[ "$countries" =~ ^[A-Z]{2}(,[A-Z]{2}){0,99}$ ]] || { error "--countries must be country codes like RU,KZ (ISO 3166)"; return 1; }
  fi
  [[ -z "$keep" || "$keep" =~ ^[0-9A-Fa-f:./]{2,49}(,[0-9A-Fa-f:./]{2,49}){0,19}$ ]] || { error "--keep must be addresses or networks, comma separated"; return 1; }
  window=$(firewall_window "$window") || return 1
  # The administrator's own SSH address is never dropped.
  local client="${SSH_CLIENT:-}"; client="${client%% *}"
  [[ -n "$client" ]] && keep="${keep:+${keep},}${client}"
  local risky=no
  [[ "$mode" == allow || ( "$mode" != off && "$ports" == all ) ]] && risky=yes
  if [[ "${confirm,,}" != yes ]]; then
    case "$mode" in
      off) echo "Plan: turn country blocking off" ;;
      deny) echo "Plan: drop connections from ${countries} to $([[ $ports == web ]] && echo "the sites and the panel (ports 80, 443)" || echo "every port, SSH included")" ;;
      allow) echo "Plan: accept $([[ $ports == web ]] && echo "web connections (ports 80, 443)" || echo "connections to every port, SSH included,") only from ${countries}; drop the rest of the world" ;;
    esac
    [[ "$mode" == off ]] || echo "      never dropped: this server, private networks${client:+, your address ${client}}${PARSED_ARGS[keep]:+, ${PARSED_ARGS[keep]}}"
    [[ "$risky" == yes ]] && echo "      undone in ${window} seconds unless confirmed (change confirm), so a mistake cannot lock you out"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  if ! command -v nft >/dev/null 2>&1; then
    run_long "Installing nftables" env DEBIAN_FRONTEND=noninteractive apt-get install -y nftables || return 1
  fi
  if [[ "$mode" != off && ! -s "$(security_geo_db)" ]]; then
    info "Downloading the country database (DB-IP Lite)"
    security_geo_download || return 1
  fi
  local begun="" id="" expires="" built
  if [[ "$risky" == yes ]]; then
    begun=$(timed_change_begin geo "" "$window" "country blocking ${mode} ${countries} on ${ports} ports" \
      "${SIMAI_GEO_DIR}/geo.env" "${SIMAI_GEO_DIR}/rules.nft") || return 1
    read -r id expires <<<"$begun"
  fi
  if ! built=$(security_geo_write "$mode" "$countries" "$ports" "$keep") || ! security_geo_load; then
    [[ -n "$id" ]] && timed_change_undo "$id" >/dev/null 2>&1
    rm -f -- "${SIMAI_GEO_DIR}/geo.env.new" "${SIMAI_GEO_DIR}/rules.nft.new"
    error "Country blocking was not changed"
    return 1
  fi
  security_audit refresh >/dev/null 2>&1 || true
  if [[ -n "$id" ]]; then
    timed_change_arm "$id" "$expires" "$window" geo
  else
    ui_result_table "Country blocking|${mode}" "Countries|${countries:-none}" "Ports|${ports}" \
      "Ranges|$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["ranges_v4"] + d["ranges_v6"])' "$built" 2>/dev/null)"
  fi
}

security_geo_status_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/geo_block.py" status "${SIMAI_GEO_DIR}/geo.env" "$(security_geo_db)" "${SIMAI_COMMAND_OUTPUT:-human}"
}

security_geo_update_handler() {
  parse_kv_args "$@"
  security_geo_download || return 1
  local mode countries ports
  mode=$(security_geo_mode)
  if [[ -n "$mode" && "$mode" != off ]]; then
    countries=$(sed -n 's/^COUNTRIES=//p' "${SIMAI_GEO_DIR}/geo.env" | tail -n1)
    ports=$(sed -n 's/^PORTS=//p' "${SIMAI_GEO_DIR}/geo.env" | tail -n1)
    security_geo_write "$mode" "$countries" "${ports:-web}" "" >/dev/null && security_geo_load || { error "The new database could not be loaded; the old rules stay"; return 1; }
  fi
  ui_result_table "Country database|$(sed -n 's/^MONTH=//p' "${SIMAI_GEO_DATA}/dbip-country-lite.csv.meta")"
}

security_geo_lookup_handler() {
  parse_kv_args "$@"
  require_args "ip" || return 1
  [[ "${PARSED_ARGS[ip]}" =~ ^[0-9A-Fa-f:.]{2,45}$ ]] || { error "--ip must be an IP address"; return 1; }
  [[ -s "$(security_geo_db)" ]] || security_geo_download || return 1
  python3 -I "${SIMAI_ENV_ROOT}/lib/geo_block.py" lookup "$(security_geo_db)" "${PARSED_ARGS[ip]}" "${SIMAI_COMMAND_OUTPUT:-human}"
}

register_cmd "security" "geo" "Block or allow countries: off, deny or allow a list, on web ports or all" "security_geo_handler" "mode" "countries= ports= keep= window= confirm=" "tier:advanced plan:handler"
register_cmd "security" "geo-status" "Show country blocking: mode, countries, database and dropped packets" "security_geo_status_handler" "" "" "tier:advanced effects:read"
register_cmd "security" "geo-update" "Download the newest country database and reload the rules (monthly by itself)" "security_geo_update_handler" "" "" "tier:advanced"
register_cmd "security" "geo-lookup" "Show the country of an IP address" "security_geo_lookup_handler" "ip" "" "tier:advanced effects:read"
register_cmd "security" "status" "Security check of the server and sites: score, problems and how to fix them" "security_status_handler" "" "" "tier:advanced effects:read"
register_cmd "security" "scan" "Ask the vulnerability databases about site components now (daily by itself)" "security_scan_handler" "" "" "tier:advanced lock:none"
register_cmd "security" "files-scan" "Check site files for web shells and malware now (nightly by itself)" "security_files_scan_handler" "" "domain=" "tier:advanced lock:none"
register_cmd "security" "files" "Show suspicious site files found by the last file scan" "security_files_handler" "" "" "tier:advanced effects:read"
register_cmd "security" "quarantine" "Move a suspicious file of a site into the quarantine" "security_quarantine_handler" "domain path" "confirm=" "tier:advanced plan:handler"
register_cmd "security" "quarantine-list" "List quarantined files" "security_quarantine_list_handler" "" "" "tier:advanced effects:read"
register_cmd "security" "quarantine-restore" "Put a quarantined file back" "security_quarantine_restore_handler" "id" "confirm=" "tier:advanced plan:handler"
register_cmd "security" "web-protect" "Limit requests per address and slow attack scanners on all sites and the panel" "security_web_protect_handler" "enabled" "rate= burst= confirm=" "tier:advanced plan:handler"
register_cmd "security" "level" "Apply a protection level: basic, enhanced or strict" "security_level_handler" "set" "confirm=" "tier:advanced plan:handler"
register_cmd "security" "fix" "Fix a security problem: antivirus, auto_updates, fail2ban or ssh_password" "security_fix_handler" "check" "confirm=" "tier:advanced plan:handler"
