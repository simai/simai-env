#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=admin/lib/backup_utils.sh
source "${SCRIPT_DIR}/admin/lib/backup_utils.sh"

backup_archive_is_menu_compatible() {
  local file="$1"
  local base
  base=$(basename "$file")
  [[ "$base" == simai-env-preupdate-* ]] && return 1
  [[ "$base" == simai-env-manualsync-* ]] && return 1
  return 0
}

backup_archive_compat_error() {
  local file="$1"
  local base
  base=$(basename "$file")
  if [[ "$base" == simai-env-preupdate-* ]]; then
    error "This archive is a platform pre-update backup, not a site settings archive: ${file}"
    echo "Use one created by: simai-admin.sh backup export --domain <domain>"
    return 0
  fi
  if [[ "$base" == simai-env-manualsync-* ]]; then
    error "This archive is a manual platform sync backup, not a site settings archive: ${file}"
    echo "Use one created by: simai-admin.sh backup export --domain <domain>"
    return 0
  fi
  return 1
}

backup_export_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Backup export"
  require_args "domain" || return 1
  local domain="${PARSED_ARGS[domain]:-}"
  local out="${PARSED_ARGS[out]:-}"

  if ! require_site_exists "$domain"; then
    return 1
  fi
  read_site_metadata "$domain"
  local slug="${SITE_META[slug]:-}"
  local profile="${SITE_META[profile]:-}"
  local root="${SITE_META[root]:-}"
  local php="${SITE_META[php]:-none}"
  local public_dir
  if [[ -z "${SITE_META[public_dir]+x}" ]]; then
    public_dir="public"
  else
    public_dir="${SITE_META[public_dir]}"
  fi
  if [[ -z "$slug" || -z "$profile" || -z "$root" ]]; then
    error "Metadata incomplete for ${domain}; need slug/profile/root"
    return 1
  fi
  local doc_root
  doc_root=$(site_compute_doc_root "$root" "$public_dir") || return 1

  local timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  if [[ -z "$out" ]]; then
    out="/root/simai-backups/${domain}-${timestamp}.tar.gz"
  fi
  local out_dir
  out_dir=$(dirname "$out")
  mkdir -p "$out_dir"
  if [[ ! -w "$out_dir" ]]; then
    error "Output directory not writable: ${out_dir}"
    return 1
  fi

  progress_init 6
  progress_step "Collecting site data"

  local nginx_avail="/etc/nginx/sites-available/${domain}.conf"
  if [[ ! -f "$nginx_avail" ]]; then
    error "Nginx config missing: ${nginx_avail}"
    return 1
  fi
  local nginx_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  local enabled_flag="no"
  [[ -L "$nginx_enabled" ]] && enabled_flag="yes"

  local files_src=() files_dst=()
  files_src+=("$nginx_avail")
  files_dst+=("nginx/sites-available/${domain}.conf")

  local php_pool=""
  if [[ "${php}" != "none" ]]; then
    php_pool="/etc/php/${php}/fpm/pool.d/${slug}.conf"
    if [[ -f "$php_pool" ]]; then
      files_src+=("$php_pool")
      files_dst+=("php-fpm/pool.d/php${php}/${slug}.conf")
    fi
  fi

  local cron_file="/etc/cron.d/${slug}"
  if [[ -f "$cron_file" ]] && backup_is_simai_cron "$cron_file" "$slug" "$domain"; then
    files_src+=("$cron_file")
    files_dst+=("cron.d/${slug}")
  fi

  local queue_unit=""
  queue_unit=$(queue_unit_path "$slug" 2>/dev/null || true)
  if [[ -n "$queue_unit" && -f "$queue_unit" ]]; then
    files_src+=("$queue_unit")
    files_dst+=("systemd/$(basename "$queue_unit")")
  fi

  progress_step "Preparing bundle"
  local tmpdir
  tmpdir=$(mktemp -d)
  backup_stage_files "$tmpdir" files_src files_dst

  local enabled_marker="${tmpdir}/nginx/sites-enabled/${domain}.conf.symlink"
  mkdir -p "$(dirname "$enabled_marker")"
  printf "enabled: %s\n" "$enabled_flag" >"$enabled_marker"

  local notes="${tmpdir}/NOTES.txt"
  {
    echo "Config-only backup (no secrets, no SSL keys, no .env)"
    echo "Included:"
    printf " - nginx: %s (enabled: %s)\n" "$nginx_avail" "$enabled_flag"
    [[ -n "$php_pool" && -f "$php_pool" ]] && printf " - php-fpm: %s\n" "$php_pool"
    if [[ -f "$cron_file" ]]; then
      if backup_is_simai_cron "$cron_file" "$slug" "$domain"; then
        printf " - cron: %s\n" "$cron_file"
      fi
    fi
    [[ -n "$queue_unit" && -f "$queue_unit" ]] && printf " - systemd: %s\n" "$queue_unit"
    echo "Excluded: SSL private keys, .env, database dumps"
  } >"$notes"

  progress_step "Writing manifest"
  local enabled_bool="false"
  [[ "$enabled_flag" == "yes" ]] && enabled_bool="true"
  backup_write_manifest "$tmpdir" "$domain" "$slug" "$profile" "$php" "$public_dir" "$doc_root" "$enabled_bool"

  progress_step "Packaging"
  mkdir -p "$out_dir"
  backup_pack_archive "$tmpdir" "$out"

  progress_step "Cleaning up"
  rm -rf "$tmpdir"

  progress_step "Summary"
  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Archive|${out}" \
    "Profile|${profile}" \
    "PHP|${php}" \
    "Enabled|${enabled_flag}"
  ui_section "Next steps"
  ui_kv "Inspect archive" "simai-admin.sh backup inspect --file ${out}"
  ui_kv "Import plan" "simai-admin.sh backup import --file ${out} --apply no"
  info "Secrets are NOT included (no SSL keys, no .env)"
}

