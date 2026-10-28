#!/usr/bin/env bash

# Exact-path redirects of a site (/ -> /ru/, /old -> https://elsewhere). The
# list is the source of truth; nginx gets it inside a managed block.

site_redirect_reapply() {
  local domain="$1" cfg="/etc/nginx/sites-available/${1}.conf" backup
  [[ -f "$cfg" ]] || { error "nginx config not found for ${domain}"; return 1; }
  backup=$(mktemp) && cp -p "$cfg" "$backup"
  if ! site_redirects_apply "$domain" "$cfg" || ! nginx -t >>"$LOG_FILE" 2>&1; then
    cp -p "$backup" "$cfg"; rm -f "$backup"
    error "nginx rejected the redirects; configuration restored"
    return 1
  fi
  rm -f "$backup"
  os_svc_reload nginx >/dev/null 2>&1 || { error "nginx reload failed"; return 1; }
}

site_redirect_list_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" file code from to rows=()
  require_args "domain" || return 1
  require_site_exists "$domain" || return 1
  file=$(site_redirects_file "$domain")
  if [[ -s "$file" ]]; then
    while read -r code from to; do
      [[ -n "$code" ]] && rows+=("${from}|${code} -> ${to}")
    done <"$file"
  fi
  [[ -n "$(site_redirect_env_get "$domain" TARGET)" ]] && {
    local suffix='$request_uri'
    [[ "$(site_redirect_env_get "$domain" PATH)" == drop ]] && suffix="/"
    rows+=("whole domain|$(site_redirect_env_get "$domain" CODE) -> $(site_redirect_env_get "$domain" TARGET)${suffix}")
  }
  [[ ${#rows[@]} -gt 0 ]] || rows=("Redirects|none")
  ui_result_table "${rows[@]}"
}

site_redirect_add_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" from="${PARSED_ARGS[from]:-}" to="${PARSED_ARGS[to]:-}" code="${PARSED_ARGS[code]:-302}"
  require_args "domain from to" || return 1
  require_site_exists "$domain" || return 1
  site_redirect_from_valid "$from" || { error "--from must be a URL path such as / or /old-page"; return 1; }
  site_redirect_target_valid "$to" || { error "--to must be a path (/ru/) or an http(s) URL without spaces, quotes, ';' or '\$'"; return 1; }
  [[ "$code" =~ ^30[1278]$ ]] || { error "--code must be 301, 302, 307 or 308"; return 1; }
  [[ "$from" != "$to" ]] || { error "--from and --to are the same"; return 1; }
  local file tmp
  file=$(site_redirects_file "$domain")
  install -d -m 0750 "$(dirname "$file")"
  tmp=$(mktemp) || return 1
  { awk -v f="$from" '$2 != f' "$file" 2>/dev/null || true; printf '%s %s %s\n' "$code" "$from" "$to"; } >"$tmp"
  local previous=""
  [[ -f "$file" ]] && previous=$(cat "$file")
  mv -f "$tmp" "$file" && chmod 0640 "$file"
  if ! site_redirect_reapply "$domain"; then
    if [[ -n "$previous" ]]; then printf '%s\n' "$previous" >"$file"; else rm -f -- "$file"; fi
    return 1
  fi
  ui_result_table "Domain|${domain}" "Redirect|${from} -> ${to} (${code})"
}

site_redirect_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" from="${PARSED_ARGS[from]:-}" file tmp
  require_args "domain from" || return 1
  require_site_exists "$domain" || return 1
  file=$(site_redirects_file "$domain")
  grep -q " ${from} " "$file" 2>/dev/null || { info "No redirect from ${from}"; return 0; }
  tmp=$(mktemp) || return 1
  awk -v f="$from" '$2 != f' "$file" >"$tmp" || true
  mv -f "$tmp" "$file" && chmod 0640 "$file"
  site_redirect_reapply "$domain" || return 1
  ui_result_table "Domain|${domain}" "Removed|${from}"
}

site_paths_allow_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" allow="${PARSED_ARGS[allow]:-}" clear="${PARSED_ARGS[clear]:-no}" file previous="" item
  require_args "domain" || return 1
  require_site_exists "$domain" || return 1
  file=$(site_paths_allow_file "$domain")
  [[ -f "$file" ]] && previous=$(cat "$file")
  install -d -m 0750 "$(dirname "$file")"
  if [[ "${clear,,}" == yes ]]; then
    rm -f -- "$file"
  else
    [[ -n "$allow" ]] || { error "--allow needs a comma-separated list such as /runner.html,/assets/ (or --clear yes)"; return 1; }
    local -a items=()
    IFS=',' read -r -a items <<<"$allow"
    : >"${file}.tmp"
    for item in "${items[@]}"; do
      item="${item// /}"
      [[ -z "$item" ]] && continue
      [[ "$item" =~ ^/[A-Za-z0-9._~/-]{1,200}$ ]] || { rm -f "${file}.tmp"; error "Invalid path ${item}"; return 1; }
      printf '%s\n' "$item" >>"${file}.tmp"
    done
    mv -f "${file}.tmp" "$file" && chmod 0640 "$file"
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf" backup
  backup=$(mktemp) && cp -p "$cfg" "$backup"
  if ! site_paths_allow_apply "$domain" "$cfg" || ! nginx -t >>"$LOG_FILE" 2>&1; then
    cp -p "$backup" "$cfg"; rm -f "$backup"
    if [[ -n "$previous" ]]; then printf '%s\n' "$previous" >"$file"; else rm -f -- "$file"; fi
    error "nginx rejected the path allowlist; configuration restored"
    return 1
  fi
  rm -f "$backup"
  os_svc_reload nginx >/dev/null 2>&1 || { error "nginx reload failed"; return 1; }
  ui_result_table "Domain|${domain}" "Allowed paths|$([[ -s $file ]] && paste -sd ' ' "$file" || echo "all (no limit)")"
}

register_cmd "site" "paths-allow" "Serve only the listed paths of a site (exact files or prefixes ending in /); others answer 404" "site_paths_allow_handler" "domain" "allow= clear=" "tier:advanced"
register_cmd "site" "redirect-list" "Show path redirects of a site" "site_redirect_list_handler" "domain" "" "effects:read"
register_cmd "site" "redirect-add" "Redirect one exact path (for example / -> /ru/) with 301/302/307/308" "site_redirect_add_handler" "domain from to" "code=" "tier:advanced"
register_cmd "site" "redirect-remove" "Remove a path redirect" "site_redirect_remove_handler" "domain from" "" "tier:advanced"
