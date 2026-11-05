#!/usr/bin/env bash
set -euo pipefail

# A site's own nginx directives, included at server level from
# /etc/nginx/simai-custom/<project>.conf. A change is a timed change: nginx
# must accept it and the site must still answer, then it is undone unless
# confirmed in time (change confirm), so a mistake cannot lock the site out.

SIMAI_CUSTOM_NGINX_DIR="${SIMAI_CUSTOM_NGINX_DIR:-/etc/nginx/simai-custom}"
NGINX_CUSTOM_MAX=65536

nginx_custom_site() {
  local domain="$1"
  validate_domain "$domain" || return 1
  require_site_exists "$domain" || return 1
  declare -A meta=()
  NGINX_CUSTOM_CONF="/etc/nginx/sites-available/${domain}.conf"
  site_nginx_metadata_parse "$NGINX_CUSTOM_CONF" meta || { error "Nginx metadata not found for ${domain}"; return 1; }
  NGINX_CUSTOM_PROJECT="${meta[project]:-${meta[slug]:-}}"
  [[ -n "$NGINX_CUSTOM_PROJECT" ]] || { error "Site metadata incomplete for ${domain}"; return 1; }
  NGINX_CUSTOM_FILE="${SIMAI_CUSTOM_NGINX_DIR}/${NGINX_CUSTOM_PROJECT}.conf"
}

# Sites rendered before 1.41.0 lack the include; it goes after the access one.
nginx_custom_include_ensure() {
  local conf="$1" project="$2"
  grep -qF "simai-custom/${project}[.]conf" "$conf" && return 0
  if grep -qF "simai-access/${project}[.]conf" "$conf"; then
    sed -i -E "s#^([[:space:]]*)(include [^;]*simai-access/${project}\[\.\]conf;)#\1\2\n\1include ${SIMAI_CUSTOM_NGINX_DIR}/${project}[.]conf;#" "$conf"
  elif grep -qE "^[[:space:]]*error_log /var/log/nginx/${project}\.error\.log;" "$conf"; then
    sed -i -E "s#^([[:space:]]*)(error_log /var/log/nginx/${project}\.error\.log;)#\1\2\n\1include ${SIMAI_CUSTOM_NGINX_DIR}/${project}[.]conf;#" "$conf"
  fi
  grep -qF "simai-custom/${project}[.]conf" "$conf"
}

nginx_custom_answers() {
  python3 -I "${SCRIPT_DIR}/lib/site_status.py" --answers 2>/dev/null \
    | awk -F '\t' -v d="$1" '$1 == d && $2 > 0 && $2 < 500 {print "yes"}'
}