backup_inspect_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Backup inspect"
  require_args "file" || return 1
  local file="${PARSED_ARGS[file]:-}"
  if [[ ! -f "$file" ]]; then
    error "Backup file not found: ${file}"
    echo "Use: simai-admin.sh backup export --domain <domain>"
    return 1
  fi
  if backup_archive_compat_error "$file"; then
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  if ! backup_safe_extract_archive "$file" "$tmpdir"; then
    error "Failed to extract archive"
    rm -rf "$tmpdir"
    return 1
  fi
  local manifest="${tmpdir}/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    error "manifest.json missing in archive"
    echo "This command expects a site settings archive created by: simai-admin.sh backup export --domain <domain>"
    rm -rf "$tmpdir"
    return 1
  fi
  ui_section "Manifest"
  backup_print_manifest "$manifest"
  ui_section "Verification"
  info "Verifying checksums..."
  if ! backup_verify_checksums "$tmpdir" "$manifest"; then
    warn "Checksum verification failed"
    rm -rf "$tmpdir"
    return 1
  fi
  info "Checksums OK"
  ui_section "Next steps"
  ui_kv "Import plan" "simai-admin.sh backup import --file ${file} --apply no"
  rm -rf "$tmpdir"
}

backup_import_handler() {
  parse_kv_args "$@"
  ui_header "SIMAI ENV · Backup import"
  require_args "file" || return 1
  local file="${PARSED_ARGS[file]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local enable="${PARSED_ARGS[enable]:-no}"
  local reload="${PARSED_ARGS[reload]:-no}"
  [[ "${apply,,}" != "yes" ]] && apply="no"
  [[ "${enable,,}" != "yes" ]] && enable="no"
  [[ "${reload,,}" != "yes" ]] && reload="no"

  if [[ ! -f "$file" ]]; then
    error "Backup file not found: ${file}"
    echo "Use: simai-admin.sh backup export --domain <domain>"
    return 1
  fi
  if backup_archive_compat_error "$file"; then
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  if ! backup_safe_extract_archive "$file" "$tmpdir"; then
    error "Failed to extract archive"
    rm -rf "$tmpdir"
    return 1
  fi
  local manifest="${tmpdir}/manifest.json"
  if [[ ! -f "$manifest" ]]; then
    error "manifest.json missing in archive"
    echo "This command expects a site settings archive created by: simai-admin.sh backup export --domain <domain>"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! backup_verify_checksums "$tmpdir" "$manifest"; then
    error "Checksum verification failed; aborting"
    rm -rf "$tmpdir"
    return 1
  fi

  local mf=()
  mapfile -t mf < <(backup_manifest_fields "$manifest")
  local domain slug profile php public_dir doc_root enabled_flag
  domain="${mf[0]:-}"
  slug="${mf[1]:-}"
  profile="${mf[2]:-}"
  php="${mf[3]:-}"
  public_dir="${mf[4]:-}"
  doc_root="${mf[5]:-}"
  enabled_flag="${mf[6]:-}"
  if ! validate_domain "$domain" "allow"; then
    error "Invalid domain in manifest: ${domain}"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! validate_project_slug "$slug"; then
    error "Invalid slug in manifest: ${slug}"
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "$php" != "none" ]] && ! validate_php_version "$php"; then
    error "Invalid PHP version in manifest: ${php}"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! validate_public_dir "$public_dir"; then
    error "Invalid public_dir in manifest"
    rm -rf "$tmpdir"
    return 1
  fi

  backup_profile_contract "$profile" || true
  local profile_known="${BACKUP_PROFILE_KNOWN:-no}"
  local profile_enabled="${BACKUP_PROFILE_ENABLED:-unknown}"
  local profile_requires_php="${BACKUP_PROFILE_REQUIRES_PHP:-unknown}"
  local profile_supports_cron="${BACKUP_PROFILE_SUPPORTS_CRON:-unknown}"
  local profile_supports_queue="${BACKUP_PROFILE_SUPPORTS_QUEUE:-unknown}"
  local profile_note="${BACKUP_PROFILE_NOTE:-unknown}"

  ui_section "Plan"
  print_kv_table \
    "Domain|${domain}" \
    "Profile|${profile}" \
    "Profile known|${profile_known}" \
    "Profile enabled|${profile_enabled}" \
    "Profile requires PHP|${profile_requires_php}" \
    "Profile supports cron|${profile_supports_cron}" \
    "Profile supports queue|${profile_supports_queue}" \
    "Manifest PHP|${php}" \
    "Note|${profile_note}"
  backup_print_plan "$tmpdir" "$domain" "$slug" "$php"
  if [[ "$apply" != "yes" ]]; then
    if [[ "$profile_known" != "yes" ]]; then
      warn "Archive profile '${profile}' is not present locally; apply would be blocked."
    elif [[ "$profile_enabled" == "no" ]]; then
      warn "Archive profile '${profile}' is disabled locally; apply would be blocked."
    elif [[ "$profile_requires_php" == "yes" && "$php" == "none" ]]; then
      warn "Profile requires PHP, but manifest declares php=none; apply would be blocked."
    fi
    info "Dry-run only. To apply changes, run with --apply yes"
    ui_section "Next steps"
    ui_kv "Apply import" "simai-admin.sh backup import --file ${file} --apply yes"
    rm -rf "$tmpdir"
    return 0
  fi

  if [[ "$profile_known" != "yes" ]]; then
    error "Archive profile '${profile}' is not present in local profile registry"
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "$profile_enabled" == "no" ]]; then
    error "Archive profile '${profile}' is disabled. Enable it first: simai-admin.sh profile enable --id ${profile}"
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "$profile_requires_php" == "yes" && "$php" == "none" ]]; then
    error "Profile '${profile}' requires PHP, but manifest has php=none"
    rm -rf "$tmpdir"
    return 1
  fi
  if [[ "$profile_requires_php" == "no" && "$php" != "none" ]]; then
    warn "Manifest includes PHP pool for non-PHP profile '${profile}'; pool import will be attempted only if file exists."
  fi

  local timestamp
  timestamp=$(date +%Y%m%d%H%M%S)
  local rollback_paths=()
  if ! backup_apply_files "$tmpdir" "$domain" "$slug" "$php" "$enable" "$timestamp" "$profile_supports_cron" "$profile_supports_queue" rollback_paths; then
    backup_rollback rollback_paths
    error "Import failed; rollback applied"
    rm -rf "$tmpdir"
    return 1
  fi

  if [[ "$reload" == "yes" ]]; then
    if ! backup_reload_services "$domain" "$php"; then
      backup_rollback rollback_paths
      error "Service reload failed; rollback applied"
      rm -rf "$tmpdir"
      return 1
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "Domain|${domain}" \
    "Profile|${profile}" \
    "Applied|yes" \
    "Enable symlink|${enable}" \
    "Reload services|${reload}"
  ui_section "Next steps"
  ui_kv "Inspect archive" "simai-admin.sh backup inspect --file ${file}"
  info "Import applied successfully"
  rm -rf "$tmpdir"
}

register_cmd "backup" "export" "Export site configs to tar.gz (config-only)" "backup_export_handler" "domain" "out="
register_cmd "backup" "inspect" "Inspect backup archive" "backup_inspect_handler" "file" ""
register_cmd "backup" "import" "Import site configs from backup (dry-run by default)" "backup_import_handler" "file" "apply= enable= reload="
