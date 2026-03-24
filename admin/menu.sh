#!/usr/bin/env bash
set -euo pipefail

prompt() {
  local label="$1" default="${2:-}"
  local value
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]] && command -v whiptail >/dev/null 2>&1 && [[ -r /dev/tty && -w /dev/tty ]]; then
    if [[ -n "$default" ]]; then
      value=$(whiptail --title "SIMAI ENV" --inputbox "$label" 10 90 "$default" 3>&1 1>&2 2>&3) || return 1
    else
      value=$(whiptail --title "SIMAI ENV" --inputbox "$label" 10 90 3>&1 1>&2 2>&3) || return 1
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
  [[ -z "$local_version" || "$local_version" == "(unknown)" ]] && [[ -f "${SCRIPT_DIR}/VERSION" ]] && local_version="$(cat "${SCRIPT_DIR}/VERSION")"
  [[ -z "$remote_version" ]] && remote_version="(unavailable)"
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
  choice=$(select_from_list "Install required packages now?" "yes" "yes" "no")
  [[ -z "$choice" ]] && choice="yes"
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
      if [[ -n "$selected" ]]; then
        out=$(whiptail --title "$title" --default-item "$selected" --menu "$prompt_text" 22 100 14 "${opts[@]}" 3>&1 1>&2 2>&3) || rc=$?
      else
        out=$(whiptail --title "$title" --menu "$prompt_text" 22 100 14 "${opts[@]}" 3>&1 1>&2 2>&3) || rc=$?
      fi
      if [[ $rc -ne 0 ]]; then
        echo ""
        return 1
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
      read -r -p "${prompt_text} [${default_key}]: " choice || true
      [[ -z "$choice" ]] && choice="$default_key"
    else
      read -r -p "${prompt_text}: " choice || true
    fi
    [[ -z "$choice" ]] && { echo ""; return 1; }
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
        local sites=()
        mapfile -t sites < <(list_sites)
        if [[ ${#sites[@]} -gt 0 ]]; then
          val=$(select_from_list "Select domain" "" "${sites[@]}")
        else
          val=$(prompt "$key")
        fi
        ;;
      file)
        if [[ "$section" == "backup" && ( "$cmd" == "inspect" || "$cmd" == "import" ) ]]; then
          local archives=()
          shopt -s nullglob
          mapfile -t archives < <(ls -1t /root/simai-backups/*.tar.gz 2>/dev/null || true)
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
          warn "Cancelled."
          echo "---- done (${section} ${cmd}), exit=0 ----"
          return 0
        fi
        args+=("--$key" "$val")
      done
    fi
    local out_file
    out_file="$(mktemp)"
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
    if [[ $rc -ne 0 ]]; then
      warn "Command failed with exit code ${rc}"
    fi
    return 0
  }
  menu_invalid_choice() {
    warn "Invalid choice."
  }

  sites_menu() {
    while true; do
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
          "6|Automatic optimization for this site"
          "7|Exclude site from automatic optimization"
          "8|Include site in automatic optimization"
          "9|Use automatic optimization defaults"
          "10|Site availability"
          "11|Pause site"
          "12|Resume site"
          "13|Change site PHP"
          "14|Remove site"
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
        6)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site auto-optimize-status
          else
            run_menu_command site runtime-status
          fi
          ;;
        7)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site auto-optimize-disable
          else
            run_menu_command site runtime-suspend
          fi
          ;;
        8)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site auto-optimize-enable
          else
            run_menu_command site runtime-resume
          fi
          ;;
        9)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site auto-optimize-reset
          else
            run_menu_command site set-php
          fi
          ;;
        10)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site runtime-status
          else
            run_menu_command site remove
          fi
          ;;
        11)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site runtime-suspend
          else
            menu_invalid_choice
          fi
          ;;
        12)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site runtime-resume
          else
            menu_invalid_choice
          fi
          ;;
        13)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site set-php
          else
            menu_invalid_choice
          fi
          ;;
        14)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site remove
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

  ssl_menu() {
    while true; do
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
      local -a items=(
        "1|List databases"
        "2|Database server status"
        "3|Create database for site"
        "4|Write site database settings"
        "5|Rotate database password"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|List databases" "2|Database server status" "3|Create database for site" "4|Write site database settings" "5|Rotate database password" "6|Remove database for site" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Database" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command db list ;;
        2) run_menu_command db status ;;
        3) run_menu_command site db-create ;;
        4) run_menu_command site db-export ;;
        5) run_menu_command site db-rotate ;;
        6)
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
      local -a items=(
        "1|Site health check"
        "2|Configuration check"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items+=("3|Repair configuration")
      fi
      items+=("4|Platform status")
      items+=("0|Back")
      local ch=""
      ch=$(menu_choose_key "Diagnostics" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command site doctor ;;
        2) run_menu_command site drift ;;
        3)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site drift --fix yes
          else
            menu_invalid_choice
          fi
          ;;
        4) run_menu_command self platform-status ;;
        0) break ;;
        "") continue ;;
        "__invalid__") menu_invalid_choice ;;
        *) menu_invalid_choice ;;
      esac
    done
  }

  logs_menu() {
    while true; do
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
      local -a items=(
        "1|Export site settings"
        "2|Review archive"
        "3|Preview import"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items+=("4|Import archive now")
      fi
      items+=("0|Back")
      local ch=""
      ch=$(menu_choose_key "Backup / Migrate" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command backup export ;;
        2) run_menu_command backup inspect ;;
        3) run_menu_command backup import --apply no ;;
        4)
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
        items=("1|Laravel status" "2|Laravel prepare app" "3|Laravel complete setup" "4|Laravel optimization" "5|Laravel cache clear" "6|Laravel scheduler enable" "7|Laravel scheduler disable" "8|Laravel worker status" "9|Laravel worker restart" "10|Laravel worker logs" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · Laravel" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command laravel status ;;
        2) run_menu_command laravel app-ready ;;
        3) run_menu_command laravel finalize ;;
        4)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command laravel perf-status
          else
            run_menu_command cache clear
          fi
          ;;
        5)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command cache clear
          else
            run_menu_command cron add
          fi
          ;;
        6)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command cron add
          else
            run_menu_command cron remove
          fi
          ;;
        7)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command cron remove
          else
            run_menu_command queue status
          fi
          ;;
        8)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command queue status
          else
            run_menu_command queue restart
          fi
          ;;
        9)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command queue restart
          else
            run_menu_command queue logs
          fi
          ;;
        10)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command queue logs
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

  wordpress_app_menu() {
    while true; do
      local -a items=(
        "1|WordPress status"
        "2|WordPress optimization"
        "3|WordPress complete setup"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|WordPress status" "2|WordPress optimization" "3|WordPress complete setup" "4|WordPress installer ready" "5|WordPress scheduler status" "6|WordPress scheduler sync" "7|WordPress cache clear" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · WordPress" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command wp status ;;
        2) run_menu_command wp perf-status ;;
        3) run_menu_command wp finalize ;;
        4)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp installer-ready
          else
            menu_invalid_choice
          fi
          ;;
        5)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp cron-status
          else
            menu_invalid_choice
          fi
          ;;
        6)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command wp cron-sync
          else
            menu_invalid_choice
          fi
          ;;
        7)
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

  bitrix_app_menu() {
    while true; do
      local -a items=(
        "1|Bitrix status"
        "2|Bitrix optimization"
        "3|Bitrix complete setup"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Bitrix status" "2|Bitrix optimization" "3|Bitrix complete setup" "4|Bitrix scheduler status" "5|Bitrix scheduler sync" "6|Bitrix cache clear" "7|Bitrix agents status" "8|Bitrix agents readiness" "9|Bitrix DB preseed" "10|Bitrix installer ready" "11|Bitrix PHP baseline sync (all)" "12|Bitrix agents sync (apply)" "0|Back")
      fi
      local ch=""
      ch=$(menu_choose_key "Applications · Bitrix" "Enter choice" "" "${items[@]}")
      case "$ch" in
        1) run_menu_command bitrix status ;;
        2) run_menu_command bitrix perf-status ;;
        3) run_menu_command bitrix finalize ;;
        4)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix cron-status
          else
            menu_invalid_choice
          fi
          ;;
        5)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix cron-sync
          else
            menu_invalid_choice
          fi
          ;;
        6)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix cache-clear
          else
            menu_invalid_choice
          fi
          ;;
        7)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix agents-status
          else
            menu_invalid_choice
          fi
          ;;
        8)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix agents-sync
          else
            menu_invalid_choice
          fi
          ;;
        9)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix db-preseed
          else
            menu_invalid_choice
          fi
          ;;
        10)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix installer-ready
          else
            menu_invalid_choice
          fi
          ;;
        11)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix php-baseline-sync --all yes
          else
            menu_invalid_choice
          fi
          ;;
        12)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command bitrix agents-sync --apply yes
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

  applications_menu() {
    while true; do
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

  profiles_menu() {
    while true; do
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

  system_menu() {
    while true; do
      local adv_label="Advanced mode (currently: $([[ $show_advanced -eq 1 ]] && echo ON || echo OFF))"
      local backend_label="Menu backend (currently: ${SIMAI_MENU_BACKEND:-text})"
      local auto_opt_label="Automatic optimization (currently: $(scheduler_job_enabled "auto_optimize" 2>/dev/null || echo no))"
      local auto_update_mode="check"
      if declare -F self_auto_update_mode >/dev/null 2>&1; then
        auto_update_mode="$(self_auto_update_mode 2>/dev/null || echo check)"
      fi
      local auto_update_label="Automatic updates (currently: ${auto_update_mode})"
      local -a items=(
        "1|Platform status"
        "2|Optimization status"
        "3|${auto_opt_label}"
        "4|Optimization plan"
        "5|Repair platform"
        "6|Update simai-env"
        "7|Version"
        "8|${auto_update_label}"
        "9|Check for updates now"
        "10|${adv_label}"
        "11|${backend_label}"
        "0|Back"
      )
      if [[ $show_advanced -eq 1 ]]; then
        items=("1|Platform status" "2|Optimization status" "3|${auto_opt_label}" "4|Optimization plan" "5|Apply optimization plan" "6|Repair platform" "7|Update simai-env" "8|Version" "9|${auto_update_label}" "10|Check for updates now" "11|Turn update checks on" "12|Turn safe auto-update on" "13|Turn automatic updates off" "14|${adv_label}" "15|${backend_label}" "16|Automation scheduler status" "17|Health review" "18|Site review" "0|Back")
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
        4)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self perf-plan
          else
            run_menu_command self perf-plan
          fi
          ;;
        5)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self perf-rebalance --mode auto --confirm yes
          else
            run_menu_command self bootstrap
          fi
          ;;
        6)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self bootstrap
          else
            run_menu_command self update
          fi
          ;;
        7)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self update
          else
            run_menu_command self version
          fi
          ;;
        8)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self version
          else
            run_menu_command self auto-update-status
          fi
          ;;
        9)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self auto-update-run-check
          else
            run_menu_command self auto-update-run-check
          fi
          ;;
        10)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self auto-update-enable-check
          else
            show_advanced=1
            export SIMAI_MENU_SHOW_ADVANCED="$show_advanced"
          fi
          ;;
        11)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self auto-update-enable-apply
          else
            if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]]; then
              export SIMAI_MENU_BACKEND="text"
            else
              if command -v whiptail >/dev/null 2>&1; then
                export SIMAI_MENU_BACKEND="whiptail"
                menu_init_whiptail_theme
              else
                warn "whiptail is not installed; backend stays text."
              fi
            fi
          fi
          ;;
        12)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self auto-update-disable
          else
            menu_invalid_choice
          fi
          ;;
        13)
          if [[ $show_advanced -eq 1 ]]; then
            show_advanced=0
            export SIMAI_MENU_SHOW_ADVANCED="$show_advanced"
          else
            menu_invalid_choice
          fi
          ;;
        14)
          if [[ $show_advanced -eq 1 ]]; then
            if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]]; then
              export SIMAI_MENU_BACKEND="text"
            else
              if command -v whiptail >/dev/null 2>&1; then
                export SIMAI_MENU_BACKEND="whiptail"
                menu_init_whiptail_theme
              else
                warn "whiptail is not installed; backend stays text."
              fi
            fi
          else
            menu_invalid_choice
          fi
          ;;
        15)
          if [[ $show_advanced -eq 1 ]]; then
            if [[ "${SIMAI_MENU_BACKEND:-text}" == "whiptail" ]]; then
              export SIMAI_MENU_BACKEND="text"
            else
              if command -v whiptail >/dev/null 2>&1; then
                export SIMAI_MENU_BACKEND="whiptail"
                menu_init_whiptail_theme
              else
                warn "whiptail is not installed; backend stays text."
              fi
            fi
          else
            menu_invalid_choice
          fi
          ;;
        16)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self scheduler-status
          else
            menu_invalid_choice
          fi
          ;;
        17)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self health-review-status
          else
            menu_invalid_choice
          fi
          ;;
        18)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command self site-review-status
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

  while true; do
    if [[ $reload_requested -eq 1 ]]; then
      reload_requested=0
      SIMAI_PREFLIGHT_DONE=0
      print_version_banner
      printf "Advanced: %s\n" "$([[ $show_advanced -eq 1 ]] && echo ON || echo OFF)"
      printf "Menu backend: %s\n" "${SIMAI_MENU_BACKEND:-text}"
      if declare -F self_auto_update_mode >/dev/null 2>&1; then
        printf "Automatic updates: %s\n" "$(self_auto_update_mode 2>/dev/null || echo check)"
      fi
      printf "Keys: type menu number and press Enter.\n"
      preflight_bootstrap
    fi
    local -a root_items=(
      "1|Sites"
      "2|SSL"
      "3|PHP"
      "4|Database"
      "5|Diagnostics"
      "6|Logs"
      "7|Backup / Migrate"
      "8|Applications"
      "9|Profiles"
      "10|System"
      "0|Exit"
    )
    local choice=""
    choice=$(menu_choose_key "SIMAI ENV" "Select section" "" "${root_items[@]}")
    case "$choice" in
      1) sites_menu ;;
      2) ssl_menu ;;
      3) php_menu ;;
      4) db_menu ;;
      5) diagnostics_menu ;;
      6) logs_menu ;;
      7) backup_menu ;;
      8) applications_menu ;;
      9) profiles_menu ;;
      10) system_menu ;;
      0) exit 0 ;;
      "") continue ;;
      "__invalid__") menu_invalid_choice ;;
      *) menu_invalid_choice ;;
    esac
  done
}
