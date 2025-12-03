#!/usr/bin/env bash
set -euo pipefail

site_add_handler() {
  parse_kv_args "$@"
  require_args "domain"

  local domain="${PARSED_ARGS[domain]}"
  local project="${PARSED_ARGS[project-name]:-}"
  local php_version="${PARSED_ARGS[php]:-8.2}"
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
  if ! require_laravel_structure "$path"; then
    return 1
  fi
  ensure_project_permissions "$path"

  create_php_pool "$project" "$php_version" "$path"
  create_nginx_site "$domain" "$project" "$path" "$php_version"

  info "Site added: domain=${domain}, project=${project}, path=${path}, php=${php_version}"
}

site_remove_handler() {
  parse_kv_args "$@"
  require_args "domain"

  local domain="${PARSED_ARGS[domain]}"
  local project="${PARSED_ARGS[project-name]:-}"
  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "$domain")
    info "project-name not provided; using ${project}"
  fi
  local path="${PARSED_ARGS[path]:-${WWW_ROOT}/${project}}"
  local remove_files="${PARSED_ARGS[remove-files]:-0}"
  local drop_db="${PARSED_ARGS[drop-db]:-0}"
  local drop_user="${PARSED_ARGS[drop-db-user]:-0}"

  info "Site remove (stub): domain=${domain}, project=${project}, path=${path}, remove_files=${remove_files}, drop_db=${drop_db}, drop_user=${drop_user}"
  info "TODO: remove nginx/php-fpm/cron/queue resources and optional files/db."
}

site_set_php_handler() {
  parse_kv_args "$@"
  require_args "project-name php"

  local project="${PARSED_ARGS[project-name]}"
  local php_version="${PARSED_ARGS[php]}"

  info "Site PHP switch (stub): project=${project}, php=${php_version}"
  info "TODO: update PHP-FPM pool and nginx upstream."
}

site_list_handler() {
  info "Sites (nginx sites-available):"
  list_sites
}

register_cmd "site" "add" "Create site scaffolding (nginx/php-fpm)" "site_add_handler" "domain" "project-name= path= php=8.2"
register_cmd "site" "remove" "Remove site resources" "site_remove_handler" "domain" "project-name= path= remove-files=0 drop-db=0 drop-db-user=0"
register_cmd "site" "set-php" "Switch PHP version for site" "site_set_php_handler" "project-name php" ""
register_cmd "site" "list" "List configured sites" "site_list_handler" "" ""
