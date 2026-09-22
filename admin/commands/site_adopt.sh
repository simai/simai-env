#!/usr/bin/env bash

# site adopt: attach an existing application directory (release checkout or
# unpacked archive) as a managed site without scaffolding. Requirements come
# from composer.json and .simai/app.json. Running it again on an adopted site
# reconciles requirements, env defaults, build and workers.

adopt_php_satisfies() {
  local ver="$1" min="$2"
  [[ -n "$min" ]] || return 0
  command -v "php${ver}" >/dev/null 2>&1 || return 1
  "php${ver}" -r "exit(version_compare(PHP_VERSION, '${min}', '>=') ? 0 : 1);"
}

adopt_run_as() {
  local user="$1" root="$2"
  shift 2
  sudo -u "$user" -H bash -c 'cd "$1" && shift && exec "$@"' _ "$root" "$@"
}

adopt_env_is_empty() {
  local file="$1" key="$2"
  [[ -z "$(laravel_env_get "$file" "$key" 2>/dev/null || true)" ]]
}

site_adopt_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" path="${PARSED_ARGS[path]:-}" profile="${PARSED_ARGS[profile]:-}"
  local php="${PARSED_ARGS[php]:-}" owner="${PARSED_ARGS[owner]:-}" engine="${PARSED_ARGS[db-engine]:-}"
  local create_db="${PARSED_ARGS[create-db]:-}" migrate="${PARSED_ARGS[migrate]:-}" build="${PARSED_ARGS[build]:-auto}"
  local pgdg="${PARSED_ARGS[pgdg]:-no}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain" || return 1
  validate_domain "$domain" || return 1

  local reconcile=no
  if [[ -f "/etc/nginx/sites-available/${domain}.conf" ]]; then
    reconcile=yes
    read_site_metadata "$domain" || return 1
    path="${SITE_META[root]}"
    profile="${SITE_META[profile]}"
    php="${SITE_META[php]}"
    PARSED_ARGS[path]="$path"
  fi
  require_args "path" || return 1
  validate_path "$path" || return 1
  [[ -d "$path" && ! -L "$path" ]] || { error "Application directory not found: ${path}"; return 1; }
  [[ -n "$(ls -A "$path" 2>/dev/null)" ]] || { error "${path} is empty; adopt attaches an existing application (use site add for a new one)"; return 1; }
  site_path_is_allowed_root "$path" || { error "${path} is outside ${WWW_ROOT}, /var/www and /srv"; return 1; }

  app_manifest_load "$path" || return 1
  [[ -n "$profile" ]] || profile="${APP_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    [[ -f "${path}/artisan" ]] && profile=laravel || profile=generic
  fi
  load_profile "$profile" || return 1
  engine="${engine:-${APP_DB_ENGINE:-}}"
  [[ -n "$migrate" ]] || migrate="${APP_MIGRATE:-no}"
  if [[ -z "$create_db" ]]; then
    [[ "${PROFILE_REQUIRES_DB:-no}" != no ]] && create_db=yes || create_db=no
  fi
  if [[ "$create_db" == yes && "$reconcile" == no ]]; then
    engine=$(site_resolve_db_engine "$engine") || return 1
  elif [[ "$reconcile" == yes ]]; then
    engine=$(site_db_engine "$domain")
  fi
  if [[ -z "$php" ]]; then
    local series
    series=$(app_php_series "$APP_PHP_MIN") || series=$(php_default_version)
    php="$series"
  fi
  validate_php_version_syntax "$php" || return 1

  local -a missing_pkgs=() ext_pkgs=()
  mapfile -t missing_pkgs < <(app_missing_packages "${APP_PACKAGES[@]}")
  local php_ok=yes
  adopt_php_satisfies "$php" "$APP_PHP_MIN" || php_ok=no
  if [[ "$php_ok" == yes ]]; then
    mapfile -t ext_pkgs < <(app_php_ext_packages "$php" "${APP_PHP_EXTS[@]}")
  fi
  [[ "$build" == auto ]] && { [[ -f "${path}/composer.json" && ! -f "${path}/vendor/autoload.php" ]] && build=yes || build=no; }

  if [[ "${confirm,,}" != yes ]]; then
    echo "Adopt plan for ${domain} (${path}):"
    echo "  mode         : $([[ $reconcile == yes ]] && echo "reconcile existing site" || echo "new site, no scaffold")"
    echo "  manifest     : .simai/app.json ${APP_MANIFEST}"
    echo "  profile      : ${profile}"
    echo "  php          : ${php} (requires >= ${APP_PHP_MIN:-any}; $([[ $php_ok == yes ]] && echo satisfied || echo "will install php${php}"))"
    [[ ${#APP_PHP_EXTS[@]} -gt 0 ]] && echo "  php ext      : ${APP_PHP_EXTS[*]}${ext_pkgs[*]:+ (install: ${ext_pkgs[*]})}"
    [[ ${#APP_PACKAGES[@]} -gt 0 ]] && echo "  os packages  : ${APP_PACKAGES[*]}${missing_pkgs[*]:+ (install: ${missing_pkgs[*]})}"
    echo "  database     : $([[ $create_db == yes ]] && echo "${engine}${APP_DB_VERSION:+ ${APP_DB_VERSION}}" || echo none)"
    echo "  runs as      : ${owner:-own site user}"
    echo "  .env         : $([[ -f ${path}/.env ]] && echo "keep existing" || echo "create from .env.example"); APP_KEY kept or generated once"
    [[ ${#APP_ENV[@]} -gt 0 ]] && echo "  env defaults : ${APP_ENV[*]%%=*} (only where not set)"
    echo "  build        : $([[ $build == yes ]] && echo "composer install --no-dev" || echo skip)"
    echo "  migrate      : ${migrate}"
    echo "  workers      : $([[ ${#APP_WORKERS[@]} -gt 0 ]] && printf '%s ' "${APP_WORKERS[@]%%|*}" || echo "profile default")"
    echo "  scheduler    : ${APP_SCHEDULER:-profile default}"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  ui_header "SIMAI ENV · Adopt application"
  # 1. Requirements.
  if [[ "$php_ok" == no ]]; then
    info "Installing PHP ${php}"
    run_command php install --php "$php" --confirm yes || return 1
    adopt_php_satisfies "$php" "$APP_PHP_MIN" || { error "PHP ${php} does not satisfy >= ${APP_PHP_MIN}"; return 1; }
    mapfile -t ext_pkgs < <(app_php_ext_packages "$php" "${APP_PHP_EXTS[@]}")
  fi
  if [[ ${#ext_pkgs[@]} -gt 0 || ${#missing_pkgs[@]} -gt 0 ]]; then
    info "Installing packages: ${ext_pkgs[*]} ${missing_pkgs[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${ext_pkgs[@]}" "${missing_pkgs[@]}" >>"$LOG_FILE" 2>&1 || {
      error "Package installation failed; see ${LOG_FILE}"
      return 1
    }
    os_svc_reload_or_restart "php${php}-fpm" >/dev/null 2>&1 || true
  fi
  local exe
  for exe in "${APP_EXECUTABLES[@]}"; do
    [[ -x "$exe" ]] || { error "Required executable ${exe} is missing after package installation"; return 1; }
  done
  if [[ "$create_db" == yes && "$engine" == pgsql ]] && ! pgsql_available; then
    info "Installing PostgreSQL ${APP_DB_VERSION:-(Ubuntu default)}"
    pgsql_install "${APP_DB_VERSION:-}" "$pgdg" || return 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y "php${php}-pgsql" >>"$LOG_FILE" 2>&1 || true
  fi

  if [[ "$create_db" == yes || "$reconcile" == yes ]] && [[ -n "$engine" ]]; then
    db_engine_ensure_php_driver "$engine" "$php" || return 1
  fi

  # 2. .env from the application's own template, never overwritten.
  if [[ ! -e "${path}/.env" && -f "${path}/.env.example" && ! -L "${path}/.env.example" ]]; then
    dd if="${path}/.env.example" of="${path}/.env" iflag=nofollow status=none 2>/dev/null || { error "Cannot copy .env.example"; return 1; }
    chmod 0640 "${path}/.env"
  fi

  # 3. Site resources (nginx, PHP-FPM, user, database) without scaffolding.
  if [[ "$reconcile" == no ]]; then
    local -a add_args=(--domain "$domain" --path "$path" --profile "$profile" --php "$php" --create-db "$create_db")
    [[ "$create_db" == yes ]] && add_args+=(--db-engine "$engine" --db-export yes)
    [[ -n "$owner" ]] && add_args+=(--owner "$owner")
    SIMAI_ADMIN_MENU=0 run_command site add "${add_args[@]}" || { error "site add failed; nothing adopted"; return 1; }
    read_site_metadata "$domain" || return 1
  fi
  site_apply_user_context --domain "$domain"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}" run_user
  run_user=$(site_effective_user "$project")

  # 4. Application env defaults (only keys that are not set yet).
  local pair
  for pair in "${APP_ENV[@]}"; do
    adopt_env_is_empty "${path}/.env" "${pair%%=*}" && env_set_kv "${path}/.env" "${pair%%=*}" "${pair#*=}"
  done
  chown "${run_user}:$(site_effective_group "$project")" "${path}/.env" 2>/dev/null || true

  # 5. Dependencies and APP_KEY, as the site user.
  local php_bin
  php_bin=$(resolve_php_bin "$php")
  # Package/config caches built elsewhere (e.g. with dev dependencies) break
  # the first artisan call after `composer install --no-dev`; they regenerate.
  if [[ -d "${path}/bootstrap/cache" ]]; then
    find "${path}/bootstrap/cache" -maxdepth 1 -type f -name '*.php' -delete
  fi
  if [[ "$build" == yes ]]; then
    command -v composer >/dev/null 2>&1 || { error "composer is not installed (simai-admin.sh self bootstrap)"; return 1; }
    info "Installing Composer dependencies as ${run_user}"
    adopt_run_as "$run_user" "$path" "$php_bin" "$(command -v composer)" install --no-dev --prefer-dist \
      --no-interaction --no-scripts --optimize-autoloader >>"$LOG_FILE" 2>&1 || { error "composer install failed; see ${LOG_FILE}"; return 1; }
    if [[ -f "${path}/artisan" ]]; then
      adopt_run_as "$run_user" "$path" "$php_bin" artisan package:discover --ansi >>"$LOG_FILE" 2>&1 || {
        error "artisan package:discover failed; see ${LOG_FILE}"
        return 1
      }
    fi
  fi
  local app_key_state="kept"
  if [[ -f "${path}/artisan" ]] && adopt_env_is_empty "${path}/.env" APP_KEY; then
    adopt_run_as "$run_user" "$path" "$php_bin" artisan key:generate --force >>"$LOG_FILE" 2>&1 \
      && app_key_state="generated" || { error "APP_KEY generation failed"; return 1; }
  fi
  if [[ "$migrate" == yes && -f "${path}/artisan" ]]; then
    info "Running migrations"
    adopt_run_as "$run_user" "$path" "$php_bin" artisan migrate --force >>"$LOG_FILE" 2>&1 || { error "Migrations failed; see ${LOG_FILE}"; return 1; }
  fi

  # 6. Background processes declared by the application.
  if [[ ${#APP_WORKERS[@]} -gt 0 ]]; then
    app_write_workers "$project" "$path" "$php" yes || return 1
  fi
  if [[ "${APP_SCHEDULER:-}" == no ]]; then
    remove_cron_file "$project" >/dev/null 2>&1 || true
  elif [[ "${APP_SCHEDULER:-}" == yes && ! -f "$(cron_site_file_path "$project")" ]]; then
    cron_site_write "$domain" "$project" "$profile" "$path" "$php"
  fi

  # 7. Record what was adopted.
  local state
  state="$(site_sites_config_dir)/${domain}/app.env"
  install -d -m 0750 "$(dirname "$state")"
  {
    printf 'ADOPTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'MANIFEST=%s\n' "$APP_MANIFEST"
    [[ -f "${path}/.simai/app.json" ]] && printf 'MANIFEST_SHA256=%s\n' "$(sha256sum "${path}/.simai/app.json" | cut -d' ' -f1)"
    printf 'PHP=%s\nDB_ENGINE=%s\n' "$php" "$([[ $create_db == yes || $reconcile == yes ]] && echo "$engine" || echo none)"
  } >"$state"
  chmod 0640 "$state"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${domain}" http://127.0.0.1/ --max-time 20 || echo 000)
  ui_result_table \
    "Domain|${domain}" \
    "Mode|$([[ $reconcile == yes ]] && echo reconciled || echo adopted)" \
    "Runs as|${run_user}" \
    "PHP|${php} ($("$php_bin" -r 'echo PHP_VERSION;'))" \
    "Database|$([[ $create_db == yes || $reconcile == yes ]] && echo "$engine" || echo none)" \
    "APP_KEY|${app_key_state}" \
    "Workers|$(app_project_worker_units "$project" | paste -sd, - || true)" \
    "Local HTTP|${http_code}"
  ui_next_steps
  ui_kv "Describe" "simai-admin.sh site describe --domain ${domain}"
  [[ "$migrate" != yes ]] && ui_kv "Migrate" "simai-admin.sh site adopt --domain ${domain} --migrate yes --confirm yes"
  return 0
}

register_cmd "site" "adopt" "Attach an existing application (no scaffold) using composer.json and .simai/app.json" "site_adopt_handler" "domain" "path= profile= php= owner= db-engine= create-db= migrate= build= pgdg= confirm=" "tier:advanced"
