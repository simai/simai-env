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
    warn "Log file not found: ${file}"
    return 1
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

# Access log lines whose status matches a list like 4xx,5xx or 404.
logs_status_filter() {
  local rx
  rx=$(printf '%s' "$1" | sed -e 's/x/[0-9]/g' -e 's/,/|/g')
  grep -E -- "\" (${rx}) " || true
}

logs_nginx_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local kind="${PARSED_ARGS[kind]:-access}"
  local lines="${PARSED_ARGS[lines]:-$LOGS_DEFAULT_LINES}"
  local match="${PARSED_ARGS[match]:-}"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "$domain" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select domain" "" "${_sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain" || return 1
  case "$kind" in
    access|error) ;;
    *) kind="access" ;;
  esac
  local file=""
  read_site_metadata "$domain"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local candidates=(
    "/var/log/nginx/${domain}.${kind}.log"
    "/var/log/nginx/${project}.${kind}.log"
  )
  for f in "${candidates[@]}"; do
    if [[ -f "$f" ]]; then
      file="$f"
      break
    fi
  done
  if [[ -z "$file" ]]; then
    warn "No ${kind} log found for ${domain} (checked: ${candidates[*]})"
    return 1
  fi
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    local format="${PARSED_ARGS[format]:-text}" status="${PARSED_ARGS[status]:-}"
    [[ "$lines" =~ ^[0-9]+$ ]] && (( lines >= 1 && lines <= 10000 )) || { error "--lines must be 1-10000"; return 1; }
    [[ "$format" == text || "$format" == json ]] || { error "--format must be text or json"; return 1; }
    [[ -z "$status" || "$status" =~ ^([1-5]xx|[1-5][0-9]{2})(,([1-5]xx|[1-5][0-9]{2}))*$ ]] || { error "--status must be a list like 4xx,5xx or 404"; return 1; }
    [[ -z "$status" || "$kind" == access ]] || { error "--status filters the access log only"; return 1; }
    # With --match (a fixed string) or --status (4xx, 5xx, 404): the last
    # matching lines among the last LOGS_MATCH_SCAN lines of the file.
    local scan="${LOGS_MATCH_SCAN:-20000}"
    if [[ -n "$match" || -n "$status" ]]; then
      tail -n "$scan" "$file" | { if [[ -n "$match" ]]; then grep -F -- "$match" || true; else cat; fi; } \
        | { if [[ -n "$status" ]]; then logs_status_filter "$status"; else cat; fi; } | tail -n "$lines"
    else
      tail -n "$lines" "$file"
    fi | FORMAT="$format" KIND="nginx-${kind}" ENTRIES="${SIMAI_ENV_ROOT}/lib/log_entries.py" python3 -I -c '
import json, os, subprocess, sys
data = sys.stdin.buffer.read()
rows = [l.rstrip("\n") for l in data.decode("utf-8", "replace").splitlines()]
answer = {"schema": "simai-log-tail/1", "domain": sys.argv[1], "kind": sys.argv[2], "file": sys.argv[3], "lines": rows,
          **({"match": sys.argv[4]} if sys.argv[4] else {}), **({"status": sys.argv[5]} if sys.argv[5] else {})}
if os.environ["FORMAT"] == "json":
    out = subprocess.run([sys.executable, "-I", os.environ["ENTRIES"], os.environ["KIND"]], input=data, capture_output=True)
    answer["entries"] = json.loads(out.stdout or b"[]")
json.dump(answer, sys.stdout, ensure_ascii=False)
print()' "$domain" "$kind" "$file" "$match" "$status"
    return 0
  fi
  if [[ -n "$match" ]]; then
    tail -n "${LOGS_MATCH_SCAN:-20000}" "$file" | { grep -F -- "$match" || true; } | tail -n "$lines"
    return 0
  fi
  logs_tail_file "$file" "$lines"
}

register_cmd "logs" "admin" "Tail simai-admin log" "logs_admin_handler" "" "lines=\${LOGS_DEFAULT_LINES}" "effects:read"
register_cmd "logs" "env" "Tail installer log" "logs_env_handler" "" "lines=\${LOGS_DEFAULT_LINES}" "effects:read"
register_cmd "logs" "audit" "Tail audit log" "logs_audit_handler" "" "lines=\${LOGS_DEFAULT_LINES}" "effects:read"
register_cmd "logs" "nginx" "Tail nginx access/error for a domain" "logs_nginx_handler" "" "domain= kind= lines=\${LOGS_DEFAULT_LINES} match= format= status=" "effects:read"
register_cmd "logs" "letsencrypt" "Tail Let's Encrypt log" "logs_letsencrypt_handler" "" "lines=\${LOGS_DEFAULT_LINES}" "effects:read"
