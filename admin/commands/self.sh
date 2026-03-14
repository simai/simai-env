#!/usr/bin/env bash
set -euo pipefail

self_update_ref() {
  local branch="${SIMAI_UPDATE_BRANCH:-main}"
  local ref="${SIMAI_UPDATE_REF:-refs/heads/${branch}}"
  if [[ "$ref" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]]; then
    echo "$ref"
    return 0
  fi
  echo "refs/heads/main"
}

self_remote_version_url() {
  local ref
  ref="$(self_update_ref)"
  case "$ref" in
    refs/heads/*)
      echo "https://raw.githubusercontent.com/simai/simai-env/${ref#refs/heads/}/VERSION"
      ;;
    refs/tags/*)
      echo "https://raw.githubusercontent.com/simai/simai-env/${ref#refs/tags/}/VERSION"
      ;;
    *)
      echo "https://raw.githubusercontent.com/simai/simai-env/main/VERSION"
      ;;
  esac
}

self_update_handler() {
  local updater="${SCRIPT_DIR}/update.sh"
  if [[ ! -x "$updater" ]]; then
    error "Updater not found or not executable at ${updater}"
    return 1
  fi
  info "Running updater ${updater}"
  progress_init 2
  progress_step "Downloading and applying update"
  "$updater"
  progress_done "Update completed"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    progress_step "Reloading admin menu"
    info "Reloading admin menu after update"
    return "${SIMAI_RC_MENU_RELOAD:-88}"
  fi
  return 0
}

self_bootstrap_handler() {
  parse_kv_args "$@"
  local php="${PARSED_ARGS[php]:-8.2}"
  local mysql="${PARSED_ARGS[mysql]:-mysql}"
  local node="${PARSED_ARGS[node-version]:-20}"
  info "Repair Environment: installs/repairs base packages and may reload services; sites are not removed."
  progress_init 3
  progress_step "Running bootstrap (php=${php}, mysql=${mysql}, node=${node})"
  if ! "${SCRIPT_DIR}/simai-env.sh" bootstrap --php "$php" --mysql "$mysql" --node-version "$node"; then
    progress_done "Bootstrap failed"
    return 1
  fi
  progress_step "Initializing profile activation defaults"
  if ! maybe_init_profiles_allowlist_core_defaults; then
    warn "Profile activation defaults not initialized"
  fi
  progress_done "Bootstrap completed"
}

self_version_handler() {
  local local_version="(unknown)"
  local version_file="${SCRIPT_DIR}/VERSION"
  [[ -f "$version_file" ]] && local_version="$(cat "$version_file")"

  local update_ref remote_version_url remote_version
  update_ref="$(self_update_ref)"
  remote_version_url="$(self_remote_version_url)"
  remote_version=$(curl -fsSL "$remote_version_url" 2>/dev/null || true)
  [[ -z "$remote_version" ]] && remote_version="(unavailable)"

  local status="n/a"
  if [[ "$remote_version" != "(unavailable)" ]]; then
    if [[ "$local_version" == "$remote_version" ]]; then
      status="up to date"
    else
      status="update available"
    fi
  fi

  local GREEN=$'\e[32m' RED=$'\e[31m' RESET=$'\e[0m'
  local status_padded
  status_padded=$(printf "%-20s" "$status")
  local status_colored="$status_padded"
  if [[ "$status" == "up to date" ]]; then
    status_colored="${GREEN}${status_padded}${RESET}"
  elif [[ "$status" == "update available" ]]; then
    status_colored="${RED}${status_padded}${RESET}"
  fi

  local sep="+----------------------+----------------------+"
  printf "%s\n" "$sep"
  printf "| %-20s | %-20s |\n" "Update ref" "$update_ref"
  printf "| %-20s | %-20s |\n" "Local version" "$local_version"
  printf "| %-20s | %-20s |\n" "Remote version" "$remote_version"
  printf "| %-20s | %-20s |\n" "Status" "$status_colored"
  printf "%s\n" "$sep"
}

self_status_handler() {
  ui_header "SIMAI ENV · System status"
  platform_detect_os
  local os_name="${PLATFORM_OS_PRETTY:-unknown}"
  local supported="no"
  if platform_is_supported_os; then
    supported="yes"
  fi
  local install_dir="${SIMAI_ENV_ROOT:-${SCRIPT_DIR:-unknown}}"

  local svc_state
  svc_state() {
    local svc="$1"
    if ! os_svc_has_unit "$svc"; then
      echo "not installed"
      return
    fi
    if os_svc_is_active "$svc"; then
      echo "active"
    else
      echo "inactive"
    fi
  }

  local nginx_state mysql_state redis_state
  nginx_state=$(svc_state "nginx")
  mysql_state=$(svc_state "mysql")
  redis_state=$(svc_state "redis-server")

  local nginx_version="unknown"
  if command -v nginx >/dev/null 2>&1; then
    nginx_version=$(nginx -v 2>&1 | sed 's/^nginx version: //')
  fi
  local php_cli_version="unknown"
  if command -v php >/dev/null 2>&1; then
    php_cli_version=$(php -v 2>/dev/null | head -n1)
  fi
  local mysql_version="unknown"
  if command -v mysql >/dev/null 2>&1; then
    mysql_version=$(mysql --version 2>/dev/null)
  elif command -v mysqld >/dev/null 2>&1; then
    mysql_version=$(mysqld --version 2>/dev/null)
  fi
  local redis_version="unknown"
  if command -v redis-server >/dev/null 2>&1; then
    redis_version=$(redis-server --version 2>/dev/null)
  elif command -v redis-cli >/dev/null 2>&1; then
    redis_version=$(redis-cli --version 2>/dev/null)
  fi
  local certbot_version="unknown"
  if command -v certbot >/dev/null 2>&1; then
    certbot_version=$(certbot --version 2>/dev/null)
  fi
  local certbot_timer="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local load_state
    load_state=$(systemctl show -p LoadState --value certbot.timer 2>/dev/null || true)
    if [[ "$load_state" == "loaded" ]]; then
      if systemctl is-active --quiet certbot.timer; then
        certbot_timer="active"
      else
        certbot_timer="inactive"
      fi
    else
      certbot_timer="missing"
    fi
  fi

  local php_status="not installed"
  if command -v systemctl >/dev/null 2>&1; then
    local units=()
    mapfile -t units < <(systemctl list-units --type=service --no-legend "php*-fpm.service" 2>/dev/null | awk '{print $1}')
    if [[ ${#units[@]} -gt 0 ]]; then
      local entries=()
      local unit ver state
      for unit in "${units[@]}"; do
        ver="${unit#php}"
        ver="${ver%-fpm.service}"
        state="inactive"
        if systemctl is-active --quiet "$unit"; then
          state="active"
        fi
        entries+=("${ver}(${state})")
      done
      php_status=$(IFS=', '; echo "${entries[*]}")
    fi
  fi
  if [[ "$php_status" == "not installed" ]]; then
    local vers=()
    if compgen -G "/etc/php/*/fpm/php-fpm.conf" >/dev/null 2>&1; then
      local dir ver
      for dir in /etc/php/*/fpm; do
        [[ -d "$dir" ]] || continue
        ver="${dir#/etc/php/}"
        ver="${ver%/fpm}"
        vers+=("$ver")
      done
      if [[ ${#vers[@]} -gt 0 ]]; then
        php_status=$(IFS=', '; echo "${vers[*]}")
      fi
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "Install dir|${install_dir}" \
    "OS|${os_name}" \
    "Supported|${supported}" \
    "nginx|${nginx_state}" \
    "nginx version|${nginx_version}" \
    "mysql|${mysql_state}" \
    "mysql version|${mysql_version}" \
    "redis|${redis_state}" \
    "redis version|${redis_version}" \
    "php-fpm|${php_status}" \
    "php cli|${php_cli_version}" \
    "certbot version|${certbot_version}" \
    "certbot timer|${certbot_timer}"
  ui_section "Next steps"
  ui_kv "Diagnostics" "simai-admin.sh self platform-status"
  ui_kv "Update" "simai-admin.sh self update"
}

self_platform_status_handler() {
  ui_header "SIMAI ENV · Platform diagnostics"
  local svc_state
  svc_state() {
    local svc="$1"
    if ! os_svc_has_unit "$svc"; then
      echo "missing"
      return
    fi
    if os_svc_is_active "$svc"; then
      echo "active"
    else
      echo "inactive"
    fi
  }

  local nginx_state mysql_state redis_state
  nginx_state=$(svc_state "nginx")
  mysql_state=$(svc_state "mysql")
  redis_state=$(svc_state "redis-server")

  local nginx_test="unknown"
  if command -v nginx >/dev/null 2>&1; then
    if nginx -t >/dev/null 2>&1; then
      nginx_test="ok"
    else
      nginx_test="fail"
    fi
  fi

  local php_units="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local units=()
    mapfile -t units < <(systemctl list-units --type=service --no-legend "php*-fpm.service" 2>/dev/null | awk '{print $1}')
    local active_units=()
    local unit
    for unit in "${units[@]}"; do
      if systemctl is-active --quiet "$unit"; then
        active_units+=("$unit")
      fi
    done
    if [[ ${#units[@]} -eq 0 ]]; then
      php_units="missing"
    elif [[ ${#active_units[@]} -eq 0 ]]; then
      php_units="inactive"
    else
      php_units=$(IFS=', '; echo "${active_units[*]}")
    fi
  fi

  local disk_root="unknown"
  disk_root=$(df -h / 2>/dev/null | awk 'NR==2{print $4}')
  [[ -z "$disk_root" ]] && disk_root="unknown"
  local disk_data_label="disk free /var"
  local disk_var="unknown"
  if [[ -d /var/lib/mysql ]]; then
    disk_data_label="disk free /var/lib/mysql"
    disk_var=$(df -h /var/lib/mysql 2>/dev/null | awk 'NR==2{print $4}')
  elif [[ -d /var ]]; then
    disk_data_label="disk free /var"
    disk_var=$(df -h /var 2>/dev/null | awk 'NR==2{print $4}')
  fi
  [[ -z "$disk_var" ]] && disk_var="unknown"

  local inodes_root="unknown"
  inodes_root=$(df -hi / 2>/dev/null | awk 'NR==2{print $4}')
  [[ -z "$inodes_root" ]] && inodes_root="unknown"

  local mem_summary="unknown"
  if command -v free >/dev/null 2>&1; then
    local total used free
    read -r total used free < <(free -h 2>/dev/null | awk 'NR==2{print $2, $3, $4}')
    if [[ -n "${total:-}" ]]; then
      mem_summary="${total}/${used}/${free}"
    fi
  fi

  local certbot_timer="unknown"
  if command -v systemctl >/dev/null 2>&1; then
    local load_state
    load_state=$(systemctl show -p LoadState --value certbot.timer 2>/dev/null || true)
    if [[ "$load_state" == "loaded" ]]; then
      if systemctl is-active --quiet certbot.timer; then
        certbot_timer="active"
      else
        certbot_timer="inactive"
      fi
    else
      certbot_timer="missing"
    fi
  fi

  ui_section "Result"
  print_kv_table \
    "nginx|${nginx_state}" \
    "nginx test|${nginx_test}" \
    "mysql|${mysql_state}" \
    "redis|${redis_state}" \
    "php-fpm units|${php_units}" \
    "disk free /|${disk_root}" \
    "${disk_data_label}|${disk_var}" \
    "inodes free /|${inodes_root}" \
    "memory (total/used/free)|${mem_summary}" \
    "certbot timer|${certbot_timer}"
  ui_section "Next steps"
  ui_kv "Validate nginx" "nginx -t"
  ui_kv "Repair stack" "simai-admin.sh self bootstrap"
}

register_cmd "self" "update" "Update simai-env/admin scripts" "self_update_handler" "" ""
register_cmd "self" "version" "Show local and remote simai-env version" "self_version_handler" "" ""
register_cmd "self" "bootstrap" "Repair Environment (base stack: nginx/php/mysql/certbot/etc.)" "self_bootstrap_handler" "" "php= mysql= node-version="
register_cmd "self" "status" "Show platform/service status" "self_status_handler" "" ""
register_cmd "self" "platform-status" "Show platform diagnostic status" "self_platform_status_handler" "" ""
