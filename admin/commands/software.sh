#!/usr/bin/env bash
set -euo pipefail

# Server software: the components simai-env manages and the package updates
# of the whole system (simai-software/1). PHP versions have their own
# commands (php list/install/update); PostgreSQL install is db pgsql-install.

software_state() { python3 -I "${SCRIPT_DIR}/lib/software_state.py" "$@"; }

software_list_handler() {
  parse_kv_args "$@"
  software_state "${SIMAI_COMMAND_OUTPUT:-human}"
}

# Refresh the apt index so list shows updates published since the last refresh.
software_refresh_handler() {
  parse_kv_args "$@"
  os_cmd_pkg_update
  run_long "Updating apt indexes" "${OS_CMD[@]}" || return 1
  ui_result_table "Updates|$(software_state upgradable | wc -l | tr -d ' ')" \
    "Security updates|$(software_state upgradable security | wc -l | tr -d ' ')"
}

# Install the waiting package updates (all, or only security ones) without
# installing or removing other packages, keep changed configuration files,
# then check that nginx and PHP-FPM still accept their configuration and that
# every site that answered before still answers. Packages cannot be rolled
# back; a site that stops answering fails the command with its name.
software_update_handler() {
  parse_kv_args "$@"
  local security="${PARSED_ARGS[security-only]:-no}" confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "$security" =~ ^(yes|no)$ ]] || { error "--security-only must be yes or no"; return 1; }
  local -a pkgs=() answered=() stopped=()
  if [[ "$security" == yes ]]; then
    mapfile -t pkgs < <(software_state upgradable security)
  else
    mapfile -t pkgs < <(software_state upgradable)
  fi
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: refresh the apt index and install $( [[ "$security" == yes ]] && echo "security" || echo "all") package updates"
    echo "      waiting now: ${#pkgs[@]}${pkgs[*]:+ (${pkgs[*]:0:20})}; the refresh may add more"
    echo "      no package is installed or removed besides upgrades; changed configuration files are kept"
    echo "      checks nginx and PHP-FPM configuration and every site that answers; packages are not rolled back"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  mapfile -t answered < <(self_update_site_answers)
  os_cmd_pkg_update
  run_long "Updating apt indexes" "${OS_CMD[@]}" || return 1
  local -a dpkg_opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  if [[ "$security" == yes ]]; then
    mapfile -t pkgs < <(software_state upgradable security)
    if (( ${#pkgs[@]} )); then
      run_long "Installing ${#pkgs[@]} security updates" env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --only-upgrade "${dpkg_opts[@]}" "${pkgs[@]}" || return 1
    fi
  else
    mapfile -t pkgs < <(software_state upgradable)
    if (( ${#pkgs[@]} )); then
      run_long "Installing ${#pkgs[@]} updates" env DEBIAN_FRONTEND=noninteractive \
        apt-get upgrade -y "${dpkg_opts[@]}" || return 1
    fi
  fi
  local -a broken=()
  nginx -t >>"$LOG_FILE" 2>&1 || broken+=("nginx")
  local v
  while IFS= read -r v; do
    [[ -n "$v" && -x "/usr/sbin/php-fpm${v}" ]] || continue
    "/usr/sbin/php-fpm${v}" -t >>"$LOG_FILE" 2>&1 || broken+=("php${v}-fpm")
  done < <(installed_php_versions)
  if (( ${#answered[@]} )); then
    local _
    for _ in 1 2 3; do
      mapfile -t stopped < <(comm -23 <(printf '%s\n' "${answered[@]}") <(self_update_site_answers))
      (( ${#stopped[@]} == 0 )) && break
      sleep 5
    done
  fi
  local reboot=no
  [[ -f /run/reboot-required ]] && reboot=yes
  ui_result_table "Packages updated|${#pkgs[@]}" "Sites checked|${#answered[@]}" \
    "Stopped answering|$( (( ${#stopped[@]} )) && echo "${stopped[*]}" || echo none)" \
    "Configuration|$( (( ${#broken[@]} )) && echo "rejected by ${broken[*]}" || echo ok)" \
    "Reboot required|${reboot}"
  (( ${#broken[@]} == 0 )) || { error "Configuration test fails after the update: ${broken[*]}. See ${LOG_FILE}"; return 1; }
  (( ${#stopped[@]} == 0 )) || { error "Sites stopped answering after the update: ${stopped[*]}"; return 1; }
}

# NodeSource repository code lives in the installer; take it from there so
# both use one pinned signing key.
# shellcheck disable=SC2034,SC2329 # read and called by the evaluated installer code
software_nodesource_repo() {
  local NODE_VERSION="$1" APT_UPDATED=0
  eval "$(sed -n '/^NODESOURCE_KEY_FPR=/p' "${SCRIPT_DIR}/simai-env.sh")"
  apt_update_once() {
    os_cmd_pkg_update
    run_long "Updating apt indexes" "${OS_CMD[@]}"
  }
  eval "$(awk '/^add_nodesource_repo\(\) \{/,/^\}/' "${SCRIPT_DIR}/simai-env.sh")"
  add_nodesource_repo
}

software_install_node() {
  local major="$1" current="" confirm="$2"
  [[ "$major" =~ ^[0-9]{2}$ ]] || { error "--version must be a Node.js major version such as 22"; return 1; }
  command -v node >/dev/null 2>&1 && current=$(node -v 2>/dev/null | sed 's/^v//; s/\..*//')
  local -a sites=()
  mapfile -t sites < <(software_state node-sites)
  if [[ -n "$current" && "$current" != "$major" && ${#sites[@]} -gt 0 ]]; then
    error "Node.js ${current} serves ${#sites[@]} node site(s): ${sites[*]}. Changing the major version would restart them on another runtime; there is one Node.js per server"
    return 1
  fi
  if [[ "${confirm,,}" != yes ]]; then
    if [[ "$current" == "$major" ]]; then
      echo "Plan: nothing to do, Node.js ${major} is installed"
    else
      echo "Plan: install Node.js ${major} from the NodeSource repository (signing key pinned by fingerprint)${current:+, replacing Node.js ${current}}"
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  [[ "$current" == "$major" ]] && { ui_result_table "Node.js|$(node -v)" "Change|none"; return 0; }
  software_nodesource_repo "$major" || { error "Cannot add the NodeSource repository"; return 1; }
  run_long "Installing Node.js ${major}" env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs || return 1
  ui_result_table "Node.js|$(node -v 2>/dev/null || echo '?')" "Previous|${current:-none}"
}

software_install_redis() {
  local confirm="$1" v
  if [[ "${confirm,,}" != yes ]]; then
    if dpkg-query -W -f '${db:Status-Abbrev}' redis-server 2>/dev/null | grep -q '^ii'; then
      echo "Plan: nothing to do, Redis is installed"
    else
      echo "Plan: install redis-server from Ubuntu (listens on localhost only) and php<ver>-redis for every installed PHP-FPM version"
    fi
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  run_long "Installing redis-server" env DEBIAN_FRONTEND=noninteractive apt-get install -y redis-server || return 1
  os_svc_enable_now redis-server || true
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    if env DEBIAN_FRONTEND=noninteractive apt-get install -y "php${v}-redis" >>"$LOG_FILE" 2>&1; then
      os_svc_reload_or_restart "php${v}-fpm" >/dev/null 2>&1 || true
    else
      warn "Could not install php${v}-redis"
    fi
  done < <(installed_php_versions)
  ui_result_table "Redis|$(redis-server --version 2>/dev/null | awk '{print $3}' | sed 's/^v=//')" \
    "Service|$(systemctl is-active redis-server 2>/dev/null || echo unknown)"
}

software_install_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" version="${PARSED_ARGS[version]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  case "$name" in
    node) software_install_node "${version:-22}" "$confirm" ;;
    redis)
      [[ -z "$version" ]] || { error "Redis comes from Ubuntu; --version is not used"; return 1; }
      software_install_redis "$confirm" ;;
    postgresql)
      local native pgdg=no
      native=$(pgsql_ubuntu_major)
      [[ -n "$version" && "$version" != "$native" ]] && pgdg=yes
      db_pgsql_install_handler ${version:+--version "$version"} --pgdg "$pgdg" --confirm "$confirm" ;;
    *) error "--name must be node, redis or postgresql (PHP: simai-admin.sh php install)"; return 1 ;;
  esac
}

register_cmd "software" "list" "Show server software (web server, databases, Redis, Node.js) and waiting system updates" "software_list_handler" "" "" "tier:advanced effects:read"
register_cmd "software" "refresh" "Refresh the apt index so software list shows new updates" "software_refresh_handler" "" "" "tier:advanced"
register_cmd "software" "update" "Install waiting system package updates and check every site" "software_update_handler" "" "security-only= confirm=" "tier:advanced plan:handler"
register_cmd "software" "install" "Install Node.js, Redis or PostgreSQL" "software_install_handler" "name" "version= confirm=" "tier:advanced plan:handler"
