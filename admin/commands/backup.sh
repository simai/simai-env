#!/usr/bin/env bash
set -euo pipefail

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  echo "$s"
}

backup_load_manifest() {
  local manifest="$1"
  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is required to read manifest.json"
    return 1
  fi
  if [[ ! -f "$manifest" ]]; then
    error "Manifest not found at ${manifest}"
    return 1
  fi
  BACKUP_INFO_SCHEMA=""
  BACKUP_INFO_GENERATED=""
  BACKUP_INFO_VERSION=""
  BACKUP_INFO_HOST_OS=""
  BACKUP_INFO_HOSTNAME=""
  BACKUP_INFO_HOST_NOTES=""
  BACKUP_SITES_DOMAINS=()
  BACKUP_SITES_PROFILES=()
  BACKUP_SITES_PROJECTS=()
  BACKUP_SITES_ROOTS=()
  BACKUP_SITES_PHPS=()
  BACKUP_SITES_TARGETS=()
  BACKUP_SITES_SSL_ENABLED=()
  BACKUP_SITES_SSL_TYPES=()
  local py_out
  py_out=$(python3 - "$manifest" <<'PY' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    data = json.load(f)
info = [
    str(data.get("schema_version", "")),
    data.get("generated_at", ""),
    data.get("simai_env_version", ""),
    data.get("host", {}).get("os", ""),
    data.get("host", {}).get("hostname", ""),
    data.get("host", {}).get("notes", ""),
]
print("INFO|" + "|".join(info))
for site in data.get("sites", []):
    vals = [
        str(site.get("domain", "") or ""),
        str(site.get("profile", "") or ""),
        str(site.get("project", "") or ""),
        str(site.get("root", "") or ""),
        str(site.get("php", "") or ""),
        str(site.get("target", "") or ""),
        str(site.get("ssl", {}).get("enabled", False)).lower(),
        str(site.get("ssl", {}).get("type", "") or ""),
    ]
    print("SITE|" + "|".join(vals))
PY
)
  if [[ -z "$py_out" ]]; then
    error "Failed to parse manifest ${manifest}"
    return 1
  fi
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if [[ "$line" == INFO\|* ]]; then
      IFS='|' read -r _ BACKUP_INFO_SCHEMA BACKUP_INFO_GENERATED BACKUP_INFO_VERSION BACKUP_INFO_HOST_OS BACKUP_INFO_HOSTNAME BACKUP_INFO_HOST_NOTES <<<"$line"
    elif [[ "$line" == SITE\|* ]]; then
      local _d _p _proj _root _php _tgt _ssl_enabled _ssl_type
      IFS='|' read -r _ _d _p _proj _root _php _tgt _ssl_enabled _ssl_type <<<"$line"
      BACKUP_SITES_DOMAINS+=("$_d")
      BACKUP_SITES_PROFILES+=("$_p")
      BACKUP_SITES_PROJECTS+=("$_proj")
      BACKUP_SITES_ROOTS+=("$_root")
      BACKUP_SITES_PHPS+=("$_php")
      BACKUP_SITES_TARGETS+=("$_tgt")
      BACKUP_SITES_SSL_ENABLED+=("$_ssl_enabled")
      BACKUP_SITES_SSL_TYPES+=("$_ssl_type")
    fi
  done <<<"$py_out"
  return 0
}

