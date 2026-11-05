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

# One field of a catalogue entry (software_state.py entry KEY) held in $SOFTWARE_ENTRY.
software_field() {
  python3 -I -c 'import json,sys
v = json.loads(sys.argv[1])
for k in sys.argv[2].split("."):
    v = v.get(k) if isinstance(v, dict) else None
print(" ".join(v) if isinstance(v, list) else ("" if v is None else v))' "$SOFTWARE_ENTRY" "$1"
}

software_entry() {
  [[ "$1" =~ ^[a-z0-9-]{1,32}$ ]] && SOFTWARE_ENTRY=$(software_state entry "$1") || { error "Unknown program: $1 (see software list)"; return 1; }
}

# Installs the packages of an apt program and its PHP extension for every
# PHP-FPM version, or upgrades them when the program is installed.
software_apt_apply() {
  local mode="$1" title pkgs ext v
  title=$(software_field title); pkgs=$(software_field packages); ext=$(software_field php_extensions)
  local -a opts=(-o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
  # shellcheck disable=SC2086 # package lists are words
  if [[ "$mode" == update ]]; then
    run_long "Updating ${title}" env DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade "${opts[@]}" $pkgs || return 1
  else
    run_long "Installing ${title}" env DEBIAN_FRONTEND=noninteractive apt-get install -y "${opts[@]}" $pkgs || return 1
  fi
  local service
  service=$(software_field unit)
  [[ -z "$service" || "$mode" == update ]] || os_svc_enable_now "$service" >/dev/null 2>&1 || true
  for v in $ext; do
    if env DEBIAN_FRONTEND=noninteractive apt-get install -y "${opts[@]}" "$v" >>"$LOG_FILE" 2>&1; then
      os_svc_reload_or_restart "$(sed -E 's/^php([0-9.]+)-.*/php\1-fpm/' <<<"$v")" >/dev/null 2>&1 || true
    else
      warn "Could not install ${v}"
    fi
  done
  SOFTWARE_ENTRY=$(software_state entry "$(software_field key)")
  ui_result_table "Program|${title}" "Version|$(software_field version)" "State|$(software_field state)"
}

software_install_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" version="${PARSED_ARGS[version]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  software_entry "$name" || return 1
  local title how installed
  title=$(software_field title); how=$(software_field how); installed=$(software_field installed)
  # A Node.js major version is its own path (one runtime per server).
  if [[ "$name" == node && -n "$version" ]]; then software_install_node "$version" "$confirm"; return; fi
  if [[ "$installed" == True && "$(software_field can_update)" == True ]]; then
    [[ -z "$version" ]] || { error "--version is for a new installation; ${title} is installed"; return 1; }
    if [[ "${confirm,,}" != yes ]]; then
      echo "Plan: update ${title} from $(software_field version) to $(software_field candidate) ($(software_field packages)); changed configuration files are kept"
      echo "Rerun with --confirm yes to apply."
      return 0
    fi
    software_apt_apply update
    return
  fi
  local why
  why=$(software_field install_blocked.text)
  case "$name" in
    node) software_install_node "${version:-22}" "$confirm"; return ;;
    postgresql)
      [[ "$installed" != True ]] || { error "$why"; return 1; }
      local native pgdg=no
      native=$(pgsql_ubuntu_major)
      [[ -n "$version" && "$version" != "$native" ]] && pgdg=yes
      db_pgsql_install_handler ${version:+--version "$version"} --pgdg "$pgdg" --confirm "$confirm"; return ;;
  esac
  [[ -z "$why" ]] || { error "$why"; return 1; }
  [[ -z "$version" ]] || { error "${title} comes from Ubuntu; --version is not used"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    case "$how" in
      apache) echo "Plan: install Apache listening on 127.0.0.1:${SIMAI_APACHE_PORT} only; nginx keeps ports 80 and 443; no site changes until site apache" ;;
      *) echo "Plan: install ${title} from Ubuntu ($(software_field packages))$( [[ -n "$(software_field php_extensions)" ]] && echo " and $(software_field php_extensions)")$( [[ -n "$(software_field unit)" ]] && echo "; starts the $(software_field unit) service")" ;;
    esac
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  if [[ "$how" == apache ]]; then
    apache_install || return 1
    ui_result_table "Program|Apache" "Listens|127.0.0.1:${SIMAI_APACHE_PORT}" "Service|$(systemctl is-active apache2 2>/dev/null || echo unknown)"
    return
  fi
  software_apt_apply install
}

# Removes a program's packages (apt-get remove: configuration and data stay),
# refused while sites need it or when apt would take a protected package too.
software_remove_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" confirm="${PARSED_ARGS[confirm]:-no}"
  software_entry "$name" || return 1
  local title why removes protected keeps
  title=$(software_field title); why=$(software_field remove_blocked.text)
  if [[ -n "$why" ]]; then
    local sites
    sites=$(software_field remove_blocked.sites)
    error "${why}${sites:+: ${sites}}; nothing removed"
    return 1
  fi
  removes=$(software_field removes); protected=$(software_field removes_protected); keeps=$(software_field keeps)
  if [[ -n "$protected" ]]; then
    error "Removing ${title} would also remove ${protected}; nothing removed"
    return 1
  fi
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: remove ${title}: ${removes:-$(software_field packages)}"
    echo "      configuration and data stay${keeps:+ (${keeps})}; installing it again picks them up"
    [[ -z "$(software_field service)" ]] || echo "      the $(software_field service) service stops"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  # shellcheck disable=SC2086 # package lists are words
  run_long "Removing ${title}" env DEBIAN_FRONTEND=noninteractive apt-get remove -y $removes || return 1
  local v
  for v in $(software_field php_extensions); do
    os_svc_reload_or_restart "$(sed -E 's/^php([0-9.]+)-.*/php\1-fpm/' <<<"$v")" >/dev/null 2>&1 || true
  done
  ui_result_table "Program|${title}" "Removed|${removes}" "Kept|${keeps:-configuration}"
}

register_cmd "software" "list" "Show the catalogue of server programs (state, actions) and waiting system updates" "software_list_handler" "" "" "tier:advanced effects:read"
register_cmd "software" "refresh" "Refresh the apt index so software list shows new updates" "software_refresh_handler" "" "" "tier:advanced"
register_cmd "software" "update" "Install waiting system package updates and check every site" "software_update_handler" "" "security-only= confirm=" "tier:advanced plan:handler"
register_cmd "software" "install" "Install a program from the catalogue (software list), or update it when installed" "software_install_handler" "name" "version= confirm=" "tier:advanced plan:handler"
register_cmd "software" "remove" "Remove a program (configuration and data stay); refused while sites need it" "software_remove_handler" "name" "confirm=" "tier:advanced plan:handler"
