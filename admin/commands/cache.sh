#!/usr/bin/env bash
set -euo pipefail

cache_clear_handler() {
  parse_kv_args "$@"
  require_args "domain"
  local domain="${PARSED_ARGS[domain]}"

  if ! validate_domain "$domain"; then
    return 1
  fi
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  if [[ "$profile" != "laravel" ]]; then
    error "Cache command is supported for laravel profile only."
    echo "For generic projects, clear cache using project-specific tooling."
    return 2
  fi
  local root="${SITE_META[root]}"
  if ! validate_path "$root"; then
    return 1
  fi
  local artisan="${root}/artisan"
  if [[ ! -f "$artisan" ]]; then
    error "Laravel artisan not found at ${artisan}"
    echo "Laravel markers missing. Run: simai-admin.sh site doctor --domain ${domain}"
    return 3
  fi
  local php_version="${SITE_META[php]}"
  if [[ -z "$php_version" || "$php_version" == "none" ]]; then
    error "Site PHP version is not set for ${domain}."
    echo "Set it with: simai-admin.sh site set-php --domain ${domain} --php <version>"
    return 3
  fi
  local php_bin
  if ! php_bin=$(resolve_php_bin_strict "$php_version"); then
    local rc=$?
    if [[ $rc -eq 2 ]]; then
      error "php${php_version} not found on this system."
      echo "Install it with: simai-admin.sh php install --version ${php_version}"
    else
      error "Unable to resolve PHP binary for version: ${php_version}"
    fi
    return 3
  fi

  local steps=("cache:clear" "config:clear" "route:clear" "view:clear")
  progress_init "${#steps[@]}"
  local cmd
  for cmd in "${steps[@]}"; do
    progress_step "artisan ${cmd}"
    local run_cmd
    run_cmd="cd $(printf '%q' "$root") && $(printf '%q' "$php_bin") artisan ${cmd}"
    if ! run_long "artisan ${cmd}" sudo -u "$ADMIN_USER" -H bash -lc "$run_cmd"; then
      error "artisan ${cmd} failed"
      return 1
    fi
  done
  progress_done "Laravel cache cleared"
}

register_cmd "cache" "clear" "Clear Laravel caches (laravel-only)" "cache_clear_handler" "domain" ""
register_cmd "cache" "run" "Alias for cache clear" "cache_clear_handler" "domain" ""
