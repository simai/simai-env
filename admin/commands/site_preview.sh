#!/usr/bin/env bash
# A temporary link to a site before its domain points here (site
# preview-link / preview-link-close / preview-link-status, 1.65.0).
#
# Owner decision (2026-11-18): everything on this server, no outside
# service; the link is closed by a key and closes by itself.
#
# The site gets a port of its own on the server's address,
# http://<server IP>:<port>/, from SIMAI_PREVIEW_PORTS (7700-7799). The first
# visit goes to /.simai-preview/<key>: nginx sets a cookie with the key
# (scoped by the port in its name: browsers ignore ports in cookies) and
# sends the visitor to /; without the cookie every request is 403. Requests
# are proxied to the site's own server block with the site's Host, over
# HTTPS when the site has a certificate (no redirect loop), else HTTP.
# Redirects to the domain are rewritten back to the link.
#
# Files (root only; the key is a secret):
#   /etc/nginx/simai-preview/<project>.conf   the server block (0600)
#   /etc/simai-env/preview/<project>.env      domain, port, key, expiry (0600)
#
# Calling it again while open keeps the address and key and moves the
# deadline. The address with the key is handed out by the command only (the
# panel gets it once, the job log never); site describe shows the address
# without the key. It closes by itself: a systemd timer at the deadline and,
# after a reboot, the five-minute status refresh. When ufw is active the
# port is opened for the link and closed with it.
SIMAI_PREVIEW_NGINX_DIR="${SIMAI_PREVIEW_NGINX_DIR:-/etc/nginx/simai-preview}"
SIMAI_PREVIEW_DIR="${SIMAI_PREVIEW_DIR:-/etc/simai-env/preview}"
SIMAI_PREVIEW_PORTS="${SIMAI_PREVIEW_PORTS:-7700-7799}"
SIMAI_PREVIEW_INCLUDE=/etc/nginx/conf.d/simai-preview.conf

preview_state_file() { printf '%s/%s.env\n' "$SIMAI_PREVIEW_DIR" "$1"; }
preview_nginx_file() { printf '%s/%s.conf\n' "$SIMAI_PREVIEW_NGINX_DIR" "$1"; }

preview_state_get() {
  local file key="$2"
  file=$(preview_state_file "$1")
  [[ -f "$file" ]] || return 1
  sed -n "s/^${key}=\\([A-Za-z0-9.:-]*\\)$/\\1/p" "$file" | head -n1
}

preview_project() {
  local domain="$1" project
  project=$(site_project_for_domain "$domain" 2>/dev/null || true)
  [[ -n "$project" ]] || project=$(project_slug_from_domain "$domain")
  validate_project_slug "$project" || return 1
  printf '%s\n' "$project"
}

preview_ip() {
  local ip="${SIMAI_PREVIEW_IP:-}"
  [[ -n "$ip" ]] || ip=$(site_best_effort_primary_ip 2>/dev/null || true)
  printf '%s\n' "$ip"
}

