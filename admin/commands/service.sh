#!/usr/bin/env bash
set -euo pipefail

# Host services the panel may restart, reload, start, stop and read: nginx,
# PHP-FPM of the installed versions, the database servers, Redis and cron.
# Names are checked against this host, never passed to systemctl as given.
# Sites stop answering without nginx, PHP-FPM or a database server: those
# are critical and only restart or reload (1.62.0).
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

service_critical() {
  [[ "$1" =~ ^(nginx|mysql|mariadb|postgresql|php[5-9]\.[0-9]-fpm)$ ]]
}

# What stops working while a service is stopped: one row per site
# (domain<TAB>why). cron runs the sites' schedulers and cron jobs; Redis
# serves the sites whose .env picks it for cache, sessions or the queue, and
# their redis workers. Only the driver keys are read, compared with "redis".
service_dependents() {
  local name="$1" domain project root env key val unit
  while IFS= read -r domain; do
    [[ -n "$domain" ]] || continue
    project=$(project_slug_from_domain "$domain" 2>/dev/null) || continue
    root="${WWW_ROOT}/${domain}"
    case "$name" in
      cron)
        if [[ -f "/etc/cron.d/${project}" ]] && grep -qsv '^[[:space:]]*\(#\|$\)' "/etc/cron.d/${project}"; then
          printf '%s\tscheduler\n' "$domain"
        fi
        ;;
      redis-server)
        env="${root}/.env"
        if [[ -f "$env" && ! -L "$env" ]]; then
          while IFS='=' read -r key val; do
            val="${val//\"/}"; val="${val//\'/}"; val="${val%%[[:space:]]*}"
            [[ "${val,,}" == redis ]] && printf '%s\t%s\n' "$domain" "${key,,}"
          done < <(grep -sE '^(CACHE_STORE|CACHE_DRIVER|SESSION_DRIVER|QUEUE_CONNECTION)=' "$env" | head -n 8)
        fi
        for unit in /etc/systemd/system/laravel-queue-"${project}".service /etc/systemd/system/laravel-queue-"${project}"-*.service; do
          [[ -f "$unit" ]] && grep -qsE '^ExecStart=.*queue:work redis' "$unit" && printf '%s\tworker\n' "$domain"
        done
        ;;
    esac
  done < <(list_sites 2>/dev/null || true)
  return 0
}

# The plan of service stop: refused for a critical service (reason
# "critical"), otherwise it names the sites that lose something.
service_stop_plan_check() {
  local name
  name=$(command_arg name "$@")
  [[ -n "$name" ]] || return 0
  service_require_name "$name" || return 1
  if service_critical "$name"; then
    error "${name} is critical: sites stop answering without it; use service restart"
    site_plan_data_write "$(python3 -I -c 'import json,sys; print(json.dumps({"refusal": "critical", "detail": sys.argv[1]}))' \
      "${name} is critical: sites stop answering without it; use service restart")"
    return 1
  fi
  local rows
  rows=$(service_dependents "$name" | sort -u)
  [[ -z "$rows" ]] || warn "While ${name} is stopped: $(cut -f1 <<<"$rows" | sort -u | paste -sd' ')"
  [[ "$name" != cron ]] || warn "While cron is stopped the server's own checks and alerts pause too"
  site_plan_data_write "$(NAME="$name" ACTIVE="$(systemctl is-active "$name" 2>/dev/null || true)" python3 -I -c '
import json, os, sys
sites = {}
for line in sys.stdin.read().splitlines():
    domain, _, why = line.partition("\t")
    if domain:
        sites.setdefault(domain, [])
        if why and why not in sites[domain]:
            sites[domain].append(why)
print(json.dumps({"service": os.environ["NAME"], "active": os.environ["ACTIVE"] or "unknown",
                  "critical": False, "server": os.environ["NAME"] == "cron",
                  "sites": [{"domain": d, "uses": w} for d, w in sorted(sites.items())],
                  "until": "start or reboot"}))' <<<"$rows")"
  return 0
}

service_journal_tail() {
  journalctl -u "$1" -n "${2:-30}" --no-pager -o short-iso 2>/dev/null || true
}

