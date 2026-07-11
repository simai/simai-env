#!/usr/bin/env bash
set -euo pipefail

prompt() {
  local label="$1" default="${2:-}"
  local value
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]] && command -v whiptail >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
    ui_terminal_geometry
    local input_width="$UI_DIALOG_WIDTH"
    (( input_width > 90 )) && input_width=90
    if [[ -n "$default" ]]; then
      value=$(whiptail --title "SIMAI ENV" --inputbox "$label" 10 "$input_width" "$default" 3>&1 1>&2 2>&3) || return 1
    else
      value=$(whiptail --title "SIMAI ENV" --inputbox "$label" 10 "$input_width" 3>&1 1>&2 2>&3) || return 1
    fi
    echo "$value"
    return 0
  fi
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || true
    [[ -z "$value" ]] && value="$default"
  else
    read -r -p "$label: " value || true
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    case "${value,,}" in
      0|cancel|back|q|quit|exit)
        echo ""
        return 1
        ;;
    esac
  fi
  echo "$value"
}

print_version_banner() {
  if declare -F self_auto_update_check_if_due >/dev/null 2>&1; then
    self_auto_update_check_if_due
  fi
  local update_ref="${SIMAI_UPDATE_REF:-refs/heads/${SIMAI_UPDATE_BRANCH:-main}}"
  local local_version="(unknown)"
  local remote_version="(unavailable)"
  local status="n/a"
  if declare -F self_auto_update_state_get >/dev/null 2>&1; then
    update_ref="$(self_auto_update_state_get "update_ref" 2>/dev/null || echo "$update_ref")"
    local_version="$(self_auto_update_state_get "local_version" 2>/dev/null || true)"
    remote_version="$(self_auto_update_state_get "remote_version" 2>/dev/null || true)"
    status="$(self_auto_update_state_get "status" 2>/dev/null || true)"
  fi
  if [[ -f "${SCRIPT_DIR}/VERSION" ]]; then
    local_version="$(cat "${SCRIPT_DIR}/VERSION")"
  fi
  [[ -z "$remote_version" ]] && remote_version="(unavailable)"
  if declare -F self_auto_update_status_from_versions >/dev/null 2>&1; then
    status="$(self_auto_update_status_from_versions "$local_version" "$remote_version")"
  fi
  [[ -z "$status" ]] && status="n/a"
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

preflight_bootstrap() {
  if [[ "${SIMAI_PREFLIGHT_DONE:-0}" -eq 1 ]]; then
    return
  fi
  SIMAI_PREFLIGHT_DONE=1
  local missing=()
  command -v nginx >/dev/null 2>&1 || missing+=("nginx")
  if ! compgen -G "/etc/php/*/fpm/php-fpm.conf" >/dev/null 2>&1; then
    missing+=("php-fpm")
  fi
  if ! command -v mysql >/dev/null 2>&1 && ! command -v mysqld >/dev/null 2>&1; then
    missing+=("mysql-server")
  fi
  command -v certbot >/dev/null 2>&1 || missing+=("certbot")
  if [[ ${#missing[@]} -eq 0 ]]; then
    return
  fi
  echo "Missing components detected: ${missing[*]}"
  local choice
  choice=$(select_from_list "Install required packages now?" "no" "no" "yes")
  [[ -z "$choice" ]] && choice="no"
  if [[ "$choice" == "yes" ]]; then
    set +e
    run_command self bootstrap
    local rc=$?
    set -e
    if [[ $rc -ne 0 ]]; then
      warn "Bootstrap failed with exit code ${rc}; you can rerun from menu (self -> bootstrap)."
    fi
  fi
}

menu_spawn_restart() {
  info "Starting fresh admin menu process..."
  exec bash "${SCRIPT_DIR}/simai-admin.sh" menu
}

run_menu() {
  export SIMAI_ADMIN_MENU=1
  if [[ ! -t 0 ]]; then
    if [[ -e /dev/tty && -r /dev/tty && -w /dev/tty ]]; then
      exec </dev/tty >/dev/tty 2>/dev/tty
    else
      error "Interactive TTY required for menu"
      return 1
    fi
  fi
  local reload_requested=1
  export SIMAI_MENU_PATH="${SIMAI_MENU_PATH:-main}"
  export SIMAI_MENU_RESTORE_PATH="${SIMAI_MENU_RESTORE_PATH:-}"
  local requested_backend="${SIMAI_MENU_BACKEND:-text}"
  menu_init_whiptail_theme() {
    if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" && -z "${NEWT_COLORS:-}" ]]; then
      export NEWT_COLORS='
root=,blue
window=white,black
border=white,black
title=yellow,black
textbox=white,black
button=black,white
actbutton=black,cyan
entry=white,black
listbox=white,black
actlistbox=black,cyan
compactbutton=black,white
actsellistbox=black,cyan
'
    fi
  }
  menu_pause_after_command() {
    local section="$1" cmd="$2" rc="$3" output_file="$4" streamed="${5:-no}"
    local status="SUCCESS"
    if [[ "$rc" -eq ${SIMAI_RC_MENU_RELOAD:-88} ]]; then
      status="SUCCESS (menu reload)"
    elif [[ "$rc" -eq ${SIMAI_RC_CANCELLED:-89} ]]; then
      status="CANCELLED"
    elif [[ "$rc" -ne 0 ]]; then
      status="FAILED (${rc})"
    fi
    echo
    echo "Result: ${section} ${cmd}"
    echo "Status: ${status}"
    if [[ "$streamed" == "yes" ]]; then
      if [[ -s "$output_file" ]]; then
        echo "(output shown above)"
      else
        echo "(no output)"
      fi
    elif [[ -s "$output_file" ]]; then
      cat "$output_file"
    else
      echo "(no output)"
    fi
    echo
    read -r -p "Press Enter to continue..." _menu_continue || true
  }
  menu_set_path() {
    local path="${1:-main}"
    export SIMAI_MENU_PATH="$path"
  }
  menu_set_restore_path() {
    local path="${1:-main}"
    export SIMAI_MENU_RESTORE_PATH="$path"
  }
  menu_clear_restore_path() {
    export SIMAI_MENU_RESTORE_PATH=""
  }
  menu_run_auto_update() {
    local path="${1:-main}"
    local out_file rc=0
    menu_set_restore_path "$path"
    echo
    echo "---- automatic update available; applying at safe point ----"
    out_file="$(mktemp)"
    if run_command self update 2>&1 | tee "$out_file"; then
      rc=0
    else
      rc=$?
    fi
    rm -f "$out_file"
    if [[ $rc -eq ${SIMAI_RC_MENU_RELOAD:-88} ]]; then
      menu_spawn_restart
    fi
    warn "Automatic update failed or did not request reload; staying in current menu."
    return 0
  }
  menu_auto_update_apply_if_safe() {
    local path="${1:-main}"
    menu_set_path "$path"
    if ! declare -F self_auto_update_mode >/dev/null 2>&1; then
      return 0
    fi
    if [[ "$(self_auto_update_mode 2>/dev/null || echo check)" != "apply-safe" ]]; then
      return 0
    fi
    self_auto_update_check_if_due || true
    local status=""
    status="$(self_auto_update_state_get "status" 2>/dev/null || true)"
    if [[ "$status" == "update available" ]]; then
      menu_run_auto_update "$path"
    fi
    return 0
  }
  menu_open_restore_path() {
    local path="${SIMAI_MENU_RESTORE_PATH:-}"
    [[ -z "$path" ]] && return 1
    menu_clear_restore_path
    case "$path" in
      main) return 0 ;;
      sites) sites_menu; return 0 ;;
      ssl) ssl_menu; return 0 ;;
      php) php_menu; return 0 ;;
      db) db_menu; return 0 ;;
      diagnostics) diagnostics_menu; return 0 ;;
      logs) logs_menu; return 0 ;;
      backup) backup_menu; return 0 ;;
      applications) applications_menu; return 0 ;;
      access) access_menu; return 0 ;;
      applications:laravel) laravel_app_menu; return 0 ;;
      applications:wordpress) wordpress_app_menu; return 0 ;;
      applications:bitrix) bitrix_app_menu; return 0 ;;
      profiles) profiles_menu; return 0 ;;
      system) system_menu; return 0 ;;
      *) return 1 ;;
    esac
  }
  case "${requested_backend,,}" in
    whiptail)
      if command -v whiptail >/dev/null 2>&1; then
        export SIMAI_MENU_BACKEND="whiptail"
      else
        warn "whiptail requested but not installed; falling back to text menu."
        export SIMAI_MENU_BACKEND="text"
      fi
      ;;
    *)
      export SIMAI_MENU_BACKEND="text"
      ;;
  esac
  local show_advanced="${SIMAI_MENU_SHOW_ADVANCED:-0}"
  case "${show_advanced,,}" in
    1|yes|true) show_advanced=1 ;;
    *) show_advanced=0 ;;
  esac
  export SIMAI_MENU_SHOW_ADVANCED="$show_advanced"
  menu_init_whiptail_theme

  menu_toggle_backend() {
    if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]]; then
      export SIMAI_MENU_BACKEND="text"
      return 0
    fi
    if command -v whiptail >/dev/null 2>&1; then
      export SIMAI_MENU_BACKEND="whiptail"
      menu_init_whiptail_theme
    else
      warn "whiptail is not installed; backend stays text."
    fi
  }

  menu_choose_key() {
    local title="$1" prompt_text="$2" default_key="${3:-}"
    shift 3
    local -a items=("$@")
    if [[ ${#items[@]} -eq 0 ]]; then
      echo ""
      return 1
    fi
    if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]] && command -v whiptail >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
      local -a opts=()
      local item key label selected=""
      for item in "${items[@]}"; do
        key="${item%%|*}"
        label="${item#*|}"
        opts+=("$key" "$label")
        if [[ -n "$default_key" && "$key" == "$default_key" ]]; then
          selected="$key"
        fi
      done
      local out rc=0
      ui_terminal_geometry
      if [[ -n "$selected" ]]; then
        out=$(whiptail --title "$title" --default-item "$selected" --menu "$prompt_text" "$UI_DIALOG_HEIGHT" "$UI_DIALOG_WIDTH" "$UI_LIST_HEIGHT" "${opts[@]}" 3>&1 1>&2 2>&3) || rc=$?
      else
        out=$(whiptail --title "$title" --menu "$prompt_text" "$UI_DIALOG_HEIGHT" "$UI_DIALOG_WIDTH" "$UI_LIST_HEIGHT" "${opts[@]}" 3>&1 1>&2 2>&3) || rc=$?
      fi
      if [[ $rc -ne 0 ]]; then
        echo "0"
        return 0
      fi
      echo "$out"
      return 0
    fi

    echo >&2
    [[ -n "$title" ]] && echo "$title" >&2
    local item key label
    for item in "${items[@]}"; do
      key="${item%%|*}"
      label="${item#*|}"
      printf "  [%s] %s\n" "$key" "$label" >&2
    done
    local choice=""
    if [[ -n "$default_key" ]]; then
      if ! read -r -p "${prompt_text} [${default_key}]: " choice; then
        echo "0"
        return 0
      fi
      [[ -z "$choice" ]] && choice="$default_key"
    else
      if ! read -r -p "${prompt_text}: " choice; then
        echo "0"
        return 0
      fi
    fi
    [[ -z "$choice" ]] && { echo ""; return 0; }
    for item in "${items[@]}"; do
      key="${item%%|*}"
      if [[ "$choice" == "$key" ]]; then
        echo "$choice"
        return 0
      fi
    done
    echo "__invalid__"
    return 0
  }

  menu_args_has_key() {
    local key="$1"; shift
    local a
    for a in "$@"; do
      if [[ "$a" == "--${key}" || "$a" == "--${key}="* ]]; then
        return 0
      fi
    done
    return 1
  }

  menu_prompt_required_arg() {
    local section="$1" cmd="$2" key="$3"
    local val=""
    case "$key" in
      domain)
        if [[ "$section" == "site" && "$cmd" == "add" ]]; then
          val=$(prompt "domain")
        else
          local sites=()
          mapfile -t sites < <(list_sites)
          if [[ ${#sites[@]} -gt 0 ]]; then
            val=$(select_from_list "Select domain" "" "${sites[@]}")
          else
            val=$(prompt "$key")
          fi
        fi
        ;;
      id)
        if [[ "$section" == "profile" ]]; then
          local profile_ids=()
          case "$cmd" in
            disable)
              mapfile -t profile_ids < <(list_enabled_profile_ids 2>/dev/null || true)
              ;;
            used-by-one|enable|used-by)
              mapfile -t profile_ids < <(list_profile_ids 2>/dev/null || true)
              ;;
          esac
          if [[ ${#profile_ids[@]} -gt 0 ]]; then
            val=$(select_from_list "Select profile" "" "${profile_ids[@]}")
          else
            val=$(prompt "$key")
          fi
        else
          val=$(prompt "$key")
        fi
        ;;
      login)
        if [[ "$section" == "access" && "$cmd" != "create-global" && "$cmd" != "create-project" ]]; then
          local access_logins=()
          if declare -F access_list_logins >/dev/null 2>&1; then
            mapfile -t access_logins < <(access_list_logins 2>/dev/null || true)
          fi
          if [[ ${#access_logins[@]} -gt 0 ]]; then
            val=$(select_from_list "Select access login" "" "${access_logins[@]}")
          else
            val=$(prompt "$key")
          fi
        else
          val=$(prompt "$key")
        fi
        ;;
      file)
        if [[ "$section" == "backup" && ( "$cmd" == "inspect" || "$cmd" == "import" ) ]]; then
          local archives=()
          shopt -s nullglob
          mapfile -t archives < <(
            ls -1t /root/simai-backups/*.tar.gz 2>/dev/null | while IFS= read -r archive; do
              if declare -F backup_archive_is_menu_compatible >/dev/null 2>&1; then
                backup_archive_is_menu_compatible "$archive" && printf '%s\n' "$archive"
              else
                printf '%s\n' "$archive"
              fi
            done
          )
          shopt -u nullglob
          if [[ ${#archives[@]} -gt 0 ]]; then
            val=$(select_from_list "Select archive" "${archives[0]}" "${archives[@]}")
          else
            val=$(prompt "$key")
          fi
        else
          val=$(prompt "$key")
        fi
        ;;
      *)
        val=$(prompt "$key")
        ;;
    esac
    echo "$val"
  }

  menu_cancel_before_command() {
    local section="$1" cmd="$2"
    echo
    echo "Result: ${section} ${cmd}"
    echo "Status: CANCELLED"
    echo "(cancelled before command start)"
    if menu_can_use_whiptail; then
      whiptail --title "SIMAI ENV" --msgbox "Result: ${section} ${cmd}\nStatus: CANCELLED\n(cancelled before command start)" 12 70
    else
      echo
      read -r -p "Press Enter to continue..." _ || true
    fi
    echo "---- done (${section} ${cmd}), command_exit=not_started ----"
  }

  menu_arg_value_is_yes() {
    local wanted="$1"
    shift
    local arg next=""
    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift
      case "$arg" in
        --${wanted}=*)
          [[ "${arg#*=}" == "yes" ]] && return 0
          ;;
        "--${wanted}")
          next="${1:-}"
          [[ $# -gt 0 ]] && shift
          [[ "$next" == "yes" ]] && return 0
          ;;
      esac
    done
    return 1
  }

  menu_command_needs_confirmation() {
    local section="$1" cmd="$2"
    shift 2
    local flags
    flags="$(get_command_flags "$section" "$cmd")"
    if [[ " ${flags} " == *" menu:confirm "* ]]; then
      return 0
    fi
    menu_arg_value_is_yes apply "$@" && return 0
    menu_arg_value_is_yes fix "$@" && return 0
    menu_arg_value_is_yes all "$@" && return 0
    menu_arg_value_is_yes confirm "$@" && return 0
    return 1
  }

  menu_command_scope() {
    local arg value=""
    while [[ $# -gt 0 ]]; do
      arg="$1"
      shift
      case "$arg" in
        --domain=*|--login=*|--id=*|--file=*)
          printf '%s\n' "${arg#*=}"
          return 0
          ;;
        --domain|--login|--id|--file)
          value="${1:-}"
          [[ -n "$value" ]] && printf '%s\n' "$value" && return 0
          ;;
        --all=yes)
          printf '%s\n' "all managed targets"
          return 0
          ;;
        --all)
          value="${1:-}"
          [[ "$value" == "yes" ]] && printf '%s\n' "all managed targets" && return 0
          ;;
      esac
    done
    printf '%s\n' "platform scope"
  }

  menu_confirm_command() {
    local section="$1" cmd="$2"
    shift 2
    local desc scope choice
    desc="$(get_command_desc "$section" "$cmd")"
    [[ -z "$desc" ]] && desc="${section} ${cmd}"
    scope="$(menu_command_scope "$@")"
    choice=$(select_from_list \
      $'Confirm managed-state change\nAction: '"${desc}"$'\nTarget: '"${scope}" \
      "no" \
      "no" \
      "yes")
    [[ "$choice" == "yes" ]]
  }

  run_menu_command() {
    local section="$1" cmd="$2"; shift 2
    echo "---- running ${section} ${cmd} ----"
    local rc=0
    local streamed_output="yes"
    local required
    required="$(get_required_opts "$section" "$cmd")"
    local -a args=("$@")
    if [[ -n "$required" ]]; then
      local key val
      for key in $required; do
        if menu_args_has_key "$key" "${args[@]}"; then
          continue
        fi
        val=$(menu_prompt_required_arg "$section" "$cmd" "$key")
        if [[ -z "$val" ]]; then
          menu_cancel_before_command "$section" "$cmd"
          return 0
        fi
        args+=("--$key" "$val")
      done
    fi
    if menu_command_needs_confirmation "$section" "$cmd" "${args[@]}"; then
      if ! menu_confirm_command "$section" "$cmd" "${args[@]}"; then
        menu_cancel_before_command "$section" "$cmd"
        return 0
      fi
    fi
    local out_file
    out_file="$(mktemp)"
    if [[ "$section" == "self" && "$cmd" == "update" ]]; then
      menu_set_restore_path "${SIMAI_MENU_PATH:-main}"
    fi
    if run_command "$section" "$cmd" "${args[@]}" 2>&1 | tee "$out_file"; then
      rc=0
    else
      rc=$?
    fi
    menu_pause_after_command "$section" "$cmd" "$rc" "$out_file" "$streamed_output"
    rm -f "$out_file"
    if [[ $rc -eq ${SIMAI_RC_MENU_RELOAD:-88} ]]; then
      echo "---- done (${section} ${cmd}), exit=0 ----"
      menu_spawn_restart
    fi
    echo "---- done (${section} ${cmd}), exit=${rc} ----"
    if [[ $rc -ne 0 && $rc -ne ${SIMAI_RC_CANCELLED:-89} ]]; then
      warn "Command failed with exit code ${rc}"
    fi
    return 0
  }
  menu_invalid_choice() {
    warn "Invalid choice."
  }

  site_automation_menu() {
    while true; do
      local -a items=("1|Automatic optimization status" "2|Exclude site from automatic optimization" "3|Include site in automatic optimization" "4|Restore inherited optimization defaults" "0|Back")
      local ch=""
      ch=$(menu_choose_key "Sites · Automatic optimization" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command site auto-optimize-status ;;
        2) run_menu_command site auto-optimize-disable ;;
        3) run_menu_command site auto-optimize-enable ;;
        4) run_menu_command site auto-optimize-reset ;;
        0) break ;;
        "") continue ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  sites_menu() {
    while true; do
      menu_auto_update_apply_if_safe "sites"
      local -a items=(
        "1|List sites"
        "2|Create site"
        "3|Site info"
        "4|Activity & optimization"
        "5|Change activity class"
        "6|Site availability"
        "7|Pause site"
        "8|Resume site"
        "9|Change site PHP"
        "10|Remove site"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=(
          "1|List sites"
          "2|Create site"
          "3|Site info"
          "4|Activity & optimization"
          "5|Change activity class"
          "6|Site availability"
          "7|Pause site"
          "8|Resume site"
          "9|Change site PHP"
          "10|Remove site"
          "20|Automatic optimization..."
          "0|Back"
        )
      fi
      local ch=""
      ch=$(menu_choose_key "Sites" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command site list ;;
        2) run_menu_command site add ;;
        3) run_menu_command site info ;;
        4) run_menu_command site usage-status ;;
        5) run_menu_command site usage-set ;;
        6) run_menu_command site runtime-status ;;
        7) run_menu_command site runtime-suspend ;;
        8) run_menu_command site runtime-resume ;;
        9) run_menu_command site set-php ;;
        10) run_menu_command site remove ;;
        20) [[ $show_advanced -eq 1 ]] && site_automation_menu || menu_invalid_choice ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  ssl_menu() {
    while true; do
      menu_auto_update_apply_if_safe "ssl"
      local -a items=(
        "1|List certificates"
        "2|Certificate status"
        "3|Issue Let's Encrypt"
        "4|Install custom certificate"
        "5|Renew certificate"
        "6|Disable HTTPS"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "SSL" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command ssl list ;;
        2) run_menu_command ssl status ;;
        3) run_menu_command ssl letsencrypt ;;
        4) run_menu_command ssl install ;;
        5) run_menu_command ssl renew ;;
        6) run_menu_command ssl remove ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  php_menu() {
    while true; do
      menu_auto_update_apply_if_safe "php"
      local -a items=(
        "1|List PHP versions"
        "2|Install PHP version"
        "3|Reload / restart PHP-FPM"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "PHP" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command php list ;;
        2) run_menu_command php install ;;
        3) run_menu_command php reload ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  db_menu() {
    while true; do
      menu_auto_update_apply_if_safe "db"
      local -a items=(
        "1|List databases"
        "2|Database server status"
        "3|Prepare site database"
        "4|Write DB credentials to project .env"
        "5|Rotate database password"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|List databases" "2|Database server status" "3|Prepare site database" "4|Write DB credentials to project .env" "5|Rotate database password" "20|Remove database for site" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Database" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command db list ;;
        2) run_menu_command db status ;;
        3) run_menu_command site db-create ;;
        4) run_menu_command site db-export ;;
        5) run_menu_command site db-rotate ;;
        20)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site db-drop
          else
            menu_invalid_choice
          fi
          ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  diagnostics_menu() {
    while true; do
      menu_auto_update_apply_if_safe "diagnostics"
      local -a items=(
        "1|Site health check"
        "2|Configuration drift status"
        "3|Platform status"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Site health check" "2|Configuration drift status" "3|Platform status" "20|Repair configuration drift")
      fi
      items+=("0|Back")
      local ch=""
      ch=$(menu_choose_key "Diagnostics" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command site doctor ;;
        2) run_menu_command site drift ;;
        3) run_menu_command self platform-status ;;
        20) [[ $show_advanced -eq 1 ]] && run_menu_command site drift --fix yes || menu_invalid_choice ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  logs_menu() {
    while true; do
      menu_auto_update_apply_if_safe "logs"
      local -a items=(
        "1|Platform log"
        "2|Setup log"
        "3|Command audit log"
        "4|Website access log"
        "5|Website error log"
        "6|Certificate log"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "Logs" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command logs admin ;;
        2) run_menu_command logs env ;;
        3) run_menu_command logs audit ;;
        4) run_menu_command logs nginx --kind access ;;
        5) run_menu_command logs nginx --kind error ;;
        6) run_menu_command logs letsencrypt ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  backup_menu() {
    while true; do
      menu_auto_update_apply_if_safe "backup"
      local -a items=(
        "1|Export site settings"
        "2|Review archive"
        "3|Preview import"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items+=("20|Import archive now")
      fi
      items+=("0|Back")
      local ch=""
      ch=$(menu_choose_key "Backup / Migrate" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command backup export ;;
        2) run_menu_command backup inspect ;;
        3) run_menu_command backup import --apply no ;;
        20)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command backup import --apply yes
          else
            menu_invalid_choice
          fi
          ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  laravel_app_menu() {
    while true; do
      menu_auto_update_apply_if_safe "applications:laravel"
      local -a items=(
        "1|Laravel status"
        "2|Laravel prepare app"
        "3|Laravel complete setup"
        "4|Laravel cache clear"
        "5|Laravel scheduler enable"
        "6|Laravel scheduler disable"
        "7|Laravel worker status"
        "8|Laravel worker restart"
        "9|Laravel worker logs"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Laravel status" "2|Prepare Laravel app" "3|Complete Laravel setup" "4|Clear Laravel cache" "5|Enable Laravel scheduler" "6|Disable Laravel scheduler" "7|Laravel worker status" "8|Restart Laravel worker" "9|Laravel worker logs" "20|Laravel optimization status" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · Laravel" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command laravel status ;;
        2) run_menu_command laravel app-ready ;;
        3) run_menu_command laravel finalize ;;
        4) run_menu_command cache clear ;;
        5) run_menu_command cron add ;;
        6) run_menu_command cron remove ;;
        7) run_menu_command queue status ;;
        8) run_menu_command queue restart ;;
        9) run_menu_command queue logs ;;
        20) [[ $show_advanced -eq 1 ]] && run_menu_command laravel perf-status || menu_invalid_choice ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  wordpress_app_menu() {
    while true; do
      menu_auto_update_apply_if_safe "applications:wordpress"
      local -a items=(
        "1|WordPress status"
        "2|WordPress optimization status"
        "3|Complete WordPress setup"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|WordPress status" "2|WordPress optimization status" "3|Complete WordPress setup" "20|Prepare WordPress installer" "21|WordPress scheduler status" "22|Sync WordPress scheduler" "23|Clear WordPress cache" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · WordPress" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command wp status ;;
        2) run_menu_command wp perf-status ;;
        3) run_menu_command wp finalize ;;
        20)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp installer-ready
          else
            menu_invalid_choice
          fi
          ;;
        21)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp cron-status
          else
            menu_invalid_choice
          fi
          ;;
        22)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp cron-sync
          else
            menu_invalid_choice
          fi
          ;;
        23)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp cache-clear
          else
            menu_invalid_choice
          fi
          ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  bitrix_advanced_menu() {
    while true; do
      local -a items=(
        "1|Repair Bitrix ownership"
        "2|Bitrix scheduler status"
        "3|Sync Bitrix scheduler"
        "4|Clear Bitrix cache"
        "5|Bitrix agents status"
        "6|Bitrix agents readiness plan"
        "7|Generate Bitrix DB config"
        "8|Prepare Bitrix installer"
        "9|Sync Bitrix PHP baseline for all sites"
        "10|Apply Bitrix agents configuration"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "Applications · Bitrix · Advanced" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command bitrix ownership --apply yes ;;
        2) run_menu_command bitrix cron-status ;;
        3) run_menu_command bitrix cron-sync ;;
        4) run_menu_command bitrix cache-clear ;;
        5) run_menu_command bitrix agents-status ;;
        6) run_menu_command bitrix agents-sync ;;
        7) run_menu_command bitrix db-preseed ;;
        8) run_menu_command bitrix installer-ready ;;
        9) run_menu_command bitrix php-baseline-sync --all yes ;;
        10) run_menu_command bitrix agents-sync --apply yes ;;
        0) break ;;
        "") continue ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  bitrix_app_menu() {
    while true; do
      menu_auto_update_apply_if_safe "applications:bitrix"
      local -a items=(
        "1|Bitrix status"
        "2|Bitrix optimization status"
        "3|Complete Bitrix setup"
        "4|Prepare Bitrix restore"
        "5|Bitrix ownership status"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Bitrix status" "2|Bitrix optimization status" "3|Complete Bitrix setup" "4|Prepare Bitrix restore" "5|Bitrix ownership status" "20|Advanced Bitrix operations..." "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · Bitrix" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command bitrix status ;;
        2) run_menu_command bitrix perf-status ;;
        3) run_menu_command bitrix finalize ;;
        4)
          run_menu_command bitrix restore-ready
          ;;
        5) run_menu_command bitrix ownership ;;
        20) [[ $show_advanced -eq 1 ]] && bitrix_advanced_menu || menu_invalid_choice ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  applications_menu() {
    while true; do
      menu_auto_update_apply_if_safe "applications"
      local -a items=(
        "1|Laravel"
        "2|WordPress"
        "3|Bitrix"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "Applications" "Choose application" "" "${items[@]}")
      case "$ch" in
        1) laravel_app_menu ;;
        2) wordpress_app_menu ;;
        3) bitrix_app_menu ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  access_menu() {
    while true; do
      menu_auto_update_apply_if_safe "access"
      local -a items=(
        "1|List accesses"
        "2|Show access details"
        "3|Create project access"
        "4|Create global access"
        "5|Add SSH key"
        "6|Disable access"
        "7|Enable access"
        "8|Reset access password"
        "9|Remove access"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "Access" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command access list ;;
        2) run_menu_command access show ;;
        3) run_menu_command access create-project ;;
        4) run_menu_command access create-global ;;
        5) run_menu_command access add-key ;;
        6) run_menu_command access disable ;;
        7) run_menu_command access enable ;;
        8) run_menu_command access reset-password ;;
        9) run_menu_command access remove ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  profiles_menu() {
    while true; do
      menu_auto_update_apply_if_safe "profiles"
      local -a items=(
        "1|List profiles"
        "2|Profile usage summary"
        "3|Sites using one profile"
        "4|Check profiles"
        "5|Turn profile on"
        "6|Turn profile off"
        "7|Initialize profile list"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "Profiles" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command profile list ;;
        2) run_menu_command profile used-by ;;
        3) run_menu_command profile used-by-one ;;
        4) run_menu_command profile validate ;;
        5) run_menu_command profile enable ;;
        6) run_menu_command profile disable ;;
        7) run_menu_command profile init ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  system_advanced_menu() {
    while true; do
      local -a items=(
        "1|Apply optimization plan"
        "2|Enable update checks"
        "3|Enable safe automatic updates"
        "4|Disable automatic updates"
        "5|Automation scheduler status"
        "6|Health review status"
        "7|Site review status"
        "0|Back"
      )
      local ch=""
      ch=$(menu_choose_key "System · Advanced operations" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command self perf-rebalance --mode auto --confirm yes ;;
        2) run_menu_command self auto-update-enable-check ;;
        3) run_menu_command self auto-update-enable-apply ;;
        4) run_menu_command self auto-update-disable ;;
        5) run_menu_command self scheduler-status ;;
        6) run_menu_command self health-review-status ;;
        7) run_menu_command self site-review-status ;;
        0) break ;;
        "") continue ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  system_menu() {
    while true; do
      menu_auto_update_apply_if_safe "system"
      local adv_label
      adv_label="Advanced mode (currently: $([[ $show_advanced -eq 1 ]] && echo ON || echo OFF))"
      local backend_label="Menu backend (currently: ${SIMAI_MENU_BACKEND:-text})"
      local auto_opt_label
      if [[ "$(scheduler_job_enabled "auto_optimize" 2>/dev/null || echo no)" == "yes" ]]; then
        auto_opt_label="Turn automatic optimization off"
      else
        auto_opt_label="Turn automatic optimization on"
      fi
      local auto_update_mode="check"
      if declare -F self_auto_update_mode >/dev/null 2>&1; then
        auto_update_mode="$(self_auto_update_mode 2>/dev/null || echo check)"
      fi
      local auto_update_label="Automatic updates status (currently: ${auto_update_mode})"
      local -a items=(
        "1|Platform status"
        "2|Optimization status"
        "3|${auto_opt_label}"
        "4|Optimization plan"
        "5|Repair/install platform components"
        "6|Update simai-env"
        "7|Version"
        "8|${auto_update_label}"
        "9|Check for updates now"
        "10|${adv_label}"
        "11|${backend_label}"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Platform status" "2|Optimization status" "3|${auto_opt_label}" "4|Optimization plan" "5|Repair/install platform components" "6|Update simai-env" "7|Version" "8|${auto_update_label}" "9|Check for updates now" "10|${adv_label}" "11|${backend_label}" "20|Advanced system operations..." "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "System" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command self status ;;
        2) run_menu_command self perf-status ;;
        3)
          if [[ "$(scheduler_job_enabled "auto_optimize" 2>/dev/null || echo no)" == "yes" ]]; then
            run_menu_command self auto-optimize-disable
          else
            run_menu_command self auto-optimize-enable
          fi
          ;;
        4) run_menu_command self perf-plan ;;
        5) run_menu_command self bootstrap ;;
        6) run_menu_command self update ;;
        7) run_menu_command self version ;;
        8) run_menu_command self auto-update-status ;;
        9) run_menu_command self auto-update-run-check ;;
        10)
          if [[ $show_advanced -eq 1 ]]; then
            show_advanced=0
          else
            show_advanced=1
          fi
          export SIMAI_MENU_SHOW_ADVANCED="$show_advanced"
          ;;
        11) menu_toggle_backend ;;
        20) [[ $show_advanced -eq 1 ]] && system_advanced_menu || menu_invalid_choice ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  while true; do
    if [[ $reload_requested -eq 1 ]]; then
      reload_requested=0
      SIMAI_PREFLIGHT_DONE=0
      menu_auto_update_apply_if_safe "main"
      print_version_banner
      printf "Advanced: %s\n" "$([[ $show_advanced -eq 1 ]] && echo ON || echo OFF)"
      printf "Menu backend: %s\n" "${SIMAI_MENU_BACKEND:-text}"
      if declare -F self_auto_update_mode >/dev/null 2>&1; then
        printf "Automatic updates: %s\n" "$(self_auto_update_mode 2>/dev/null || echo check)"
      fi
      printf "Keys: type menu number and press Enter.\n"
      preflight_bootstrap
      if menu_open_restore_path; then
        continue
      fi
    fi
    menu_set_path "main"
    local -a root_items=(
      "1|Sites"
      "2|SSL"
      "3|PHP"
      "4|Database"
      "5|Access"
      "6|Diagnostics"
      "7|Logs"
      "8|Backup / Migrate"
      "9|Applications"
      "10|Profiles"
      "11|System"
      "0|Exit"
    )
    local choice=""
    choice=$(menu_choose_key "SIMAI ENV" "Select section" "" "${root_items[@]}")
    case "$choice" in
      1) sites_menu ;;
      2) ssl_menu ;;
      3) php_menu ;;
      4) db_menu ;;
      5) access_menu ;;
      6) diagnostics_menu ;;
      7) logs_menu ;;
      8) backup_menu ;;
      9) applications_menu ;;
      10) profiles_menu ;;
      11) system_menu ;;
      0) exit 0 ;;
      "") continue ;;
      "__invalid__") menu_invalid_choice ;;
      *) menu_invalid_choice ;;
    esac
  done
}
