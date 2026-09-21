#!/usr/bin/env bash

# Idempotent host migrations: brings servers installed by earlier releases in
# line with the current layout. Safe to run repeatedly; self update runs it.

self_migrate_observer_storage() {
  local legacy="${SIMAI_HOME}/runtime-observer" base dir slug target
  [[ -d "$legacy" && ! -L "$legacy" ]] || return 0
  base=$(observer_base)
  install -d -m 0700 -o root -g root "$base" || return 1
  for dir in "$legacy"/*/; do
    dir="${dir%/}"
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    slug=$(basename "$dir")
    target="${base}/${slug}"
    if [[ -e "$target" ]]; then
      warn "Observer storage ${target} already exists; leaving ${dir} for manual review"
      continue
    fi
    mv "$dir" "$target" || return 1
    chown -R root:root "$target"
    chmod -R go-rwx "$target"
    # The old location was reachable by site users: drop anything git could
    # execute (config drivers, hooks, attribute files) and start clean.
    if [[ -d "${target}/repo/.git" ]]; then
      rm -rf -- "${target}/repo/.git/hooks" "${target}/repo/.git/info/attributes"
      printf '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n\tlogallrefupdates = true\n' \
        >"${target}/repo/.git/config"
    fi
    # Session state is re-validated by observer_read_session on next use.
    info "Observer storage moved: ${dir} -> ${target}"
    SELF_MIGRATE_CHANGES+=("observer ${slug} -> ${target}")
  done
  rmdir "$legacy" 2>/dev/null || true
}

self_migrate_catchall() {
  local conf="/etc/nginx/sites-available/000-catchall.conf"
  command -v nginx >/dev/null 2>&1 || return 0
  grep -qs 'simai-catchall-v2' "$conf" && return 0
  local backup=""
  [[ -f "$conf" ]] && { backup=$(mktemp); cp -p "$conf" "$backup"; }
  ensure_nginx_catchall
  if nginx -t >>"$LOG_FILE" 2>&1; then
    os_svc_reload nginx || true
    grep -qs 'simai-catchall-v2' "$conf" && SELF_MIGRATE_CHANGES+=("catch-all answers 443")
  elif [[ -n "$backup" ]]; then
    cp -p "$backup" "$conf"
    warn "nginx -t failed with the new catch-all; previous catch-all restored"
  fi
  [[ -n "$backup" ]] && rm -f -- "$backup"
  return 0
}

self_migrate_home_owner() {
  local parent owner
  parent=$(dirname "$SIMAI_HOME")
  owner=$(stat -c '%U' "$parent" 2>/dev/null) || return 0
  [[ "$parent" == /home && "$owner" == "$SIMAI_BASE_USER" ]] || return 0
  chown root:root "$parent" && chmod 0755 "$parent" && SELF_MIGRATE_CHANGES+=("/home owner restored to root")
}

# Site users can read anything world-readable under the shared home. Report
# directories other than the web root and shared code checkouts.
self_migrate_report_open_home_dirs() {
  local dir name mode
  for dir in "$SIMAI_HOME"/*/; do
    dir="${dir%/}"
    [[ -d "$dir" && ! -L "$dir" ]] || continue
    name=$(basename "$dir")
    case "$name" in www|git|releases) continue ;; esac
    mode=$(stat -c '%a' "$dir")
    if (( (8#$mode & 8#005) != 0 )); then
      warn "${dir} (mode ${mode}) is readable by site users; if sites do not need it: chmod o-rwx ${dir}"
    fi
  done
  return 0
}

# Bitrix pools created by earlier releases kept the profile baseline inside
# the site ini block, so `site php-ini set` silently dropped short_open_tag.
self_migrate_bitrix_runtime() {
  local cfg domain project slug pool ver cron backup
  for cfg in /etc/nginx/sites-available/*.conf; do
    [[ -f "$cfg" ]] || continue
    grep -q '^# simai-profile: bitrix$' "$cfg" || continue
    domain=$(basename "$cfg" .conf)
    project=$(sed -n 's/^# simai-php-socket-project: *//p' "$cfg" | head -n1)
    [[ -n "$project" ]] || project=$(sed -n 's/^# simai-project: *//p' "$cfg" | head -n1)
    slug=$(sed -n 's/^# simai-slug: *//p' "$cfg" | head -n1)
    validate_project_slug "$project" 2>/dev/null || continue
    for pool in /etc/php/*/fpm/pool.d/"${project}".conf; do
      [[ -f "$pool" ]] || continue
      ver=$(awk -F/ '{print $4}' <<<"$pool")
      site_ensure_bitrix_cli_ini "$ver"
      grep -q '; simai-profile-ini-begin' "$pool" && continue
      backup=$(mktemp) && cp -p "$pool" "$backup"
      bitrix_profile_ini_block >>"$pool"
      if command -v "php-fpm${ver}" >/dev/null 2>&1 && ! "php-fpm${ver}" -t >>"$LOG_FILE" 2>&1; then
        cp -p "$backup" "$pool"
        warn "Could not add the Bitrix profile block to ${pool}; left unchanged"
      else
        os_svc_reload "php${ver}-fpm" >/dev/null 2>&1 || true
        SELF_MIGRATE_CHANGES+=("${domain}: Bitrix PHP baseline moved to the profile block (php ${ver})")
      fi
      rm -f -- "$backup"
    done
    cron="/etc/cron.d/${slug:-$project}"
    if [[ -f "$cron" ]] && grep -q 'cron_events\.php' "$cron" && ! grep -q 'short_open_tag=1.*cron_events\.php' "$cron"; then
      sed -i -E 's#(/php[0-9.]*) (public/bitrix/modules/main/tools/cron_events\.php)#\1 -d short_open_tag=1 \2#' "$cron"
      SELF_MIGRATE_CHANGES+=("${domain}: cron runs Bitrix agents with short_open_tag")
    fi
  done
  return 0
}

self_migrate_handler() {
  parse_kv_args "$@"
  declare -ga SELF_MIGRATE_CHANGES=()
  ui_header "SIMAI ENV · Host migrations"
  self_migrate_home_owner || warn "Could not repair /home ownership"
  ensure_simai_logrotate
  self_migrate_observer_storage || warn "Observer storage migration failed"
  self_migrate_catchall
  self_migrate_bitrix_runtime
  if [[ ${#SELF_MIGRATE_CHANGES[@]} -eq 0 ]]; then
    info "Host is up to date; nothing to migrate"
  else
    local change
    for change in "${SELF_MIGRATE_CHANGES[@]}"; do info "Migrated: ${change}"; done
  fi
  local legacy=0 f
  for f in /etc/php/*/fpm/pool.d/*.conf; do
    [[ -f "$f" ]] && grep -q "^user = ${SIMAI_BASE_USER}\$" "$f" && legacy=$((legacy + 1))
  done
  if (( legacy > 0 )); then
    warn "${legacy} PHP pool(s) still run as the shared ${SIMAI_BASE_USER} user; migrate them with: simai-admin.sh site isolate --domain <domain>"
  fi
  self_migrate_report_open_home_dirs
  return 0
}

register_cmd "self" "migrate" "Apply idempotent host migrations after an update" "self_migrate_handler" "" "" "tier:advanced"
