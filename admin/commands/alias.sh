#!/usr/bin/env bash
set -euo pipefail

alias_add_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local target_domain="${PARSED_ARGS[target-domain]:-}"
  local target_path="${PARSED_ARGS[target-path]:-}"
  local project="${PARSED_ARGS[project-name]:-}"

  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi

  if [[ -z "$target_path" && -z "$target_domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    target_domain=$(select_from_list "Select target site" "" "${sites[@]}")
  fi

  if [[ -n "$target_domain" && -z "$target_path" ]]; then
    local slug
    slug=$(project_slug_from_domain "$target_domain")
    target_path="${WWW_ROOT}/${slug}"
  fi

  if [[ -z "$project" ]]; then
    project=$(project_slug_from_domain "${target_domain:-$domain}")
  fi

  if [[ -z "$target_path" ]]; then
    require_args "target-path"
  fi

  local pool_file
  pool_file=$(detect_pool_for_project "$project")
  local php_version
  php_version=$(echo "$pool_file" | awk -F'/' '{print $4}')
  if [[ -z "$php_version" ]]; then
    warn "Could not detect PHP version for project ${project}; using 8.2"
    php_version="8.2"
  fi

  create_nginx_site "$domain" "$project" "$target_path" "$php_version" "$NGINX_TEMPLATE_GENERIC"
  info "Alias added: domain=${domain}, target=${target_path}, php=${php_version}"
}

alias_remove_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select alias to remove" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  remove_nginx_site "$domain"
  info "Alias removed: domain=${domain}"
}

register_cmd "alias" "add" "Add alias domain to existing site" "alias_add_handler" "domain" "target-domain= target-path= project-name="
register_cmd "alias" "remove" "Remove alias domain" "alias_remove_handler" "" "domain="
