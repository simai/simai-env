#!/usr/bin/env bash

site_fix_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local apply="${PARSED_ARGS[apply]:-none}"
  local include_recommended="${PARSED_ARGS[include-recommended]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local apply_mode="${apply,,}"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    domain=$(select_from_list "Select domain to fix" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "${PARSED_ARGS[apply]:-}" ]]; then
    local choice
    choice=$(select_from_list "Select fix actions" "1" "1: Plan only" "2: Apply missing REQUIRED PHP extensions" "3: Apply REQUIRED PHP INI overrides (pool)" "4: Apply both (extensions + INI)")
    case "$choice" in
      1*) apply="none" ;;
      2*) apply="php-ext" ;;
      3*) apply="php-ini" ;;
      4*) apply="all" ;;
    esac
  fi
  case "$apply_mode" in
    none|php-ext|php-ini|all) ;;
    *) error "Invalid --apply value: ${apply} (use none|php-ext|php-ini|all)"; return 1 ;;
  esac

  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" && -z "${PARSED_ARGS[include-recommended]:-}" ]]; then
    local choice
    choice=$(select_from_list "Include RECOMMENDED items?" "no" "no" "yes")
    include_recommended="$choice"
  fi
  [[ "${include_recommended,,}" == "yes" ]] && include_recommended="yes" || include_recommended="no"

  if [[ "$apply_mode" != "none" && "${SIMAI_ADMIN_MENU:-0}" != "1" ]]; then
    if [[ "${confirm,,}" != "yes" ]]; then
      error "Apply requested (--apply ${apply}); add --confirm yes to proceed"
      return 1
    fi
  fi

  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi

  progress_init 5
  progress_step "Reading site metadata"
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  local root="${SITE_META[root]:-${WWW_ROOT}/${domain}}"
  local php_version="${SITE_META[php]:-}"
  local socket_meta="${SITE_META[php_socket_project]:-$project}"

  progress_step "Validating profile and environment"
  if ! validate_path "$root"; then
    error "Project root path ${root} is invalid in metadata"
    return 1
  fi
  if ! load_profile "$profile"; then
    error "Failed to load profile ${profile} for ${domain}"
    return 1
  fi
  if [[ "${PROFILE_IS_ALIAS:-no}" == "yes" ]]; then
    error "Fix must be run on the target site (alias inherits target)."
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_PHP}" == "no" ]]; then
    error "Profile ${profile} does not use PHP."
    return 1
  fi
  if [[ -z "$php_version" || "$php_version" == "none" ]]; then
    error "Site has no PHP version configured in metadata."
    return 1
  fi
  if [[ ! -d "/etc/php/${php_version}" ]]; then
    error "PHP ${php_version} is not installed."
    return 1
  fi
  local php_bin
  php_bin=$(command -v "php${php_version}" || true)
  if [[ -z "$php_bin" ]]; then
    error "PHP binary php${php_version} not found in PATH."
    return 1
  fi

  local resolved
  resolved=$(fix_resolve_effective_project_and_socket "$domain" "$project" "$socket_meta")
  local socket_project
  IFS="|" read -r _ socket_project <<<"$resolved"

  progress_step "Planning PHP extensions"
  local missing_req=() missing_rec=()
  local modules=()
  mapfile -t modules < <(doctor_php_modules "$php_bin" || true)
  local ext
  for ext in "${PROFILE_PHP_EXTENSIONS_REQUIRED[@]}"; do
    [[ -z "$ext" ]] && continue
    if ! printf '%s\n' "${modules[@]}" | grep -qx "${ext,,}"; then
      missing_req+=("$ext")
    fi
  done
  if [[ "$include_recommended" == "yes" ]]; then
    for ext in "${PROFILE_PHP_EXTENSIONS_RECOMMENDED[@]}"; do
      [[ -z "$ext" ]] && continue
      if ! printf '%s\n' "${modules[@]}" | grep -qx "${ext,,}"; then
        missing_rec+=("$ext")
      fi
    done
  fi
  if [[ ${#missing_req[@]} -eq 0 ]]; then
    info "Missing REQUIRED extensions: none"
  else
    info "Missing REQUIRED extensions: ${missing_req[*]}"
  fi
  if [[ "$include_recommended" == "yes" ]]; then
    if [[ ${#missing_rec[@]} -eq 0 ]]; then
      info "Missing RECOMMENDED extensions: none"
    else
      info "Missing RECOMMENDED extensions: ${missing_rec[*]}"
    fi
  fi

  progress_step "Planning PHP INI overrides"
  local desired_ini=()
  desired_ini+=("${PROFILE_PHP_INI_REQUIRED[@]}")
  if [[ "$include_recommended" == "yes" ]]; then
    desired_ini+=("${PROFILE_PHP_INI_RECOMMENDED[@]}")
  fi
  local ini_to_apply=()
  local ini_unknown=()
  local ini_ok=()
  local ext_plan_req_desc="" ext_plan_rec_desc=""
  local ini_plan_desc="" ini_unknown_desc=""
  local ini_entry parsed key expected actual cmp
  for ini_entry in "${desired_ini[@]}"; do
    [[ -z "$ini_entry" ]] && continue
    parsed=$(doctor_parse_ini_expectation "$ini_entry" || true)
    if [[ -z "$parsed" ]]; then
      warn "INI entry ignored (invalid format): ${ini_entry}"
      continue
    fi
    key="${parsed%%|*}"; expected="${parsed#*|}"
    actual=$(doctor_php_ini_get "$php_bin" "$key" || true)
    cmp=$(doctor_compare_ini "$key" "$expected" "$actual")
    case "$cmp" in
      ok) ini_ok+=("${key}=${actual}") ;;
      bad) ini_to_apply+=("${key}|${expected}") ;;
      unknown) ini_unknown+=("${key}") ;;
    esac
  done
  if [[ ${#ini_to_apply[@]} -eq 0 ]]; then
    info "INI overrides needed: none"
  else
    local list=()
    for ini_entry in "${ini_to_apply[@]}"; do
      list+=("${ini_entry%%|*}")
    done
    info "INI overrides needed for: ${list[*]}"
  fi
  if [[ ${#ini_unknown[@]} -gt 0 ]]; then
    warn "INI entries unevaluable; skipping auto-fix: ${ini_unknown[*]}"
  fi
  ext_plan_req_desc=$([[ ${#missing_req[@]} -gt 0 ]] && echo "${missing_req[*]}" || echo "none")
  if [[ "$include_recommended" == "yes" ]]; then
    ext_plan_rec_desc=$([[ ${#missing_rec[@]} -gt 0 ]] && echo "${missing_rec[*]}" || echo "none")
  else
    ext_plan_rec_desc="skipped"
  fi
  ini_plan_desc=$([[ ${#ini_to_apply[@]} -gt 0 ]] && { local keys=(); for ini_entry in "${ini_to_apply[@]}"; do keys+=("${ini_entry%%|*}"); done; echo "${keys[*]}"; } || echo "none")
  ini_unknown_desc=$([[ ${#ini_unknown[@]} -gt 0 ]] && echo "${ini_unknown[*]}" || echo "none")

  progress_step "Applying requested fixes"
  if [[ "$apply_mode" == "none" ]]; then
    info "Plan only (no changes applied)"
  fi

  local apply_ext=0 apply_ini=0
  case "$apply_mode" in
    php-ext) apply_ext=1 ;;
    php-ini) apply_ini=1 ;;
    all) apply_ext=1; apply_ini=1 ;;
  esac

  local apt_updated=0
  local ext_failed=0
  local ext_result="skipped"
  if (( apply_ext == 1 )); then
    ext_result="none needed"
    if [[ ${#missing_req[@]} -eq 0 && ${#missing_rec[@]} -eq 0 ]]; then
      info "No PHP extensions to install"
    else
      local pkgs=() unknown_ext=()
      for ext in "${missing_req[@]}" "${missing_rec[@]}"; do
        [[ -z "$ext" ]] && continue
        local pkg
        pkg=$(doctor_ext_to_apt_pkg "$php_version" "$ext")
        if [[ -n "$pkg" ]]; then
          pkgs+=("$pkg")
        else
          unknown_ext+=("$ext")
        fi
      done
      if [[ ${#unknown_ext[@]} -gt 0 ]]; then
        warn "No package mapping for extensions: ${unknown_ext[*]} (install manually)"
      fi
      if [[ ${#pkgs[@]} -eq 0 ]]; then
        error "No installable packages resolved for missing extensions"
        ext_failed=1
      else
        mapfile -t pkgs < <(printf "%s\n" "${pkgs[@]}" | sort -u)
        info "Installing packages: ${pkgs[*]}"
        if [[ $apt_updated -eq 0 ]]; then
          os_cmd_pkg_update
          if ! run_long "Updating apt indexes" "${OS_CMD[@]}"; then
            error "apt-get update failed; aborting extension install"
            ext_failed=1
          fi
          apt_updated=1
        fi
        if [[ $ext_failed -eq 0 ]]; then
          os_cmd_pkg_install "${pkgs[@]}"
          if run_long "Installing packages" "${OS_CMD[@]}"; then
            if ! fix_php_fpm_test "$php_version"; then
              error "php-fpm${php_version} config test failed after extension install"
              ext_failed=1
            else
              if ! fix_reload_php_fpm "$php_version"; then
                ext_failed=1
              fi
            fi
          else
            ext_failed=1
          fi
        fi
        if [[ $ext_failed -eq 0 ]]; then
          mapfile -t modules < <(doctor_php_modules "$php_bin" || true)
          local still_missing=()
          for ext in "${missing_req[@]}"; do
            if ! printf '%s\n' "${modules[@]}" | grep -qx "${ext,,}"; then
              still_missing+=("$ext")
            fi
          done
          if [[ ${#still_missing[@]} -gt 0 ]]; then
            error "Required extensions still missing after install: ${still_missing[*]}"
            ext_failed=1
          else
            info "Required extensions installed"
          fi
        else
          error "Failed to install packages: ${pkgs[*]}"
          ext_failed=1
        fi
      fi
    fi
    if [[ $ext_failed -eq 0 ]]; then
      ext_result="applied"
    else
      ext_result="failed"
    fi
  elif [[ "$apply_mode" == "none" ]]; then
    ext_result="skipped (plan)"
  fi

  local ini_failed=0
  local ini_result="skipped"
  if (( apply_ini == 1 )); then
    ini_result="none needed"
    if [[ ${#ini_to_apply[@]} -eq 0 ]]; then
      info "No INI overrides to apply"
    else
      local pool_file
      pool_file=$(fix_resolve_pool_file "$php_version" "$socket_project") || return 1
      local backup
      backup="${pool_file}.bak.$(date +%Y%m%d%H%M%S)"
      cp -p "$pool_file" "$backup" >>"$LOG_FILE" 2>&1 || backup=""

      local tmp_clean tmp_out
      tmp_clean=$(mktemp)
      tmp_out=$(mktemp)
      perl -0pe 's/; simai-profile-ini-begin.*?; simai-profile-ini-end\n?//s' "$pool_file" >"$tmp_clean"
      cat "$tmp_clean" >"$tmp_out"
      printf "\n; simai-profile-ini-begin\n" >>"$tmp_out"
      for ini_entry in "${ini_to_apply[@]}"; do
        key="${ini_entry%%|*}"; expected="${ini_entry#*|}"
        local norm
        norm=$(doctor_normalize_bool "$expected")
        if [[ "$norm" == "1" || "$norm" == "0" ]]; then
          local flag="off"
          [[ "$norm" == "1" ]] && flag="on"
          printf "php_admin_flag[%s] = %s\n" "$key" "$flag" >>"$tmp_out"
        else
          printf "php_admin_value[%s] = %s\n" "$key" "$expected" >>"$tmp_out"
        fi
      done
      printf "; simai-profile-ini-end\n" >>"$tmp_out"
      rm -f "$tmp_clean"

      chmod --reference="$pool_file" "$tmp_out" 2>/dev/null || true
      chown --reference="$pool_file" "$tmp_out" 2>/dev/null || true
      mv "$tmp_out" "$pool_file"

      if ! fix_php_fpm_test "$php_version"; then
        error "php-fpm${php_version} config test failed; restoring pool file"
        if [[ -n "$backup" && -f "$backup" ]]; then
          cp -p "$backup" "$pool_file" >>"$LOG_FILE" 2>&1 || true
        fi
        ini_failed=1
      else
        if ! fix_reload_php_fpm "$php_version"; then
          ini_failed=1
        fi
      fi
    fi
    if [[ $ini_failed -eq 0 ]]; then
      ini_result="applied"
    else
      ini_result="failed"
    fi
  elif [[ "$apply_mode" == "none" ]]; then
    ini_result="skipped (plan)"
  fi

  local exit_code=0
  if (( ext_failed != 0 || ini_failed != 0 )); then
    exit_code=1
  fi

  echo "===== site fix summary ====="
  echo "Domain     : ${domain}"
  echo "Profile    : ${profile}"
  echo "PHP        : ${php_version}"
  echo "Apply mode : ${apply_mode}"
  echo "Ext plan   : required=${ext_plan_req_desc}; recommended=${ext_plan_rec_desc}"
  echo "Ext result : ${ext_result}"
  echo "INI plan   : overrides=${ini_plan_desc}; unevaluable=${ini_unknown_desc}"
  echo "INI result : ${ini_result}"
  echo "Exit       : $([[ $exit_code -eq 0 ]] && echo OK || echo ERROR)"

  return $exit_code
}

register_cmd "site" "fix" "Fix site PHP requirements by profile (extensions/ini) — plan by default" "site_fix_handler" "" "domain= apply= include-recommended= confirm=" "tier:advanced"