# --content-file F sets the directives; an empty file removes them.
site_nginx_custom_handler() {
  parse_kv_args "$@"
  require_args "domain content-file" || return 1
  local domain="${PARSED_ARGS[domain]}" src="${PARSED_ARGS[content-file]}" window begun id expires before
  nginx_custom_site "$domain" || return 1
  window=$(firewall_window "${PARSED_ARGS[window]:-}") || return 1
  [[ -f "$src" && ! -L "$src" ]] || { error "--content-file must be a file"; return 1; }
  (( $(stat -c %s "$src") <= NGINX_CUSTOM_MAX )) || { error "The directives are larger than ${NGINX_CUSTOM_MAX} bytes"; return 1; }
  [[ "$(tr -d '\000' <"$src" | wc -c)" -eq "$(stat -c %s "$src")" ]] || { error "The directives must be text"; return 1; }
  before=$(nginx_custom_answers "$domain")
  begun=$(timed_change_begin nginx_custom "$domain" "$window" "nginx directives of ${domain}" "$NGINX_CUSTOM_CONF" "$NGINX_CUSTOM_FILE") || return 1
  read -r id expires <<<"$begun"
  local test_out
  install -d -m 0755 "$SIMAI_CUSTOM_NGINX_DIR" \
    && nginx_custom_include_ensure "$NGINX_CUSTOM_CONF" "$NGINX_CUSTOM_PROJECT" || {
      timed_change_undo "$id" >/dev/null || true
      error "Cannot find where to include ${NGINX_CUSTOM_FILE} in ${NGINX_CUSTOM_CONF}"
      return 1
    }
  if [[ -s "$src" ]]; then
    { echo "# simai-env: own directives of ${domain}; managed by: simai-admin.sh site nginx-custom"; cat "$src"; echo; } \
      >"${NGINX_CUSTOM_FILE}.tmp" && mv -f "${NGINX_CUSTOM_FILE}.tmp" "$NGINX_CUSTOM_FILE"
  else
    rm -f -- "$NGINX_CUSTOM_FILE"
  fi
  if ! test_out=$(nginx -t 2>&1); then
    timed_change_undo "$id" >/dev/null || true
    error "nginx refused the directives; nothing changed:"
    grep -E 'emerg|error' <<<"$test_out" | grep -v 'test failed' | sed 's/^/  /' >&2
    return 1
  fi
  os_svc_reload_or_restart nginx >>"$LOG_FILE" 2>&1 || { timed_change_undo "$id" >/dev/null || true; error "nginx did not reload; nothing changed"; return 1; }
  sleep 1  # reload returns before the workers have the new configuration
  if [[ "$before" == yes ]]; then
    local _ now=""
    for _ in 1 2 3; do
      now=$(nginx_custom_answers "$domain"); [[ "$now" == yes ]] && break; sleep 2
    done
    if [[ "$now" != yes ]]; then
      timed_change_undo "$id" >/dev/null || true
      error "${domain} stopped answering with the new directives; they were undone"
      return 1
    fi
  fi
  timed_change_arm "$id" "$expires" "$window" nginx_custom
}

site_nginx_custom_show_handler() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]}" pending
  nginx_custom_site "$domain" || return 1
  pending=$(python3 -I "$TIMED_CHANGE_PY" pending nginx_custom 2>/dev/null || true)
  FILE="$NGINX_CUSTOM_FILE" DOMAIN="$domain" PENDING="$pending" OUTPUT="${SIMAI_COMMAND_OUTPUT:-human}" \
    INCLUDED=$(grep -qF "simai-custom/${NGINX_CUSTOM_PROJECT}[.]conf" "$NGINX_CUSTOM_CONF" && echo yes || echo no) \
    python3 -I -c '
import hashlib, json, os
path = os.environ["FILE"]
try:
    lines = open(path, encoding="utf-8", errors="replace").read().splitlines(keepends=True)
except OSError:
    lines = None
content = "".join(l for l in lines if not l.startswith("# simai-env: own directives")) if lines is not None else ""
content = content[:-1] if content.endswith("\n\n") else content
d = {"schema": "simai-nginx-custom/1", "domain": os.environ["DOMAIN"], "file": path, "present": lines is not None,
     "included": os.environ["INCLUDED"] == "yes", "content": content,
     "sha256": hashlib.sha256(content.encode()).hexdigest(), "pending_change": None}
if os.environ["PENDING"]:
    p = json.loads(os.environ["PENDING"])
    if p.get("domain") == d["domain"]:
        d["pending_change"] = {"change_id": p["change_id"], "expires_at": p["expires_at"]}
if os.environ["OUTPUT"] == "json":
    print(json.dumps(d, ensure_ascii=False))
else:
    print(content if content else "(no own directives)", end="" if content.endswith("\n") else "\n")
    if d["pending_change"]:
        print("Waiting for confirmation: change {change_id} until {expires_at}".format(**d["pending_change"]))'
}

register_cmd "site" "nginx-custom" "Set a site's own nginx directives (server level); undone unless confirmed (change confirm)" "site_nginx_custom_handler" "domain content-file" "window=" "tier:advanced"
register_cmd "site" "nginx-custom-show" "Show a site's own nginx directives" "site_nginx_custom_show_handler" "domain" "" "tier:advanced effects:read"
