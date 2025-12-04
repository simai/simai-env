#!/usr/bin/env bash
set -euo pipefail

site_add_handler() {
  parse_kv_args "$@"
  require_args "domain"

  local domain="${PARSED_ARGS[domain]}"
  local project="${PARSED_ARGS[project-name]:-}"
  local profile="${PARSED_ARGS[profile]:-}"
  local php_version="${PARSED_ARGS[php]:-}"
  local create_db="${PARSED_ARGS[create-db]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  local db_pass="${PARSED_ARGS[db-pass]:-}"
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  local path="${PARSED_ARGS[path]:-${WWW_ROOT}/${project}}"

  ensure_user
  if [[ ! -d "$path" ]]; then
    info "Project path not found, creating: $path"
    mkdir -p "$path"
  fi
  local template_path="$NGINX_TEMPLATE"
  if [[ -z "$profile" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    profile=$(select_from_list "Select profile" "laravel" "laravel" "generic")
    [[ -z "$profile" ]] && profile="laravel"
  fi
  [[ -z "$profile" ]] && profile="laravel"

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
  create_nginx_site "$domain" "$project" "$path" "$php_version" "$template_path"

  if [[ "$create_db" == "yes" ]]; then
    info "Creating database ${db_name} with user ${db_user}"
    create_mysql_db_user "$db_name" "$db_user" "$db_pass"
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
  if [[ "$create_db" == "yes" ]]; then
    echo "DB name     : ${db_name}"
    echo "DB user     : ${db_user}"
    echo "DB password : ${db_pass} (not logged)"
  fi
  echo "Log file    : ${LOG_FILE}"
}

site_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local project="${PARSED_ARGS[project-name]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain to remove" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  local path="${PARSED_ARGS[path]:-${WWW_ROOT}/${project}}"
  local remove_files="${PARSED_ARGS[remove-files]:-}"
  local drop_db="${PARSED_ARGS[drop-db]:-}"
  local drop_user="${PARSED_ARGS[drop-db-user]:-}"
  local db_name="${PARSED_ARGS[db-name]:-}"
  local db_user="${PARSED_ARGS[db-user]:-}"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    [[ -z "$remove_files" ]] && remove_files=$(select_from_list "Remove project files?" "no" "no" "yes")
    [[ -z "$drop_db" ]] && drop_db=$(select_from_list "Drop database?" "no" "no" "yes")
    [[ -z "$drop_user" ]] && drop_user=$(select_from_list "Drop DB user?" "no" "no" "yes")
  fi
  [[ "$remove_files" == "yes" ]] && remove_files=1 || remove_files=0
  [[ "$drop_db" == "yes" ]] && drop_db=1 || drop_db=0
  [[ "$drop_user" == "yes" ]] && drop_user=1 || drop_user=0
  [[ -z "$db_name" ]] && db_name="${project}"
  [[ -z "$db_user" ]] && db_user="${project}"

  info "Removing site: domain=${domain}, project=${project}, path=${path}"
  remove_nginx_site "$domain"
  remove_php_pools "$project"
  # TODO: remove cron/queue resources when implemented
  if [[ "$remove_files" == "1" ]]; then
    remove_project_files "$path"
  fi
  if [[ "$drop_db" == "1" ]]; then
    mysql -uroot -e "DROP DATABASE IF EXISTS \`${db_name}\`;" >>"$LOG_FILE" 2>&1 || warn "Failed to drop database ${db_name}"
  fi
  if [[ "$drop_user" == "1" ]]; then
    mysql -uroot -e "DROP USER IF EXISTS '${db_user}'@'%';" >>"$LOG_FILE" 2>&1 || warn "Failed to drop user ${db_user}"
  fi
  info "Site remove completed for ${domain}"
}

site_set_php_handler() {
  parse_kv_args "$@"
  local project="${PARSED_ARGS[project-name]:-}"
  local domain="${PARSED_ARGS[domain]:-}"
  local php_version="${PARSED_ARGS[php]:-}"

  if [[ -z "$project" && -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select site" "" "${sites[@]}")
  fi
  if [[ -z "$project" ]]; then
    if [[ -n "$domain" ]]; then
      project=$(project_slug_from_domain "$domain")
      info "project-name not provided; using ${project}"
    fi
  fi
  if [[ -z "$project" ]]; then
    require_args "project-name"
  fi

  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(installed_php_versions)
    php_version=$(select_from_list "Select PHP version" "${versions[0]:-}" "${versions[@]}")
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi

  info "Site PHP switch (stub): project=${project}, php=${php_version}"
  info "TODO: update PHP-FPM pool and nginx upstream."
}

site_list_handler() {
  info "Sites (nginx sites-available):"
  list_sites
}

register_cmd "site" "add" "Create site scaffolding (nginx/php-fpm)" "site_add_handler" "domain" "project-name= path= php= profile= create-db= db-name= db-user= db-pass="
register_cmd "site" "remove" "Remove site resources" "site_remove_handler" "" ""
register_cmd "site" "set-php" "Switch PHP version for site" "site_set_php_handler" "" "project-name= domain= php="
register_cmd "site" "list" "List configured sites" "site_list_handler" "" ""
