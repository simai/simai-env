#!/usr/bin/env bash
# site cache-clear: the caches of one site, and nothing of another site.
#   OPcache   only this site's scripts, invalidated from inside its own pool
#             (lib/site_opcache.py); OPcache memory is shared by every pool
#             of a PHP version, so there is no opcache_reset() and no reload.
#   nginx     the fastcgi/proxy cache zone the site's own config uses, when
#             no other site uses that zone.
#   framework laravel artisan optimize:clear (current release), wordpress
#             wp cache flush + transients (WP-CLI), bitrix bitrix/cache,
#             managed_cache and stack_cache; all as the site user.

SITE_CACHE_NGINX_PREFIXES=(/var/cache/ /var/lib/nginx/ /var/tmp/ /tmp/ /run/ /dev/shm/)
SITE_CACHE_BITRIX_DIRS=(cache managed_cache stack_cache)

# Sets SCC_* for a domain; SCC_REFUSAL names a refusal (profile_unsupported).
site_cache_site() {
  local domain="$1"
  SCC_REFUSAL="" SCC_REFUSAL_TEXT=""
  [[ -n "$domain" ]] || { require_args "domain"; return 1; }
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || { error "Failed to read site metadata for ${domain}"; return 1; }
  SCC_DOMAIN="$domain"
  SCC_PROFILE="${SITE_META[profile]:-generic}"
  case "$SCC_PROFILE" in
    alias|redirect|proxy)
      SCC_REFUSAL=profile_unsupported
      SCC_REFUSAL_TEXT="A ${SCC_PROFILE} site has no caches of its own; clear the caches of the site that serves it"
      return 0 ;;
  esac
  SCC_ROOT="${SITE_META[root]:-}"
  validate_path "$SCC_ROOT" || return 1
  [[ -d "$SCC_ROOT" ]] || { error "Site directory ${SCC_ROOT} is missing"; return 1; }
  SCC_PROJECT="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  SCC_USER=$(site_effective_user "$SCC_PROJECT")
  [[ -n "$SCC_USER" && "$SCC_USER" != root ]] || { error "Site ${domain} has no user to run as"; return 1; }
  local public_dir="public"
  [[ -z "${SITE_META[public_dir]+x}" ]] || public_dir="${SITE_META[public_dir]}"
  SCC_DOC_ROOT=$(site_compute_doc_root "$SCC_ROOT" "$public_dir") || return 1
  SCC_PHP="${SITE_META[php]:-}"
  [[ "$SCC_PHP" != none ]] || SCC_PHP=""
  SCC_SOCKET_PROJECT="${SITE_META[php_socket_project]:-$SCC_PROJECT}"
  validate_project_slug "$SCC_SOCKET_PROJECT" >/dev/null 2>&1 || SCC_SOCKET_PROJECT="$SCC_PROJECT"
  return 0
}