# A free port of the range: not taken by another link, nothing listening.
preview_free_port() {
  local lo="${SIMAI_PREVIEW_PORTS%-*}" hi="${SIMAI_PREVIEW_PORTS#*-}" port used
  used=$(cat "$SIMAI_PREVIEW_DIR"/*.env 2>/dev/null | sed -n 's/^PORT=//p')
  for (( port = lo; port <= hi; port++ )); do
    grep -qx "$port" <<<"$used" && continue
    ss -Htln "sport = :${port}" 2>/dev/null | grep -q . && continue
    printf '%s\n' "$port"
    return 0
  done
  return 1
}

PREVIEW_REFUSAL=""
preview_refuse() { PREVIEW_REFUSAL="$1"; error "$2"; return 1; }

# Sets PV_PROJECT, PV_CONF (the site's nginx file).
preview_check() {
  local domain="$1" minutes="$2"
  PREVIEW_REFUSAL=""
  [[ "$minutes" =~ ^[0-9]+$ ]] && (( minutes >= 10 && minutes <= 1440 )) \
    || preview_refuse bad_minutes "--minutes must be 10-1440" || return 1
  validate_domain "$domain" allow || return 1
  [[ -f "/etc/nginx/sites-available/${domain}.conf" ]] || preview_refuse site_missing "Site ${domain} is not managed here" || return 1
  PV_CONF="/etc/nginx/sites-available/${domain}.conf"
  PV_PROJECT=$(preview_project "$domain") || return 1
  read_site_metadata "$domain" >/dev/null 2>&1 || true
  [[ "${SITE_META[profile]:-}" != alias ]] || preview_refuse alias "${domain} is an alias; open a link to its target site" || return 1
  [[ ! -f "/etc/simai-env/sites/${domain}/suspended" ]] || preview_refuse suspended "${domain} is suspended" || return 1
  [[ -n "$(preview_ip)" ]] || preview_refuse no_address "The server address is unknown; set SIMAI_PREVIEW_IP" || return 1
  command -v nginx >/dev/null 2>&1 || preview_refuse no_nginx "nginx is not installed" || return 1
  return 0
}

preview_plan_check() {
  local domain minutes
  domain=$(command_arg domain "$@"); minutes=$(command_arg minutes "$@")
  [[ -n "$domain" ]] || return 0
  if ! preview_check "$domain" "${minutes:-60}"; then
    [[ -z "$PREVIEW_REFUSAL" ]] || site_plan_data_write "{\"refusal\": \"${PREVIEW_REFUSAL}\"}"
    return 1
  fi
  local port open=false
  port=$(preview_state_get "$PV_PROJECT" PORT 2>/dev/null || true)
  [[ -n "$port" && -f "$(preview_nginx_file "$PV_PROJECT")" ]] && open=true
  [[ -n "$port" ]] || port=$(preview_free_port) || { site_plan_data_write '{"refusal": "no_port"}'; error "No free port in ${SIMAI_PREVIEW_PORTS}"; return 1; }
  site_plan_data_write "$(printf '{"preview": {"address": "http://%s:%s/", "minutes": %s, "renew": %s, "mode": "ip_port"}}' \
    "$(preview_ip)" "$port" "${minutes:-60}" "$open")"
}

preview_render() {
  local port="$1" key="$2" domain="$3" max_age="$4" stamp="$5" upstream
  if grep -qE '^\s*listen\s+(\[::\]:)?443' "$PV_CONF"; then
    upstream="proxy_pass https://127.0.0.1:443;
        proxy_ssl_server_name on;
        proxy_ssl_name ${domain};
        proxy_ssl_verify off;"
  else
    upstream="proxy_pass http://127.0.0.1:80;"
  fi
  cat <<EOF
# simai-preview: ${domain} until $(date -u -d "@$(( $(date +%s) + max_age ))" +%Y-%m-%dT%H:%M:%SZ)
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    access_log /var/log/nginx/simai-preview.access.log simai_preview;

    location = /.simai-preview/${key} {
        add_header Set-Cookie "simai_preview_${port}=${key}; Path=/; Max-Age=${max_age}; HttpOnly; SameSite=Lax" always;
        add_header Cache-Control "no-store" always;
        # Which configuration answers: the command waits for this one.
        add_header X-Simai-Preview "${stamp}" always;
        return 302 /;
    }

    location / {
        if (\$cookie_simai_preview_${port} != "${key}") {
            return 403;
        }
        ${upstream}
        proxy_http_version 1.1;
        proxy_set_header Host ${domain};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$http_connection;
        proxy_redirect https://${domain}/ /;
        proxy_redirect http://${domain}/ /;
        proxy_read_timeout 300s;
        client_max_body_size 1g;
    }
}
EOF
}

# The access log never holds the link key: the key path is logged masked and
# the cookie and Referer are not logged at all (1.65.1).
preview_include_text() {
  cat <<EOF
# simai-env temporary site links (site preview-link)
map \$uri \$simai_preview_uri {
    ~^/\.simai-preview/ "/.simai-preview/***";
    default \$uri;
}
log_format simai_preview '\$remote_addr [\$time_local] "\$request_method \$simai_preview_uri" \$status \$body_bytes_sent "\$http_user_agent" port=\$server_port';
include ${SIMAI_PREVIEW_NGINX_DIR}/*.conf;
EOF
}

preview_include_ensure() {
  local want
  want=$(preview_include_text)
  [[ -f "$SIMAI_PREVIEW_INCLUDE" && "$(cat "$SIMAI_PREVIEW_INCLUDE")" == "$want" ]] && return 0
  install -d -m 0755 /etc/nginx/conf.d
  printf '%s\n' "$want" >"$SIMAI_PREVIEW_INCLUDE"
  preview_log_scrub
}

# Mask link keys an older log format wrote (rotated .gz copies are left alone).
preview_log_scrub() {
  local log
  for log in /var/log/nginx/simai-preview.access.log /var/log/nginx/simai-preview.access.log.1 /var/log/nginx/error.log; do
    [[ -f "$log" ]] || continue
    grep -qE '/\.simai-preview/[0-9a-f]{32}' "$log" || continue
    sed -i -E 's#/\.simai-preview/[0-9a-f]{32}#/.simai-preview/***#g' "$log"
  done
  return 0
}

preview_reload() {
  if nginx -t >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
    os_svc_reload_or_restart nginx >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1
  else
    return 1
  fi
}

preview_ufw() {
  local action="$1" port="$2"
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if [[ "$action" == allow ]]; then
    ufw allow "${port}/tcp" comment "simai-preview" >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1
  else
    ufw delete allow "${port}/tcp" >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 || true
  fi
}

preview_teardown() {
  local project="$1" port conf
  conf=$(preview_nginx_file "$project")
  port=$(preview_state_get "$project" PORT 2>/dev/null || true)
  systemctl stop "simai-preview-${project}.timer" >/dev/null 2>&1 || true
  rm -f -- "$(preview_state_file "$project")"
  if [[ -f "$conf" ]]; then
    rm -f -- "$conf"
    preview_reload || true
  fi
  [[ "$port" =~ ^[0-9]+$ ]] && preview_ufw delete "$port"
  return 0
}

preview_wait_ready() {
  local port="$1" key="$2" stamp="$3" got
  command -v curl >/dev/null 2>&1 || return 0
  # nginx reloads in the background: the link is handed out once the new
  # configuration (its stamp) answers, not the one it replaces.
  for _ in $(seq 1 20); do
    got=$(curl -s -o /dev/null -D - --max-time 3 "http://127.0.0.1:${port}/.simai-preview/${key}" 2>/dev/null \
      | tr -d '\r' | sed -n 's/^[Xx]-[Ss]imai-[Pp]review: //p')
    [[ "$got" == "$stamp" ]] && return 0
    sleep 0.5
  done
  warn "The link did not answer yet; try it in a few seconds"
}

site_preview_link_handler() {
  parse_kv_args "$@"
  local domain minutes port key expires renew=no conf state
  domain=$(site_pick_existing_domain "${PARSED_ARGS[domain]:-}") || return $?
  [[ -z "$domain" ]] && return 0
  minutes="${PARSED_ARGS[minutes]:-60}"
  preview_check "$domain" "$minutes" || return 1
  conf=$(preview_nginx_file "$PV_PROJECT"); state=$(preview_state_file "$PV_PROJECT")
  port=$(preview_state_get "$PV_PROJECT" PORT 2>/dev/null || true)
  key=$(preview_state_get "$PV_PROJECT" KEY 2>/dev/null || true)
  if [[ -f "$conf" && "$port" =~ ^[0-9]+$ && "$key" =~ ^[0-9a-f]{32}$ ]]; then
    renew=yes
  else
    port=$(preview_free_port) || { error "No free port in ${SIMAI_PREVIEW_PORTS}"; return 1; }
    key=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fi
  expires=$(( $(date +%s) + minutes * 60 ))
  install -d -m 0700 -o root -g root "$SIMAI_PREVIEW_DIR" "$SIMAI_PREVIEW_NGINX_DIR"
  preview_include_ensure || return 1
  (umask 077; preview_render "$port" "$key" "$domain" "$(( minutes * 60 ))" "$expires" >"${conf}.tmp") || return 1
  mv -f "${conf}.tmp" "$conf"
  if ! preview_reload; then
    rm -f -- "$conf"
    preview_reload || true
    error "nginx refused the link configuration; nothing changed"
    return 1
  fi
  (umask 077; printf 'DOMAIN=%s\nPORT=%s\nKEY=%s\nEXPIRES=%s\nIP=%s\n' "$domain" "$port" "$key" "$expires" "$(preview_ip)" >"$state")
  [[ "$renew" == yes ]] || preview_ufw allow "$port"
  systemctl stop "simai-preview-${PV_PROJECT}.timer" >/dev/null 2>&1 || true
  systemd-run --unit="simai-preview-${PV_PROJECT}" --on-active="${minutes}m" --timer-property=AccuracySec=10s \
    --collect --quiet --setenv=SIMAI_ADMIN_MENU=0 \
    "${SIMAI_ENV_ROOT}/simai-admin.sh" site preview-link-close --domain "$domain" --confirm yes >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1 \
    || warn "The closing timer did not start; the status refresh closes the link after its deadline"
  preview_wait_ready "$port" "$key" "$expires"
  local ip address url expires_iso
  ip=$(preview_ip)
  [[ "$ip" == *:* ]] && ip="[${ip}]"
  address="http://${ip}:${port}/"
  url="${address}.simai-preview/${key}"
  expires_iso=$(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ)
  if [[ -n "${SIMAI_JOB_RESULT:-}" ]]; then
    # The link opens the site: the panel gets it once, the job log never.
    printf '{"preview_url":"%s","address":"%s","expires_at":"%s","mode":"ip_port","renewed":%s}\n' \
      "$url" "$address" "$expires_iso" "$([[ $renew == yes ]] && echo true || echo false)" >"$SIMAI_JOB_RESULT"
    url="(handed to the panel)"
  fi
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '{"schema":"simai-preview-link/1","domain":"%s","url":"%s","address":"%s","expires_at":"%s","mode":"ip_port","renewed":%s}\n' \
      "$domain" "$url" "$address" "$expires_iso" "$([[ $renew == yes ]] && echo true || echo false)"
    return 0
  fi
  ui_header "SIMAI ENV · Temporary link"
  ui_result_table \
    "Domain|${domain}" \
    "Link|${url}" \
    "Address|${address} (opens only after the link)" \
    "Closes at|${expires_iso}" \
    "Renewed|${renew}"
  ui_next_steps
  ui_kv "Close now" "simai-admin.sh site preview-link-close --domain ${domain} --confirm yes"
}

site_preview_link_close_handler() {
  parse_kv_args "$@"
  local domain project was=false
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" allow || return 1
  project=$(preview_project "$domain") || return 1
  [[ -f "$(preview_state_file "$project")" || -f "$(preview_nginx_file "$project")" ]] && was=true
  preview_teardown "$project"
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '{"schema":"simai-preview-link/1","domain":"%s","closed":%s}\n' "$domain" "$was"
  else
    ui_result_table "Domain|${domain}" "Temporary link|$([[ $was == true ]] && echo closed || echo 'was not open')"
  fi
}

# {address, expires_at} of an open link, or null (site describe, status).
preview_link_json() {
  local project expires port ip
  project=$(preview_project "$1" 2>/dev/null) || { echo null; return 0; }
  expires=$(preview_state_get "$project" EXPIRES 2>/dev/null || true)
  port=$(preview_state_get "$project" PORT 2>/dev/null || true)
  if [[ "$expires" =~ ^[0-9]+$ && "$port" =~ ^[0-9]+$ ]] && (( expires > $(date +%s) )) && [[ -f "$(preview_nginx_file "$project")" ]]; then
    ip=$(preview_ip); [[ "$ip" == *:* ]] && ip="[${ip}]"
    printf '{"url":"http://%s:%s/","expires_at":"%s","mode":"ip_port"}\n' "$ip" "$port" "$(date -u -d "@${expires}" +%Y-%m-%dT%H:%M:%SZ)"
  else
    echo null
  fi
}

site_preview_link_status_handler() {
  parse_kv_args "$@"
  local domain link
  domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  link=$(preview_link_json "$domain")
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '{"schema":"simai-preview-link/1","domain":"%s","preview_link":%s}\n' "$domain" "$link"
  else
    ui_result_table "Domain|${domain}" "Temporary link|$([[ "$link" == null ]] && echo closed || python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["url"] + " until " + d["expires_at"])' "$link")"
  fi
}

# Status refresh: links past their deadline (their timer lost to a reboot).
preview_expire_all() {
  local file project expires now
  now=$(date +%s)
  for file in "$SIMAI_PREVIEW_DIR"/*.env; do
    [[ -f "$file" ]] || continue
    project=$(basename "$file" .env)
    validate_project_slug "$project" >/dev/null 2>&1 || continue
    expires=$(preview_state_get "$project" EXPIRES 2>/dev/null || true)
    if [[ ! "$expires" =~ ^[0-9]+$ ]] || (( expires <= now )); then
      preview_teardown "$project"
    fi
  done
  return 0
}

register_cmd "site" "preview-link" "Open a temporary link to a site before its domain points here (renews an open one)" "site_preview_link_handler" "domain" "minutes=" "tier:advanced"
register_cmd "site" "preview-link-close" "Close a site's temporary link now" "site_preview_link_close_handler" "domain" "" "tier:advanced"
register_cmd "site" "preview-link-status" "Show a site's temporary link (address and deadline, never the key)" "site_preview_link_status_handler" "domain" "" "tier:advanced effects:read"
