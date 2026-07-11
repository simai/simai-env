#!/usr/bin/env bash

site_remove_metadata_cleanup() {
  local config_dir="$1" remove_db_env="${2:-no}"
  local expected_remaining=0 entry

  remove_db_env=$(printf '%s' "$remove_db_env" | tr '[:upper:]' '[:lower:]')

  [[ -d "$config_dir" ]] || return 0

  rm -f -- "${config_dir}/perf.env"
  if [[ "$remove_db_env" == "yes" ]]; then
    rm -f -- "${config_dir}/db.env"
  elif [[ -e "${config_dir}/db.env" ]]; then
    expected_remaining=1
  fi

  while IFS= read -r entry; do
    if [[ $expected_remaining -eq 1 && "$entry" == "${config_dir}/db.env" ]]; then
      continue
    fi
    error "Site metadata was retained because an unexpected entry remains: ${entry}"
    return 1
  done < <(find "$config_dir" -mindepth 1 -maxdepth 1 -print)

  if [[ $expected_remaining -eq 0 ]]; then
    rmdir -- "$config_dir"
  fi
}
