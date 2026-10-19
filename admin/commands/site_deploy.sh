#!/usr/bin/env bash

# Release deployments for application sites:
#   <root>/.env and <root>/storage   shared state (all other commands keep using them)
#   <root>/releases/<id>             code of one release, built as the site user
#   <root>/current -> releases/<id>  switched atomically; nginx serves current/<public>
# Deploy builds and migrates before the switch, then reloads PHP-FPM and asks
# Laravel workers to restart gracefully after their current job.
# Service sites (profile node) build with npm/yarn (and a Python venv when the
# manifest asks for one), restart simai-app-<project>.service after the switch
# and return to the previous release when its health check fails.

deploy_state_file() {
  echo "$(site_sites_config_dir)/$1/deploy.env"
}

deploy_state_get() {
  local domain="$1" key="$2"
  sed -n "s/^${key}=//p" "$(deploy_state_file "$domain")" 2>/dev/null | tail -n1
}

deploy_state_set() {
  local domain="$1" key="$2" value="$3" file tmp
  file=$(deploy_state_file "$domain")
  install -d -m 0750 "$(dirname "$file")"
  tmp=$(mktemp "${file}.XXXXXX") || return 1
  { grep -v "^${key}=" "$file" 2>/dev/null || true; printf '%s=%s\n' "$key" "$value"; } >"$tmp"
  chmod 0640 "$tmp" && mv -f "$tmp" "$file"
}

deploy_layout_active() {
  [[ -L "${1}/current" && -d "${1}/releases" ]]
}