backup_export_handler() {
  parse_kv_args "$@"
  local ts output include_nginx domains_filter dry_run
  ts=$(date +%Y%m%d%H%M%S)
  output="${PARSED_ARGS[output]:-/root/simai-backup-${ts}.tar.gz}"
  include_nginx="${PARSED_ARGS[include-nginx]:-no}"
  domains_filter="${PARSED_ARGS[domains]:-}"
  dry_run="${PARSED_ARGS[dry-run]:-no}"

  local out_dir
  out_dir=$(dirname "$output")
  if [[ ! -d "$out_dir" || ! -w "$out_dir" ]]; then
    error "Output directory is not writable: ${out_dir}"
    return 1
  fi
  [[ "${include_nginx,,}" != "yes" ]] && include_nginx="no"
  [[ "${dry_run,,}" != "yes" ]] && dry_run="no"

  local filter_map=()
  IFS=',' read -r -a filter_map <<<"${domains_filter}"

  local domains=()
  mapfile -t domains < <(list_sites)
  local selected=() skipped=()
  for d in "${domains[@]}"; do
    if [[ -n "$domains_filter" ]]; then
      local matched=0
      for f in "${filter_map[@]}"; do
        [[ "$d" == "$f" ]] && matched=1
      done
      [[ $matched -eq 0 ]] && continue
    fi
    if ! has_simai_metadata "$d"; then
      warn "Skipping ${d}: missing simai metadata in nginx config"
      skipped+=("$d")
      continue
    fi
    selected+=("$d")
  done

  if [[ ${#selected[@]} -eq 0 ]]; then
    error "No sites matched for export"
    return 1
  fi

  local simai_version host_os host_name
  simai_version=$(cat "${SCRIPT_DIR}/VERSION" 2>/dev/null || echo "unknown")
  if command -v lsb_release >/dev/null 2>&1; then
    host_os=$(lsb_release -ds 2>/dev/null || echo "unknown")
  else
    host_os=$( (source /etc/os-release && echo "${PRETTY_NAME:-unknown}") 2>/dev/null || echo "unknown")
  fi
  host_name=$(hostname 2>/dev/null || echo "unknown")

  local tmpdir
  tmpdir=$(mktemp -d)
  mkdir -p "$tmpdir"
  local sites_json=()
  local summary_file="${tmpdir}/summary.txt"
  local manifest_file="${tmpdir}/manifest.json"

  local summary_sep="+------------------------------+----------+------+------------------------------------------+-----------+"
  {
    printf "%s\n" "$summary_sep"
    printf "| %-28s | %-8s | %-4s | %-40s | %-9s |\n" "Domain" "Profile" "PHP" "Root/Target" "SSL"
    printf "%s\n" "$summary_sep"
  } >"$summary_file"

  for d in "${selected[@]}"; do
    read_site_metadata "$d"
    local profile="${SITE_META[profile]:-generic}"
    local project="${SITE_META[project]}"
    local root="${SITE_META[root]}"
    local php="${SITE_META[php]}"
    local socket_project="${SITE_META[php_socket_project]:-$project}"
    local target="${SITE_META[target]:-}"
    local ssl_state ssl_type
    read ssl_state ssl_type < <(site_ssl_info "$d")
    local type_display="$ssl_type"
    [[ "$ssl_state" == "false" ]] && type_display="off"

    local entry
    entry=$(cat <<EOF
    {
      "domain": "$(json_escape "$d")",
      "profile": "$(json_escape "$profile")",
      "project": "$(json_escape "$project")",
      "root": "$(json_escape "$root")",
      "php": "$(json_escape "$php")",
      "php_socket_project": "$(json_escape "$socket_project")",
      "target": "$(json_escape "$target")",
      "ssl": {
        "enabled": $ssl_state,
        "type": "$(json_escape "$ssl_type")"
      }
    }
EOF
)
    sites_json+=("$entry")

    local summary_target="$root"
    [[ "$profile" == "alias" && -n "$target" ]] && summary_target="alias -> ${target}"
    printf "| %-28s | %-8s | %-4s | %-40s | %-9s |\n" "$d" "$profile" "$php" "$summary_target" "$type_display" >>"$summary_file"

    if [[ "$include_nginx" == "yes" ]]; then
      local dst_dir="${tmpdir}/nginx/sites-available"
      mkdir -p "$dst_dir"
      cp "/etc/nginx/sites-available/${d}.conf" "$dst_dir/" 2>/dev/null || warn "Failed to copy nginx config for ${d}"
    fi
  done
  printf "%s\n" "$summary_sep" >>"$summary_file"

  cat >"$manifest_file" <<EOF
{
  "schema_version": 1,
  "generated_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "simai_env_version": "$(json_escape "$simai_version")",
  "host": {
    "os": "$(json_escape "$host_os")",
    "hostname": "$(json_escape "$host_name")",
    "notes": "config-only export; no secrets"
  },
  "sites": [
$(for i in "${!sites_json[@]}"; do
  echo "${sites_json[$i]}"
  if [[ $i -lt $((${#sites_json[@]}-1)) ]]; then
    echo "    ,"
  fi
done)
  ]
}
EOF

  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run: would export ${#selected[@]} site(s) to ${output}"
    echo "Include nginx: ${include_nginx}"
    echo "Manifest preview: ${manifest_file}"
    rm -rf "$tmpdir"
    return 0
  fi

  (cd "$tmpdir" && tar -czf "$output" .)
  chmod 600 "$output" 2>/dev/null || true
  rm -rf "$tmpdir"

  echo "Backup export created: ${output}"
  echo "Sites exported: ${#selected[@]}"
  echo "This is config-only; no DB/files/certs included."
  return 0
}

register_cmd "backup" "export" "Export config-only migration bundle" "backup_export_handler" "" "output= include-nginx= domains= dry-run="

backup_inspect_handler() {
  parse_kv_args "$@"
  local input="${PARSED_ARGS[input]:-}"
  if [[ -z "$input" ]]; then
    error "--input is required"
    return 1
  fi
  if [[ ! -r "$input" ]]; then
    error "Input file not readable: ${input}"
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  if ! tar -xzf "$input" -C "$tmpdir" 2>>"$LOG_FILE"; then
    error "Failed to extract ${input}"
    return 1
  fi
  local manifest="${tmpdir}/manifest.json"
  if ! backup_load_manifest "$manifest"; then
    return 1
  fi
  echo "===== Backup manifest ====="
  echo "Schema       : ${BACKUP_INFO_SCHEMA}"
  echo "Generated    : ${BACKUP_INFO_GENERATED}"
  echo "simai-env    : ${BACKUP_INFO_VERSION}"
  echo "Host OS      : ${BACKUP_INFO_HOST_OS}"
  echo "Host name    : ${BACKUP_INFO_HOSTNAME}"
  echo "Host notes   : ${BACKUP_INFO_HOST_NOTES}"
  local summary="${tmpdir}/summary.txt"
  if [[ -f "$summary" ]]; then
    echo "----- summary.txt -----"
    cat "$summary"
  fi
  local existing_sites=()
  mapfile -t existing_sites < <(list_sites)
  local warnings=()
  local ssl_warn_domains=()
  local ssl_warn_count=0
  local idx
  for idx in "${!BACKUP_SITES_DOMAINS[@]}"; do
    local d="${BACKUP_SITES_DOMAINS[$idx]}"
    local p="${BACKUP_SITES_PROFILES[$idx]}"
    local php="${BACKUP_SITES_PHPS[$idx]}"
    local tgt="${BACKUP_SITES_TARGETS[$idx]}"
    local ssl_enabled="${BACKUP_SITES_SSL_ENABLED[$idx]}"
    if [[ "${ssl_enabled,,}" == "true" ]]; then
      ((ssl_warn_count++))
      if [[ ${#ssl_warn_domains[@]} -lt 10 ]]; then
        ssl_warn_domains+=("$d")
      fi
    fi
    if ! is_profile_enabled "$p"; then
      warnings+=("Profile '${p}' is disabled (required for ${d})")
    fi
    local requires_php="yes"
    requires_php=$( ( set +u; unset PROFILE_REQUIRES_PHP PROFILE_IS_ALIAS PROFILE_REQUIRES_DB; source_profile_file_raw "$p" 2>/dev/null && echo "${PROFILE_REQUIRES_PHP:-yes}" ) 2>/dev/null || echo "yes")
    if [[ "${requires_php,,}" != "no" && -n "$php" && "$php" != "none" ]]; then
      if ! is_php_version_installed "$php"; then
        warnings+=("PHP ${php} not installed (needed for ${d})")
      fi
    fi
    if [[ "$p" == "alias" ]]; then
      local target_found=0
      for t in "${existing_sites[@]}" "${BACKUP_SITES_DOMAINS[@]}"; do
        [[ "$t" == "$tgt" ]] && target_found=1
      done
      if [[ -z "$tgt" || $target_found -eq 0 ]]; then
        warnings+=("Alias ${d} target '${tgt:-missing}' not found on this host or in backup")
      fi
    fi
  done
  if [[ $ssl_warn_count -gt 0 ]]; then
    echo "----- WARN (SSL) -----"
    echo "SSL detected in backup metadata for ${ssl_warn_count} site(s). Certificates/keys are NOT imported. Configure SSL manually after import."
    if [[ ${#ssl_warn_domains[@]} -gt 0 ]]; then
      local ssl_list
      ssl_list=$(IFS=', '; echo "${ssl_warn_domains[*]}")
      if [[ $ssl_warn_count -gt ${#ssl_warn_domains[@]} ]]; then
        local more=$((ssl_warn_count - ${#ssl_warn_domains[@]}))
        echo "Domains: ${ssl_list}, and ${more} more"
      else
        echo "Domains: ${ssl_list}"
      fi
    fi
  fi
  if [[ ${#warnings[@]} -gt 0 ]]; then
    echo "----- Warnings -----"
    local w
    for w in "${warnings[@]}"; do
      echo "- ${w}"
    done
  fi
  return 0
}

backup_import_handler() {
  parse_kv_args "$@"
  local input="${PARSED_ARGS[input]:-}"
  local apply="${PARSED_ARGS[apply]:-no}"
  local domains_filter="${PARSED_ARGS[domains]:-}"
  [[ "${apply,,}" != "yes" ]] && apply="no"
  if [[ -z "$input" ]]; then
    error "--input is required"
    return 1
  fi
  if [[ ! -r "$input" ]]; then
    error "Input file not readable: ${input}"
    return 1
  fi
  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' RETURN
  if ! tar -xzf "$input" -C "$tmpdir" 2>>"$LOG_FILE"; then
    error "Failed to extract ${input}"
    return 1
  fi
  local manifest="${tmpdir}/manifest.json"
  if ! backup_load_manifest "$manifest"; then
    return 1
  fi
  local filter_list=()
  if [[ -n "$domains_filter" ]]; then
    IFS=',' read -r -a filter_list <<<"$domains_filter"
  fi

  local existing_sites=()
  mapfile -t existing_sites < <(list_sites)
  local plan_domains=() plan_profiles=() plan_projects=() plan_roots=() plan_phps=() plan_targets=() plan_actions=() plan_alias=() plan_requires_db=() plan_requires_php=() plan_ssl_enabled=() plan_ssl_type=()
  local idx
  for idx in "${!BACKUP_SITES_DOMAINS[@]}"; do
    local d="${BACKUP_SITES_DOMAINS[$idx]}"
    if [[ ${#filter_list[@]} -gt 0 ]]; then
      local matched=0 f
      for f in "${filter_list[@]}"; do
        [[ "$f" == "$d" ]] && matched=1
      done
      [[ $matched -eq 0 ]] && continue
    fi
    plan_domains+=("$d")
    plan_profiles+=("${BACKUP_SITES_PROFILES[$idx]}")
    plan_projects+=("${BACKUP_SITES_PROJECTS[$idx]}")
    plan_roots+=("${BACKUP_SITES_ROOTS[$idx]}")
    plan_phps+=("${BACKUP_SITES_PHPS[$idx]}")
    plan_targets+=("${BACKUP_SITES_TARGETS[$idx]}")
    plan_alias+=("no")
    plan_requires_db+=("optional")
    plan_requires_php+=("yes")
    plan_ssl_enabled+=("${BACKUP_SITES_SSL_ENABLED[$idx]}")
    plan_ssl_type+=("${BACKUP_SITES_SSL_TYPES[$idx]}")
  done

  for idx in "${!plan_domains[@]}"; do
    local prof="${plan_profiles[$idx]}"
    local is_alias="no"
    local requires_db="required" requires_php="yes"
    is_alias=$( ( set +u; unset PROFILE_IS_ALIAS PROFILE_REQUIRES_DB PROFILE_REQUIRES_PHP; source_profile_file_raw "$prof" 2>/dev/null && echo "${PROFILE_IS_ALIAS:-no}" ) 2>/dev/null || echo "no")
    requires_db=$( ( set +u; unset PROFILE_IS_ALIAS PROFILE_REQUIRES_DB PROFILE_REQUIRES_PHP; source_profile_file_raw "$prof" 2>/dev/null && echo "${PROFILE_REQUIRES_DB:-required}" ) 2>/dev/null || echo "required")
    requires_php=$( ( set +u; unset PROFILE_IS_ALIAS PROFILE_REQUIRES_DB PROFILE_REQUIRES_PHP; source_profile_file_raw "$prof" 2>/dev/null && echo "${PROFILE_REQUIRES_PHP:-yes}" ) 2>/dev/null || echo "yes")
    plan_alias[$idx]="$is_alias"
    plan_requires_db[$idx]="$requires_db"
    plan_requires_php[$idx]="$requires_php"
  done

  local plan_order=()
  for idx in "${!plan_domains[@]}"; do
    [[ "${plan_alias[$idx]}" == "yes" ]] && continue
    plan_order+=("$idx")
  done
  for idx in "${!plan_domains[@]}"; do
    [[ "${plan_alias[$idx]}" != "yes" ]] && continue
    plan_order+=("$idx")
  done

  local table_sep="+------------------------------+----------+------+------------------------------------------+-----------+------------------------------------------+"
  printf "%s\n" "$table_sep"
  printf "| %-28s | %-8s | %-4s | %-40s | %-9s | %-40s |\n" "Domain" "Profile" "PHP" "Path/Target" "Action" "Notes"
  printf "%s\n" "$table_sep"
  local add_count=0 skip_count=0 block_count=0
  for idx in "${plan_order[@]}"; do
    local d="${plan_domains[$idx]}"
    local prof="${plan_profiles[$idx]}"
    local php="${plan_phps[$idx]}"
    local root="${plan_roots[$idx]}"
    local tgt="${plan_targets[$idx]}"
    local is_alias="${plan_alias[$idx]}"
    local ssl_enabled="${plan_ssl_enabled[$idx]}"
    local act="ADD"
    local notes=()
    if printf '%s\n' "${existing_sites[@]}" | grep -qx "$d"; then
      act="SKIP"
      notes+=("exists")
    fi
    if ! is_profile_enabled "$prof"; then notes+=("profile disabled -> enable"); fi
    if [[ "$is_alias" == "yes" ]]; then
      local target_found=0
      for t in "${existing_sites[@]}" "${plan_domains[@]}"; do
        [[ "$t" == "$tgt" ]] && target_found=1
      done
      [[ -z "$tgt" ]] && target_found=0
      if [[ $target_found -eq 0 ]]; then
        act="BLOCK"
        notes+=("alias target missing")
      fi
    fi
    if [[ "$act" != "SKIP" && "${plan_requires_php[$idx],,}" != "no" ]]; then
      if [[ -z "$php" || "$php" == "none" ]]; then
        act="BLOCK"
        notes+=("missing php in backup")
      elif ! is_php_version_installed "$php"; then
        act="BLOCK"
        notes+=("missing php ${php}")
      fi
    fi
    if [[ "$act" != "SKIP" && "${plan_requires_db[$idx]}" != "no" ]]; then
      if [[ "${plan_requires_db[$idx]}" == "required" ]]; then
        notes+=("DB required -> not created")
      else
        notes+=("DB optional -> not created")
      fi
    fi
    if [[ "$act" != "SKIP" && "${ssl_enabled,,}" == "true" ]]; then
      notes+=("SSL present -> manual")
    fi
    [[ "$act" == "ADD" ]] && ((add_count++))
    [[ "$act" == "SKIP" ]] && ((skip_count++))
    [[ "$act" == "BLOCK" ]] && ((block_count++))
    plan_actions[$idx]="$act"
    local path_display="$root"
    [[ "$is_alias" == "yes" ]] && path_display="alias -> ${tgt}"
    printf "| %-28s | %-8s | %-4s | %-40s | %-9s | %-40s |\n" "$d" "$prof" "$php" "$path_display" "$act" "${notes[*]}"
  done
  printf "%s\n" "$table_sep"
  echo "Plan: ADD=${add_count}, SKIP=${skip_count}, BLOCK=${block_count}"
  if [[ "$apply" != "yes" ]]; then
    echo "Apply mode: plan only (use --apply yes to execute)"
    return 0
  fi

  local enable_profiles=()
  local -A seen_profiles=()
  local idx_enable
  for idx in "${plan_order[@]}"; do
    if [[ "${plan_actions[$idx]}" != "ADD" ]]; then continue; fi
    local prof="${plan_profiles[$idx]}"
    if ! is_profile_enabled "$prof"; then
      if [[ -z "${seen_profiles[$prof]+x}" ]]; then
        enable_profiles+=("$prof")
        seen_profiles[$prof]=1
      fi
    fi
  done
  local tasks=$(( ${#plan_order[@]} + ${#enable_profiles[@]} ))
  ((tasks<1)) && tasks=1
  progress_init "$tasks"
  for idx_enable in "${!enable_profiles[@]}"; do
    local p="${enable_profiles[$idx_enable]}"
    progress_step "Enabling profile ${p}"
    if ! run_command "profile" "enable" --id "$p"; then
      error "Failed to enable profile ${p}"
      return 1
    fi
    progress_ok
  done

  apply_site() {
    local idx="$1"
    local d="${plan_domains[$idx]}" prof="${plan_profiles[$idx]}" root="${plan_roots[$idx]}" php="${plan_phps[$idx]}" tgt="${plan_targets[$idx]}"
    local project="${plan_projects[$idx]}"
    local is_alias="${plan_alias[$idx]}"
    progress_step "Importing ${d}"
    if [[ "${plan_actions[$idx]}" != "ADD" ]]; then
      progress_ok
      return 0
    fi
    if [[ "${plan_requires_php[$idx],,}" != "no" && -n "$php" && "$php" != "none" ]]; then
      if ! is_php_version_installed "$php"; then
        progress_fail
        return 1
      fi
    fi
    local args=(--domain "$d" --profile "$prof" --project-name "$project" --path "$root" --create-db "no" --skip-db-required "yes" --db-export "no")
    if [[ -n "$php" && "$php" != "none" ]]; then
      args+=(--php "$php")
    fi
    if [[ "$is_alias" == "yes" ]]; then
      args+=(--target-domain "$tgt")
    fi
    if ! run_command "site" "add" "${args[@]}"; then
      progress_fail
      return 1
    fi
    progress_ok
    return 0
  }

  local idx_apply
  for idx_apply in "${plan_order[@]}"; do
    [[ "${plan_alias[$idx_apply]}" == "yes" ]] && continue
    if ! apply_site "$idx_apply"; then
      return 1
    fi
  done
  for idx_apply in "${plan_order[@]}"; do
    [[ "${plan_alias[$idx_apply]}" != "yes" ]] && continue
    if ! apply_site "$idx_apply"; then
      return 1
    fi
  done
  progress_done "Backup import completed"
  return 0
}

register_cmd "backup" "inspect" "Inspect backup manifest (plan-only)" "backup_inspect_handler" "" "input="
register_cmd "backup" "import" "Import backup bundle (plan/apply; no DB/secrets)" "backup_import_handler" "" "input= apply= domains="
