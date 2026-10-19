#!/usr/bin/env bash

normalize_cleanup() {
  set +e  # restore every file even if one step fails
  if [[ "$NORMALIZE_SUCCESS" != yes ]]; then
    cp -p "$NORMALIZE_BACKUP" "$NORMALIZE_POOL"
    if [[ "$NORMALIZE_PERF_EXISTED" == yes ]]; then
      cp -p "$NORMALIZE_PERF_BACKUP" "$NORMALIZE_PERF_FILE"
    else
      rm -f "$NORMALIZE_PERF_FILE"
    fi
    cp -p "$NORMALIZE_NGINX_BACKUP" "$NORMALIZE_NGINX"
    os_svc_reload "php${NORMALIZE_PHP}-fpm" >/dev/null 2>&1 || warn 'Restored pool could not be reloaded'
    os_svc_reload nginx >/dev/null 2>&1 || warn 'Restored nginx could not be reloaded'
  fi
  rm -f "$NORMALIZE_TMP" "$NORMALIZE_BACKUP" "$NORMALIZE_PERF_BACKUP" "$NORMALIZE_NGINX_BACKUP"
}

site_config_normalize_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args domain || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local php="${SITE_META[php]:-none}" profile="${SITE_META[profile]:-}" project
  project="${SITE_META[php_socket_project]:-${SITE_META[project]}}"
  [[ "$php" != none ]] || { info 'Site has no PHP pool'; return 0; }
  local pool="/etc/php/${php}/fpm/pool.d/${project}.conf" tmp backup perf_backup perf_file perf_existed=no
  [[ -f "$pool" ]] || { error 'PHP pool not found'; return 1; }
  tmp=$(mktemp); backup=$(mktemp)
  cp -p "$pool" "$backup"
  perf_file="$(site_sites_config_dir)/${domain}/perf.env"
  perf_backup=$(mktemp)
  if [[ -f "$perf_file" ]]; then cp -p "$perf_file" "$perf_backup"; perf_existed=yes; fi
  local nginx_cfg="/etc/nginx/sites-available/${domain}.conf" nginx_backup
  nginx_backup=$(mktemp)
  cp -p "$nginx_cfg" "$nginx_backup"
  # Capture all affected state before the first write. The trap also handles
  # an unanticipated failing command under strict execution.
  NORMALIZE_SUCCESS=no NORMALIZE_POOL="$pool" NORMALIZE_BACKUP="$backup" NORMALIZE_TMP="$tmp"
  NORMALIZE_PERF_FILE="$perf_file" NORMALIZE_PERF_BACKUP="$perf_backup" NORMALIZE_PERF_EXISTED="$perf_existed"
  NORMALIZE_NGINX="$nginx_cfg" NORMALIZE_NGINX_BACKUP="$nginx_backup" NORMALIZE_PHP="$php"
  trap normalize_cleanup EXIT
  if [[ "$profile" == bitrix ]]; then
    # Stored governance must agree with the effective profile budget too.
    write_site_perf_settings_merged "$domain" 'request_terminate_timeout|300s'
    apply_site_perf_settings_to_pool "$domain" "$php" "$project" no || return 1
    python3 "${SIMAI_ENV_ROOT}/lib/fpm_normalize.py" --nginx-bitrix <"$nginx_cfg" >"$tmp"
    cat "$tmp" >"$nginx_cfg"
  fi
  python3 "${SIMAI_ENV_ROOT}/lib/fpm_normalize.py" <"$pool" >"$tmp"
  cat "$tmp" >"$pool"
  if ! "php-fpm${php}" -t >>"$LOG_FILE" 2>&1; then
    error 'Pool validation failed; configuration will be restored'; return 1
  fi
  nginx -t >>"$LOG_FILE" 2>&1 || { error 'nginx validation failed; configuration will be restored'; return 1; }
  os_svc_reload "php${php}-fpm"
  os_svc_reload nginx
  NORMALIZE_SUCCESS=yes
  rm -f "$tmp" "$backup" "$perf_backup" "$nginx_backup"
  trap - EXIT
  info "Normalized managed pool for ${domain}; verify with site doctor"
}

register_cmd site config-normalize 'Normalize PHP/nginx directives and align the Bitrix request budget' site_config_normalize_handler domain '' 'tier:advanced'