# The socket of the site's pool: its pool file's listen line, or the default.
site_cache_pool_socket() {
  local pool="/etc/php/${SCC_PHP}/fpm/pool.d/${SCC_SOCKET_PROJECT}.conf" listen=""
  [[ -f "$pool" ]] && listen=$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*//p' "$pool" | head -n1 | tr -d '[:space:]')
  [[ "$listen" == /* ]] || listen="/run/php/php${SCC_PHP}-fpm-${SCC_SOCKET_PROJECT}.sock"
  printf '%s\n' "$listen"
}

# "zone" lines: fastcgi_cache/proxy_cache zones of the site's own config files.
site_cache_nginx_zones() {
  local files=("/etc/nginx/sites-available/${SCC_DOMAIN}.conf")
  [[ -f "/etc/nginx/simai-custom/${SCC_PROJECT}.conf" ]] && files+=("/etc/nginx/simai-custom/${SCC_PROJECT}.conf")
  cat "${files[@]}" 2>/dev/null \
    | sed -n -E 's/^[[:space:]]*(fastcgi|proxy)_cache[[:space:]]+([A-Za-z0-9_-]+)[[:space:]]*;.*/\2/p' \
    | grep -v '^off$' | sort -u || true
}

site_cache_nginx_own_uses() {
  local zone="$1" files=("/etc/nginx/sites-available/${SCC_DOMAIN}.conf")
  [[ -f "/etc/nginx/simai-custom/${SCC_PROJECT}.conf" ]] && files+=("/etc/nginx/simai-custom/${SCC_PROJECT}.conf")
  cat "${files[@]}" 2>/dev/null | grep -cE "^[[:space:]]*(fastcgi|proxy)_cache[[:space:]]+${zone}[[:space:]]*;" || true
}

# Sets SCC_NGX_STATE planned|skipped, SCC_NGX_REASON and SCC_NGX_PATHS.
site_cache_nginx_survey() {
  SCC_NGX_STATE=skipped SCC_NGX_REASON=none SCC_NGX_PATHS=()
  local zones zone dump path real uses own prefix ok
  zones=$(site_cache_nginx_zones)
  [[ -n "$zones" ]] || return 0
  dump=$(nginx -T 2>/dev/null || true)
  while IFS= read -r zone; do
    [[ -n "$zone" ]] || continue
    path=$(printf '%s\n' "$dump" | sed -n -E "s/^[[:space:]]*(fastcgi|proxy)_cache_path[[:space:]]+([^[:space:];]+)[[:space:]].*keys_zone=${zone}:.*/\2/p" | head -n1)
    [[ -n "$path" ]] || { SCC_NGX_REASON=zone_path_unknown; continue; }
    uses=$(printf '%s\n' "$dump" | grep -cE "^[[:space:]]*(fastcgi|proxy)_cache[[:space:]]+${zone}[[:space:]]*;" || true)
    own=$(site_cache_nginx_own_uses "$zone")
    if (( ${uses:-0} > ${own:-0} )); then SCC_NGX_REASON=zone_shared; continue; fi
    real=$(readlink -f -- "$path" 2>/dev/null || true)
    ok=no
    for prefix in "${SITE_CACHE_NGINX_PREFIXES[@]}"; do
      [[ -n "$real" && "$real" == "$prefix"?* ]] && ok=yes
    done
    [[ "$ok" == yes ]] || { SCC_NGX_REASON=path_not_allowed; continue; }
    SCC_NGX_PATHS+=("$real")
  done <<<"$zones"
  if (( ${#SCC_NGX_PATHS[@]} > 0 )); then SCC_NGX_STATE=planned SCC_NGX_REASON=""; fi
  return 0
}

# Sets SCC_OPC_STATE, SCC_OPC_REASON, SCC_OPC_TARGET.
site_cache_opcache_survey() {
  SCC_OPC_STATE=skipped SCC_OPC_REASON="" SCC_OPC_TARGET=""
  [[ -n "$SCC_PHP" ]] || { SCC_OPC_REASON=no_php; return 0; }
  SCC_OPC_TARGET=$(site_cache_pool_socket)
  [[ -S "$SCC_OPC_TARGET" || -e "$SCC_OPC_TARGET" ]] || { SCC_OPC_REASON=pool_socket_missing; return 0; }
  SCC_OPC_STATE=planned
}

site_cache_laravel_dir() {
  if [[ -d "${SCC_ROOT}/current" ]]; then printf '%s\n' "${SCC_ROOT}/current"; else printf '%s\n' "$SCC_ROOT"; fi
}

site_cache_wp_ready() {
  [[ -d "${SCC_DOC_ROOT}/wp-includes" && -f "${SCC_DOC_ROOT}/wp-config.php" ]] \
    && ! grep -q "SIMAI placeholder" "${SCC_DOC_ROOT}/wp-config.php" 2>/dev/null
}

# Sets SCC_FW_STATE, SCC_FW_REASON, SCC_FW_TARGET.
site_cache_framework_survey() {
  SCC_FW_STATE=skipped SCC_FW_REASON="" SCC_FW_TARGET=""
  case "$SCC_PROFILE" in
    laravel)
      local app
      app=$(site_cache_laravel_dir)
      SCC_FW_TARGET="artisan optimize:clear in ${app}"
      [[ -n "$SCC_PHP" ]] || { SCC_FW_REASON=no_php; return 0; }
      [[ -f "${app}/artisan" ]] || { SCC_FW_REASON=artisan_missing; return 0; }
      SCC_FW_STATE=planned ;;
    wordpress)
      SCC_FW_TARGET="wp cache flush, wp transient delete --all in ${SCC_DOC_ROOT}"
      [[ -n "$SCC_PHP" ]] || { SCC_FW_REASON=no_php; return 0; }
      wordpress_wp_cli_bin >/dev/null 2>&1 || { SCC_FW_REASON=wp_cli_missing; return 0; }
      site_cache_wp_ready || { SCC_FW_REASON=wordpress_not_installed; return 0; }
      SCC_FW_STATE=planned ;;
    bitrix)
      local d dirs=()
      for d in "${SITE_CACHE_BITRIX_DIRS[@]}"; do dirs+=("bitrix/${d}"); done
      SCC_FW_TARGET="contents of ${dirs[*]} in ${SCC_DOC_ROOT}"
      [[ -d "${SCC_DOC_ROOT}/bitrix" ]] || { SCC_FW_REASON=bitrix_missing; return 0; }
      SCC_FW_STATE=planned ;;
    *)
      SCC_FW_REASON=none ;;
  esac
  return 0
}

site_cache_survey() {
  site_cache_site "$1" || return 1
  [[ -z "$SCC_REFUSAL" ]] || return 0
  site_cache_opcache_survey
  site_cache_nginx_survey
  site_cache_framework_survey
}

# name<TAB>state<TAB>target<TAB>detail<TAB>reason lines -> JSON (stdout).
site_cache_json() {
  local applied="$1" indent="${2:-2}"
  python3 -I -c '
import json, sys
domain, profile, applied, indent = sys.argv[1:5]
items = []
for line in sys.stdin.read().splitlines():
    if not line:
        continue
    name, state, target, detail, reason = (line.split("\t") + [""] * 5)[:5]
    items.append({"name": name, "state": state, "target": target or None,
                  "detail": detail or None, "reason": reason or None})
out = {"schema": "simai-site-cache/1", "domain": domain, "profile": profile,
       "applied": applied == "yes", "items": items}
print(json.dumps(out, indent=int(indent) or None))' "$SCC_DOMAIN" "$SCC_PROFILE" "$applied" "$indent"
}

site_cache_plan_rows() {
  local ngx_target="" opc_target=""
  (( ${#SCC_NGX_PATHS[@]} == 0 )) || ngx_target="${SCC_NGX_PATHS[*]}"
  [[ -z "$SCC_OPC_TARGET" ]] || opc_target="this site's scripts in the OPcache of pool ${SCC_SOCKET_PROJECT} (PHP ${SCC_PHP})"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    opcache "$SCC_OPC_STATE" "$opc_target" "" "$SCC_OPC_REASON" \
    nginx_cache "$SCC_NGX_STATE" "$ngx_target" "" "$SCC_NGX_REASON" \
    framework "$SCC_FW_STATE" "$SCC_FW_TARGET" "" "$SCC_FW_REASON"
}

site_cache_table() {
  local rows=() name state target detail reason
  # A tab is IFS white space (empty fields would merge); split on \x1f.
  while IFS=$'\x1f' read -r name state target detail reason; do
    [[ -n "$name" ]] || continue
    case "$state" in
      planned) rows+=("${name}|will clear: ${target}") ;;
      cleared) rows+=("${name}|cleared${detail:+ (${detail})}") ;;
      skipped) rows+=("${name}|skipped: ${reason}${target:+ (${target})}") ;;
      *) rows+=("${name}|${state}: ${reason}${detail:+ (${detail})}") ;;
    esac
  done < <(tr '\t' '\037')
  print_kv_table "Domain|${SCC_DOMAIN}" "Profile|${SCC_PROFILE}" "${rows[@]}"
}

