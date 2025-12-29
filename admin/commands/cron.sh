#!/usr/bin/env bash
set -euo pipefail

cron_add_handler() {
  parse_kv_args "$@"
  require_args "project-path"

  local project_path="${PARSED_ARGS[project-path]}"
  local project="${PARSED_ARGS[project-name]:-$(basename "$project_path")}"
  local php_version="${PARSED_ARGS[php]:-8.2}"
  local user="${PARSED_ARGS[user]:-simai}"

  if ! validate_path "$project_path"; then
    return 1
  fi

  local prev_user="${SIMAI_USER:-simai}"
  SIMAI_USER="$user"
  ensure_project_cron "$project" "laravel" "$project_path" "$php_version"
  SIMAI_USER="$prev_user"
  echo "Cron created at /etc/cron.d/${project} for ${project_path} (php ${php_version}, user ${user})"
}

cron_remove_handler() {
  parse_kv_args "$@"
  local project_path="${PARSED_ARGS[project-path]:-}"
  local project="${PARSED_ARGS[project-name]:-}"
  if [[ -z "$project" && -z "$project_path" ]]; then
    error "project-name or project-path is required"
    return 1
  fi
  if [[ -z "$project" && -n "$project_path" ]]; then
    if ! validate_path "$project_path"; then
      return 1
    fi
    project=$(basename "$project_path")
  fi
  remove_cron_file "$project"
  echo "Cron removed for project ${project}"
}

register_cmd "cron" "add" "Add schedule:run cron entry" "cron_add_handler" "project-path" "php= user=simai project-name="
register_cmd "cron" "remove" "Remove schedule:run cron entry" "cron_remove_handler" "" "project-path= project-name= user=simai"
