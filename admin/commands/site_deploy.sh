#!/usr/bin/env bash

# Release deployments for application sites:
#   <root>/.env and <root>/storage   shared state (all other commands keep using them)
#   <root>/releases/<id>             code of one release, built as the site user
#   <root>/current -> releases/<id>  switched atomically; nginx serves current/<public>
# Deploy builds and migrates before the switch, then reloads PHP-FPM and asks
# Laravel workers to restart gracefully after their current job.

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
  local root="$1" user="$2" group="$3" id="$4" entry name
  install -d -m 0750 -o "$user" -g "$group" "${root}/releases" "${root}/releases/${id}" || return 1
  shopt -s dotglob nullglob
  for entry in "${root}"/*; do
    name=$(basename "$entry")
    case "$name" in
      releases|current|current.tmp|.env|storage|.simai-deploy.lock) continue ;;
    esac
    mv -- "$entry" "${root}/releases/${id}/" || { shopt -u dotglob nullglob; return 1; }
  done
  shopt -u dotglob nullglob
  [[ -f "${root}/releases/${id}/.simai/app.json" ]] || true
  deploy_link_shared "$root" "${root}/releases/${id}" "$user" "$group"
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
  ln -sfn "releases/${release_id}" "${root}/current.tmp" && mv -Tf "${root}/current.tmp" "${root}/current" || return 1
  os_svc_reload "php${php}-fpm" >/dev/null 2>&1 || os_svc_reload_or_restart "php${php}-fpm" >/dev/null 2>&1 || true
  if [[ -f "${root}/current/artisan" ]]; then
    deploy_run_as "$user" "${root}/current" "$(resolve_php_bin "$php")" artisan queue:restart >>"$LOG_FILE" 2>&1 || true
  fi
}

site_deploy_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" git_url="${PARSED_ARGS[git]:-}" ref="${PARSED_ARGS[ref]:-}"
  local archive="${PARSED_ARGS[archive]:-}" sha256="${PARSED_ARGS[sha256]:-}" from="${PARSED_ARGS[from]:-}"
  local migrate="${PARSED_ARGS[migrate]:-}" keep="${PARSED_ARGS[keep]:-5}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  local root="${SITE_META[root]}" php="${SITE_META[php]}" profile="${SITE_META[profile]}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  [[ "$profile" != alias && "$php" != none ]] || { error "Deploy supports PHP application sites"; return 1; }
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
    echo "  - link shared .env and storage; composer install --no-dev; artisan package:discover"
    echo "  - migrate: ${migrate:-from .simai/app.json (default no)}"
    echo "  - switch current atomically, reload php${php}-fpm, artisan queue:restart; keep ${keep} releases"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  exec 7>"$(site_sites_config_dir)/${domain}/.deploy.lock" 2>/dev/null || { install -d -m 0750 "$(site_sites_config_dir)/${domain}"; exec 7>"$(site_sites_config_dir)/${domain}/.deploy.lock"; }
  flock -n 7 || { error "Another deploy of ${domain} is running"; return 1; }
  ui_header "SIMAI ENV · Deploy"

  if ! deploy_layout_active "$root"; then
    info "Converting ${root} to the release layout"
    deploy_init_layout "$root" "$user" "$group" "${release_id}-initial" || { error "Could not create the release layout"; return 1; }
    deploy_switch_site_to_layout "$domain" "$root" "$php" "$profile" "$project" || return 1
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
  [[ -z "$failed" ]] && { deploy_link_shared "$root" "$release" "$user" "$group" || failed="shared links"; }

  local php_bin
  php_bin=$(resolve_php_bin "$php")
  if [[ -z "$failed" ]]; then
    app_manifest_load "$release" || failed="manifest"
  fi
  if [[ -z "$failed" && -n "$APP_PHP_MIN" ]] && ! "$php_bin" -r "exit(version_compare(PHP_VERSION, '${APP_PHP_MIN}', '>=') ? 0 : 1);"; then
    failed="PHP ${php} is older than the release requires (${APP_PHP_MIN}); run site adopt --confirm yes first"
  fi
  if [[ -z "$failed" ]]; then
    local -a missing=()
    mapfile -t missing < <(app_missing_packages "${APP_PACKAGES[@]}"; app_php_ext_packages "$php" "${APP_PHP_EXTS[@]}")
    [[ ${#missing[@]} -eq 0 ]] || failed="missing requirements: ${missing[*]} (run site adopt --domain ${domain} --confirm yes)"
  fi
  if [[ -z "$failed" && -f "${release}/composer.json" ]]; then
    info "Building release as ${user}"
    find "${release}/bootstrap/cache" -maxdepth 1 -type f -name '*.php' -delete 2>/dev/null || true
    deploy_run_as "$user" "$release" "$php_bin" "$(command -v composer)" install --no-dev --prefer-dist --no-interaction \
      --no-scripts --optimize-autoloader >>"$LOG_FILE" 2>&1 || failed="composer install"
    if [[ -z "$failed" && -f "${release}/artisan" ]]; then
      deploy_run_as "$user" "$release" "$php_bin" artisan package:discover >>"$LOG_FILE" 2>&1 || failed="package:discover"
    fi
  fi
  [[ -n "$migrate" ]] || migrate="${APP_MIGRATE:-no}"
  if [[ -z "$failed" && "$migrate" == yes && -f "${release}/artisan" ]]; then
    info "Migrating (before the switch)"
    deploy_run_as "$user" "$release" "$php_bin" artisan migrate --force >>"$LOG_FILE" 2>&1 || failed="migrations"
  fi
  if [[ -n "$failed" ]]; then
    rm -rf --one-file-system -- "${release:?}"
    error "Deploy of ${domain} failed at: ${failed}. The current release keeps serving; see ${LOG_FILE}"
    return 1
  fi

  DEPLOY_PREVIOUS=$(basename "$(readlink "${root}/current")")
  deploy_activate "$domain" "$root" "$php" "$release_id" "$user" || { error "Switch failed"; return 1; }
  if [[ ${#APP_WORKERS[@]} -gt 0 ]]; then
    app_write_workers "$project" "${root}/current" "$php" yes || warn "Worker units could not be updated"
  fi
  deploy_state_set "$domain" PREVIOUS "$DEPLOY_PREVIOUS"
  deploy_state_set "$domain" CURRENT "$release_id"
  deploy_state_set "$domain" DEPLOYED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  deploy_state_set "$domain" SOURCE "$([[ -n $git_url ]] && echo "git ${git_url} ${ref} ${release_ref:-}" || [[ -n $archive ]] && echo "archive $(basename "$archive")" || echo "dir ${from}")"
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
  [[ -n "$to" ]] || to=$(find "${root}/releases" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r | grep -vx "$current" | head -n1)
  [[ -n "$to" && "$to" =~ ^[0-9]{14}(-[A-Za-z0-9._-]+)?$ && -d "${root}/releases/${to}" ]] || { error "No release to roll back to"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    echo "Rollback plan: ${current} -> ${to} (code only; database migrations are not reverted)"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  deploy_activate "$domain" "$root" "$php" "$to" "$(site_effective_user "$project")" || return 1
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
  ui_result_table "Domain|${domain}" "Source|$(deploy_state_get "$domain" SOURCE)" "Deployed at|$(deploy_state_get "$domain" DEPLOYED_AT)" "${rows[@]}"
}

register_cmd "site" "deploy" "Deploy a release (git ref, archive or directory) with atomic switch" "site_deploy_handler" "domain" "git= ref= archive= sha256= from= migrate= keep= confirm=" "tier:advanced"
register_cmd "site" "deploy-rollback" "Switch back to a previous release (code only)" "site_deploy_rollback_handler" "domain" "release= confirm=" "tier:advanced"
register_cmd "site" "deploy-status" "Show releases of a site" "site_deploy_status_handler" "domain" "" "tier:advanced"