site_cache_plan_check() {
  local domain
  domain=$(command_arg domain "$@")
  site_cache_survey "$domain" || return 1
  if [[ -n "$SCC_REFUSAL" ]]; then
    error "$SCC_REFUSAL_TEXT"
    site_plan_data_write "$(python3 -I -c 'import json,sys; print(json.dumps({"refusal": sys.argv[1], "detail": sys.argv[2]}))' \
      "$SCC_REFUSAL" "$SCC_REFUSAL_TEXT")"
    return 1
  fi
  site_plan_data_write "$(site_cache_plan_rows | site_cache_json no 0)"
  return 0
}

# --- clearing -------------------------------------------------------------

site_cache_run_opcache() {
  local out state scripts found reason
  out=$(python3 -I "${SIMAI_ENV_ROOT}/lib/site_opcache.py" "$SCC_OPC_TARGET" "$(readlink -f -- "$SCC_ROOT")" 2>>"${LOG_FILE:-/dev/null}") \
    || out='{"state":"failed","reason":"helper_failed"}'
  read -r state scripts found reason < <(python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
print(d.get("state") or "failed", d.get("scripts") or 0, d.get("found") or 0, d.get("reason") or "-")' "$out" 2>/dev/null \
    || echo "failed 0 0 helper_failed")
  [[ "$reason" != "-" ]] || reason=""
  if [[ "$state" == cleared ]]; then
    printf 'opcache\tcleared\t%s\t%s\t\n' "pool ${SCC_SOCKET_PROJECT} (PHP ${SCC_PHP})" "${scripts} of ${found} cached scripts invalidated"
  else
    printf 'opcache\tskipped\t%s\t\t%s\n' "pool ${SCC_SOCKET_PROJECT} (PHP ${SCC_PHP})" "$reason"
  fi
}

site_cache_run_nginx() {
  local path count total=0 failed=no
  for path in "${SCC_NGX_PATHS[@]}"; do
    [[ -d "$path" && ! -L "$path" ]] || continue
    count=$(find "$path" -xdev -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
    find "$path" -xdev -mindepth 1 -delete 2>>"${LOG_FILE:-/dev/null}" || failed=yes
    total=$((total + count))
  done
  if [[ "$failed" == yes ]]; then
    printf 'nginx_cache\tfailed\t%s\t%s\t%s\n' "${SCC_NGX_PATHS[*]}" "some cache files could not be removed" delete_failed
    return 1
  fi
  printf 'nginx_cache\tcleared\t%s\t%s\t\n' "${SCC_NGX_PATHS[*]}" "${total} cached responses removed"
}

site_cache_as_user() {
  (cd / && sudo -u "$SCC_USER" -H "$@")
}

site_cache_run_framework() {
  local php_bin rc=0
  case "$SCC_PROFILE" in
    laravel)
      local app
      app=$(site_cache_laravel_dir)
      php_bin=$(resolve_php_bin "$SCC_PHP")
      (cd "$app" && sudo -u "$SCC_USER" -H "$php_bin" artisan optimize:clear --no-interaction) >>"${LOG_FILE:-/dev/null}" 2>&1 || rc=$?
      if (( rc != 0 )); then
        printf 'framework\tfailed\t%s\t%s\t%s\n' "$SCC_FW_TARGET" "artisan exited with ${rc}" command_failed
        return 1
      fi
      printf 'framework\tcleared\t%s\t%s\t\n' "$SCC_FW_TARGET" "laravel: config, routes, views, events, cache" ;;
    wordpress)
      local what=()
      if SIMAI_USER="$SCC_USER" wordpress_wp_cli_run "$SCC_DOC_ROOT" "$SCC_PHP" cache flush >>"${LOG_FILE:-/dev/null}" 2>&1; then
        what+=("object cache")
      else
        printf 'framework\tfailed\t%s\t%s\t%s\n' "$SCC_FW_TARGET" "wp cache flush failed" command_failed
        return 1
      fi
      if SIMAI_USER="$SCC_USER" wordpress_wp_cli_run "$SCC_DOC_ROOT" "$SCC_PHP" transient delete --all >>"${LOG_FILE:-/dev/null}" 2>&1; then
        what+=("transients")
      else
        printf 'framework\tfailed\t%s\t%s\t%s\n' "$SCC_FW_TARGET" "object cache flushed; wp transient delete failed" command_failed
        return 1
      fi
      printf 'framework\tcleared\t%s\t%s\t\n' "$SCC_FW_TARGET" "wordpress: ${what[*]}" ;;
    bitrix)
      local d dir count total=0 failed=no done_dirs=()
      for d in "${SITE_CACHE_BITRIX_DIRS[@]}"; do
        dir="${SCC_DOC_ROOT}/bitrix/${d}"
        [[ -d "$dir" && ! -L "$dir" ]] || continue
        count=$(site_cache_as_user find "$dir" -xdev -mindepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
        site_cache_as_user find "$dir" -xdev -mindepth 1 -delete 2>>"${LOG_FILE:-/dev/null}" || failed=yes
        total=$((total + count))
        done_dirs+=("$d")
      done
      if [[ "$failed" == yes ]]; then
        printf 'framework\tfailed\t%s\t%s\t%s\n' "$SCC_FW_TARGET" "some files could not be removed by ${SCC_USER}" delete_failed
        return 1
      fi
      printf 'framework\tcleared\t%s\t%s\t\n' "$SCC_FW_TARGET" "bitrix: ${total} files removed from ${done_dirs[*]:-no cache directory}" ;;
  esac
}

