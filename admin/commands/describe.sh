#!/usr/bin/env bash

# AI-first discovery: an agent that connects to a server runs
#   simai-admin.sh self describe      (host, services, owners, sites)
#   simai-admin.sh site describe ...  (one site: layout, database, workers, how-to)
#   simai-admin.sh self commands      (every command with its options)
# All output is JSON on stdout; logs go to stderr. Secrets are never included.

self_describe_handler() {
  parse_kv_args "$@"
  python3 "${SIMAI_ENV_ROOT}/lib/host_describe.py" "$SIMAI_ENV_ROOT" host
}

site_describe_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  python3 "${SIMAI_ENV_ROOT}/lib/host_describe.py" "$SIMAI_ENV_ROOT" site "$domain"
}

# Whether sites answer and how much disk they use, for self describe; cron
# runs it every five minutes (self_status_cron_ensure).
SIMAI_STATUS_CRON="${SIMAI_STATUS_CRON:-/etc/cron.d/simai-site-status}"

self_status_refresh_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/site_status.py" --disk-every "${SIMAI_STATUS_DISK_MINUTES:-60}" || return 1
  # Alerts and the load history come from the same run, so they keep working
  # while the panel is closed or down.
  python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" run
  # Unattended upgrades change packages outside simai-env: refill the apt
  # answer cache so the panel's software and PHP lists stay fast.
  apt_cache_warm
  # The security report (local checks; vulnerability databases once a day).
  security_refresh_background
  # Firewall and panel access changes nobody confirmed are undone even when
  # their timer is gone (after a reboot).
  if [[ -n "$(python3 -I "${SIMAI_ENV_ROOT}/lib/timed_change.py" expired 2>/dev/null)" || -s /etc/simai-env/firewall/blocks.json ]]; then
    SIMAI_ADMIN_MENU=0 "${SIMAI_ENV_ROOT}/simai-admin.sh" change expire --confirm yes >/dev/null 2>&1 || true
  fi
}

self_profiles_handler() {
  parse_kv_args "$@"
  SIMAI_PROFILES_DIR="$(profiles_dir)" python3 -I "${SIMAI_ENV_ROOT}/lib/site_profiles.py" "${SIMAI_COMMAND_OUTPUT:-human}"
}

self_alerts_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" alerts "${SIMAI_COMMAND_OUTPUT:-human}"
}

self_alerts_ack_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[id]:-}" by="${PARSED_ARGS[by]:-${SUDO_USER:-root}}"
  require_args "id" || return 1
  [[ "$id" =~ ^[a-f0-9]{12}$ ]] || { error "--id must be an alert id from self alerts"; return 1; }
  python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" ack "$id" "$by"
}

# The Telegram bot token is read from a file and kept root-only; it is never
# printed. The webhook URL is shown only as its scheme and host.
self_alerts_channel_handler() {
  parse_kv_args "$@"
  local kind="${PARSED_ARGS[kind]:-}" target="${PARSED_ARGS[target]:-}" token_file="${PARSED_ARGS[token-file]:-}"
  require_args "kind" || return 1
  case "$kind" in
    off) python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" channel off - ;;
    webhook|telegram)
      require_args "target" || return 1
      python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" channel "$kind" "$target" ${token_file:+"$token_file"} ;;
    *) error "--kind must be webhook, telegram or off"; return 1 ;;
  esac
}

self_alerts_test_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" test
}

self_metrics_history_handler() {
  parse_kv_args "$@"
  local period="${PARSED_ARGS[period]:-day}"
  [[ "$period" =~ ^(day|week|month)$ ]] || { error "--period must be day, week or month"; return 1; }
  python3 -I "${SIMAI_ENV_ROOT}/lib/server_watch.py" history "$period" "${SIMAI_COMMAND_OUTPUT:-human}"
}

self_status_cron_ensure() {
  local want tmp
  want="*/5 * * * * root SIMAI_ADMIN_MENU=0 ${SIMAI_ENV_ROOT}/simai-admin.sh self status-refresh --confirm yes >/dev/null 2>&1"
  grep -qsxF "$want" "$SIMAI_STATUS_CRON" && return 1
  tmp=$(mktemp) || return 0
  printf '# simai-managed: yes (site answers, disk, alerts and load history)\n%s\n' "$want" >"$tmp"
  install -m 0644 -o root -g root "$tmp" "$SIMAI_STATUS_CRON"
  rm -f "$tmp"
  return 0
}

