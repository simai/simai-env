#!/usr/bin/env bash

profile_validate_results_status=()
profile_validate_results_profile=()
profile_validate_results_msg=()

profile_add_result() {
  local status="$1" profile="$2" msg="$3"
  profile_validate_results_status+=("$status")
  profile_validate_results_profile+=("$profile")
  profile_validate_results_msg+=("$msg")
}

profile_print_summary() {
  local pass=0 warn=0 fail=0
  local i
  for i in "${profile_validate_results_status[@]}"; do
    case "$i" in
      PASS) ((pass++)) ;;
      WARN) ((warn++)) ;;
      FAIL) ((fail++)) ;;
    esac
  done
  local total=${#profile_validate_results_status[@]}
  for i in $(seq 0 $((total-1))); do
    printf "[%s] %s — %s\n" "${profile_validate_results_status[$i]}" "${profile_validate_results_profile[$i]}" "${profile_validate_results_msg[$i]}"
  done
  declare -A seen=()
  for i in "${profile_validate_results_profile[@]}"; do
    seen["$i"]=1
  done
  printf "Profiles checked: %d\n" "${#seen[@]}"
  printf "PASS: %d, WARN: %d, FAIL: %d\n" "$pass" "$warn" "$fail"
  [[ $fail -eq 0 ]] && return 0 || return 1
}