service_apply() {
  local action="$1" name="$2"
  service_require_name "$name" || return 1
  if ! service_config_test "$name" >&2; then
    error "${name}: the configuration test failed; nothing was done (${action})"
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

service_stop_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}"
  service_require_name "$name" || return 1
  if service_critical "$name"; then
    error "${name} is critical: sites stop answering without it; use service restart"
    return 1
  fi
  if ! systemctl stop "$name" || systemctl is-active --quiet "$name"; then
    error "${name} is still running after stop; last journal lines:"
    service_journal_tail "$name" 30 >&2
    return 1
  fi
  ui_result_table "Service|${name}" "Action|stop" "State|$(systemctl is-active "$name" 2>/dev/null || true)" \
    "Note|starts again with service start or on reboot"
}

service_start_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  service_apply start "${PARSED_ARGS[name]}"
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
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$(systemctl is-active "$name" 2>/dev/null || true)" \
      "$(systemctl is-enabled "$name" 2>/dev/null || true)" \
      "$(systemctl show -p ActiveEnterTimestamp --value "$name" 2>/dev/null || true)" \
      "$(systemctl show -p CanReload --value "$name" 2>/dev/null || true)" \
      "$(service_critical "$name" && echo yes || echo no)"
  done | OUTPUT="${SIMAI_COMMAND_OUTPUT:-human}" python3 -I -c '
import json, os, sys
rows = []
for line in sys.stdin:
    name, active, enabled, since, reload, critical = line.rstrip("\n").split("\t")
    rows.append({"name": name, "active": active or "unknown", "enabled": enabled or "unknown",
                 "since": since or None, "can_reload": reload == "yes",
                 "critical": critical == "yes", "can_stop": critical != "yes"})
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
  local format="${PARSED_ARGS[format]:-text}" priority="${PARSED_ARGS[priority]:-}"
  service_require_name "$name" || return 1
  [[ "$lines" =~ ^[1-9][0-9]{0,4}$ ]] && (( lines <= 10000 )) || { error "--lines must be 1-10000"; return 1; }
  [[ "$format" == text || "$format" == json ]] || { error "--format must be text or json"; return 1; }
  [[ -z "$priority" || "$priority" =~ ^(emerg|alert|crit|err|warning|notice|info|debug)$ ]] || { error "--priority must be emerg, alert, crit, err, warning, notice, info or debug"; return 1; }
  local -a filter=()
  [[ -z "$priority" ]] || filter=(-p "$priority")
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" != json ]]; then
    journalctl -u "$name" -n "$lines" "${filter[@]}" --no-pager -o short-iso 2>/dev/null || true
    return 0
  fi
  # JSON: journald's own entries, so time (with the zone) and priority are exact.
  journalctl -u "$name" -n "$lines" "${filter[@]}" --no-pager -o json 2>/dev/null \
    | "${SIMAI_ENV_ROOT}/lib/log_entries.py" journal \
    | NAME="$name" FORMAT="$format" PRIORITY="$priority" python3 -I -c '
import json, os, sys
entries = json.load(sys.stdin)
answer = {"schema": "simai-service-log/1", "name": os.environ["NAME"], "lines": [e["raw"][:2000] for e in entries]}
if os.environ["PRIORITY"]:
    answer["priority"] = os.environ["PRIORITY"]
if os.environ["FORMAT"] == "json":
    answer["entries"] = entries
print(json.dumps(answer, ensure_ascii=False))'
}

register_cmd "service" "list" "List host services (nginx, PHP-FPM, databases, Redis, cron) and their state" "service_list_handler" "" "" "tier:advanced effects:read"
register_cmd "service" "restart" "Restart a host service after its configuration test" "service_restart_handler" "name" "" "tier:advanced"
register_cmd "service" "reload" "Reload a host service's configuration after its test" "service_reload_handler" "name" "" "tier:advanced"
register_cmd "service" "stop" "Stop a host service that sites can do without for a while (Redis, cron); the plan names the sites that lose it" "service_stop_handler" "name" "" "tier:advanced"
register_cmd "service" "start" "Start a stopped host service after its configuration test" "service_start_handler" "name" "" "tier:advanced"
register_cmd "service" "log" "Show the last journal lines of a host service" "service_log_handler" "name" "lines= format= priority=" "tier:advanced effects:read"
