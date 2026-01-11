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

  menu_is_visible_cmd() {
    local section="$1" cmd="$2"
    local flags
    flags="$(get_command_flags "$section" "$cmd")"
    if [[ ",${flags}," == *",menu:hidden,"* ]]; then
      return 1
    fi
    if [[ $show_advanced -ne 1 && ",${flags}," == *",tier:advanced,"* ]]; then
      return 1
    fi
    return 0
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
    local sections=()
    local idx=1
    while IFS= read -r s; do
      local cmds=()
      mapfile -t cmds < <(list_commands_for_section "$s")
      local visible_in_section=0
      for c in "${cmds[@]}"; do
        if menu_is_visible_cmd "$s" "$c"; then
          visible_in_section=1
          break
        fi
      done
      if [[ $visible_in_section -eq 0 ]]; then
        continue
      fi
      sections+=("$s")
      local label="$s"
      if [[ "$s" == "backup" ]]; then
        label="Backup / Migrate"
      fi
      echo "  [$idx] $label"
      ((idx++))
    done < <(list_sections)
    echo "  [0] Exit"
    read -r -p "Enter choice: " choice || true
    if [[ "$choice" == "0" ]]; then
      exit 0
    fi
    if [[ -z "$choice" ]]; then
      continue
    fi
    local section="${sections[$((choice-1))]:-}"
    if [[ -z "$section" ]]; then
      echo "Invalid choice"
      continue
    fi

    while true; do
      echo
      echo "Section: $section"
      local commands=()
      idx=1
      while IFS= read -r c; do
        if ! menu_is_visible_cmd "$section" "$c"; then
          continue
        fi
        commands+=("$c")
        local label="$c"
        if [[ "$section" == "self" && "$c" == "bootstrap" ]]; then
          label="Repair Environment ..."
        fi
        echo "  [$idx] $label - $(get_command_desc "$section" "$c")"
        ((idx++))
      done < <(list_commands_for_section "$section")
      printf "  [99] Toggle advanced commands (currently: %s)\n" "$([[ $show_advanced -eq 1 ]] && echo ON || echo OFF)"
      echo "  [0] Back"
      read -r -p "Enter choice: " cchoice || true
      if [[ "$cchoice" == "0" ]]; then
        break
      elif [[ -z "$cchoice" ]]; then
        continue
      elif [[ "$cchoice" == "99" ]]; then
        if [[ $show_advanced -eq 1 ]]; then
          show_advanced=0
        else
          show_advanced=1
        fi
        continue
      fi
      local cmd="${commands[$((cchoice-1))]:-}"
      if [[ -z "$cmd" ]]; then
        echo "Invalid choice"
        continue
      fi

      local req opts
      req="$(get_required_opts "$section" "$cmd")"
      opts="$(get_optional_opts "$section" "$cmd")"
      local args=()

      for key in $req; do
        local value
        value=$(prompt "$key")
        args+=("--$key" "$value")
      done

      for pair in $opts; do
        local key="${pair%%=*}"
        local def="${pair#*=}"
        # if default is empty, skip prompting (handler may derive a value)
        if [[ -z "$def" ]]; then
          continue
        fi
        local val
        val=$(prompt "$key" "$def")
        args+=("--$key" "$val")
      done

      echo "---- running ${section} ${cmd} ----"
      set +e
      run_command "$section" "$cmd" "${args[@]}"
      rc=$?
      set -e
      if [[ $rc -eq ${SIMAI_RC_MENU_RELOAD:-88} ]]; then
        info "Restarting menu..."
        reload_requested=1
        break
      fi
      echo "---- done (${section} ${cmd}), exit=${rc} ----"
      if [[ $rc -ne 0 ]]; then
        warn "Command failed with exit code ${rc}"
      fi
    done
  done
}