site_cache_job_result() {
  [[ -n "${SIMAI_JOB_RESULT:-}" ]] || return 0
  python3 -I -c '
import os, sys
path, data = sys.argv[1:3]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as out:
    out.write(data[:4000])' "$SIMAI_JOB_RESULT" "$1" || true
}

site_cache_clear_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  site_cache_survey "$domain" || return 1
  if [[ -n "$SCC_REFUSAL" ]]; then
    error "$SCC_REFUSAL_TEXT"
    return 1
  fi
  if [[ "${confirm,,}" != yes && "${SIMAI_ADMIN_MENU:-0}" != 1 ]]; then
    ui_header "SIMAI ENV · Site cache clear (plan)"
    site_cache_plan_rows | site_cache_table
    echo "Nothing was changed. Rerun with --confirm yes to clear."
    return 0
  fi
  local result="" row rc=0
  if [[ "$SCC_OPC_STATE" == planned ]]; then
    row=$(site_cache_run_opcache) || rc=1
  else
    row=$(site_cache_plan_rows | sed -n '1p')
  fi
  result+="${row}"$'\n'
  if [[ "$SCC_NGX_STATE" == planned ]]; then
    row=$(site_cache_run_nginx) || rc=1
  else
    row=$(site_cache_plan_rows | sed -n '2p')
  fi
  result+="${row}"$'\n'
  if [[ "$SCC_FW_STATE" == planned ]]; then
    row=$(site_cache_run_framework) || rc=1
  else
    row=$(site_cache_plan_rows | sed -n '3p')
  fi
  result+="${row}"$'\n'
  site_cache_job_result "$(printf '%s' "$result" | site_cache_json yes 0)"
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '%s' "$result" | site_cache_json yes
  else
    ui_header "SIMAI ENV · Site cache clear"
    printf '%s' "$result" | site_cache_table
  fi
  (( rc == 0 )) || { error "Some caches of ${domain} were not cleared"; return 1; }
  return 0
}

register_cmd "site" "cache-clear" "Clear one site's caches: its OPcache scripts, its nginx cache, the framework cache of its profile" "site_cache_clear_handler" "domain" "confirm=" "tier:advanced plan:handler"
