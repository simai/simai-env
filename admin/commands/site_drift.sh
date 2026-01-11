#!/usr/bin/env bash
set -euo pipefail

site_drift_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local fix="${PARSED_ARGS[fix]:-no}"
  [[ "${fix,,}" == "yes" ]] && fix="yes" || fix="no"
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  if ! validate_domain "$domain"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi
  local cfg="/etc/nginx/sites-available/${domain}.conf"
  declare -A meta=()
  local meta_status="MISSING" meta_version="-"
  if site_nginx_metadata_parse "$cfg" meta; then
    meta_status="OK"
    meta_version="${meta[meta_version]:-?}"
  else
    meta_status="MISSING"
    meta_version="-"
  fi
  local cron_file cron_status="MISSING" cron_notes=()
  if [[ "$meta_status" == "OK" && -n "${meta[slug]:-}" ]]; then
    cron_file=$(cron_site_file_path "${meta[slug]}")
    if [[ -f "$cron_file" ]]; then
      cron_status="OK"
    fi
  else
    cron_file=$(cron_site_file_path "$(project_slug_from_domain "$domain")")
    [[ -f "$cron_file" ]] && cron_status="OK (guessed)"
  fi
  local legacy_info legacy_state legacy_user legacy_fmt
  legacy_info=$(cron_legacy_detect_any "$domain")
  IFS="|" read -r legacy_state legacy_user legacy_fmt _ <<<"$legacy_info"
  if [[ "$legacy_state" == "marked" ]]; then
    cron_notes+=("legacy cron (marked) in ${legacy_user}")
    [[ "$cron_status" == "OK" ]] && cron_status="DRIFT" || cron_status="DRIFT"
  elif [[ "$legacy_state" == "suspect" ]]; then
    cron_notes+=("legacy cron (unmarked) in ${legacy_user:-unknown}")
    [[ "$cron_status" == "OK" ]] && cron_status="DRIFT" || cron_status="DRIFT"
  fi

  local sep="+------------------------------+---------+----------+"
  printf "%s\n" "$sep"
  printf "| %-28s | %-7s | %-8s |\n" "Metadata" "Status" "Version"
  printf "%s\n" "$sep"
  printf "| %-28s | %-7s | %-8s |\n" "$domain" "$meta_status" "$meta_version"
  printf "%s\n" "$sep"

  local cron_sep="+------------------------------+---------+----------------------+"
  printf "%s\n" "$cron_sep"
  printf "| %-28s | %-7s | %-20s |\n" "Cron" "Status" "Notes"
  printf "%s\n" "$cron_sep"
  printf "| %-28s | %-7s | %-20s |\n" "$domain" "$cron_status" "${cron_notes[*]:-}"
  printf "%s\n" "$cron_sep"

  if [[ "$fix" != "yes" ]]; then
    echo "Plan only (use --fix yes to apply safe fixes)"
    [[ "$meta_status" != "OK" ]] && echo "- Metadata missing; manual inspection needed (no guessing)."
    if [[ "$legacy_state" == "marked" ]]; then
      echo "- Would migrate legacy cron block from ${legacy_user} to cron.d (simai-managed only) if metadata is present"
    elif [[ "$legacy_state" == "suspect" ]]; then
      echo "- Legacy cron lines without safe markers detected; not safe to remove automatically"
    fi
    return 0
  fi

  local steps=0
  [[ "$legacy_state" == "marked" ]] && ((steps++))
  ((steps==0)) && { info "No fixes needed"; return 0; }
  progress_init "$steps"
  if [[ "$legacy_state" == "marked" ]]; then
    progress_step "Migrating legacy cron (managed block) from ${legacy_user}"
    if [[ "$meta_status" != "OK" ]]; then
      warn "Metadata missing; refusing to migrate cron without reliable metadata"
      progress_ok
    else
      local slug="${meta[slug]:-${meta[project]:-}}"
      local profile="${meta[profile]:-}"
      local root="${meta[root]:-}"
      local php="${meta[php]:-}"
      if [[ -z "$slug" || -z "$profile" || -z "$root" || -z "$php" ]]; then
        warn "Legacy cron marked block found, but metadata is incomplete; refusing to migrate to /etc/cron.d safely."
        progress_ok
      else
        if [[ ! -f "$cron_file" ]]; then
          if ! cron_site_write "$domain" "$slug" "$profile" "$root" "$php"; then
            warn "Failed to create cron.d entry; leaving legacy cron untouched"
            progress_ok
            return 0
          fi
        fi
        if ! cron_legacy_remove_marked "$domain" "$legacy_user"; then
          warn "Failed to remove marked legacy cron for ${legacy_user}; manual cleanup required"
        fi
        progress_ok
      fi
    fi
  fi
  progress_done "Drift fixes completed"
}

register_cmd "site" "drift" "Check site metadata/cron drift (plan/apply)" "site_drift_handler" "domain" "fix=no" "tier:advanced"
