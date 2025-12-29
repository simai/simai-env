#!/usr/bin/env bash
set -euo pipefail

site_add_handler() {
  parse_kv_args "$@"
  require_args "domain"

  local domain="${PARSED_ARGS[domain]}"
  if ! validate_domain "$domain"; then
    return 1
  fi
  local project="${PARSED_ARGS[project-name]:-}"
  local profile="${PARSED_ARGS[profile]:-}"
  local php_version="${PARSED_ARGS[php]:-}"
  local create_db="${PARSED_ARGS[create-db]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  local db_pass="${PARSED_ARGS[db-pass]:-}"
  local target_domain="" target_path="" target_project="" target_php=""
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  local path="${PARSED_ARGS[path]:-${WWW_ROOT}/${project}}"
  if ! validate_path "$path"; then
    return 1
  fi

  ensure_user
  if [[ -z "$profile" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    profile=$(select_from_list "Select profile" "generic" "generic" "laravel" "alias")
    [[ -z "$profile" ]] && profile="generic"
  fi
  [[ -z "$profile" ]] && profile="generic"

  if [[ "$profile" == "alias" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    if [[ ${#sites[@]} -eq 0 ]]; then
      error "No existing sites to alias"
      return 1
    fi
    target_domain=$(select_from_list "Select target site for alias" "" "${sites[@]}")
    if [[ -z "$target_domain" ]]; then
      error "Target site is required for alias"
      return 1
    fi
    read_site_metadata "$target_domain"
    target_path="${SITE_META[root]}"
    target_project="${SITE_META[project]}"
    target_php="${SITE_META[php]}"
    php_version="$target_php"
    create_nginx_site "$domain" "$project" "$target_path" "$php_version" "$NGINX_TEMPLATE_GENERIC" "$profile" "$target_domain" "$target_project"
    info "Alias added: domain=${domain}, target=${target_domain}, php=${php_version}"
    echo "===== Site summary ====="
    echo "Domain      : ${domain}"
    echo "Project     : ${project}"
    echo "Profile     : ${profile}"
    echo "Target site : ${target_domain}"
    echo "PHP version : ${php_version}"
    echo "Root path   : ${target_path}"
    echo "Nginx conf  : /etc/nginx/sites-available/${domain}.conf"
    echo "Log file    : ${LOG_FILE}"
    return
  fi

  if [[ ! -d "$path" ]]; then
    info "Project path not found, creating: $path"
    mkdir -p "$path"
  fi
  local template_path="$NGINX_TEMPLATE"

  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(installed_php_versions)
    if [[ ${#versions[@]} -gt 0 ]]; then
      php_version=$(select_from_list "Select PHP version" "${versions[0]}" "${versions[@]}")
    fi
  fi
  [[ -z "$php_version" ]] && php_version="8.2"

  if [[ -z "$create_db" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    create_db=$(select_from_list "Create MySQL database and user?" "no" "no" "yes")
  fi
  [[ -z "$create_db" ]] && create_db="no"
  if [[ "$create_db" == "yes" ]]; then
    [[ -z "$db_name" ]] && db_name="${project}"
    [[ -z "$db_user" ]] && db_user="${project}"
    [[ -z "$db_pass" ]] && db_pass=$(generate_password)
  fi

  if [[ "$profile" == "generic" ]]; then
    template_path="$NGINX_TEMPLATE_GENERIC"
    create_placeholder_if_missing "$path"
  else
    if ! require_laravel_structure "$path"; then
      if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
        local choice
        choice=$(select_from_list "Laravel structure not found. Use generic profile with placeholder?" "yes" "yes" "no")
        if [[ "$choice" == "yes" ]]; then
          profile="generic"
          template_path="$NGINX_TEMPLATE_GENERIC"
          create_placeholder_if_missing "$path"
        else
          return 1
        fi
      else
        return 1
      fi
    fi
  fi
  ensure_project_permissions "$path"

  create_php_pool "$project" "$php_version" "$path"
  create_nginx_site "$domain" "$project" "$path" "$php_version" "$template_path" "$profile" "" "$project" "" "" "" "no" "no"
  install_healthcheck "$path"
  local cron_summary="none"
  if [[ "$profile" == "laravel" ]]; then
    ensure_project_cron "$project" "$profile" "$path" "$php_version"
    cron_summary="/etc/cron.d/${project} (created/updated)"
  fi

  if [[ "$create_db" == "yes" ]]; then
    info "Creating database ${db_name} with user ${db_user}"
    create_mysql_db_user "$db_name" "$db_user" "$db_pass"
    if [[ "$profile" == "generic" ]]; then
      write_generic_env "$path" "$db_name" "$db_user" "$db_pass"
    fi
  fi

  info "Site added: domain=${domain}, project=${project}, path=${path}, php=${php_version}, profile=${profile}"

  # Print summary to stdout (avoid logging secrets)
  echo "===== Site summary ====="
  echo "Domain      : ${domain}"
  echo "Project     : ${project}"
  echo "Profile     : ${profile}"
  echo "PHP version : ${php_version}"
  echo "Path        : ${path}"
  echo "Nginx conf  : /etc/nginx/sites-available/${domain}.conf"
  echo "PHP-FPM pool: /etc/php/${php_version}/fpm/pool.d/${project}.conf"
  echo "Cron file   : ${cron_summary}"
  if [[ "$create_db" == "yes" ]]; then
    echo "DB name     : ${db_name}"
    echo "DB user     : ${db_user}"
    echo "DB password : ${db_pass} (not logged)"
  fi
  echo "Healthcheck (local): curl -i -H \"Host: ${domain}\" http://127.0.0.1/healthcheck.php"
  echo "Log file    : ${LOG_FILE}"
}

site_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local project="${PARSED_ARGS[project-name]:-}"
  local confirm="${PARSED_ARGS[confirm]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain to remove" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  if ! validate_domain "$domain"; then
    return 1
  fi
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  local path="${PARSED_ARGS[path]:-${WWW_ROOT}/${project}}"
  local path_provided=0
  [[ -n "${PARSED_ARGS[path]:-}" ]] && path_provided=1
  local remove_files="${PARSED_ARGS[remove-files]:-}"
  local drop_db="${PARSED_ARGS[drop-db]:-}"
  local drop_user="${PARSED_ARGS[drop-db-user]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  local profile="generic"
  if [[ -n "$domain" ]]; then
    read_site_metadata "$domain"
    profile="${SITE_META[profile]:-generic}"
    [[ -z "$project" ]] && project="${SITE_META[project]:-$project}"
    path="${PARSED_ARGS[path]:-${SITE_META[root]:-$path}}"
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" ]]; then
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
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    if [[ "$profile" == "alias" ]]; then
      remove_files=0
      drop_db=0
      drop_user=0
    else
      [[ -z "$remove_files" ]] && remove_files=$(select_from_list "Remove project files?" "no" "no" "yes")
      [[ -z "$drop_db" ]] && drop_db=$(select_from_list "Drop database?" "no" "no" "yes")
      [[ -z "$drop_user" ]] && drop_user=$(select_from_list "Drop DB user?" "no" "no" "yes")
    fi
  fi
  [[ "$remove_files" == "yes" ]] && remove_files=1 || remove_files=0
  [[ "$drop_db" == "yes" ]] && drop_db=1 || drop_db=0
  [[ "$drop_user" == "yes" ]] && drop_user=1 || drop_user=0
  [[ -z "$db_name" ]] && db_name="${project}"
  [[ -z "$db_user" ]] && db_user="${project}"
  if [[ "$remove_files" -eq 1 || "$path_provided" -eq 1 ]]; then
    if ! validate_path "$path"; then
      return 1
    fi
  fi

  info "Removing site: domain=${domain}, project=${project}, path=${path}"
  local removed_queue=0 removed_cron=0
  remove_nginx_site "$domain"
  if [[ "$profile" != "alias" ]]; then
    remove_php_pools "$project"
    remove_cron_file "$project" && removed_cron=1 || removed_cron=0
    remove_queue_unit "$project" && removed_queue=1 || removed_queue=0
  fi
  # TODO: remove cron/queue resources when implemented
  if [[ "$remove_files" == "1" ]]; then
    remove_project_files "$path"
  fi
  if [[ "$drop_db" == "1" ]]; then
    mysql -uroot -e "DROP DATABASE IF EXISTS \`${db_name}\`;" >>"$LOG_FILE" 2>&1 || warn "Failed to drop database ${db_name}"
  fi
  if [[ "$drop_user" == "1" ]]; then
    mysql -uroot -e "DROP USER IF EXISTS '${db_user}'@'127.0.0.1';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop user ${db_user}@127.0.0.1"
    mysql -uroot -e "DROP USER IF EXISTS '${db_user}'@'localhost';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop user ${db_user}@localhost"
    mysql -uroot -e "DROP USER IF EXISTS '${db_user}'@'%';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop legacy wildcard user ${db_user}@%"
  fi
  info "Site remove completed for ${domain}"
  echo "===== Site remove summary ====="
  echo "Domain     : ${domain}"
  echo "Profile    : ${profile}"
  echo "Nginx      : removed"
  echo "PHP-FPM    : removed (${project})"
  echo "Cron       : $([[ $removed_cron -eq 1 ]] && echo removed || echo none)"
  echo "Queue unit : $([[ $removed_queue -eq 1 ]] && echo removed || echo none)"
  echo "Files      : $([[ $remove_files -eq 1 ]] && echo removed || echo kept)"
  echo "Database   : $([[ $drop_db -eq 1 ]] && echo dropped || echo kept)"
  echo "DB user    : $([[ $drop_user -eq 1 ]] && echo dropped || echo kept)"
}

site_set_php_handler() {
  parse_kv_args "$@"
  local project="${PARSED_ARGS[project-name]:-}"
  local domain="${PARSED_ARGS[domain]:-}"
  local php_version="${PARSED_ARGS[php]:-}"
  local keep_old_pool="${PARSED_ARGS[keep-old-pool]:-}"
  local profile=""

  if [[ -z "$project" && -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=() filtered=()
    mapfile -t sites < <(list_sites)
    for s in "${sites[@]}"; do
      read_site_metadata "$s"
      if [[ "${SITE_META[profile]:-}" != "alias" ]]; then
        filtered+=("$s")
      fi
    done
    domain=$(select_from_list "Select site" "" "${filtered[@]}")
  fi
  if [[ -z "$project" ]]; then
    if [[ -n "$domain" ]]; then
      project=$(project_slug_from_domain "$domain")
      info "project-name not provided; using ${project}"
    fi
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi

  if [[ -n "$domain" ]]; then
    if ! validate_domain "$domain"; then
      return 1
    fi
    read_site_metadata "$domain"
    profile="${SITE_META[profile]:-}"
    if [[ "$profile" == "alias" ]]; then
      error "Cannot change PHP version for alias site ${domain}; change the target site instead."
      return 1
    fi
  fi

  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(installed_php_versions)
    php_version=$(select_from_list "Select PHP version" "${versions[0]:-}" "${versions[@]}")
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi

  if [[ -z "$keep_old_pool" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    keep_old_pool=$(select_from_list "Keep old PHP-FPM pool?" "no" "no" "yes")
  fi
  [[ "$keep_old_pool" == "yes" ]] && keep_old_pool="yes" || keep_old_pool="no"

  switch_site_php "$domain" "$php_version" "$keep_old_pool"
  echo "===== PHP switch summary ====="
  echo "Domain : ${domain}"
  echo "PHP    : ${php_version}"
  echo "Keep old pool: ${keep_old_pool}"
}

site_list_handler() {
  local sep="+------------------------------+------------+----------+----------------------+------------------------------------------+"
  printf "%s\n" "$sep"
  printf "| %-28s | %-10s | %-8s | %-20s | %-40s |\n" "Domain" "Profile" "PHP" "SSL" "Root/Target"
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
    printf "| %-28s | %-10s | %-8s | %-20s | %-40s |\n" "$s" "$profile" "$php" "$ssl_info" "$summary"
  done < <(list_sites)
  printf "%s\n" "$sep"
}

register_cmd "site" "add" "Create site scaffolding (nginx/php-fpm)" "site_add_handler" "domain" "project-name= path= php= profile= create-db= db-name= db-user= db-pass="
register_cmd "site" "remove" "Remove site resources" "site_remove_handler" "" "domain= project-name= path= remove-files= drop-db= drop-db-user= confirm="
register_cmd "site" "set-php" "Switch PHP version for site" "site_set_php_handler" "" "project-name= domain= php= keep-old-pool="
register_cmd "site" "list" "List configured sites" "site_list_handler" "" ""