profile_validate_file() {
  local file="$1" id="$2"
  local failures=0 warnings=0
  local templates_dir="${SCRIPT_DIR}/templates"

  if ! bash -n "$file" 2>>"$LOG_FILE"; then
    profile_add_result "FAIL" "$id" "Bash syntax error (bash -n failed)"
    failures=1
  fi

  if ! validate_profile_file "$file"; then
    profile_add_result "FAIL" "$id" "Profile file contains forbidden syntax (PROFILE_* assignments only)"
    return
  fi

  local non_profile_vars
  non_profile_vars=$(bash -c 'set -a; before=$(compgen -v | sort); source "$1"; after=$(compgen -v | sort); comm -13 <(echo "$before") <(echo "$after")' bash "$file" 2>/dev/null) || {
    profile_add_result "FAIL" "$id" "Failed to source profile for variable diff"
    failures=1
  }
  if [[ -n "$non_profile_vars" ]]; then
    local v
    while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      if [[ ! "$v" =~ ^PROFILE_ ]]; then
        profile_add_result "FAIL" "$id" "Non-PROFILE variable declared: ${v}"
        failures=1
      fi
    done <<<"$non_profile_vars"
  fi

  local meta
  meta=$(bash -c '
set -a
source "$1" || exit 1
printf "PROFILE_ID=%s\n" "${PROFILE_ID-}"
printf "PROFILE_TITLE=%s\n" "${PROFILE_TITLE-}"
printf "PROFILE_REQUIRES_PHP=%s\n" "${PROFILE_REQUIRES_PHP-}"
printf "PROFILE_REQUIRES_DB=%s\n" "${PROFILE_REQUIRES_DB-}"
printf "PROFILE_NGINX_TEMPLATE=%s\n" "${PROFILE_NGINX_TEMPLATE-}"
printf "PROFILE_PUBLIC_DIR=%s\n" "${PROFILE_PUBLIC_DIR-}"
printf "PROFILE_IS_ALIAS=%s\n" "${PROFILE_IS_ALIAS-}"
printf "PROFILE_ALLOW_PHP_SWITCH=%s\n" "${PROFILE_ALLOW_PHP_SWITCH-}"
printf "PROFILE_SUPPORTS_CRON=%s\n" "${PROFILE_SUPPORTS_CRON-}"
printf "PROFILE_SUPPORTS_QUEUE=%s\n" "${PROFILE_SUPPORTS_QUEUE-}"
printf "PROFILE_HEALTHCHECK_ENABLED=%s\n" "${PROFILE_HEALTHCHECK_ENABLED-}"
printf "PROFILE_HEALTHCHECK_MODE=%s\n" "${PROFILE_HEALTHCHECK_MODE-}"
declare -p PROFILE_PHP_EXTENSIONS_REQUIRED 2>/dev/null || true
declare -p PROFILE_PHP_EXTENSIONS_RECOMMENDED 2>/dev/null || true
declare -p PROFILE_PHP_INI_REQUIRED 2>/dev/null || true
declare -p PROFILE_PHP_INI_RECOMMENDED 2>/dev/null || true
declare -p PROFILE_PHP_INI_FORBIDDEN 2>/dev/null || true
declare -p PROFILE_ALLOWED_PHP_VERSIONS 2>/dev/null || true
declare -p PROFILE_WRITABLE_PATHS 2>/dev/null || true
declare -p PROFILE_REQUIRED_MARKERS 2>/dev/null || true
declare -p PROFILE_BOOTSTRAP_FILES 2>/dev/null || true
' bash "$file" 2>/dev/null) || {
    profile_add_result "FAIL" "$id" "Failed to source profile for required fields"
    return
  }

  declare -A fields=()
  local line
  while IFS= read -r line; do
    [[ "$line" != PROFILE_* ]] && continue
    local key="${line%%=*}"
    local val="${line#*=}"
    fields["$key"]="$val"
  done <<<"$(printf "%s\n" "$meta" | grep '^PROFILE_')"

  local file_id="$id"
  local profile_id="${fields[PROFILE_ID]:-}"
  local required_fields=(PROFILE_ID PROFILE_TITLE PROFILE_REQUIRES_PHP PROFILE_REQUIRES_DB PROFILE_PUBLIC_DIR)
  local rf
  for rf in "${required_fields[@]}"; do
    if [[ -z "${fields[$rf]:-}" ]]; then
      profile_add_result "FAIL" "$id" "Missing required field ${rf}"
      failures=1
    fi
  done

  if [[ -n "$profile_id" ]]; then
    if [[ ! "$profile_id" =~ ^[a-z0-9][a-z0-9-]{1,63}$ ]]; then
      profile_add_result "FAIL" "$id" "Invalid PROFILE_ID format '${profile_id}'"
      failures=1
    elif [[ "$profile_id" != "$file_id" ]]; then
      profile_add_result "WARN" "$id" "PROFILE_ID (${profile_id}) does not match filename id (${file_id})"
      warnings=1
    fi
  fi

  local yesno_fields=(PROFILE_REQUIRES_PHP PROFILE_IS_ALIAS PROFILE_ALLOW_PHP_SWITCH PROFILE_SUPPORTS_CRON PROFILE_SUPPORTS_QUEUE PROFILE_HEALTHCHECK_ENABLED)
  local yf
  for yf in "${yesno_fields[@]}"; do
    local val="${fields[$yf]:-}"
    [[ -z "$val" ]] && continue
    if [[ "$val" != "yes" && "$val" != "no" ]]; then
      profile_add_result "FAIL" "$id" "Field ${yf} must be yes/no (got '${val}')"
      failures=1
    fi
  done

  if [[ "${fields[PROFILE_HEALTHCHECK_ENABLED]:-}" == "yes" ]]; then
    local mode="${fields[PROFILE_HEALTHCHECK_MODE]:-}"
    if [[ "$mode" != "php" && "$mode" != "nginx" ]]; then
      profile_add_result "FAIL" "$id" "PROFILE_HEALTHCHECK_MODE must be php|nginx when enabled (got '${mode:-<empty>}')"
      failures=1
    fi
  fi

  local requires_db_val="${fields[PROFILE_REQUIRES_DB]:-}"
  if [[ -n "$requires_db_val" && "$requires_db_val" != "no" && "$requires_db_val" != "optional" && "$requires_db_val" != "required" ]]; then
    profile_add_result "FAIL" "$id" "PROFILE_REQUIRES_DB must be no|optional|required (got '${requires_db_val}')"
    failures=1
  fi

  local public_dir="${fields[PROFILE_PUBLIC_DIR]:-}"
  if [[ -n "$public_dir" && "$public_dir" != "public" ]]; then
    profile_add_result "FAIL" "$id" "PROFILE_PUBLIC_DIR must be 'public' (got '${public_dir}')"
    failures=1
  fi

  local tmpl="${fields[PROFILE_NGINX_TEMPLATE]:-}"
  local is_alias="${fields[PROFILE_IS_ALIAS]:-no}"
  if [[ "$is_alias" != "yes" ]]; then
    if [[ -z "$tmpl" ]]; then
      profile_add_result "FAIL" "$id" "PROFILE_NGINX_TEMPLATE is required"
      failures=1
    elif [[ "$tmpl" == */* || "$tmpl" == *".."* || "$tmpl" =~ [[:space:]] ]]; then
      profile_add_result "FAIL" "$id" "PROFILE_NGINX_TEMPLATE must be a filename under templates/ with no slashes/spaces (got '${tmpl}')"
      failures=1
    else
      local tmpl_path="${templates_dir}/${tmpl}"
      if [[ ! -f "$tmpl_path" ]]; then
        profile_add_result "FAIL" "$id" "nginx template file missing: ${tmpl_path}"
        failures=1
      fi
    fi
  fi

  local requires_php="${fields[PROFILE_REQUIRES_PHP]:-no}"
  local declared_arrays
  declared_arrays="$(printf "%s\n" "$meta" | grep '^declare -[aA] PROFILE_PHP_' || true)"
  if [[ "$requires_php" != "yes" && -n "$declared_arrays" ]]; then
    profile_add_result "WARN" "$id" "PHP-specific fields set while PROFILE_REQUIRES_PHP=${requires_php}"
    warnings=1
  fi

  check_array_declared() {
    local name="$1"
    printf "%s\n" "$meta" | grep -q "declare -a ${name}=" 
  }

  local array_names=(PROFILE_PHP_EXTENSIONS_REQUIRED PROFILE_PHP_EXTENSIONS_RECOMMENDED PROFILE_PHP_INI_REQUIRED PROFILE_PHP_INI_RECOMMENDED PROFILE_PHP_INI_FORBIDDEN)
  local an
  for an in "${array_names[@]}"; do
    if printf "%s\n" "$meta" | grep -q "^declare .* ${an}="; then
      if ! printf "%s\n" "$meta" | grep -q "declare -a ${an}="; then
        profile_add_result "FAIL" "$id" "${an} must be an array"
        failures=1
      fi
    fi
  done

  validate_ini_array() {
    local arr_name="$1" op_type="$2" entries
    mapfile -t entries < <(bash -c "source \"$file\" || exit 1; for e in \"\${${arr_name}[@]}\"; do echo \"\$e\"; done" 2>/dev/null)
    local entry
    for entry in "${entries[@]}"; do
      [[ -z "$entry" ]] && continue
      if [[ "$op_type" == "forbidden" ]]; then
        if [[ ! "$entry" =~ ^[A-Za-z0-9_.-]+=.+$ ]]; then
          profile_add_result "WARN" "$id" "${arr_name}: expected KEY=VALUE for forbidden entry ('${entry}')"
          warnings=1
        fi
      else
        if [[ ! "$entry" =~ ^[A-Za-z0-9_.-]+([><]=?|=)[^[:space:]]+$ ]]; then
          profile_add_result "FAIL" "$id" "${arr_name}: invalid INI expectation format ('${entry}')"
          failures=1
        fi
      fi
    done
  }

  [[ "$requires_php" == "yes" ]] && validate_ini_array "PROFILE_PHP_INI_REQUIRED" "req"
  [[ "$requires_php" == "yes" ]] && validate_ini_array "PROFILE_PHP_INI_RECOMMENDED" "rec"
  validate_ini_array "PROFILE_PHP_INI_FORBIDDEN" "forbidden"

  if [[ $failures -eq 0 && $warnings -eq 0 ]]; then
    profile_add_result "PASS" "$id" "OK"
  fi
}

profile_validate_handler() {
  parse_kv_args "$@"
  profile_validate_results_status=()
  profile_validate_results_profile=()
  profile_validate_results_msg=()
  local id="${PARSED_ARGS[id]:-}"
  local all="${PARSED_ARGS[all]:-yes}"
  [[ "${all,,}" == "yes" ]] && all="yes" || all="no"
  if [[ -z "$id" && "$all" != "yes" ]]; then
    error "Specify --id or set --all yes"
    return 1
  fi
  local dir
  dir=$(profiles_dir)
  local files=()
  if [[ -n "$id" ]]; then
    local file="${dir}/${id}.profile.sh"
    if [[ ! -f "$file" ]]; then
      error "Profile file not found: ${file}"
      return 1
    fi
    files+=("$file")
  else
    shopt -s nullglob
    for f in "$dir"/*.profile.sh; do
      files+=("$f")
    done
    shopt -u nullglob
  fi

  progress_init ${#files[@]}
  local f
  for f in "${files[@]}"; do
    local pid
    pid=$(basename "$f" | sed 's/\.profile\.sh$//')
    progress_step "Validating profile ${pid}"
    profile_validate_file "$f" "$pid"
  done
  progress_done "Validation complete"
  profile_print_summary
}

register_cmd "profile" "validate" "Validate profile files (read-only lint)" "profile_validate_handler" "" "id= all=yes"

profile_list_handler() {
  parse_kv_args "$@"
  local all="${PARSED_ARGS[all]:-no}"
  [[ "${all,,}" == "yes" ]] && all="yes" || all="no"
  local ids=()
  if [[ "$all" == "yes" ]]; then
    mapfile -t ids < <(list_profile_ids 2>/dev/null || true)
  else
    mapfile -t ids < <(list_enabled_profile_ids 2>/dev/null || true)
  fi
  if [[ ${#ids[@]} -eq 0 ]]; then
    info "No profiles found"
    return 0
  fi
  local border="+------------+----------+--------------------------+-------------+-------------+-------+"
  printf "%s\n" "$border"
  printf "| %-10s | %-8s | %-24s | %-11s | %-11s | %-5s |\n" "ID" "Status" "Title" "RequiresPHP" "RequiresDB" "Alias"
  printf "%s\n" "$border"
  local id
  for id in "${ids[@]}"; do
    local status="disabled"
    if is_profile_enabled "$id"; then
      status="enabled"
    fi
    local file
    file="$(profiles_dir)/${id}.profile.sh"
    local title="(invalid)" req_php="?" req_db="?" alias="no"
    if [[ -f "$file" ]] && validate_profile_file "$file"; then
      local meta
      meta=$(bash -c '
set -a
source "$1" || exit 1
printf "%s\n" "${PROFILE_TITLE-}"
printf "%s\n" "${PROFILE_REQUIRES_PHP-}"
printf "%s\n" "${PROFILE_REQUIRES_DB-}"
printf "%s\n" "${PROFILE_IS_ALIAS-}"
' bash "$file" 2>/dev/null || true)
      if [[ -n "$meta" ]]; then
        title=$(echo "$meta" | sed -n '1p')
        req_php=$(echo "$meta" | sed -n '2p')
        req_db=$(echo "$meta" | sed -n '3p')
        alias=$(echo "$meta" | sed -n '4p')
      fi
    fi
    printf "| %-10s | %-8s | %-24s | %-11s | %-11s | %-5s |\n" "$id" "$status" "${title:0:24}" "${req_php:-?}" "${req_db:-?}" "${alias:-no}"
  done
  printf "%s\n" "$border"
  if profiles_allowlist_exists; then
    echo "Activation mode: allowlist ($(profiles_enabled_file))"
  else
    echo "Activation mode: legacy (all profiles enabled)"
  fi
}

profile_used_by_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[id]:-}"
  local domains=()
  mapfile -t domains < <(list_sites)
  declare -A profile_to_domains=()
  local d
  for d in "${domains[@]}"; do
    read_site_metadata "$d"
    local pid="${SITE_META[profile]:-}"
    profile_to_domains["$pid"]+="${d} "
  done
  if [[ -n "$id" ]]; then
    if ! is_profile_known "$id"; then
      error "Unknown profile: ${id}"
      return 1
    fi
    local list="${profile_to_domains[$id]:-}"
    if [[ -z "$list" ]]; then
      info "No sites use profile ${id}"
      return 0
    fi
    echo "Sites using profile ${id}:"
    for d in $list; do
      echo "- ${d}"
    done
    return 0
  fi
  local border="+------------+-------+"
  printf "%s\n" "$border"
  printf "| %-10s | %-5s |\n" "Profile" "Count"
  printf "%s\n" "$border"
  local pid
  for pid in "${!profile_to_domains[@]}"; do
    local count=0
    for _ in ${profile_to_domains[$pid]}; do ((count++)); done
    printf "| %-10s | %-5s |\n" "$pid" "$count"
  done
  printf "%s\n" "$border"
  echo "Use --id <profile> to list domains for a specific profile."
}

profile_enable_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[id]:-}"
  if [[ -z "$id" ]]; then
    require_args "id"
  fi
  if ! is_profile_known "$id"; then
    error "Unknown profile: ${id}"
    return 1
  fi
  ensure_profiles_allowlist_initialized_from_legacy
  local current=()
  mapfile -t current < <(read_profiles_allowlist || true)
  if printf '%s\n' "${current[@]}" | grep -qx "$id"; then
    info "Profile ${id} already enabled"
    return 0
  fi
  current+=("$id")
  printf "%s\n" "${current[@]}" | write_profiles_allowlist
  info "Profile ${id} enabled"
}

profile_disable_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[id]:-}"
  local force="${PARSED_ARGS[force]:-no}"
  [[ "${force,,}" == "yes" ]] && force="yes" || force="no"
  if [[ -z "$id" ]]; then
    require_args "id"
  fi
  if ! is_profile_known "$id"; then
    error "Unknown profile: ${id}"
    return 1
  fi
  if profiles_core_ids | grep -qx "$id"; then
    if [[ "$force" != "yes" ]]; then
      error "Cannot disable core profile ${id} without --force yes"
      return 1
    else
      warn "Disabling core profile ${id} with --force yes"
    fi
  fi
  ensure_profiles_allowlist_initialized_from_legacy
  local domains=()
  mapfile -t domains < <(list_sites)
  local used=()
  local d
  for d in "${domains[@]}"; do
    read_site_metadata "$d"
    if [[ "${SITE_META[profile]:-}" == "$id" ]]; then
      used+=("$d")
    fi
  done
  if [[ ${#used[@]} -gt 0 && "$force" != "yes" ]]; then
    error "Profile ${id} is used by existing sites: ${used[*]}. Re-run with --force yes to disable anyway."
    return 1
  elif [[ ${#used[@]} -gt 0 ]]; then
    warn "Disabling profile ${id} that is used by sites: ${used[*]}"
  fi
  local remaining=()
  mapfile -t remaining < <(read_profiles_allowlist || true)
  if [[ ${#remaining[@]} -eq 0 ]]; then
    info "Allowlist is empty; nothing to disable"
    return 0
  fi
  mapfile -t remaining < <(printf '%s\n' "${remaining[@]}" | grep -vx "$id" || true)
  printf "%s\n" "${remaining[@]}" | write_profiles_allowlist
  info "Profile ${id} disabled"
}

profile_init_handler() {
  parse_kv_args "$@"
  local mode="${PARSED_ARGS[mode]:-core}"
  local force="${PARSED_ARGS[force]:-no}"
  [[ "${force,,}" == "yes" ]] && force="yes" || force="no"
  case "$mode" in
    core|all) ;;
    *) error "Invalid mode: ${mode} (use core|all)"; return 1 ;;
  esac
  if profiles_allowlist_exists && [[ "$force" != "yes" ]]; then
    error "Profiles allowlist already exists at $(profiles_enabled_file). Use --force yes to overwrite."
    return 1
  fi
  local ids=()
  mapfile -t ids < <(profiles_core_ids)
  local domains=()
  mapfile -t domains < <(list_sites)
  local d
  for d in "${domains[@]}"; do
    read_site_metadata "$d"
    ids+=("${SITE_META[profile]:-}")
  done
  if [[ "$mode" == "all" ]]; then
    mapfile -t extra < <(list_profile_ids 2>/dev/null || true)
    ids+=("${extra[@]}")
  fi
  printf "%s\n" "${ids[@]}" | write_profiles_allowlist
  info "Profiles allowlist initialized (${mode}) at $(profiles_enabled_file)"
}

register_cmd "profile" "list" "List profiles and activation status" "profile_list_handler" "" "all=no"
register_cmd "profile" "used-by" "Show profile usage summary" "profile_used_by_handler" "" "id="
register_cmd "profile" "used-by-one" "Show sites using a specific profile" "profile_used_by_handler" "id" ""
register_cmd "profile" "enable" "Enable a profile" "profile_enable_handler" "id" ""
register_cmd "profile" "disable" "Disable a profile" "profile_disable_handler" "id" "force=no"
register_cmd "profile" "init" "Initialize profile activation allowlist" "profile_init_handler" "" "mode=core force=no"
