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

run_menu() {
  export SIMAI_ADMIN_MENU=1
  while true; do
    echo
    echo "Select section:"
    local sections=()
    local idx=1
    while IFS= read -r s; do
      sections+=("$s")
      echo "  [$idx] $s"
      ((idx++))
    done < <(list_sections)
    echo "  [0] Exit"
    read -r -p "Enter choice: " choice || true
    if [[ "$choice" == "0" || -z "$choice" ]]; then
      exit 0
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
        commands+=("$c")
        echo "  [$idx] $c - $(get_command_desc "$section" "$c")"
        ((idx++))
      done < <(list_commands_for_section "$section")
      echo "  [0] Back"
      read -r -p "Enter choice: " cchoice || true
      if [[ "$cchoice" == "0" || -z "$cchoice" ]]; then
        break
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

      set +e
      run_command "$section" "$cmd" "${args[@]}"
      rc=$?
      set -e
      if [[ $rc -ne 0 ]]; then
        warn "Command failed with exit code ${rc}"
      fi
    done
  done
}
