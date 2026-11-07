#!/usr/bin/env bash
set -euo pipefail

# Installed versions with their sites and waiting package updates, and the
# versions apt can install (simai-php/1).
php_list_handler() {
  [[ -n "${PLATFORM_OS_CODENAME:-}" ]] || platform_detect_os
  python3 -I "${SCRIPT_DIR}/lib/php_versions.py" "${SIMAI_COMMAND_OUTPUT:-human}" "$(platform_native_php_version)"
}

php_installed_or_fail() {
  [[ "$1" =~ ^[5-9]\.[0-9]$ && -d "/etc/php/$1/fpm" ]] || { error "PHP ${1:-?} is not installed"; return 1; }
}

php_sites_on() { python3 -I "${SCRIPT_DIR}/lib/php_versions.py" sites "$1"; }

# Remove a PHP version no site, the system and the php command use.
php_remove_handler() {
  parse_kv_args "$@"
  require_args "php" || return 1
  local v="${PARSED_ARGS[php]}" native cli
  php_installed_or_fail "$v" || return 1
  [[ -n "${PLATFORM_OS_CODENAME:-}" ]] || platform_detect_os
  native=$(platform_native_php_version)
  [[ "$v" != "$native" ]] || { error "PHP ${v} is the system version of this Ubuntu release and stays"; return 1; }
  # A php command chosen by hand stays; in auto mode dpkg picks another.
  cli=$(update-alternatives --query php 2>/dev/null | awk '/^Status:/{s=$2} /^Value:/{v=$2} END{print s" "v}')
  [[ "$cli" != "manual /usr/bin/php${v}" ]] || { error "PHP ${v} is the php command of this server; switch it first: update-alternatives --set php /usr/bin/php<version>"; return 1; }
  local -a sites=() pkgs=()
  mapfile -t sites < <(php_sites_on "$v")
  (( ${#sites[@]} == 0 )) || { error "PHP ${v} serves ${#sites[@]} site(s): ${sites[*]}. Move them first: simai-admin.sh site set-php --domain D --php <version>"; return 1; }
  mapfile -t pkgs < <(python3 -I "${SCRIPT_DIR}/lib/php_versions.py" packages "$v")
  (( ${#pkgs[@]} )) || { error "No packages of PHP ${v} found"; return 1; }
  run_long "Removing PHP ${v} (${#pkgs[@]} packages)" env DEBIAN_FRONTEND=noninteractive apt-get purge -y "${pkgs[@]}" || return 1
  run_long "Removing packages nothing needs" env DEBIAN_FRONTEND=noninteractive apt-get autoremove -y || true
  # Pools and settings left from sites that used this version; no site does now.
  if ! dpkg-query -W -f '${db:Status-Abbrev}\n' "php${v}-*" 2>/dev/null | grep '^ii' >/dev/null; then
    rm -rf -- "/etc/php/${v}"
  fi
  ui_result_table "PHP|${v}" "Packages removed|${#pkgs[@]}" "Sites|none used it"
}

# Turn an extension on or off for PHP-FPM of one version; turning on installs
# its package when needed. The previous state comes back if FPM fails its test.
php_extension_handler() {
  parse_kv_args "$@"
  require_args "php name enabled" || return 1
  local v="${PARSED_ARGS[php]}" name="${PARSED_ARGS[name],,}" enabled="${PARSED_ARGS[enabled]}"
  php_installed_or_fail "$v" || return 1
  [[ "$name" =~ ^[a-z0-9_]{2,32}$ ]] || { error "--name must be an extension name such as intl or imagick"; return 1; }
  [[ "$enabled" =~ ^(yes|no)$ ]] || { error "--enabled must be yes or no"; return 1; }
  local ini="/etc/php/${v}/mods-available/${name}.ini" fpm="/usr/sbin/php-fpm${v}" was=no
  [[ -f "$ini" ]] && "$fpm" -m 2>/dev/null | tr 'A-Z' 'a-z' | grep -x -- "$name" >/dev/null && was=yes
  if [[ "$enabled" == yes && ! -f "$ini" ]]; then
    apt-cache show "php${v}-${name}" >/dev/null 2>&1 || { error "No package php${v}-${name}; see simai-admin.sh php extensions --php ${v}"; return 1; }
    run_long "Installing php${v}-${name}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "php${v}-${name}" || return 1
    [[ -f "$ini" ]] || { error "php${v}-${name} brings no ${name}.ini"; return 1; }
  fi
  [[ -f "$ini" ]] || { error "Extension ${name} is not installed for PHP ${v}"; return 1; }
  if [[ "$enabled" == yes ]]; then phpenmod -v "$v" -s fpm "$name"; else phpdismod -v "$v" -s fpm "$name"; fi
  if ! "$fpm" -t >>"$LOG_FILE" 2>&1; then
    if [[ "$was" == yes ]]; then phpenmod -v "$v" -s fpm "$name"; else phpdismod -v "$v" -s fpm "$name"; fi
    error "php-fpm${v} rejects the change; the previous state is back. See ${LOG_FILE}"
    return 1
  fi
  os_svc_reload_or_restart "php${v}-fpm" || { error "php${v}-fpm did not reload"; return 1; }
  ui_result_table "PHP|${v}" "Extension|${name}" "Enabled|${enabled}"
}

# Install the package updates of one PHP version (fixes within the version,
# never a new version) and check the sites on it before and after.
php_update_handler() {
  parse_kv_args "$@"
  require_args "php" || return 1
  local v="${PARSED_ARGS[php]}"
  php_installed_or_fail "$v" || return 1
  local -a sites=() pkgs=() answered=() stopped=()
  mapfile -t sites < <(php_sites_on "$v")
  mapfile -t pkgs < <(python3 -I "${SCRIPT_DIR}/lib/php_versions.py" packages "$v")
  if (( ${#sites[@]} )); then
    mapfile -t answered < <(self_update_site_answers | grep -Fxf <(printf '%s\n' "${sites[@]}") || true)
  fi
  local before after
  before=$(dpkg-query -W -f '${Version}' "php${v}-fpm" 2>/dev/null || true)
  os_cmd_pkg_update
  run_long "Updating apt indexes" "${OS_CMD[@]}" || return 1
  run_long "Updating PHP ${v} packages" env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${pkgs[@]}" || return 1
  after=$(dpkg-query -W -f '${Version}' "php${v}-fpm" 2>/dev/null || true)
  "/usr/sbin/php-fpm${v}" -t >>"$LOG_FILE" 2>&1 || { error "php-fpm${v} configuration test fails after the update. See ${LOG_FILE}"; return 1; }
  os_svc_restart "php${v}-fpm" || { error "php${v}-fpm did not start after the update"; return 1; }
  if (( ${#answered[@]} )); then
    local _
    for _ in 1 2 3; do
      mapfile -t stopped < <(comm -23 <(printf '%s\n' "${answered[@]}" | sort) <(self_update_site_answers))
      (( ${#stopped[@]} == 0 )) && break
      sleep 3
    done
  fi
  ui_result_table "PHP|${v}" "Version|${before:-?} -> ${after:-?}" "Sites checked|${#answered[@]}" \
    "Stopped answering|$( (( ${#stopped[@]} )) && echo "${stopped[*]}" || echo none)"
  (( ${#stopped[@]} == 0 )) || { error "Sites stopped answering after the PHP ${v} update: ${stopped[*]}"; return 1; }
}

# Extensions PHP-FPM of one version loads, and the packaged ones it does not.
php_extensions_handler() {
  parse_kv_args "$@"
  local php_version="${PARSED_ARGS[php]:-}"
  require_args "php" || return 1
  [[ "$php_version" =~ ^[5-9]\.[0-9]$ && -d "/etc/php/${php_version}" ]] || { error "PHP ${php_version} is not installed"; return 1; }
  local fpm="/usr/sbin/php-fpm${php_version}"
  [[ -x "$fpm" ]] || { error "php-fpm${php_version} not found"; return 1; }
  "$fpm" -m 2>/dev/null | python3 -c '
import json, os, sys
loaded = set()
for line in sys.stdin:
    line = line.strip()
    if line and not line.startswith("["):
        loaded.add("opcache" if line == "Zend OPcache" else line.lower())
mods = "/etc/php/%s/mods-available" % sys.argv[1]
available = {f[:-4].lower() for f in (os.listdir(mods) if os.path.isdir(mods) else []) if f.endswith(".ini")}
rows = [{"name": n, "enabled": n in loaded} for n in sorted(loaded | available)]
if sys.argv[2] == "json":
    json.dump({"schema": "simai-php-extensions/1", "php": sys.argv[1], "extensions": rows}, sys.stdout)
    print()
else:
    for r in rows:
        print("%-24s %s" % (r["name"], "enabled" if r["enabled"] else "available"))
' "$php_version" "${SIMAI_COMMAND_OUTPUT:-human}"
}

php_reload_handler() {
  parse_kv_args "$@"
  local php_version="${PARSED_ARGS[php]:-}"
  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(installed_php_versions)
    if [[ ${#versions[@]} -eq 0 ]]; then
      error "No installed PHP versions available for reload"
      return 1
    fi
    php_version=$(select_from_list "Select PHP version to reload" "" "${versions[@]}")
    if [[ -z "$php_version" ]]; then
      command_cancelled
      return $?
    fi
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi
  [[ -z "$php_version" ]] && return 1
  local svc="php${php_version}-fpm"
  info "Reloading ${svc}"
  os_svc_reload_or_restart "$svc"
}

php_install_handler() {
  parse_kv_args "$@"
  local php_version="${PARSED_ARGS[php]:-}"
  local include_common="${PARSED_ARGS[include-common]:-yes}"
  local confirm="${PARSED_ARGS[confirm]:-no}"

  if [[ -z "$php_version" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local versions=()
    mapfile -t versions < <(php_list_available_install_versions)
    if [[ ${#versions[@]} -eq 0 ]]; then
      error "No installable PHP versions found in apt metadata. Run apt update or check configured repositories."
      return 1
    fi
    local default_sel=""
    default_sel=$(php_pick_preferred_version "${versions[@]}" || true)
    php_version=$(select_from_list "Select PHP version to install" "$default_sel" "${versions[@]}")
    if [[ -z "$php_version" ]]; then
      command_cancelled
      return $?
    fi
  fi
  if [[ -z "$php_version" ]]; then
    require_args "php"
  fi

  include_common=$([[ "${include_common,,}" == "no" ]] && echo "no" || echo "yes")

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Install common extensions?" "yes" "yes" "no")
    if [[ -z "$choice" ]]; then
      command_cancelled
      return $?
    fi
    include_common="$choice"
    local proceed
    proceed=$(select_from_list "Proceed with installation?" "no" "no" "yes")
    if [[ "$proceed" != "yes" ]]; then
      command_cancelled "Installation cancelled"
      return $?
    fi
  fi

  if ! validate_php_version "$php_version"; then
    return 1
  fi

  local missing_pkgs=()
  mapfile -t missing_pkgs < <(detect_missing_php_packages "$php_version" "$include_common")
  local total_steps=4
  [[ ${#missing_pkgs[@]} -gt 0 ]] && total_steps=7
  progress_init "$total_steps"
  progress_step "Checking current PHP installation"

  if [[ ${#missing_pkgs[@]} -eq 0 ]]; then
    progress_step "Testing php-fpm${php_version} configuration"
  else
    if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "${confirm,,}" != "yes" ]]; then
      error "Will install packages: ${missing_pkgs[*]}. Re-run with --confirm yes to proceed."
      return 1
    fi
    progress_step "Ensuring a repository for PHP ${php_version}"
    if ! ensure_ondrej_php_repo "$php_version"; then
      return 1
    fi
    progress_step "Updating apt indexes"
    os_cmd_pkg_update
    if ! run_long "Updating apt indexes" "${OS_CMD[@]}"; then
      return 1
    fi

    progress_step "Installing PHP ${php_version} packages"
    # A newer version would take over the php command (cron, CLI scripts);
    # the command stays on the version it was.
    local cli_before=""
    cli_before=$(readlink -f /etc/alternatives/php 2>/dev/null || true)
    os_cmd_pkg_install "${missing_pkgs[@]}"
    if ! run_long "Installing PHP ${php_version}" "${OS_CMD[@]}"; then
      return 1
    fi
    if [[ -n "$cli_before" && -x "$cli_before" && "$(readlink -f /etc/alternatives/php 2>/dev/null)" != "$cli_before" ]]; then
      update-alternatives --set php "$cli_before" >/dev/null 2>&1 || warn "The php command now runs $(readlink -f /etc/alternatives/php)"
    fi
    progress_step "Testing php-fpm${php_version} configuration"
  fi

  local fpm_bin_path=""
  fpm_bin_path=$(command -v "php-fpm${php_version}" 2>/dev/null || true)
  if [[ -z "$fpm_bin_path" && -x "/usr/sbin/php-fpm${php_version}" ]]; then
    fpm_bin_path="/usr/sbin/php-fpm${php_version}"
  fi
  if [[ -n "$fpm_bin_path" ]]; then
    if ! "$fpm_bin_path" -t >>"$LOG_FILE" 2>&1; then
      error "php-fpm${php_version} config test failed. See ${LOG_FILE}"
      return 1
    fi
  else
    error "php-fpm${php_version} binary not found after install"
    return 1
  fi

  progress_step "Enabling php${php_version}-fpm service"
  if ! os_svc_enable_now "php${php_version}-fpm"; then
    error "Failed to enable/start php${php_version}-fpm. See ${LOG_FILE}"
    return 1
  fi

  progress_step "Verifying php${php_version}-fpm status"
  local svc_status
  if os_svc_is_active "php${php_version}-fpm"; then
    svc_status="active"
  else
    svc_status="inactive"
  fi
  if [[ "$svc_status" != "active" ]]; then
    error "php${php_version}-fpm service is ${svc_status}"
    return 1
  fi

  progress_done "PHP ${php_version} installation complete"
  echo "===== PHP install summary ====="
  echo "PHP version : ${php_version}"
  echo "Packages    : $([[ ${#missing_pkgs[@]} -gt 0 ]] && echo "${missing_pkgs[*]}" || echo none)"
  echo "php binary  : $(command -v "php${php_version}" || echo missing)"
  echo "php-fpm bin : ${fpm_bin_path:-missing}"
  echo "Service     : ${svc_status}"
  echo "Next steps  : To switch a site, run: simai-admin.sh site set-php --domain <domain> --php ${php_version}"
}

register_cmd "php" "list" "List installed PHP versions and FPM status" "php_list_handler" "" "" "effects:read"
register_cmd "php" "extensions" "List PHP-FPM extensions of a PHP version: loaded and available" "php_extensions_handler" "php" "" "effects:read"
register_cmd "php" "reload" "Reload or restart PHP-FPM for version" "php_reload_handler" "" "php=" "menu:confirm"
register_cmd "php" "install" "Install a PHP version (FPM/CLI + base extensions)" "php_install_handler" "" "php= include-common= confirm=" "menu:internal-confirm"
register_cmd "php" "remove" "Remove a PHP version that no site, the system or the php command uses" "php_remove_handler" "php" "" "tier:advanced"
register_cmd "php" "extension" "Turn a PHP-FPM extension on or off (installs its package when needed)" "php_extension_handler" "php name enabled" "" "tier:advanced"
register_cmd "php" "update" "Install package updates of one PHP version and check its sites" "php_update_handler" "php" "" "tier:advanced"