deploy_run_as() {
  local user="$1" dir="$2"
  shift 2
  sudo -u "$user" -H bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

deploy_archive_safe() {
  local archive="$1" entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == /* || "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]; then
      error "Unsafe path in archive: ${entry}"
      return 1
    fi
  done < <(tar -tzf "$archive")
  if tar -tvzf "$archive" | awk 'NF {print substr($0,1,1)}' | grep -qv '^[-dl]$'; then
    error "Archive contains hard links or special files"
    return 1
  fi
}

# Points nginx at <root>/current/<public> and background jobs at current.
deploy_switch_site_to_layout() {
  local domain="$1" root="$2" php="$3" profile="$4" project="$5"
  local cfg="/etc/nginx/sites-available/${domain}.conf" public backup
  public=$(sed -n 's/^# simai-public-dir: *//p' "$cfg" | head -n1)
  [[ "$public" == current/* || "$public" == current ]] && return 0
  local new_public="current${public:+/${public}}"
  backup=$(mktemp) && cp -p "$cfg" "$backup"
  ROOT_OLD="${root}${public:+/${public}}" ROOT_NEW="${root}/${new_public}" PUB_NEW="$new_public" perl -0pi -e '
    s/^(\s*root\s+)\Q$ENV{ROOT_OLD}\E(\s*;)/$1$ENV{ROOT_NEW}$2/mg;
    s/^(# simai-public-dir:).*$/$1 $ENV{PUB_NEW}/m' "$cfg"
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    cp -p "$backup" "$cfg"; rm -f "$backup"
    error "nginx rejected the release layout; configuration restored"
    return 1
  fi
  rm -f "$backup"
  os_svc_reload nginx >/dev/null 2>&1 || true
  if [[ -f "$(cron_site_file_path "$project")" ]]; then
    cron_site_write "$domain" "$project" "$profile" "${root}/current" "$php"
  fi
  local unit
  for unit in $(app_project_worker_units "$project"); do
    sed -i -e "s#^WorkingDirectory=.*#WorkingDirectory=${root}/current#" \
      -e "s# ${root}/artisan# ${root}/current/artisan#" "/etc/systemd/system/${unit}"
  done
  os_svc_daemon_reload >/dev/null 2>&1 || true
}

# First deploy of an in-place site: its code becomes release <ts>-initial so
# a rollback to the pre-deploy state stays possible.
deploy_init_layout() {
  local root="$1" user="$2" group="$3" id="$4" service="${5:-no}" entry name
  install -d -m 0750 -o "$user" -g "$group" "${root}/releases" "${root}/releases/${id}" || return 1
  shopt -s dotglob nullglob
  for entry in "${root}"/*; do
    name=$(basename "$entry")
    case "$name" in
      releases|current|current.tmp|.env|storage|shared|.cache|.simai-deploy.lock) continue ;;
      public) [[ "$service" == yes ]] && continue ;;
    esac
    mv -- "$entry" "${root}/releases/${id}/" || { shopt -u dotglob nullglob; return 1; }
  done
  shopt -u dotglob nullglob
  [[ "$service" == yes ]] || deploy_link_shared "$root" "${root}/releases/${id}" "$user" "$group"
  ln -sfn "releases/${id}" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current"
}

deploy_link_shared() {
  local root="$1" release="$2" user="$3" group="$4" d
  for d in storage/app/public storage/framework/cache/data storage/framework/sessions storage/framework/views storage/logs; do
    install -d -m 0775 -o "$user" -g "$group" "${root}/${d}"
  done
  rm -rf --one-file-system -- "${release}/storage"
  ln -sfn ../../storage "${release}/storage"
  [[ -e "${root}/.env" ]] && { rm -f -- "${release}/.env"; ln -sfn ../../.env "${release}/.env"; }
  chown -h "${user}:${group}" "${release}/storage" "${release}/.env" 2>/dev/null || true
}

# Paths the manifest lists in "shared" live in <root>/shared and survive
# releases. The first release seeds them with its own copy.
deploy_link_manifest_shared() {
  local root="$1" release="$2" user="$3" group="$4" item target depth up
  install -d -m 0750 -o "$user" -g "$group" "${root}/shared" || return 1
  for item in "${APP_SHARED[@]}"; do
    target="${root}/shared/${item}"
    if [[ ! -e "$target" ]]; then
      install -d -m 0750 -o "$user" -g "$group" "$(dirname "$target")" || return 1
      if [[ -e "${release}/${item}" && ! -L "${release}/${item}" ]]; then
        cp -a -- "${release}/${item}" "$target" || return 1
      else
        install -d -m 0750 -o "$user" -g "$group" "$target" || return 1
      fi
    fi
    rm -rf --one-file-system -- "${release:?}/${item}"
    install -d -m 0750 -o "$user" -g "$group" "$(dirname "${release}/${item}")" || return 1
    depth=$(awk -F/ '{print NF}' <<<"$item")
    up=$(printf '../%.0s' $(seq 1 $((depth + 1))))
    ln -sfn "${up}shared/${item}" "${release}/${item}" || return 1
    chown -h "${user}:${group}" "${release}/${item}" 2>/dev/null || true
  done
}

# Installs dependencies and builds a service release as the site user.
deploy_build_service() {
  local root="$1" release="$2" user="$3" group="$4" install="${APP_INSTALL:-auto}"
  install -d -m 0750 -o "$user" -g "$group" "${root}/.cache" "${root}/.cache/npm" "${root}/.cache/yarn" "${root}/.cache/pip" || return 1
  local -a envs=("npm_config_cache=${root}/.cache/npm" "YARN_CACHE_FOLDER=${root}/.cache/yarn" "PIP_CACHE_DIR=${root}/.cache/pip" "npm_config_update_notifier=false")
  if [[ "$install" == auto ]]; then
    if [[ -f "${release}/yarn.lock" ]]; then install=yarn
    elif [[ -f "${release}/package.json" ]]; then install=npm
    else install=none
    fi
  fi
  # Dev dependencies are needed only when the release builds itself.
  local -a omit=()
  case "$install" in
    yarn)
      [[ -n "$APP_BUILD" ]] || omit=(--production)
      deploy_run_as "$user" "$release" env "${envs[@]}" npx --yes yarn@1.22.22 install --frozen-lockfile --non-interactive "${omit[@]}" >>"$LOG_FILE" 2>&1 || return 1
      ;;
    npm)
      [[ -n "$APP_BUILD" ]] || omit=(--omit=dev)
      if [[ -f "${release}/package-lock.json" ]]; then
        deploy_run_as "$user" "$release" env "${envs[@]}" npm ci --no-audit --no-fund "${omit[@]}" >>"$LOG_FILE" 2>&1 || return 1
      else
        deploy_run_as "$user" "$release" env "${envs[@]}" npm install --no-audit --no-fund "${omit[@]}" >>"$LOG_FILE" 2>&1 || return 1
      fi
      ;;
  esac
  if [[ -n "$APP_PYTHON_REQUIREMENTS" ]]; then
    [[ -f "${release}/${APP_PYTHON_REQUIREMENTS}" ]] || { error "${APP_PYTHON_REQUIREMENTS} not found in the release"; return 1; }
    deploy_run_as "$user" "$release" env "${envs[@]}" python3 -m venv .venv >>"$LOG_FILE" 2>&1 || return 1
    deploy_run_as "$user" "$release" env "${envs[@]}" .venv/bin/pip install --disable-pip-version-check --no-input -r "$APP_PYTHON_REQUIREMENTS" >>"$LOG_FILE" 2>&1 || return 1
  fi
  if [[ -n "$APP_BUILD" ]]; then
    local -a build_cmd=()
    read -r -a build_cmd <<<"$APP_BUILD"
    deploy_run_as "$user" "$release" env "${envs[@]}" PATH="${release}/.venv/bin:/usr/local/bin:/usr/bin:/bin" "${build_cmd[@]}" >>"$LOG_FILE" 2>&1 || return 1
  fi
}

# Switches a service site to a release, restarts the unit and waits for the
# health check; returns to the previous release when it fails.
deploy_activate_service() {
  local domain="$1" root="$2" release_id="$3" project="$4" previous_link unit port
  unit=$(app_service_unit_name "$project")
  port=$(app_port_get "$domain")
  previous_link=$(readlink "${root}/current")
  ln -sfn "releases/${release_id}" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current" || return 1
  app_service_write "$project" "$root" || return 1
  systemctl restart "$unit" >/dev/null 2>&1 || true
  info "Waiting for ${unit} on 127.0.0.1:${port}${APP_HEALTH_PATH:-/} (up to ${APP_HEALTH_TIMEOUT:-120} s)"
  if app_health_wait "$port" "${APP_HEALTH_PATH:-/}" "${APP_HEALTH_TIMEOUT:-120}"; then
    return 0
  fi
  error "${unit} did not pass its health check; see: journalctl -u ${unit} -n 50"
  if [[ -n "$previous_link" && "$previous_link" != "releases/${release_id}" && -d "${root}/${previous_link}" ]]; then
    ln -sfn "$previous_link" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current"
    if [[ -f "${root}/${previous_link}/.simai/app.json" ]]; then
      systemctl restart "$unit" >/dev/null 2>&1 || true
      if app_health_wait "$port" "${APP_HEALTH_PATH:-/}" "${APP_HEALTH_TIMEOUT:-120}"; then
        warn "Returned to ${previous_link}; it passes its health check"
      else
        warn "Returned to ${previous_link}, but it does not pass its health check either"
      fi
    else
      # The first release replaced an empty site: nothing to run.
      systemctl stop "$unit" >/dev/null 2>&1 || true
      warn "Returned to ${previous_link} (no application); ${unit} stopped"
    fi
  fi
  return 1
}

deploy_prune() {
  local root="$1" keep="$2" current previous name
  current=$(basename "$(readlink "${root}/current")")
  previous="${DEPLOY_PREVIOUS:-}"
  find "${root}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | awk -v keep="$keep" 'NR > keep' \
    | while IFS= read -r name; do
      [[ "$name" == "$current" || "$name" == "$previous" ]] && continue
      [[ "$name" =~ ^[0-9]{14}(-[A-Za-z0-9._-]+)?$ ]] && rm -rf --one-file-system -- "${root}/releases/${name:?}"
    done
}

deploy_activate() {
  local domain="$1" root="$2" php="$3" release_id="$4" user="$5"
  local previous_link
  previous_link=$(readlink "${root}/current")
  ln -sfn "releases/${release_id}" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current" || return 1
  os_svc_reload "php${php}-fpm" >/dev/null 2>&1 || os_svc_reload_or_restart "php${php}-fpm" >/dev/null 2>&1 || {
    ln -sfn "$previous_link" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current" || error 'Could not restore the previous release link'
    error "PHP-FPM activation failed for ${domain}; previous link restoration attempted; inspect deploy-status before retry"
    return 1
  }
  if [[ -f "${root}/current/artisan" ]]; then
    deploy_run_as "$user" "${root}/current" "$(resolve_php_bin "$php")" artisan queue:restart >>"$LOG_FILE" 2>&1 || true
  fi
}

# Requirements, shared .env and build of a service release.
deploy_service_release() {
  local domain="$1" root="$2" release="$3" user="$4" group="$5" major
  DEPLOY_SERVICE_FAILED=""
  [[ -n "$APP_START" ]] || { DEPLOY_SERVICE_FAILED="manifest: node.start is required for a service site"; return 1; }
  command -v node >/dev/null 2>&1 || { DEPLOY_SERVICE_FAILED="Node.js is not installed (simai-env.sh bootstrap installs it)"; return 1; }
  major=$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)
  if [[ -n "$APP_NODE_VERSION" ]] && (( major < APP_NODE_VERSION )); then
    DEPLOY_SERVICE_FAILED="Node.js ${major} is older than the release requires (${APP_NODE_VERSION})"; return 1
  fi
  if [[ -n "$APP_PYTHON_REQUIREMENTS" ]] && ! python3 -c 'import ensurepip, venv' >/dev/null 2>&1; then
    DEPLOY_SERVICE_FAILED="missing requirements: python3-venv"; return 1
  fi
  app_service_env_ensure "$root" "$release" "$(app_port_get "$domain")" "$group" || { DEPLOY_SERVICE_FAILED="shared .env"; return 1; }
  rm -f -- "${release}/.env"; ln -sfn ../../.env "${release}/.env"; chown -h "${user}:${group}" "${release}/.env" 2>/dev/null || true
  info "Building release as ${user}"
  deploy_build_service "$root" "$release" "$user" "$group" || { DEPLOY_SERVICE_FAILED="dependency install/build (see ${LOG_FILE})"; return 1; }
}

site_deploy_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" git_url="${PARSED_ARGS[git]:-}" ref="${PARSED_ARGS[ref]:-}"
  local archive="${PARSED_ARGS[archive]:-}" sha256="${PARSED_ARGS[sha256]:-}" from="${PARSED_ARGS[from]:-}"
  local migrate="${PARSED_ARGS[migrate]:-}" keep="${PARSED_ARGS[keep]:-5}" confirm="${PARSED_ARGS[confirm]:-no}"
  local build="${PARSED_ARGS[build]:-auto}"
  [[ "$build" =~ ^(auto|yes|no)$ ]] || { error "--build must be auto, yes or no"; return 1; }
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local root="${SITE_META[root]}" php="${SITE_META[php]}" profile="${SITE_META[profile]}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local service=no
  [[ -n "$(app_port_get "$domain")" ]] && service=yes
  [[ "$profile" != alias && ( "$php" != none || "$service" == yes ) ]] || { error "Deploy supports PHP application sites and service sites (profile node)"; return 1; }
  [[ "$keep" =~ ^[0-9]+$ ]] && (( keep >= 2 && keep <= 50 )) || { error "--keep must be 2..50"; return 1; }
  local sources=0
  [[ -n "$git_url" ]] && sources=$((sources + 1))
  [[ -n "$archive" ]] && sources=$((sources + 1))
  [[ -n "$from" ]] && sources=$((sources + 1))
  (( sources == 1 )) || { error "Give exactly one source: --git <url> --ref <ref>, --archive <file.tar.gz> or --from <dir>"; return 1; }
  if [[ -n "$git_url" ]]; then
    [[ "$git_url" =~ ^(https://|ssh://|git@)[A-Za-z0-9@:/._~-]+$ ]] || { error "Unsupported git URL"; return 1; }
    [[ "$ref" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$ ]] || { error "--ref must be a branch, tag or commit"; return 1; }
  fi
  if [[ -n "$archive" ]]; then
    [[ -f "$archive" ]] || { error "Archive not found: ${archive}"; return 1; }
    if [[ -n "$sha256" ]] && [[ "$(sha256sum "$archive" | cut -d' ' -f1)" != "${sha256,,}" ]]; then
      error "Archive checksum does not match --sha256"; return 1
    fi
  fi
  if [[ -n "$from" ]]; then
    validate_path "$from" || return 1
    [[ -d "$from" ]] || { error "Source directory not found: ${from}"; return 1; }
  fi
  local user group
  user=$(site_effective_user "$project")
  group=$(site_effective_group "$project")
  local release_id
  release_id="$(date -u +%Y%m%d%H%M%S)"

  if [[ "${confirm,,}" != yes ]]; then
    echo "Deploy plan for ${domain}:"
    deploy_layout_active "$root" || echo "  - first deploy: move the current code to releases/${release_id}-initial and serve ${root}/current"
    echo "  - fetch $([[ -n $git_url ]] && echo "${git_url} @ ${ref}" || [[ -n $archive ]] && echo "archive ${archive}" || echo "directory ${from}") into releases/<new> as ${user}"
    if [[ "$service" == yes ]]; then
      echo "  - read .simai/app.json (node.start required); link shared .env and the manifest's shared paths"
      echo "  - install dependencies (yarn/npm), Python venv when the manifest lists requirements, optional build"
      echo "  - switch current, (re)write and restart $(app_service_unit_name "$project") on 127.0.0.1:$(app_port_get "$domain")"
      echo "  - wait for the health check; on failure return to the previous release; keep ${keep} releases"
    else
      echo "  - link shared .env and storage; composer install --no-dev unless the release ships vendor/ (--build ${build}); artisan package:discover"
      echo "  - migrate: ${migrate:-from .simai/app.json (default no)}"
      echo "  - switch current atomically, reload php${php}-fpm, artisan queue:restart; keep ${keep} releases"
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  exec 7>"$(site_sites_config_dir)/${domain}/.deploy.lock" 2>/dev/null || { install -d -m 0750 "$(site_sites_config_dir)/${domain}"; exec 7>"$(site_sites_config_dir)/${domain}/.deploy.lock"; }
  flock -n 7 || { error "Another deploy of ${domain} is running"; return 1; }
  ui_header "SIMAI ENV · Deploy"

  if ! deploy_layout_active "$root"; then
    info "Converting ${root} to the release layout"
    deploy_init_layout "$root" "$user" "$group" "${release_id}-initial" "$service" || { error "Could not create the release layout"; return 1; }
    # nginx of a service site proxies to the unit and keeps public/ for ACME.
    [[ "$service" == yes ]] || deploy_switch_site_to_layout "$domain" "$root" "$php" "$profile" "$project" || return 1
    deploy_state_set "$domain" CURRENT "${release_id}-initial"
    sleep 1
    release_id="$(date -u +%Y%m%d%H%M%S)"
  fi

  local release="${root}/releases/${release_id}"
  install -d -m 0750 -o "$user" -g "$group" "$release" || return 1
  local failed="" release_ref=""
  info "Fetching release ${release_id}"
  if [[ -n "$git_url" ]]; then
    deploy_run_as "$user" "$release" git clone --quiet --no-tags "$git_url" . >>"$LOG_FILE" 2>&1 \
      && deploy_run_as "$user" "$release" git -c advice.detachedHead=false checkout --quiet "$ref" >>"$LOG_FILE" 2>&1 \
      || failed="git fetch"
    [[ -z "$failed" ]] && release_ref=$(deploy_run_as "$user" "$release" git rev-parse --short HEAD 2>/dev/null)
  elif [[ -n "$archive" ]]; then
    deploy_archive_safe "$archive" || failed="archive validation"
    if [[ -z "$failed" ]]; then
      local staged
      staged=$(mktemp -p /tmp simai-release-XXXXXX.tar.gz) && cp "$archive" "$staged" && chmod 0644 "$staged"
      deploy_run_as "$user" "$release" tar --no-same-owner --no-same-permissions -xzf "$staged" >>"$LOG_FILE" 2>&1 || failed="archive extraction"
      rm -f -- "$staged"
    fi
  else
    rsync -a --delete --exclude=.git --exclude=/.env --exclude=/storage "${from%/}/" "${release}/" >>"$LOG_FILE" 2>&1 \
      && chown -R "${user}:${group}" "$release" || failed="copy"
  fi
  [[ -z "$failed" && "$service" != yes ]] && { deploy_link_shared "$root" "$release" "$user" "$group" || failed="shared links"; }

  local php_bin=""
  [[ "$php" != none ]] && php_bin=$(resolve_php_bin "$php")
  if [[ -z "$failed" ]]; then
    app_manifest_load "$release" || failed="manifest"
  fi
  [[ -z "$failed" && ${#APP_SHARED[@]} -gt 0 ]] && { deploy_link_manifest_shared "$root" "$release" "$user" "$group" || failed="shared paths"; }
  if [[ -z "$failed" && "$service" == yes ]]; then
    deploy_service_release "$domain" "$root" "$release" "$user" "$group" || failed="${DEPLOY_SERVICE_FAILED:-service build}"
  fi
  if [[ -z "$failed" && -n "$APP_PHP_MIN" && -n "$php_bin" ]] && ! "$php_bin" -r "exit(version_compare(PHP_VERSION, '${APP_PHP_MIN}', '>=') ? 0 : 1);"; then
    failed="PHP ${php} is older than the release requires (${APP_PHP_MIN}); run site adopt --confirm yes first"
  fi
  if [[ -z "$failed" ]]; then
    local -a missing=()
    mapfile -t missing < <(app_missing_packages "${APP_PACKAGES[@]}"; [[ -z "$php_bin" ]] || app_php_ext_packages "$php" "${APP_PHP_EXTS[@]}")
    [[ ${#missing[@]} -eq 0 ]] || failed="missing requirements: ${missing[*]} (run site adopt --domain ${domain} --confirm yes)"
  fi
  # Prebuilt artifacts (vendor included, e.g. from a monorepo with path
  # repositories) skip composer; --build yes forces it, --build no skips it.
  if [[ "$build" == auto ]]; then
    [[ -f "${release}/composer.json" && ! -f "${release}/vendor/autoload.php" ]] && build=yes || build=no
  fi
  if [[ -z "$failed" && -n "$php_bin" && -f "${release}/composer.json" ]]; then
    find "${release}/bootstrap/cache" -maxdepth 1 -type f -name '*.php' -delete 2>/dev/null || true
    if [[ "$build" == yes ]]; then
      info "Building release as ${user}"
      deploy_run_as "$user" "$release" "$php_bin" "$(command -v composer)" install --no-dev --prefer-dist --no-interaction \
        --no-scripts --optimize-autoloader >>"$LOG_FILE" 2>&1 || failed="composer install"
    fi
    if [[ -z "$failed" && -f "${release}/artisan" ]]; then
      deploy_run_as "$user" "$release" "$php_bin" artisan package:discover >>"$LOG_FILE" 2>&1 || failed="package:discover"
    fi
  fi
  [[ -n "$migrate" ]] || migrate="${APP_MIGRATE:-no}"
  if [[ -z "$failed" && -n "$php_bin" && "$migrate" == yes && -f "${release}/artisan" ]]; then
    info "Migrating (before the switch)"
    deploy_run_as "$user" "$release" "$php_bin" artisan migrate --force >>"$LOG_FILE" 2>&1 || failed="migrations"
  fi
  if [[ -n "$failed" ]]; then
    rm -rf --one-file-system -- "${release:?}"
    error "Deploy of ${domain} failed at: ${failed}. The current release keeps serving; see ${LOG_FILE}"
    return 1
  fi

  DEPLOY_PREVIOUS=$(basename "$(readlink "${root}/current")")
  if [[ "$service" == yes ]]; then
    if ! deploy_activate_service "$domain" "$root" "$release_id" "$project"; then
      # Kept for inspection under a name that rollback never picks.
      mv -T -- "$release" "${release}-failed" 2>/dev/null || true
      deploy_state_set "$domain" FAILED "${release_id}-failed"
      error "Deploy of ${domain} failed at: health check. The release is kept as releases/${release_id}-failed for inspection"
      return 1
    fi
  else
    deploy_activate "$domain" "$root" "$php" "$release_id" "$user" || { error "Switch failed"; return 1; }
  fi
  if [[ ${#APP_WORKERS[@]} -gt 0 ]]; then
    app_write_workers "$project" "${root}/current" "$php" yes || warn "Worker units could not be updated"
  fi
  deploy_state_set "$domain" PREVIOUS "$DEPLOY_PREVIOUS"
  deploy_state_set "$domain" CURRENT "$release_id"
  deploy_state_set "$domain" DEPLOYED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deploy_state_set "$domain" SOURCE "$([[ -n $git_url ]] && echo "git $(redact_by_key git "$git_url") ${ref} ${release_ref:-}" || [[ -n $archive ]] && echo "archive $(basename "$archive")" || echo "dir ${from}")"
  deploy_prune "$root" "$keep"

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${domain}" http://127.0.0.1/ --max-time 20 || echo 000)
  ui_result_table "Domain|${domain}" "Release|${release_id}" "Previous|${DEPLOY_PREVIOUS}" "Migrated|${migrate}" "Local HTTP|${http_code}"
  ui_next_steps
  ui_kv "Roll back" "simai-admin.sh site deploy-rollback --domain ${domain} --confirm yes"
}

site_deploy_rollback_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" to="${PARSED_ARGS[release]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local root="${SITE_META[root]}" php="${SITE_META[php]}" project="${SITE_META[project]}"
  deploy_layout_active "$root" || { error "${domain} has no releases"; return 1; }
  local current
  current=$(basename "$(readlink "${root}/current")")
  [[ -n "$to" ]] || to=$(find "${root}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | grep -vx "$current" | grep -v -- '-failed$' | head -n1)
  [[ -n "$to" && "$to" =~ ^[0-9]{14}(-[A-Za-z0-9._-]+)?$ && -d "${root}/releases/${to}" ]] || { error "No release to roll back to"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    echo "Rollback plan: ${current} -> ${to} (code only; database migrations are not reverted)"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  if [[ -n "$(app_port_get "$domain")" ]]; then
    app_manifest_load "${root}/releases/${to}" || return 1
    deploy_activate_service "$domain" "$root" "$to" "$project" || return 1
  else
    deploy_activate "$domain" "$root" "$php" "$to" "$(site_effective_user "$project")" || return 1
  fi
  deploy_state_set "$domain" PREVIOUS "$current"
  deploy_state_set "$domain" CURRENT "$to"
  ui_result_table "Domain|${domain}" "Current|${to}" "Was|${current}" "Database|unchanged"
}

site_deploy_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local root="${SITE_META[root]}"
  if ! deploy_layout_active "$root"; then
    ui_result_table "Domain|${domain}" "Layout|in-place (no releases yet)" "First deploy|simai-admin.sh site deploy --domain ${domain} --git <url> --ref <tag>"
    return 0
  fi
  local current name rows=()
  current=$(basename "$(readlink "${root}/current")")
  while IFS= read -r name; do
    rows+=("${name}|$([[ $name == "$current" ]] && echo current || echo available)")
  done < <(find "${root}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  ui_result_table "Domain|${domain}" "Source|$(redact_by_key source "$(deploy_state_get "$domain" SOURCE)")" "Deployed at|$(deploy_state_get "$domain" DEPLOYED_AT)" "${rows[@]}"
}

site_service_restart_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local root="${SITE_META[root]}" project="${SITE_META[project]}" port unit
  port=$(app_port_get "$domain")
  [[ -n "$port" ]] || { error "${domain} has no application service"; return 1; }
  unit=$(app_service_unit_name "$project")
  [[ -f "/etc/systemd/system/${unit}" ]] || { error "${unit} does not exist yet; deploy a release first"; return 1; }
  app_manifest_load "${root}/current" || return 1
  systemctl restart "$unit" || { error "Restart of ${unit} failed; see: journalctl -u ${unit} -n 50"; return 1; }
  if ! app_health_wait "$port" "${APP_HEALTH_PATH:-/}" "${APP_HEALTH_TIMEOUT:-120}"; then
    error "${unit} restarted but did not pass its health check; see: journalctl -u ${unit} -n 50"
    return 1
  fi
  ui_result_table "Domain|${domain}" "Service|${unit}" "Health|127.0.0.1:${port}${APP_HEALTH_PATH:-/} OK"
}

register_cmd "site" "service-restart" "Restart the application service of a node site and wait for its health check" "site_service_restart_handler" "domain" "" "tier:advanced"
register_cmd "site" "deploy" "Deploy a release (git ref, archive or directory) with atomic switch" "site_deploy_handler" "domain" "git= ref= archive= sha256= from= migrate= keep= build= confirm=" "tier:advanced plan:handler"
register_cmd "site" "deploy-rollback" "Switch back to a previous release (code only)" "site_deploy_rollback_handler" "domain" "release= confirm=" "tier:advanced plan:handler"
register_cmd "site" "deploy-status" "Show releases of a site" "site_deploy_status_handler" "domain" "" "tier:advanced effects:read"
