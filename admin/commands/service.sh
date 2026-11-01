#!/usr/bin/env bash
set -euo pipefail

# Host services the panel may restart, reload and read: nginx, PHP-FPM of the
# installed versions, the database servers, Redis and cron. Names are checked
# against this host, never passed to systemctl as given.
service_names() {
  local name ver
  for name in nginx mysql mariadb postgresql redis-server cron; do
    os_svc_has_unit "$name" && printf '%s\n' "$name"
  done
  while IFS= read -r ver; do
    [[ -n "$ver" ]] && os_svc_has_unit "php${ver}-fpm" && printf 'php%s-fpm\n' "$ver"
  done < <(installed_php_versions)
  return 0
}

service_require_name() {
  local name="$1" names
  names=$(service_names)
  [[ "$name" =~ ^(nginx|mysql|mariadb|postgresql|redis-server|cron|php[5-9]\.[0-9]-fpm)$ ]] \
    && grep -qx -- "$name" <<<"$names" && return 0
  error "Unknown service: ${name:-<empty>}. Services on this host: ${names//$'\n'/ }"
  return 1
}

# A broken configuration must not take a running service down.
service_config_test() {
  case "$1" in
    nginx) nginx -t ;;
    php*-fpm) local ver="${1#php}"; "php-fpm${ver%-fpm}" -t 2>&1 | sed 's/^/  /' ; return "${PIPESTATUS[0]}" ;;
    *) return 0 ;;
  esac
}

service_journal_tail() {
  journalctl -u "$1" -n "${2:-30}" --no-pager -o short-iso 2>/dev/null || true
}

service_apply() {
  local action="$1" name="$2"
  service_require_name "$name" || return 1
  if ! service_config_test "$name" >&2; then
    error "${name}: the configuration test failed; the service was not ${action}ed and keeps running"
    return 1
  fi
  if [[ "$action" == reload && "$(systemctl show -p CanReload --value "$name" 2>/dev/null)" != yes ]]; then
    error "${name} cannot reload its configuration; use service restart"
    return 1
  fi
  if ! systemctl "$action" "$name" || ! systemctl is-active --quiet "$name"; then
    error "${name} is not running after ${action}; last journal lines:"
    service_journal_tail "$name" 30 >&2
    return 1
  fi
  ui_result_table "Service|${name}" "Action|${action}" "State|$(systemctl is-active "$name" 2>/dev/null)"
}

service_restart_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  service_apply restart "${PARSED_ARGS[name]}"
}

service_reload_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  service_apply reload "${PARSED_ARGS[name]}"
}

service_list_handler() {
  parse_kv_args "$@"
  local name
  service_names | while IFS= read -r name; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$(systemctl is-active "$name" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$name" 2>/dev/null || true)" \
      "$(systemctl show -p ActiveEnterTimestamp --value "$name" 2>/dev/null || true)" \
      "$(systemctl show -p CanReload --value "$name" 2>/dev/null || true)"
  done | OUTPUT="${SIMAI_COMMAND_OUTPUT:-human}" python3 -I -c '
import json, os, sys
rows = []
for line in sys.stdin:
    name, active, enabled, since, reload = line.rstrip("\n").split("\t")
    rows.append({"name": name, "active": active or "unknown", "enabled": enabled or "unknown",
                 "since": since or None, "can_reload": reload == "yes"})
if os.environ["OUTPUT"] == "json":
    print(json.dumps({"schema": "simai-services/1", "services": rows}))
else:
    for r in rows:
        print("{:<16} {:<10} {:<10} {}".format(r["name"], r["active"], r["enabled"], r["since"] or ""))'
}

service_log_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" lines="${PARSED_ARGS[lines]:-100}"
  service_require_name "$name" || return 1
  [[ "$lines" =~ ^[1-9][0-9]{0,3}$ ]] && (( lines <= 1000 )) || { error "--lines must be 1-1000"; return 1; }
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" != json ]]; then
    service_journal_tail "$name" "$lines"
    return 0
  fi
  service_journal_tail "$name" "$lines" | NAME="$name" python3 -I -c '
import json, os, sys
print(json.dumps({"schema": "simai-service-log/1", "name": os.environ["NAME"],
                  "lines": [l.rstrip("\n")[:2000] for l in sys.stdin]}, ensure_ascii=False))'
}

register_cmd "service" "list" "List host services (nginx, PHP-FPM, databases, Redis, cron) and their state" "service_list_handler" "" "" "tier:advanced effects:read"
register_cmd "service" "restart" "Restart a host service after its configuration test" "service_restart_handler" "name" "" "tier:advanced"
register_cmd "service" "reload" "Reload a host service's configuration after its test" "service_reload_handler" "name" "" "tier:advanced"
register_cmd "service" "log" "Show the last journal lines of a host service" "service_log_handler" "name" "lines=" "tier:advanced effects:read"