# shellcheck disable=SC2120 # called by the dispatcher with optional global arguments
self_commands_handler() {
  parse_kv_args "$@"
  local key
  for key in "${!CMD_HANDLERS[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$key" "${CMD_DESCRIPTIONS[$key]:-}" "${CMD_REQUIRED[$key]:-}" \
      "${CMD_OPTIONAL[$key]:-}" "${CMD_FLAGS[$key]:-}" "${CMD_EFFECTS[$key]}" "${CMD_AUTHORIZATION[$key]}" \
      "${CMD_CONFIRMATION[$key]}" "${CMD_LOCK[$key]}" "${CMD_VERIFICATION[$key]}"
  done | sort | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    key, desc, required, optional, flags, effects, authorization, confirmation, lock, verification = line.rstrip("\n").split("\t")
    section, name = key.split(":", 1)
    opts = [o.split("=", 1) for o in optional.split()]
    out.append({
        "command": f"simai-admin.sh {section} {name}",
        "description": desc,
        "required": [f"--{r}" for r in required.split()],
        "optional": {f"--{o[0]}": (o[1] if len(o) > 1 and o[1] else None) for o in opts},
        "flags": flags.split(),
        "effects": effects,
        "authorization": authorization,
        "confirmation": confirmation,
        "lock": lock if effects != "read" else "none",
        "verification": verification,
        "global_options": {"--confirm": "yes|no", "--dry-run": "yes|no", "--dry_run": "yes|no (alias)", "--output": "human|json"},
        "conditional_effects": {"observer:status": "--refresh yes writes", "self:version": "--refresh yes writes update cache", "self:auto-update-status": "--refresh yes writes update cache", "site:drift": "--fix yes writes", "backup:import": "--apply yes writes", "backup:data-verify": "--restore-test yes writes"}.get(key),
    })
json.dump({"schema": "simai-commands/1", "count": len(out), "commands": out}, sys.stdout, indent=2, ensure_ascii=False)
print()'
}

self_ai_catalog_handler() {
  parse_kv_args "$@"
  self_commands_handler | python3 "${SIMAI_ENV_ROOT}/lib/ai_catalog.py" "$(cat "${SIMAI_ENV_ROOT}/VERSION")"
}

self_metrics_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/host_metrics.py" "${SIMAI_COMMAND_OUTPUT:-human}"
}

register_cmd "self" "describe" "Describe this host for humans and AI agents (JSON)" "self_describe_handler" "" "" "tier:advanced effects:read"
register_cmd "site" "describe" "Describe one site: layout, database, workers, how-to (JSON)" "site_describe_handler" "domain" "" "tier:advanced effects:read"
register_cmd "self" "commands" "List every command with its options (JSON)" "self_commands_handler" "" "" "tier:advanced effects:read"
register_cmd "self" "metrics" "Show current CPU load, memory, swap and disk use" "self_metrics_handler" "" "" "tier:advanced effects:read"
register_cmd "self" "status-refresh" "Check whether sites answer, measure their disk use, update alerts and the load history" "self_status_refresh_handler" "" "" "tier:advanced lock:none"
register_cmd "self" "alerts" "List server alerts: disk, certificates, sites, backups, the panel" "self_alerts_handler" "" "" "tier:advanced effects:read"
register_cmd "self" "alerts-ack" "Acknowledge an open alert" "self_alerts_ack_handler" "id" "by=" "tier:advanced lock:none"
register_cmd "self" "alerts-channel" "Send alerts to a webhook or a Telegram chat, or nowhere" "self_alerts_channel_handler" "kind" "target= token-file=" "tier:advanced lock:none"
register_cmd "self" "alerts-test" "Send a test message to the alert channel" "self_alerts_test_handler" "" "" "tier:advanced lock:none"
register_cmd "self" "metrics-history" "Show the load history: 5-minute points for a day, hourly for a week or month" "self_metrics_history_handler" "" "period=" "tier:advanced effects:read"
register_cmd "self" "profiles" "List enabled site profiles with the site add arguments, values and defaults of each" "self_profiles_handler" "" "" "tier:advanced effects:read"
register_cmd "self" "ai-catalog" "Generate AI First 1.0.0 discovery for the read-only pilot (JSON)" "self_ai_catalog_handler" "" "" "tier:advanced effects:read"
