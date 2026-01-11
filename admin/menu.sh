#!/usr/bin/env bash
set -euo pipefail

prompt() {
  local label="$1" default="${2:-}"
  local value
  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value || true
    [[ -z "$value" ]] && value="$default"
  else
    read -r -p "$label: " value || true
  fi
  echo "$value"
}

print_version_banner() {
  local local_version="(unknown)"
  local remote_version="(unavailable)"
  [[ -f "${SCRIPT_DIR}/VERSION" ]] && local_version="$(cat "${SCRIPT_DIR}/VERSION")"
  remote_version=$(curl -fsSL https://raw.githubusercontent.com/simai/simai-env/main/VERSION 2>/dev/null || true)
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
  local depth="${SIMAI_MENU_RESTART_DEPTH:-0}"
  depth=$((depth + 1))
  export SIMAI_MENU_RESTART_DEPTH="$depth"
  if [[ $depth -gt 2 ]]; then
    warn "Menu restart depth limit reached; staying in current menu."
    return 1
  fi
  info "Starting fresh admin menu process..."
  bash "${SCRIPT_DIR}/simai-admin.sh" menu
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
  local show_advanced="${SIMAI_MENU_SHOW_ADVANCED:-0}"
  case "${show_advanced,,}" in
    1|yes|true) show_advanced=1 ;;
    *) show_advanced=0 ;;
  esac

  run_menu_command() {
    local section="$1" cmd="$2"; shift 2
    echo "---- running ${section} ${cmd} ----"
    local rc=0
    if run_command "$section" "$cmd" "$@"; then
      rc=0
    else
      rc=$?
    fi
    if [[ $rc -eq ${SIMAI_RC_MENU_RELOAD:-88} ]]; then
      info "Restarting menu after update..."
      if menu_spawn_restart; then
        exit 0
      fi
      warn "Menu restart failed; continuing current session."
      reload_requested=1
      echo "---- done (${section} ${cmd}), exit=${rc} ----"
      return $rc
    fi
    echo "---- done (${section} ${cmd}), exit=${rc} ----"
    if [[ $rc -ne 0 ]]; then
      warn "Command failed with exit code ${rc}"
    fi
    return $rc
  }

  sites_menu() {
    while true; do
      echo
      echo "Sites"
      cat <<'EOF'
  [1] list
  [2] add
  [3] set-php
  [4] remove
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command site list ;;
        2) run_menu_command site add ;;
        3) run_menu_command site set-php ;;
        4) run_menu_command site remove ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  ssl_menu() {
    while true; do
      echo
      echo "SSL"
      cat <<'EOF'
  [1] status
  [2] letsencrypt
  [3] renew
  [4] remove
  [5] install
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command ssl status ;;
        2) run_menu_command ssl letsencrypt ;;
        3) run_menu_command ssl renew ;;
        4) run_menu_command ssl remove ;;
        5) run_menu_command ssl install ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  diagnose_menu() {
    while true; do
      echo
      echo "Diagnose"
      printf "  [1] site doctor\n"
      if [[ $show_advanced -eq 1 ]]; then
        printf "  [2] site drift\n"
      fi
      echo "  [0] Back"
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command site doctor ;;
        2)
          if [[ $show_advanced -eq 1 ]]; then
            run_menu_command site drift
          else
            echo "Invalid choice"
          fi
          ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  maintenance_menu() {
    while true; do
      echo
      echo "Maintenance"
      cat <<'EOF'
  [1] Repair Environment ...
  [2] PHP list
  [3] PHP reload
  [4] Update simai-env
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command self bootstrap ;;
        2) run_menu_command php list ;;
        3) run_menu_command php reload ;;
        4) run_menu_command self update ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  logs_menu() {
    while true; do
      echo
      echo "Logs"
      cat <<'EOF'
  [1] admin
  [2] env
  [3] audit
  [4] nginx
  [5] letsencrypt
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command logs admin ;;
        2) run_menu_command logs env ;;
        3) run_menu_command logs audit ;;
        4) run_menu_command logs nginx ;;
        5) run_menu_command logs letsencrypt ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  backup_menu() {
    while true; do
      echo
      echo "Backup / Migrate"
      cat <<'EOF'
  [1] export
  [2] inspect
  [3] import
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command backup export ;;
        2) run_menu_command backup inspect ;;
        3) run_menu_command backup import ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  workers_menu() {
    while true; do
      echo
      echo "Workers"
      cat <<'EOF'
  [1] status
  [2] restart
  [3] logs
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command queue status ;;
        2) run_menu_command queue restart ;;
        3) run_menu_command queue logs ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  scheduler_menu() {
    while true; do
      echo
      echo "Scheduler"
      cat <<'EOF'
  [1] add
  [2] remove
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command cron add ;;
        2) run_menu_command cron remove ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  profiles_menu() {
    while true; do
      echo
      echo "Profiles"
      cat <<'EOF'
  [1] list
  [2] used-by
  [3] used-by-one
  [4] validate
  [5] enable
  [6] disable
  [7] init
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
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
        *) echo "Invalid choice" ;;
      esac
    done
  }

  adv_db_menu() {
    while true; do
      echo
      echo "Advanced Tools / Database"
      cat <<'EOF'
  [1] status
  [2] create
  [3] export
  [4] rotate
  [5] drop
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command site db-status ;;
        2) run_menu_command site db-create ;;
        3) run_menu_command site db-export ;;
        4) run_menu_command site db-rotate ;;
        5) run_menu_command site db-drop ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  adv_php_menu() {
    while true; do
      echo
      echo "Advanced Tools / PHP Tuning"
      cat <<'EOF'
  [1] ini list
  [2] ini set
  [3] ini unset
  [4] ini apply
  [5] site fix
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command site php-ini-list ;;
        2) run_menu_command site php-ini-set ;;
        3) run_menu_command site php-ini-unset ;;
        4) run_menu_command site php-ini-apply ;;
        5) run_menu_command site fix ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  adv_consistency_menu() {
    while true; do
      echo
      echo "Advanced Tools / Consistency"
      cat <<'EOF'
  [1] drift
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command site drift ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  advanced_menu() {
    if [[ $show_advanced -ne 1 ]]; then
      warn "Advanced commands are hidden; enable Advanced to view."
      return
    fi
    while true; do
      echo
      echo "Advanced Tools"
      cat <<'EOF'
  [1] Database
  [2] PHP Tuning
  [3] Consistency
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) adv_db_menu ;;
        2) adv_php_menu ;;
        3) adv_consistency_menu ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  tools_menu() {
    while true; do
      echo
      echo "Tools"
      cat <<'EOF'
  [1] Cache clear
  [2] Cache run
  [3] PHP install
  [0] Back
EOF
      read -r -p "Enter choice: " ch || true
      case "$ch" in
        1) run_menu_command cache clear ;;
        2) run_menu_command cache run ;;
        3) run_menu_command php install ;;
        0) break ;;
        "") continue ;;
        *) echo "Invalid choice" ;;
      esac
    done
  }

  while true; do
    if [[ $reload_requested -eq 1 ]]; then
      reload_requested=0
      SIMAI_PREFLIGHT_DONE=0
      print_version_banner
      preflight_bootstrap
    fi
    echo
    echo "Select section:"
    printf "  [1] Sites\n"
    printf "  [2] SSL\n"
    printf "  [3] Diagnose\n"
    printf "  [4] Maintenance\n"
    printf "  [5] Logs\n"
    printf "  [6] Backup / Migrate\n"
    printf "  [7] Workers\n"
    printf "  [8] Scheduler\n"
    printf "  [9] Profiles\n"
    printf "  [10] Tools\n"
    if [[ $show_advanced -eq 1 ]]; then
      printf "  [11] Advanced Tools\n"
    fi
    printf "  [99] Toggle advanced commands (currently: %s)\n" "$([[ $show_advanced -eq 1 ]] && echo ON || echo OFF)"
    echo "  [0] Exit"
    read -r -p "Enter choice: " choice || true
    case "$choice" in
      1) sites_menu ;;
      2) ssl_menu ;;
      3) diagnose_menu ;;
      4) maintenance_menu ;;
      5) logs_menu ;;
      6) backup_menu ;;
      7) workers_menu ;;
      8) scheduler_menu ;;
      9) profiles_menu ;;
      10) tools_menu ;;
      11)
        if [[ $show_advanced -eq 1 ]]; then
          advanced_menu
        else
          warn "Advanced commands are hidden; toggle advanced to show."
        fi
        ;;
      99)
        if [[ $show_advanced -eq 1 ]]; then
          show_advanced=0
        else
          show_advanced=1
        fi
        ;;
      0) exit 0 ;;
      "") continue ;;
      *) echo "Invalid choice" ;;
    esac
  done
}
