#!/usr/bin/env bash
set -euo pipefail

site_add_handler() {
  parse_kv_args "$@"
  require_args "domain"

  local domain="${PARSED_ARGS[domain]}"
  local path_style="${SIMAI_DEFAULT_PATH_STYLE:-domain}"
  if [[ -n "${PARSED_ARGS[path-style]:-}" ]]; then
    path_style="${PARSED_ARGS[path-style]}"
  fi
  case "$path_style" in
    slug|domain) ;;
    *)
      error "Invalid path-style: ${path_style} (use slug or domain)"
      return 1
      ;;
  esac
  if ! validate_domain "$domain"; then
    return 1
  fi
  local project="${PARSED_ARGS[project-name]:-}"
  local profile="${PARSED_ARGS[profile]:-}"
  local php_version="${PARSED_ARGS[php]:-}"
  local create_db="${PARSED_ARGS[create-db]:-}"
  local db_export_opt="${PARSED_ARGS[db-export]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  local target_domain="${PARSED_ARGS[target-domain]:-}" target_path="" target_project="" target_php=""
  local path_created=0 path_empty=0 need_post_bootstrap_marker_check=0
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  if ! validate_project_slug "$project"; then
    return 1
  fi
  local path="${PARSED_ARGS[path]:-}"
  if [[ -z "$path" ]]; then
    path="${WWW_ROOT}/${domain}"
    if [[ "$path_style" == "slug" ]]; then
      path="${WWW_ROOT}/${project}"
    fi
  fi
  if ! validate_path "$path"; then
    return 1
  fi

  ensure_user
  local profiles_available=()
  mapfile -t profiles_available < <(list_enabled_profile_ids 2>/dev/null || true)
  local fallback_profiles=("generic" "laravel" "static" "alias")
  if [[ -z "$profile" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local ordered=()
    for p in "${fallback_profiles[@]}"; do
      if [[ ${#profiles_available[@]} -eq 0 ]]; then
        ordered+=("$p")
      else
        if printf '%s\n' "${profiles_available[@]}" | grep -qx "$p"; then
          ordered+=("$p")
        fi
      fi
    done
      if [[ ${#profiles_available[@]} -gt 0 ]]; then
        for p in "${profiles_available[@]}"; do
        if [[ ! " ${ordered[*]} " =~ [[:space:]]${p}[[:space:]] ]]; then
          ordered+=("$p")
        fi
      done
    fi
    if [[ ${#ordered[@]} -eq 0 ]]; then
      ordered=("${fallback_profiles[@]}")
    fi
    local default_profile="generic"
    if ! printf '%s\n' "${ordered[@]}" | grep -qx "generic"; then
      default_profile="${ordered[0]}"
    fi
    profile=$(select_from_list "Select profile" "$default_profile" "${ordered[@]}")
    [[ -z "$profile" ]] && profile="$default_profile"
  fi
  [[ -z "$profile" ]] && profile="generic"
  if [[ ${#profiles_available[@]} -eq 0 ]]; then
    if [[ ! " ${fallback_profiles[*]} " =~ [[:space:]]${profile}[[:space:]] ]]; then
      error "Unknown profile: ${profile}."
      return 1
    fi
  else
    if ! is_profile_known "$profile"; then
      local avail
      avail=$(list_profile_ids 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
      error "Unknown profile: ${profile}. Available: ${avail}"
      return 1
    fi
    if ! is_profile_enabled "$profile"; then
      error "Profile '${profile}' is disabled. Enable it: simai-admin.sh profile enable --id ${profile}"
      return 1
    fi
  fi

  load_profile "$profile" || return 1

  if [[ "${PROFILE_IS_ALIAS:-no}" == "yes" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    if [[ -z "$target_domain" ]]; then
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
        if [[ ${#sites[@]} -eq 0 ]]; then
          error "No existing sites to alias"
          return 1
        fi
        target_domain=$(select_from_list "Select target site for alias" "" "${sites[@]}")
      else
        error "Target site is required for alias; use --target-domain"
        return 1
      fi
    fi
    if [[ -z "$target_domain" ]]; then
      error "Target site is required for alias"
      return 1
    fi
    if [[ ${#sites[@]} -eq 0 ]]; then
      mapfile -t sites < <(list_sites)
    fi
    if ! printf '%s\n' "${sites[@]}" | grep -qx "$target_domain"; then
      error "Target site ${target_domain} not found on this host"
      return 1
    fi
    local target_cfg="/etc/nginx/sites-available/${target_domain}.conf"
    declare -A target_meta=()
    if ! site_nginx_metadata_parse "$target_cfg" target_meta; then
      error "Target site metadata is missing or unreadable for ${target_domain}."
      echo "Fix target metadata first: simai-admin.sh site drift --domain ${target_domain} --fix yes (or restore # simai-* header manually)"
      return 1
    fi
    target_path="${target_meta[root]}"
    target_project="${target_meta[project]:-${target_meta[slug]:-}}"
    if ! validate_project_slug "${target_project:-}"; then
      local safe_target
      safe_target=$(project_slug_from_domain "$target_domain")
      warn "Target project slug '${target_project:-<empty>}' is invalid; using safe slug ${safe_target} for socket/project references"
      target_project="$safe_target"
    fi
    target_php="${target_meta[php]:-none}"
    if [[ -n "$target_path" ]] && ! validate_path "$target_path"; then
      error "Target site root ${target_path} is invalid"
      return 1
    fi
    local target_profile="${target_meta[profile]:-}"
    if [[ -z "$target_profile" ]]; then
      error "Target site profile is unknown; refusing to create alias."
      echo "Run: simai-admin.sh site drift --domain ${target_domain} --fix yes (or restore # simai-* header manually)"
      return 1
    fi
    if ! load_profile "$target_profile"; then
      error "Failed to load profile ${target_profile} for target ${target_domain}"
      return 1
    fi
    local alias_template
    if ! alias_template=$(resolve_profile_nginx_template_path); then
      return 1
    fi
    [[ -z "$target_project" ]] && target_project=$(project_slug_from_domain "$target_domain")
    [[ -z "$target_path" ]] && target_path="${WWW_ROOT}/${target_domain}"
    php_version="${target_php:-none}"
    [[ "${PROFILE_REQUIRES_PHP}" == "no" ]] && php_version="none"
    local template_id="${target_meta[nginx_template]:-${target_profile}}"
    local target_socket_project="${target_meta[php_socket_project]:-$target_project}"
    local target_public_dir
    if [[ -z "${target_meta[public_dir]+x}" ]]; then
      target_public_dir="public"
    else
      target_public_dir="${target_meta[public_dir]}"
    fi
    create_nginx_site "$domain" "$project" "$target_path" "$php_version" "$alias_template" "alias" "$target_domain" "$target_socket_project" "" "" "" "no" "no" "$template_id" "$target_public_dir"
    site_nginx_metadata_upsert "/etc/nginx/sites-available/${domain}.conf" "$domain" "$project" "alias" "$target_path" "$project" "$php_version" "none" "" "$target_domain" "$target_socket_project" "$template_id" "$target_public_dir" >/dev/null 2>&1 || true
    info "Alias added: domain=${domain}, target=${target_domain}, php=${php_version}"
    echo "===== Site summary ====="
    echo "Domain      : ${domain}"
    echo "Project     : ${project}"
    echo "Profile     : alias"
    echo "Target site : ${target_domain}"
    echo "PHP version : ${php_version}"
    echo "Root path   : ${target_path}"
    echo "Nginx conf  : /etc/nginx/sites-available/${domain}.conf"
    echo "Healthcheck : uses target site (${target_domain})"
    echo "Log file    : ${LOG_FILE}"
    return
  fi

  if [[ ! -d "$path" ]]; then
    info "Project path not found, creating: $path"
    mkdir -p "$path"
    path_created=1
    path_empty=1
  else
    if [[ -z "$(ls -A "$path" 2>/dev/null)" ]]; then
      path_empty=1
    fi
  fi
  if ! validate_path "$path"; then
    return 1
  fi

  if [[ ${#PROFILE_REQUIRED_MARKERS[@]} -gt 0 ]]; then
    if ! ensure_profile_required_markers "$path"; then
      if [[ $path_created -eq 1 || $path_empty -eq 1 ]]; then
        need_post_bootstrap_marker_check=1
      else
        if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
          local choice
          choice=$(select_from_list "Required files not found for profile ${profile}. Fallback to generic?" "yes" "yes" "no")
          if [[ "$choice" == "yes" ]]; then
            profile="generic"
            load_profile "$profile" || return 1
          else
            return 1
          fi
        else
          return 1
        fi
      fi
    fi
  fi

  local public_dir="${PROFILE_PUBLIC_DIR}"
  ensure_profile_public_dir "$path"
  ensure_profile_bootstrap_files "$path"
  if [[ "${PROFILE_IS_ALIAS:-no}" != "yes" && $need_post_bootstrap_marker_check -eq 1 ]]; then
    if [[ ${#PROFILE_REQUIRED_MARKERS[@]} -gt 0 ]] && ! ensure_profile_required_markers "$path"; then
      error "Required markers are still missing for profile ${profile} after bootstrap"
      return 1
    fi
  fi

  if [[ "${PROFILE_REQUIRES_PHP}" == "no" ]]; then
    if [[ -n "$php_version" && "$php_version" != "none" ]]; then
      warn "--php is ignored for profile ${profile} (no PHP runtime)"
    fi
    php_version="none"
  else
    php_version=$(select_php_version_for_profile "$php_version") || return 1
  fi

  local template_path
  template_path=$(resolve_profile_nginx_template_path) || return 1

  ensure_project_permissions "$path"

  if [[ "$php_version" != "none" ]]; then
    create_php_pool "$project" "$php_version" "$path"
  fi

  local ssl_redirect="no" ssl_hsts="no"
  local doc_root
  doc_root=$(site_compute_doc_root "$path" "$public_dir") || return 1
  create_nginx_site "$domain" "$project" "$path" "$php_version" "$template_path" "$profile" "" "$project" "" "" "" "$ssl_redirect" "$ssl_hsts" "" "$public_dir"

  local healthcheck_summary="disabled"
  if [[ "${PROFILE_HEALTHCHECK_ENABLED:-no}" == "yes" ]]; then
    if [[ "${PROFILE_HEALTHCHECK_MODE:-php}" == "php" ]]; then
      install_healthcheck "$doc_root"
      healthcheck_summary="local-only (curl -i -H \"Host: ${domain}\" http://127.0.0.1/healthcheck.php)"
    else
      healthcheck_summary="local-only via nginx (/healthcheck)"
    fi
  fi

  local cron_summary="none"
  if [[ "${PROFILE_SUPPORTS_CRON:-no}" == "yes" ]]; then
    cron_site_write "$domain" "$project" "$profile" "$path" "$php_version"
    cron_summary="/etc/cron.d/${project} (created/updated)"
  fi

  local db_summary="not requested"
  if [[ "${PROFILE_REQUIRES_DB}" != "no" ]]; then
    create_db=$(decide_create_db_for_profile) || return 1
  else
    [[ -n "$create_db" && "${create_db,,}" == "yes" ]] && warn "Database creation ignored for profile ${profile}"
    create_db="no"
  fi

  if [[ "$create_db" == "yes" ]]; then
    local charset="${PROFILE_DB_CHARSET:-utf8mb4}"
    local coll="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
    site_db_load_or_generate_creds "$domain" "$project" "$charset" "$coll" || return 1
    local privs=()
    if [[ -n "${PROFILE_DB_REQUIRED_PRIVILEGES+x}" && ${#PROFILE_DB_REQUIRED_PRIVILEGES[@]} -gt 0 ]]; then
      privs=("${PROFILE_DB_REQUIRED_PRIVILEGES[@]}")
    else
      mapfile -t privs < <(db_default_privileges)
    fi
    info "Creating database ${DB_CREDS_NAME} with user ${DB_CREDS_USER}"
    if ! site_db_apply_create "$domain" "$DB_CREDS_NAME" "$DB_CREDS_USER" "$DB_CREDS_PASS" "$DB_CREDS_CHARSET" "$DB_CREDS_COLLATION" "${privs[@]}"; then
      return 1
    fi
    db_summary="created"
    local do_export="no"
    if [[ "$profile" == "generic" ]]; then
      do_export="yes"
    elif [[ "${PROFILE_REQUIRES_DB}" == "required" ]]; then
      if [[ -n "$db_export_opt" ]]; then
        [[ "${db_export_opt,,}" == "yes" ]] && do_export="yes" || do_export="no"
      elif [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
        local choice
        choice=$(select_from_list "Export DB creds to .env now?" "yes" "yes" "no")
        [[ "$choice" == "yes" ]] && do_export="yes" || do_export="no"
      else
        do_export="yes"
      fi
    fi
    if [[ "$do_export" == "yes" ]]; then
      site_db_export_to_env "$domain" "$path" ".env" || warn "Failed to export DB creds to ${path}/.env"
    fi
  fi

  info "Site added: domain=${domain}, project=${project}, path=${path}, php=${php_version}, profile=${profile}"

  echo "===== Site summary ====="
  echo "Domain      : ${domain}"
  echo "Project     : ${project}"
  echo "Profile     : ${profile}"
  echo "PHP version : ${php_version}"
  echo "Path        : ${path}"
  echo "Nginx conf  : /etc/nginx/sites-available/${domain}.conf"
  if [[ "$php_version" == "none" ]]; then
    echo "PHP-FPM pool: none"
  else
    echo "PHP-FPM pool: /etc/php/${php_version}/fpm/pool.d/${project}.conf"
  fi
  echo "Cron file   : ${cron_summary}"
  if [[ "$create_db" == "yes" ]]; then
    echo "DB name     : ${DB_CREDS_NAME}"
    echo "DB user     : ${DB_CREDS_USER}"
    echo "DB password : ${DB_CREDS_PASS} (not logged)"
  else
    echo "Database    : ${db_summary}"
  fi
  echo "Healthcheck : ${healthcheck_summary}"
  echo "Log file    : ${LOG_FILE}"
}

site_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local project="${PARSED_ARGS[project-name]:-}"
  local confirm="${PARSED_ARGS[confirm]:-}"
  local dry_run="${PARSED_ARGS[dry-run]:-}"
  local is_dry_run=0 show_plan_first=0
  case "${dry_run,,}" in
    yes|true|1) is_dry_run=1 ;;
    *) is_dry_run=0 ;;
  esac
  local remove_files="${PARSED_ARGS[remove-files]:-}"
  local drop_db="${PARSED_ARGS[drop-db]:-}"
  local drop_user="${PARSED_ARGS[drop-db-user]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  local path="${PARSED_ARGS[path]:-}"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "${PARSED_ARGS[dry-run]:-}" ]]; then
    local mode_choice
    mode_choice=$(select_from_list "Select remove mode" "plan" "plan" "apply")
    case "$mode_choice" in
      plan) is_dry_run=1 ;;
      apply) show_plan_first=1; is_dry_run=0 ;;
    esac
  fi

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain to remove" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi

  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local root="${SITE_META[root]:-${WWW_ROOT}/${domain}}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local php_version="${SITE_META[php]:-}"
  local safe_project="$project"

  if ! validate_project_slug "$project"; then
    safe_project=$(project_slug_from_domain "$domain")
    warn "Site metadata project slug '${project}' is invalid; using safe slug ${safe_project} for derived paths"
  fi
  if [[ -z "$socket_project" ]] || ! validate_project_slug "$socket_project"; then
    socket_project="$safe_project"
  fi

  [[ -z "$path" ]] && path="$root"
  local root_valid=1
  if ! validate_path "$path"; then
    root_valid=0
    warn "Project root path ${path} is invalid; file removal will be skipped"
  fi

  if ! load_profile "$profile"; then
    error "Failed to load profile ${profile} for ${domain}"
    return 1
  fi
  local requires_php="${PROFILE_REQUIRES_PHP:-yes}"
  local supports_cron="${PROFILE_SUPPORTS_CRON:-no}"
  local is_alias="${PROFILE_IS_ALIAS:-no}"
  local requires_db="${PROFILE_REQUIRES_DB:-no}"
  local supports_queue="${PROFILE_SUPPORTS_QUEUE:-no}"

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    if [[ "$is_alias" == "yes" ]]; then
      remove_files="no"
      drop_db="no"
      drop_user="no"
    else
      [[ -z "$remove_files" ]] && remove_files=$(select_from_list "Remove project files?" "no" "no" "yes")
      if [[ "${requires_db}" == "no" ]]; then
        drop_db="no"
        drop_user="no"
      else
        if [[ -z "$drop_db" ]]; then
          drop_db=$(select_from_list "Drop database?" "no" "no" "yes")
        fi
        if [[ "${drop_db,,}" == "yes" && -z "$drop_user" ]]; then
          drop_user=$(select_from_list "Drop DB user?" "no" "no" "yes")
        fi
      fi
    fi
  else
    if [[ "$is_alias" == "yes" ]]; then
      if [[ "${remove_files,,}" == "yes" || "${drop_db,,}" == "yes" || "${drop_user,,}" == "yes" ]]; then
        error "Alias profile does not own filesystem/DB resources; refusing to remove files or DB. Remove on target site instead."
        return 1
      fi
      if [[ -n "${PARSED_ARGS[path]:-}" ]]; then
        error "Alias uses target root; --path override is not applicable."
        return 1
      fi
    else
      if [[ "${requires_db}" == "no" && ( "${drop_db,,}" == "yes" || "${drop_user,,}" == "yes" ) ]]; then
        error "Database removal is not applicable for profile ${profile}."
        return 1
      fi
      if [[ $is_dry_run -eq 0 ]]; then
        local destructive=0
        [[ "${remove_files,,}" == "yes" ]] && destructive=1
        [[ "${drop_db,,}" == "yes" ]] && destructive=1
        [[ "${drop_user,,}" == "yes" ]] && destructive=1
        if [[ $destructive -eq 1 ]]; then
          case "${confirm,,}" in
            yes|true|1) ;;
            *) error "Destructive flags set; add --confirm yes"; return 1 ;;
          esac
        fi
      fi
    fi
  fi

  [[ "${remove_files,,}" == "yes" ]] && remove_files=1 || remove_files=0
  [[ "${drop_db,,}" == "yes" ]] && drop_db=1 || drop_db=0
  [[ "${drop_user,,}" == "yes" ]] && drop_user=1 || drop_user=0
  if [[ "${requires_db}" == "no" ]]; then
    drop_db=0; drop_user=0
  fi
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
      esac
    done <<<"$read_env"
  fi
  if (( drop_db == 1 )) && [[ -z "$db_name" ]]; then
    error "db.env missing; provide --db-name to drop database"
    return 1
  fi
  if (( drop_user == 1 )) && [[ -z "$db_user" ]]; then
    error "db.env missing; provide --db-user to drop DB user"
    return 1
  fi
  [[ -z "$db_name" ]] && db_name="${safe_project}"
  [[ -z "$db_user" ]] && db_user="${safe_project}"

  print_remove_plan() {
    local mode_desc st
    if [[ $is_dry_run -eq 1 ]]; then
      mode_desc="dry-run (no changes)"
    elif [[ $show_plan_first -eq 1 ]]; then
      mode_desc="plan preview (apply selected)"
    else
      mode_desc="apply"
    fi
    echo "===== Site remove plan (dry-run) ====="
    echo "Domain     : ${domain}"
    echo "Profile    : ${profile}"
    echo "Mode       : ${mode_desc}"
    echo
    echo "Nginx"
    local avail="/etc/nginx/sites-available/${domain}.conf"
    local enabled="/etc/nginx/sites-enabled/${domain}.conf"
    local st
    [[ -e "$avail" ]] && st="exists" || st="missing"
    echo "- ${avail} : would remove (${st})"
    [[ -e "$enabled" || -L "$enabled" ]] && st="exists" || st="missing"
    echo "- ${enabled} : would remove (${st})"
    echo
    echo "PHP-FPM (profile-aware)"
    if [[ "$is_alias" == "yes" || "${requires_php}" == "no" ]]; then
      echo "- skipped (profile does not manage PHP for removal)"
    else
      local plan_versions=()
      if [[ -n "$php_version" && "$php_version" != "none" ]]; then
        plan_versions+=("$php_version")
      else
        shopt -s nullglob
        local pool
        for pool in /etc/php/*/fpm/pool.d/${socket_project}.conf; do
          plan_versions+=("$(echo "$pool" | awk -F'/' '{print $4}')")
        done
        shopt -u nullglob
      fi
      if [[ ${#plan_versions[@]} -eq 0 ]]; then
        echo "- No pool files discovered for ${socket_project}"
      else
        local ver
        for ver in "${plan_versions[@]}"; do
          local pool_file="/etc/php/${ver}/fpm/pool.d/${socket_project}.conf"
          local sock="/run/php/php${ver}-fpm-${socket_project}.sock"
          [[ -e "$pool_file" ]] && st="exists" || st="missing"
          echo "- ${pool_file} : would remove (${st})"
          [[ -S "$sock" ]] && st="exists" || st="missing"
          echo "  socket ${sock} : ${st}"
        done
      fi
    fi
    echo
    echo "Cron"
    if [[ "$is_alias" == "yes" || "${supports_cron}" != "yes" || "${requires_php}" == "no" ]]; then
      echo "- skipped"
    else
      local cron_file="/etc/cron.d/${safe_project}"
      [[ -e "$cron_file" ]] && st="exists" || st="missing"
      echo "- ${cron_file} : would remove (${st})"
    fi
    echo
    echo "Queue"
    if [[ "$is_alias" == "yes" || "${supports_queue}" != "yes" || "${requires_php}" == "no" ]]; then
      echo "- skipped"
    else
      local unit st
      if unit=$(queue_unit_path "$safe_project"); then
        [[ -e "$unit" ]] && st="exists" || st="missing"
        echo "- ${unit} : would remove (${st})"
      else
        local unit_name
        unit_name=$(queue_unit_name "$safe_project" 2>/dev/null || echo "<invalid queue unit>")
        echo "- ${unit_name} : skipped (invalid project slug)"
      fi
    fi
    echo
    echo "Files"
    if [[ "$is_alias" == "yes" ]]; then
      echo "- ${path} : skipped (alias profile)"
    elif [[ $root_valid -eq 0 ]]; then
      echo "- ${path} : skipped (invalid path)"
    elif [[ $remove_files -eq 1 ]]; then
      [[ -e "$path" ]] && st="exists" || st="missing"
      echo "- ${path} : would remove (${st})"
    else
      echo "- ${path} : would keep"
    fi
    echo
    echo "Database"
    if [[ "$is_alias" == "yes" || "${requires_db}" == "no" ]]; then
      echo "- DB ${db_name} : skipped"
      echo "- User ${db_user} : skipped"
    else
      if [[ $drop_db -eq 1 ]]; then
        echo "- DB ${db_name} : would drop"
      else
        echo "- DB ${db_name} : would keep"
      fi
      if [[ $drop_user -eq 1 ]]; then
        echo "- User ${db_user} : would drop"
      else
        echo "- User ${db_user} : would keep"
      fi
    fi
    echo
    echo "Hint: to apply removal, run without --dry-run yes (CLI requires --confirm yes when destructive flags are set)"
  }

  print_remove_plan
  if [[ $is_dry_run -eq 1 ]]; then
    return 0
  fi
  if [[ $show_plan_first -eq 1 ]]; then
    local proceed
    proceed=$(select_from_list "Proceed with removal now?" "no" "no" "yes")
    if [[ "$proceed" != "yes" ]]; then
      return 0
    fi
  fi

  progress_init 5
  progress_step "Removing nginx configuration"
  if ! remove_nginx_site "$domain"; then
    error "Failed to remove nginx config for ${domain}"
    return 1
  fi

  progress_step "Removing PHP/queue resources (profile-aware)"
  local removed_queue=0 removed_cron=0
  if [[ "$is_alias" == "yes" ]]; then
    info "Profile is alias; skipping PHP/cron/queue removal"
  else
    if [[ "${requires_php}" != "no" ]]; then
      if [[ -n "$php_version" ]]; then
        remove_php_pool_version "$socket_project" "$php_version" || true
      else
        remove_php_pools "$socket_project" || true
      fi
    fi
    if [[ "${supports_cron}" == "yes" && "${requires_php}" != "no" ]]; then
      remove_cron_file "$safe_project" && removed_cron=1 || removed_cron=0
      local legacy_info legacy_state legacy_user
      legacy_info=$(cron_legacy_detect_any "$domain")
      IFS="|" read -r legacy_state legacy_user _ <<<"$legacy_info"
      if [[ "$legacy_state" == "marked" && -n "$legacy_user" ]]; then
        if cron_legacy_remove_marked "$domain" "$legacy_user"; then
          removed_cron=1
        else
          warn "Failed to remove marked legacy cron for ${legacy_user}; manual cleanup may be required"
        fi
      elif [[ "$legacy_state" == "suspect" ]]; then
        warn "Legacy cron lines without safe markers detected for ${domain} (user=${legacy_user:-unknown}); not removing automatically"
      fi
    fi
    if [[ "${supports_queue}" == "yes" && "${requires_php}" != "no" ]]; then
      remove_queue_unit "$safe_project" && removed_queue=1 || removed_queue=0
    fi
  fi

  progress_step "Removing project files (if approved)"
  if [[ $remove_files -eq 1 ]]; then
    if [[ $root_valid -eq 1 ]]; then
      remove_project_files "$path"
    else
      warn "Skipping file removal due to invalid path"
    fi
  fi

  progress_step "Dropping database (if approved)"
  if [[ $drop_db -eq 1 ]]; then
    if ! db_validate_db_name "$db_name"; then return 1; fi
    if ! site_db_apply_drop "$domain" "$db_name" "" "no"; then
      warn "Failed to drop database ${db_name}"
    fi
  fi

  progress_step "Dropping database user (if approved)"
  if [[ $drop_user -eq 1 ]]; then
    if ! db_validate_db_user "$db_user"; then return 1; fi
    if ! site_db_apply_drop "$domain" "" "$db_user" "no"; then
      warn "Failed to drop user ${db_user}"
    fi
  fi

  info "Site remove completed for ${domain}"
  local php_summary="none"
  if [[ "$is_alias" != "yes" && "${requires_php}" != "no" ]]; then
    php_summary="$([[ -n "$php_version" ]] && echo removed || echo cleaned)"
  fi
  local cron_summary
  cron_summary="$([[ $removed_cron -eq 1 ]] && echo removed || echo none)"
  local queue_summary
  queue_summary="$([[ $removed_queue -eq 1 ]] && echo removed || echo none)"
  local db_summary
  db_summary="$([[ $drop_db -eq 1 ]] && echo dropped || echo kept)"
  local db_user_summary
  db_user_summary="$([[ $drop_user -eq 1 ]] && echo dropped || echo kept)"
  local files_summary
  files_summary="$([[ $remove_files -eq 1 ]] && echo removed || echo kept)"
  if [[ "$is_alias" == "yes" ]]; then
    php_summary="skipped (alias profile)"
    cron_summary="skipped (alias profile)"
    queue_summary="skipped (alias profile)"
    db_summary="n/a"
    db_user_summary="n/a"
    files_summary="skipped (alias profile)"
  elif [[ "${requires_php}" == "no" ]]; then
    php_summary="n/a (profile without PHP)"
  fi
  echo "===== Site remove summary ====="
  echo "Domain     : ${domain}"
  echo "Profile    : ${profile}"
  echo "Nginx      : removed"
  echo "PHP-FPM    : ${php_summary}"
  echo "Cron       : ${cron_summary}"
  echo "Queue unit : ${queue_summary}"
  echo "Files      : ${files_summary}"
  if [[ "$is_alias" == "yes" || "${requires_db}" == "no" ]]; then
    echo "Database   : skipped (profile=${profile})"
    echo "DB user    : skipped (profile=${profile})"
  else
    echo "Database   : ${db_summary}"
    echo "DB user    : ${db_user_summary}"
  fi
}

site_set_php_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local php_version="${PARSED_ARGS[php]:-}"
  local keep_old_pool="${PARSED_ARGS[keep-old-pool]:-}"
  local project=""
  local profile=""

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=() filtered=()
    mapfile -t sites < <(list_sites)
    for s in "${sites[@]}"; do
      read_site_metadata "$s"
      filtered+=("$s")
    done
    domain=$(select_from_list "Select site" "" "${filtered[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi

  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi

  read_site_metadata "$domain"
  profile="${SITE_META[profile]:-generic}"
  project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local root="${SITE_META[root]:-${WWW_ROOT}/${domain}}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local old_php="${SITE_META[php]:-}"
  local safe_project="$project"

  if ! validate_project_slug "$project"; then
    safe_project=$(project_slug_from_domain "$domain")
    warn "Site metadata project slug '${project}' is invalid; using safe slug ${safe_project} for derived paths"
  fi
  if [[ -z "$socket_project" ]] || ! validate_project_slug "$socket_project"; then
    socket_project="$safe_project"
  fi
  if ! validate_path "$root"; then
    error "Project root path ${root} is invalid in metadata"
    return 1
  fi
  if ! load_profile "$profile"; then
    error "Failed to load profile ${profile} for ${domain}"
    return 1
  fi
  local supports_cron="${PROFILE_SUPPORTS_CRON:-no}"
  local supports_queue="${PROFILE_SUPPORTS_QUEUE:-no}"
  if [[ "${PROFILE_IS_ALIAS:-no}" == "yes" ]]; then
    error "Alias inherits target; change PHP on the target site instead."
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_PHP}" == "no" ]]; then
    error "Profile ${profile} does not use PHP."
    return 1
  fi
  if [[ "${PROFILE_ALLOW_PHP_SWITCH:-yes}" == "no" ]]; then
    error "PHP switch is not allowed for profile ${profile}."
    return 1
  fi

  php_version=$(select_php_version_for_profile "$php_version") || return 1
  if [[ -z "$keep_old_pool" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    keep_old_pool=$(select_from_list "Keep old PHP-FPM pool?" "no" "no" "yes")
  fi
  [[ "$keep_old_pool" == "yes" ]] && keep_old_pool="yes" || keep_old_pool="no"

  if [[ "$php_version" == "$old_php" ]]; then
    info "PHP version for ${domain} is already ${php_version}; nothing to change."
    return 0
  fi

  progress_init 4
  progress_step "Preparing PHP-FPM pool"
  if ! create_php_pool "$socket_project" "$php_version" "$root"; then
    error "Failed to create PHP-FPM pool for ${socket_project}"
    return 1
  fi

  local nginx_cfg="/etc/nginx/sites-available/${domain}.conf"
  local nginx_cfg_enabled="/etc/nginx/sites-enabled/${domain}.conf"
  local nginx_backup=""
  if [[ -f "$nginx_cfg" ]]; then
    nginx_backup=$(mktemp "/tmp/simai-nginx-${domain}.XXXX.conf")
    cp -p "$nginx_cfg" "$nginx_backup" >>"$LOG_FILE" 2>&1 || nginx_backup=""
  fi

  progress_step "Patching nginx upstream"
  if ! nginx_patch_php_socket "$domain" "$php_version" "$socket_project"; then
    [[ -n "$nginx_backup" && -f "$nginx_backup" ]] && cp -p "$nginx_backup" "$nginx_cfg" >>"$LOG_FILE" 2>&1 || true
    remove_php_pool_version "$socket_project" "$php_version" || true
    return 1
  fi
  site_nginx_metadata_upsert "$nginx_cfg" "$domain" "$safe_project" "$profile" "$root" "$project" "$php_version" "${SITE_META[ssl]:-unknown}" "" "${SITE_META[target]:-}" "$socket_project" "${SITE_META[nginx_template]:-$profile}" "${SITE_META[public_dir]}" >/dev/null 2>&1 || true

  progress_step "Validating nginx configuration"
  if ! nginx -t >>"$LOG_FILE" 2>&1; then
    error "nginx config test failed after updating PHP socket"
    if [[ -n "$nginx_backup" && -f "$nginx_backup" ]]; then
      cp -p "$nginx_backup" "$nginx_cfg" >>"$LOG_FILE" 2>&1 || true
      ln -sf "$nginx_cfg" "$nginx_cfg_enabled"
    fi
    remove_php_pool_version "$socket_project" "$php_version" || true
    return 1
  fi

  if [[ -f "$(site_php_ini_file "$domain")" ]]; then
    local _site_overrides=()
    mapfile -t _site_overrides < <(read_site_php_ini_overrides "$domain")
    if [[ ${#_site_overrides[@]} -gt 0 ]]; then
      info "Applying stored per-site PHP ini overrides for ${domain}"
      if ! apply_site_php_ini_overrides_to_pool "$domain" "$php_version" "$socket_project" "no"; then
        error "Failed to apply site PHP ini overrides"
        if [[ -n "$nginx_backup" && -f "$nginx_backup" ]]; then
          cp -p "$nginx_backup" "$nginx_cfg" >>"$LOG_FILE" 2>&1 || true
          ln -sf "$nginx_cfg" "$nginx_cfg_enabled"
        fi
        remove_php_pool_version "$socket_project" "$php_version" || true
        return 1
      fi
    fi
  fi

  progress_step "Reloading services"
  os_svc_reload_or_restart nginx || true
  os_svc_reload_or_restart "php${php_version}-fpm" || true
  if [[ "$keep_old_pool" != "yes" && -n "$old_php" && "$old_php" != "$php_version" ]]; then
    remove_php_pool_version "$socket_project" "$old_php" || true
  fi

  if [[ "$supports_cron" == "yes" ]]; then
    local cron_project="$project"
    if ! validate_project_slug "$cron_project"; then
      cron_project="$safe_project"
    fi
    cron_site_write "$domain" "$cron_project" "$profile" "$root" "$php_version"
  fi

  local queue_updated="no"
  if [[ "$supports_queue" == "yes" ]]; then
    local queue_project="$project"
    if ! validate_project_slug "$queue_project"; then
      queue_project="$safe_project"
    fi
    local unit unit_name
    unit=$(queue_unit_path "$queue_project") || unit=""
    unit_name=$(queue_unit_name "$queue_project" 2>/dev/null || echo "<invalid queue unit>")
    if [[ -f "$unit" ]]; then
      backup_file "$unit"
      local php_bin
      php_bin=$(resolve_php_bin "$php_version")
      perl -pi -e "s#^(ExecStart=)\\S+(\\s+.*)#\\1${php_bin}\\2#" "$unit"
      os_svc_daemon_reload || true
      os_svc_restart "$unit_name" || warn "Failed to restart queue service ${unit_name}"
      queue_updated="yes"
    else
      info "Queue unit not found for ${queue_project}; skipping queue update"
    fi
  fi

  echo "===== PHP switch summary ====="
  echo "Domain      : ${domain}"
  echo "Profile     : ${profile}"
  echo "Socket proj : ${socket_project}"
  echo "PHP         : ${old_php:-<unset>} -> ${php_version}"
  echo "Nginx       : patched in-place (validated with nginx -t)"
  echo "Pool        : new ${php_version} created; old $([[ "$keep_old_pool" == "yes" ]] && echo kept || echo removed)"
  if [[ "$supports_cron" == "yes" ]]; then
    echo "Cron        : refreshed"
  fi
  if [[ "$supports_queue" == "yes" ]]; then
    if [[ "$queue_updated" == "yes" ]]; then
      echo "Queue unit  : updated/restarted"
    else
      echo "Queue unit  : none"
    fi
  fi
}

site_list_handler() {
  repeat() {
    local char="$1" count="$2"
    printf "%*s" "$count" "" | tr ' ' "$char"
  }
  truncate_cell() {
    local width="$1" text="$2"
    local len=${#text}
    if (( len <= width )); then
      printf "%s" "$text"
    else
      local cut=$((width-3))
      ((cut<0)) && cut=0
      printf "%s..." "${text:0:cut}"
    fi
  }

  local is_tty=0
  [[ -t 1 ]] && is_tty=1
  local cols
  cols=$(tput cols 2>/dev/null || echo 120)

  local domain_w=28 profile_w=10 php_w=6 ssl_w=12 root_w=40
  local min_domain=15 min_profile=8 min_php=4 min_ssl=10 min_root=20
  if [[ $is_tty -eq 1 ]]; then
    domain_w=$min_domain; profile_w=$min_profile; php_w=$min_php; ssl_w=$min_ssl; root_w=$min_root
    local ncols=5
    local total=$((domain_w+profile_w+php_w+ssl_w+root_w + 3*ncols + 1))
    if (( cols > total )); then
      local extra=$((cols - total))
      root_w=$((root_w + extra))
    else
      # compact mode
      local compact_domain compact_profile compact_php compact_ssl
      compact_domain=$min_domain
      compact_profile=$min_profile
      compact_php=$min_php
      compact_ssl=$min_ssl
      local available=$((cols - (3*4 + 1)))
      if (( available < compact_profile+compact_php+compact_ssl+8 )); then
        compact_domain=8
      else
        compact_domain=$((available - (compact_profile+compact_php+compact_ssl)))
      fi
      ((compact_domain<8)) && compact_domain=8
      local sep
      sep="+$(repeat '-' $((compact_domain+2)))+$(repeat '-' $((compact_profile+2)))+$(repeat '-' $((compact_php+2)))+$(repeat '-' $((compact_ssl+2)))+"
      printf "%s\n" "$sep"
      printf "| %-*s | %-*s | %-*s | %-*s |\n" \
        "$compact_domain" "Domain" "$compact_profile" "Profile" "$compact_php" "PHP" "$compact_ssl" "SSL"
      printf "%s\n" "$sep"
      while IFS= read -r s; do
        [[ -z "$s" ]] && continue
        read_site_metadata "$s"
        local profile="${SITE_META[profile]:-generic}"
        local php="${SITE_META[php]:-}"
        local root="${SITE_META[root]:-}"
        local target="${SITE_META[target]:-}"
        local ssl_info
        ssl_info=$(site_ssl_brief "$s")
        local summary="$root"
        if [[ "$profile" == "alias" && -n "$target" ]]; then
          summary="alias -> ${target}"
        fi
        printf "| %-*s | %-*s | %-*s | %-*s |\n" \
          "$compact_domain" "$(truncate_cell "$compact_domain" "$s")" \
          "$compact_profile" "$(truncate_cell "$compact_profile" "$profile")" \
          "$compact_php" "$(truncate_cell "$compact_php" "$php")" \
          "$compact_ssl" "$(truncate_cell "$compact_ssl" "$ssl_info")"
        local label="Root/Target"
        local max_summary=$((cols-4-${#label}))
        ((max_summary<0)) && max_summary=0
        printf "  %s: %s\n" "$label" "$(truncate_cell "$max_summary" "$summary")"
      done < <(list_sites)
      printf "%s\n" "$sep"
      return
    fi
  fi

  local ncols=5
  local total=$((domain_w+profile_w+php_w+ssl_w+root_w + 3*ncols + 1))
  local sep
  sep="+$(repeat '-' $((domain_w+2)))+$(repeat '-' $((profile_w+2)))+$(repeat '-' $((php_w+2)))+$(repeat '-' $((ssl_w+2)))+$(repeat '-' $((root_w+2)))+"
  printf "%s\n" "$sep"
  printf "| %-*s | %-*s | %-*s | %-*s | %-*s |\n" \
    "$domain_w" "Domain" "$profile_w" "Profile" "$php_w" "PHP" "$ssl_w" "SSL" "$root_w" "Root/Target"
  printf "%s\n" "$sep"
  local s
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    read_site_metadata "$s"
    local profile="${SITE_META[profile]:-generic}"
    local php="${SITE_META[php]:-}"
    local root="${SITE_META[root]:-}"
    local target="${SITE_META[target]:-}"
    local ssl_info
    ssl_info=$(site_ssl_brief "$s")
    local summary="$root"
    if [[ "$profile" == "alias" && -n "$target" ]]; then
      summary="alias -> ${target}"
    fi
    printf "| %-*s | %-*s | %-*s | %-*s | %-*s |\n" \
      "$domain_w" "$(truncate_cell "$domain_w" "$s")" \
      "$profile_w" "$(truncate_cell "$profile_w" "$profile")" \
      "$php_w" "$(truncate_cell "$php_w" "$php")" \
      "$ssl_w" "$(truncate_cell "$ssl_w" "$ssl_info")" \
      "$root_w" "$(truncate_cell "$root_w" "$summary")"
  done < <(list_sites)
  printf "%s\n" "$sep"
}

register_cmd "site" "add" "Create site scaffolding (nginx/php-fpm)" "site_add_handler" "domain" "project-name= path= php= profile= create-db= db-name= db-user= db-pass= db-export= path-style= target-domain= skip-db-required="
register_cmd "site" "remove" "Remove site resources" "site_remove_handler" "" "domain= project-name= path= remove-files= drop-db= drop-db-user= db-name= db-user= dry-run= confirm="
register_cmd "site" "set-php" "Switch PHP version for site" "site_set_php_handler" "" "domain= php= keep-old-pool="
register_cmd "site" "list" "List configured sites" "site_list_handler" "" ""
