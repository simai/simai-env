#!/usr/bin/env bash
set -euo pipefail

doctor_nginx_location_is_local_only() {
  local conf="$1" location_path="$2"
  [[ -f "$conf" ]] || return 1
  local loc_path_lc="${location_path,,}"
  local location_regex="${loc_path_lc//./\\.}"
  local in_block=0 depth=0 started=0 found=0
  local allow_v4=0 allow_v6=0 deny_all=0
  local location_pattern="location[[:space:]]*=[[:space:]]*${location_regex}[[:space:]]*\\{?"
  while IFS= read -r line; do
    local line_lc="${line,,}"
    if [[ "$line_lc" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    if (( in_block == 0 )); then
      if [[ "$line_lc" =~ $location_pattern ]]; then
        in_block=1
        found=1
      else
        continue
      fi
    fi
    [[ "$line_lc" =~ allow[[:space:]]+127\.0\.0\.1\; ]] && allow_v4=1
    [[ "$line_lc" =~ allow[[:space:]]+\:\:1\; ]] && allow_v6=1
    [[ "$line_lc" =~ deny[[:space:]]+all\; ]] && deny_all=1
    local opens closes
    opens=$(printf '%s' "$line" | tr -cd '{' | wc -c | tr -d '[:space:]')
    closes=$(printf '%s' "$line" | tr -cd '}' | wc -c | tr -d '[:space:]')
    if [[ $opens -gt 0 || $closes -gt 0 ]]; then
      ((depth+=opens))
      ((depth-=closes))
      if [[ $opens -gt 0 ]]; then
        started=1
      fi
    fi
    if (( started == 1 && depth <= 0 )); then
      break
    fi
  done < "$conf"
  if (( found == 0 )); then
    return 2
  fi
  if (( (allow_v4 == 1 || allow_v6 == 1) && deny_all == 1 )); then
    return 0
  fi
  return 1
}

site_doctor_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local strict="${PARSED_ARGS[strict]:-no}"
  local include_target="${PARSED_ARGS[include-target]:-yes}"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local sites=()
    mapfile -t sites < <(list_sites)
    if [[ ${#sites[@]} -eq 0 ]]; then
      error "No sites found to diagnose"
      return 1
    fi
    domain=$(select_from_list "Select domain to diagnose" "" "${sites[@]}")
  fi
  if [[ -z "$domain" ]]; then
    require_args "domain"
  fi
  if ! validate_domain "$domain" "allow"; then
    return 1
  fi
  if ! require_site_exists "$domain"; then
    return 1
  fi

  progress_init 10
  doctor_results_init

  progress_step "Reading site metadata"
  read_site_metadata "$domain"
  local profile="${SITE_META[profile]:-generic}"
  local project="${SITE_META[project]:-}"
  local root="${SITE_META[root]:-}"
  local php_version="${SITE_META[php]:-}"
  local socket_project="${SITE_META[php_socket_project]:-$project}"
  local ssl_flag="${SITE_META[ssl]:-off}"
  local target="${SITE_META[target]:-}"
  local simai_user="${SIMAI_USER:-simai}"
  local current_user
  current_user=$(id -un 2>/dev/null || echo "")
  local safe_project="$project"

  progress_step "Validating invariants"
  if ! validate_project_slug "$project"; then
    doctor_add_result "FAIL" "profile" "Project slug" "Invalid slug '${project}'" "Regenerate config with a safe slug derived from domain"
    safe_project=$(project_slug_from_domain "$domain")
    doctor_add_result "WARN" "profile" "Project slug fallback" "Using ${safe_project} for derived paths" "Regenerate site metadata to fix slug"
  else
    doctor_add_result "PASS" "profile" "Project slug" "${project}" ""
  fi
  if [[ -z "$socket_project" ]] || ! validate_project_slug "$socket_project"; then
    socket_project="$safe_project"
  fi
  if ! validate_path "$root"; then
    doctor_add_result "FAIL" "fs" "Project root" "Invalid path ${root}" "Fix path in nginx metadata and regenerate site"
  else
    doctor_add_result "PASS" "fs" "Project root" "${root}" ""
  fi

  progress_step "Loading profile ${profile}"
  if ! load_profile "$profile"; then
    doctor_add_result "FAIL" "profile" "Profile" "Failed to load profile ${profile}" "Ensure profiles/${profile}.profile.sh exists and is valid"
    doctor_print_report
    doctor_exit_code "$strict"
    return $?
  else
    doctor_add_result "PASS" "profile" "Profile" "${profile}" ""
  fi

  progress_step "Filesystem checks"
  if [[ ! -d "$root" ]]; then
    doctor_add_result "FAIL" "fs" "Root directory" "Missing ${root}" "Create directory or update site root"
  else
    doctor_add_result "PASS" "fs" "Root directory" "Present" ""
    if [[ "$root" != ${WWW_ROOT}/* ]]; then
      doctor_add_result "WARN" "fs" "Root location" "Root not under ${WWW_ROOT}" "Ensure permissions and backups cover custom root"
    fi
    local meta_public="${SITE_META[public_dir]:-}"
    local profile_public="${PROFILE_PUBLIC_DIR}"
    local effective_public="$profile_public"
    if [[ "${SITE_META[meta_version]:-}" == "2" ]]; then
      local meta_public="${SITE_META[public_dir]}"
      effective_public="$meta_public"
      if [[ "${PROFILE_IS_ALIAS:-no}" != "yes" && "$meta_public" != "$profile_public" ]]; then
        doctor_add_result "WARN" "fs" "Public dir mismatch" "Metadata='${meta_public}', profile='${profile_public}'" "Align metadata with profile or regenerate nginx config"
      fi
    fi
    local doc_root
    doc_root=$(site_compute_doc_root "$root" "$effective_public") || {
      doctor_add_result "FAIL" "fs" "Docroot" "Invalid docroot (${effective_public})" "Fix public_dir in metadata or profile"
      doctor_print_report
      doctor_exit_code "$strict"
      return $?
    }
    if [[ -d "$doc_root" ]]; then
      doctor_add_result "PASS" "fs" "Docroot" "${doc_root}" ""
    else
      doctor_add_result "FAIL" "fs" "Docroot" "Missing ${doc_root}" "Create ${doc_root} or update metadata"
    fi
    if [[ ${#PROFILE_REQUIRED_MARKERS[@]} -gt 0 ]]; then
      local missing=()
      local m
      for m in "${PROFILE_REQUIRED_MARKERS[@]}"; do
        [[ -z "$m" ]] && continue
        [[ -e "${root}/${m}" ]] || missing+=("$m")
      done
      if [[ ${#missing[@]} -gt 0 ]]; then
        doctor_add_result "FAIL" "fs" "Required markers" "Missing: ${missing[*]}" "Ensure project structure matches profile or use a different profile"
      else
        doctor_add_result "PASS" "fs" "Required markers" "All present" ""
      fi
    fi
    if [[ ${#PROFILE_BOOTSTRAP_FILES[@]} -gt 0 ]]; then
      local missing_boot=()
      local b
      for b in "${PROFILE_BOOTSTRAP_FILES[@]}"; do
        [[ -z "$b" ]] && continue
        [[ -e "${root}/${b}" ]] || missing_boot+=("$b")
      done
      if [[ ${#missing_boot[@]} -gt 0 ]]; then
        doctor_add_result "WARN" "fs" "Bootstrap files" "Missing: ${missing_boot[*]}" "Create placeholders or rerun site add without destructive flags"
      else
        doctor_add_result "PASS" "fs" "Bootstrap files" "Present" ""
      fi
    fi
    if [[ ${#PROFILE_WRITABLE_PATHS[@]} -gt 0 ]]; then
      local wp
      for wp in "${PROFILE_WRITABLE_PATHS[@]}"; do
        [[ -z "$wp" ]] && continue
        local full="${root}/${wp}"
        if [[ ! -e "$full" ]]; then
          doctor_add_result "FAIL" "fs" "Writable path" "Missing ${full}" "mkdir -p ${full} && chown -R ${SIMAI_USER}:www-data ${full}"
          continue
        fi
        local perm=""
        perm=$(stat -c "%a" "$full" 2>/dev/null || echo "")
        local writable_status=1
        if [[ "$current_user" == "$simai_user" ]]; then
          [[ -w "$full" ]] && writable_status=0
        elif runuser -u "${simai_user}" -- test -w "$full" 2>/dev/null; then
          writable_status=0
        fi
        if (( writable_status == 0 )); then
          doctor_add_result "PASS" "fs" "Writable path" "${full}" ""
        else
          doctor_add_result "FAIL" "fs" "Writable path" "Not writable by ${simai_user}: ${full}" "chown -R ${SIMAI_USER}:www-data ${full}; chmod u+w"
        fi
        if [[ -n "$perm" && "${perm: -1}" =~ [2367] ]]; then
          doctor_add_result "WARN" "fs" "World-writable" "${full} mode ${perm}" "chmod o-w ${full}"
        fi
      done
    fi
    if [[ -f "${root}/.env" ]]; then
      local mode
      mode=$(stat -c "%a" "${root}/.env" 2>/dev/null || echo "")
      if [[ "$mode" == "640" ]]; then
        doctor_add_result "PASS" "fs" ".env permissions" "640" ""
      else
        doctor_add_result "WARN" "fs" ".env permissions" "Mode ${mode}" "Set chmod 640 ${root}/.env"
      fi
    fi
  fi

  progress_step "Nginx checks"
  local avail="/etc/nginx/sites-available/${domain}.conf"
  local enabled="/etc/nginx/sites-enabled/${domain}.conf"
  [[ -f "$avail" ]] && doctor_add_result "PASS" "nginx" "Config exists" "$avail" || doctor_add_result "FAIL" "nginx" "Config missing" "$avail" "Regenerate with site add"
  if [[ -L "$enabled" ]]; then
    local target_link
    target_link=$(readlink "$enabled")
    if [[ "$target_link" == "$avail" ]]; then
      doctor_add_result "PASS" "nginx" "Enabled link" "$enabled -> $target_link" ""
    else
      doctor_add_result "WARN" "nginx" "Enabled link" "$enabled -> $target_link" "Point to $avail"
    fi
  else
    doctor_add_result "FAIL" "nginx" "Enabled link" "Missing symlink $enabled" "ln -sf $avail $enabled && nginx -t && systemctl reload nginx"
  fi
  if [[ -f /etc/nginx/sites-enabled/default ]]; then
    doctor_add_result "WARN" "nginx" "Default site" "default enabled" "Remove default to avoid conflicts"
  fi
  if [[ -f "$avail" ]]; then
    if [[ "${PROFILE_HEALTHCHECK_ENABLED:-no}" == "yes" ]]; then
      if [[ "${PROFILE_HEALTHCHECK_MODE:-php}" == "php" ]]; then
        doctor_nginx_location_is_local_only "$avail" "/healthcheck.php"
        local hc_rc=$?
        if [[ $hc_rc -eq 0 ]]; then
          doctor_add_result "PASS" "nginx" "Healthcheck location" "php mode (local-only)" ""
        elif [[ $hc_rc -eq 2 ]]; then
          doctor_add_result "WARN" "nginx" "Healthcheck location" "Missing /healthcheck.php location" "Ensure template includes php healthcheck location"
        else
          doctor_add_result "WARN" "nginx" "Healthcheck location" "Healthcheck location missing local-only allow/deny" "Allow 127.0.0.1/::1 and deny all in /healthcheck.php location"
        fi
        if [[ ! -f "${root}/${PROFILE_PUBLIC_DIR}/healthcheck.php" ]]; then
          doctor_add_result "WARN" "fs" "Healthcheck file" "Missing ${root}/${PROFILE_PUBLIC_DIR}/healthcheck.php" "Reinstall healthcheck via site add"
        fi
      else
        doctor_nginx_location_is_local_only "$avail" "/healthcheck"
        local hc_rc=$?
        if [[ $hc_rc -eq 0 ]]; then
          doctor_add_result "PASS" "nginx" "Healthcheck location" "nginx mode (local-only)" ""
        elif [[ $hc_rc -eq 2 ]]; then
          doctor_add_result "FAIL" "nginx" "Healthcheck location" "Missing /healthcheck location" "Ensure static template is applied"
        else
          doctor_add_result "FAIL" "nginx" "Healthcheck location" "Healthcheck location is not local-only" "Allow 127.0.0.1/::1 and deny all in /healthcheck location"
        fi
      fi
    else
      doctor_add_result "SKIP" "nginx" "Healthcheck" "Profile disables healthcheck" ""
    fi
  fi
  local ngout
  ngout=$(nginx -t 2>&1 || true)
  if echo "$ngout" | grep -q "test is successful"; then
    doctor_add_result "PASS" "nginx" "nginx -t" "OK" ""
  else
    doctor_add_result "FAIL" "nginx" "nginx -t" "Failed" "See /var/log/simai-admin.log and nginx -t output"
  fi

  progress_step "PHP checks"
  local php_bin="" pool_file=""
  if [[ "${PROFILE_REQUIRES_PHP}" == "no" ]]; then
    if [[ "$php_version" == "none" ]]; then
      doctor_add_result "PASS" "php" "PHP runtime" "Not required" ""
    else
      doctor_add_result "WARN" "php" "PHP runtime" "Profile says none, metadata has ${php_version}" "Update metadata/profile if PHP is actually needed"
    fi
  else
    if [[ ! -d "/etc/php/${php_version}" ]]; then
      doctor_add_result "FAIL" "php" "PHP version" "/etc/php/${php_version} missing" "Install php${php_version}"
    else
      doctor_add_result "PASS" "php" "PHP version" "${php_version}" ""
    fi
    php_bin=$(command -v "php${php_version}" || command -v php || true)
    if [[ -z "$php_bin" ]]; then
      doctor_add_result "WARN" "php" "PHP binary" "php${php_version} not found in PATH" "Install php${php_version}"
    else
      doctor_add_result "PASS" "php" "PHP binary" "$php_bin" ""
    fi
    if os_svc_is_active "php${php_version}-fpm"; then
      doctor_add_result "PASS" "php" "php-fpm service" "active" ""
    else
      doctor_add_result "WARN" "php" "php-fpm service" "inactive" "systemctl enable --now php${php_version}-fpm"
    fi
    pool_file="/etc/php/${php_version}/fpm/pool.d/${socket_project}.conf"
    if [[ -f "$pool_file" ]]; then
      doctor_add_result "PASS" "php" "Pool config" "$pool_file" ""
    else
      doctor_add_result "FAIL" "php" "Pool config" "Missing $pool_file" "Recreate pool with site set-php or site add"
    fi
    if [[ ! -S "/run/php/php${php_version}-fpm-${socket_project}.sock" ]]; then
      doctor_add_result "WARN" "php" "Socket" "Missing /run/php/php${php_version}-fpm-${socket_project}.sock" "Ensure php-fpm is running"
    else
      doctor_add_result "PASS" "php" "Socket" "Present" ""
    fi
    if [[ -n "$php_bin" ]]; then
      local mods
      mapfile -t mods < <(doctor_php_modules "$php_bin" || true)
      local missing_req=() missing_rec=()
      local ext
      for ext in "${PROFILE_PHP_EXTENSIONS_REQUIRED[@]}"; do
        [[ -z "$ext" ]] && continue
        if ! printf '%s\n' "${mods[@]}" | grep -qx "${ext,,}"; then
          missing_req+=("$ext")
        fi
      done
      for ext in "${PROFILE_PHP_EXTENSIONS_RECOMMENDED[@]}"; do
        [[ -z "$ext" ]] && continue
        if ! printf '%s\n' "${mods[@]}" | grep -qx "${ext,,}"; then
          missing_rec+=("$ext")
        fi
      done
      if [[ ${#missing_req[@]} -gt 0 ]]; then
        local hint=""
        local pkgs=()
        local m pkg
        for m in "${missing_req[@]}"; do
          pkg=$(doctor_ext_to_apt_pkg "$php_version" "$m")
          if [[ -n "$pkg" ]]; then
            pkgs+=("$pkg")
          fi
        done
        if [[ ${#pkgs[@]} -gt 0 ]]; then
          hint="apt install ${pkgs[*]}; simai-admin.sh php reload --php ${php_version}"
        fi
        doctor_add_result "FAIL" "php" "Required extensions" "Missing: ${missing_req[*]}" "${hint}"
      else
        doctor_add_result "PASS" "php" "Required extensions" "All present" ""
      fi
      if [[ ${#missing_rec[@]} -gt 0 ]]; then
        local hint=""
        local pkgs=()
        local m pkg
        for m in "${missing_rec[@]}"; do
          pkg=$(doctor_ext_to_apt_pkg "$php_version" "$m")
          if [[ -n "$pkg" ]]; then
            pkgs+=("$pkg")
          fi
        done
        if [[ ${#pkgs[@]} -gt 0 ]]; then
          hint="apt install ${pkgs[*]}; simai-admin.sh php reload --php ${php_version}"
        fi
        doctor_add_result "WARN" "php" "Recommended extensions" "Missing: ${missing_rec[*]}" "${hint}"
      else
        doctor_add_result "PASS" "php" "Recommended extensions" "All present" ""
      fi

      # PHP ini expectations
      local ini_entry parsed key expected actual cmp
      for ini_entry in "${PROFILE_PHP_INI_REQUIRED[@]}"; do
        [[ -z "$ini_entry" ]] && continue
        parsed=$(doctor_parse_ini_expectation "$ini_entry" || true)
        if [[ -z "$parsed" ]]; then
          doctor_add_result "WARN" "php" "INI required" "Invalid format: ${ini_entry}" "Use key=value"
          continue
        fi
        key="${parsed%%|*}"; expected="${parsed#*|}"
        actual=$(doctor_php_ini_get "$php_bin" "$key" || true)
        cmp=$(doctor_compare_ini "$key" "$expected" "$actual")
        if [[ "$cmp" == "ok" ]]; then
          doctor_add_result "PASS" "php" "INI required" "${key}=${actual}" ""
        elif [[ "$cmp" == "unknown" ]]; then
          doctor_add_result "WARN" "php" "INI required" "${key} unable to compare" "Check php.ini/pool"
        else
          doctor_add_result "FAIL" "php" "INI required" "${key}=${actual:-<empty>} (expected ${expected})" "Set in php-fpm ini/pool and reload"
        fi
      done
      for ini_entry in "${PROFILE_PHP_INI_RECOMMENDED[@]}"; do
        [[ -z "$ini_entry" ]] && continue
        parsed=$(doctor_parse_ini_expectation "$ini_entry" || true)
        [[ -z "$parsed" ]] && continue
        key="${parsed%%|*}"; expected="${parsed#*|}"
        actual=$(doctor_php_ini_get "$php_bin" "$key" || true)
        cmp=$(doctor_compare_ini "$key" "$expected" "$actual")
        if [[ "$cmp" == "ok" ]]; then
          doctor_add_result "PASS" "php" "INI recommended" "${key}=${actual}" ""
        elif [[ "$cmp" == "unknown" ]]; then
          doctor_add_result "WARN" "php" "INI recommended" "${key} unable to compare" "Check php.ini/pool"
        else
          doctor_add_result "WARN" "php" "INI recommended" "${key}=${actual:-<empty>} (expected ${expected})" "Adjust in php-fpm ini/pool if needed"
        fi
      done
      for ini_entry in "${PROFILE_PHP_INI_FORBIDDEN[@]}"; do
        [[ -z "$ini_entry" ]] && continue
        parsed=$(doctor_parse_ini_expectation "$ini_entry" || true)
        if [[ -z "$parsed" ]]; then
          doctor_add_result "WARN" "php" "INI forbidden" "Invalid format: ${ini_entry}" "Use key=value"
          continue
        fi
        key="${parsed%%|*}"; expected="${parsed#*|}"
        actual=$(doctor_php_ini_get "$php_bin" "$key" || true)
        cmp=$(doctor_ini_equals "$expected" "$actual")
        if [[ "$cmp" == "yes" ]]; then
          doctor_add_result "FAIL" "php" "INI forbidden" "${key}=${actual:-<empty>} is forbidden" "Set to a safe value in pool/php.ini and reload"
        elif [[ "$cmp" == "no" ]]; then
          doctor_add_result "PASS" "php" "INI forbidden" "${key}=${actual}" ""
        else
          doctor_add_result "WARN" "php" "INI forbidden" "${key} cannot be evaluated" ""
        fi
      done
    fi
  fi

  progress_step "Cron checks"
  if [[ "${PROFILE_SUPPORTS_CRON:-no}" == "yes" ]]; then
    local cron_file="/etc/cron.d/${safe_project}"
    if [[ -f "$cron_file" ]]; then
      if grep -q "schedule:run" "$cron_file"; then
        doctor_add_result "PASS" "cron" "Cron file" "$cron_file" ""
      else
        doctor_add_result "WARN" "cron" "Cron file" "Missing schedule:run entry" "Recreate cron via site add"
      fi
    else
      doctor_add_result "FAIL" "cron" "Cron file" "Missing ${cron_file}" "Ensure cron is created for profile ${profile}"
    fi
  else
    doctor_add_result "SKIP" "cron" "Cron" "Not required by profile" ""
  fi

  progress_step "SSL checks"
  if [[ "${ssl_flag}" == "on" ]]; then
    local le_dir="/etc/letsencrypt/live/${domain}"
    if [[ -f "${le_dir}/fullchain.pem" && -f "${le_dir}/privkey.pem" ]]; then
      doctor_add_result "PASS" "ssl" "Certificates" "LetsEncrypt files present" ""
    else
      doctor_add_result "WARN" "ssl" "Certificates" "Expected cert files missing under ${le_dir}" "Re-run ssl letsencrypt or install custom certs"
    fi
  else
    doctor_add_result "SKIP" "ssl" "SSL" "Disabled in metadata" ""
  fi

progress_step "DB checks"
if [[ "${PROFILE_REQUIRES_DB}" != "no" ]]; then
  if os_svc_is_active mysql || os_svc_is_active mariadb || os_svc_is_active percona || os_svc_is_active mysqld; then
    doctor_add_result "PASS" "db" "MySQL service" "Active" ""
  else
    doctor_add_result "WARN" "db" "MySQL service" "Inactive" "Install/enable MySQL or Percona"
  fi
  local db_env_file
  db_env_file="$(site_db_env_file "$domain")"
  if [[ -f "$db_env_file" ]]; then
    doctor_add_result "PASS" "db" "db.env" "Present at ${db_env_file}" ""
  else
    doctor_add_result "WARN" "db" "db.env" "Missing db.env" "Create via: simai-admin.sh site db-create --domain ${domain} --confirm yes"
  fi
  if [[ "${PROFILE_REQUIRES_DB}" == "required" ]]; then
    if [[ -f "${root}/.env" ]]; then
      doctor_add_result "PASS" "db" ".env presence" ".env exists" ""
    else
      doctor_add_result "WARN" "db" ".env presence" "Missing ${root}/.env" "Export credentials: simai-admin.sh site db-export --domain ${domain} --confirm yes"
    fi
    if [[ ! -f "$db_env_file" ]]; then
      doctor_add_result "WARN" "db" "db.env required" "db.env missing for required DB profile" "Create via: simai-admin.sh site db-create --domain ${domain} --confirm yes"
    fi
  fi
else
  doctor_add_result "SKIP" "db" "Database" "Not required by profile" ""
fi

  progress_step "Alias/target checks"
  if [[ "$profile" == "alias" ]]; then
    if [[ -z "$target" ]]; then
      doctor_add_result "FAIL" "profile" "Alias target" "Missing simai-target in metadata" "Recreate alias with a target site"
    else
      doctor_add_result "PASS" "profile" "Alias target" "$target" ""
      local target_ready=1
      if ! require_site_exists "$target"; then
        doctor_add_result "FAIL" "nginx" "target: Config" "sites-available/${target}.conf missing" "Create target site first"
        target_ready=0
      fi
      if [[ "${include_target,,}" == "yes" && $target_ready -eq 1 ]]; then
        read_site_metadata "$target"
        local target_profile="${SITE_META[profile]:-}"
        local target_project="${SITE_META[project]:-}"
        local target_root="${SITE_META[root]:-}"
        local target_php_version="${SITE_META[php]:-}"
        local target_socket_project="${SITE_META[php_socket_project]:-$target_project}"
        if [[ "$target_profile" == "alias" ]]; then
          doctor_add_result "WARN" "profile" "target: Profile" "Target is alias; skipping deep check" ""
        else
          if ! validate_project_slug "$target_project"; then
            doctor_add_result "FAIL" "profile" "target: Project slug" "Invalid slug '${target_project}'" "Regenerate config with a safe slug derived from domain"
          else
            doctor_add_result "PASS" "profile" "target: Project slug" "${target_project}" ""
          fi
          local target_path_ok=1
          if ! validate_path "$target_root"; then
            doctor_add_result "FAIL" "fs" "target: Project root" "Invalid path ${target_root}" "Fix path in nginx metadata and regenerate site"
            target_path_ok=0
          else
            doctor_add_result "PASS" "fs" "target: Project root" "${target_root}" ""
          fi
          local target_profile_loaded=0
          if ! load_profile "$target_profile"; then
            doctor_add_result "FAIL" "profile" "target: Profile" "Failed to load profile ${target_profile}" "Ensure profiles/${target_profile}.profile.sh exists and is valid"
          else
            doctor_add_result "PASS" "profile" "target: Profile" "${target_profile}" ""
            target_profile_loaded=1
          fi
          if [[ $target_profile_loaded -eq 1 && $target_path_ok -eq 1 ]]; then
            local target_root_exists="yes"
            if [[ ! -d "$target_root" ]]; then
              target_root_exists="no"
              doctor_add_result "FAIL" "fs" "target: Root directory" "Missing ${target_root}" "Create directory or update site root"
            else
              doctor_add_result "PASS" "fs" "target: Root directory" "Present" ""
              local target_pub="${target_root}/${PROFILE_PUBLIC_DIR}"
              if [[ -d "$target_pub" ]]; then
                doctor_add_result "PASS" "fs" "target: Public dir" "${target_pub}" ""
              else
                doctor_add_result "FAIL" "fs" "target: Public dir" "Missing ${target_pub}" "Create ${target_pub}"
              fi
              if [[ ${#PROFILE_REQUIRED_MARKERS[@]} -gt 0 ]]; then
                local target_missing=()
                local tm
                for tm in "${PROFILE_REQUIRED_MARKERS[@]}"; do
                  [[ -z "$tm" ]] && continue
                  [[ -e "${target_root}/${tm}" ]] || target_missing+=("$tm")
                done
                if [[ ${#target_missing[@]} -gt 0 ]]; then
                  doctor_add_result "FAIL" "fs" "target: Required markers" "Missing: ${target_missing[*]}" "Ensure project structure matches profile or use a different profile"
                else
                  doctor_add_result "PASS" "fs" "target: Required markers" "All present" ""
                fi
              fi
            fi
            local target_avail="/etc/nginx/sites-available/${target}.conf"
            if [[ -f "$target_avail" ]]; then
              if [[ "${PROFILE_HEALTHCHECK_ENABLED:-no}" == "yes" ]]; then
                if [[ "${PROFILE_HEALTHCHECK_MODE:-php}" == "php" ]]; then
                  doctor_nginx_location_is_local_only "$target_avail" "/healthcheck.php"
                  local target_hc_rc=$?
                  if [[ $target_hc_rc -eq 0 ]]; then
                    doctor_add_result "PASS" "nginx" "target: Healthcheck location" "php mode (local-only)" ""
                  elif [[ $target_hc_rc -eq 2 ]]; then
                    doctor_add_result "WARN" "nginx" "target: Healthcheck location" "Missing /healthcheck.php location" "Ensure template includes php healthcheck location"
                  else
                    doctor_add_result "WARN" "nginx" "target: Healthcheck location" "Healthcheck location missing local-only allow/deny" "Allow 127.0.0.1/::1 and deny all in /healthcheck.php location"
                  fi
                  if [[ "$target_root_exists" == "yes" && ! -f "${target_root}/${PROFILE_PUBLIC_DIR}/healthcheck.php" ]]; then
                    doctor_add_result "WARN" "fs" "target: Healthcheck file" "Missing ${target_root}/${PROFILE_PUBLIC_DIR}/healthcheck.php" "Reinstall healthcheck via site add"
                  fi
                else
                  doctor_nginx_location_is_local_only "$target_avail" "/healthcheck"
                  local target_hc_rc=$?
                  if [[ $target_hc_rc -eq 0 ]]; then
                    doctor_add_result "PASS" "nginx" "target: Healthcheck location" "nginx mode (local-only)" ""
                  elif [[ $target_hc_rc -eq 2 ]]; then
                    doctor_add_result "FAIL" "nginx" "target: Healthcheck location" "Missing /healthcheck location" "Ensure static template is applied"
                  else
                    doctor_add_result "FAIL" "nginx" "target: Healthcheck location" "Healthcheck location is not local-only" "Allow 127.0.0.1/::1 and deny all in /healthcheck location"
                  fi
                fi
              else
                doctor_add_result "SKIP" "nginx" "target: Healthcheck" "Profile disables healthcheck" ""
              fi
            else
              doctor_add_result "FAIL" "nginx" "target: Config exists" "/etc/nginx/sites-available/${target}.conf missing" "Create target site first"
            fi
            if echo "$ngout" | grep -q "test is successful"; then
              doctor_add_result "PASS" "nginx" "target: nginx -t" "OK" ""
            else
              doctor_add_result "FAIL" "nginx" "target: nginx -t" "Failed" "See /var/log/simai-admin.log and nginx -t output"
            fi
            if [[ "${PROFILE_REQUIRES_PHP}" == "no" ]]; then
              doctor_add_result "SKIP" "php" "target: PHP runtime" "Not required by profile" ""
            else
              if [[ -z "$target_php_version" ]]; then
                doctor_add_result "WARN" "php" "target: PHP version" "Missing in metadata" "Set php version in metadata"
              elif [[ ! -d "/etc/php/${target_php_version}" ]]; then
                doctor_add_result "FAIL" "php" "target: PHP version" "/etc/php/${target_php_version} missing" "Install php${target_php_version}"
              else
                doctor_add_result "PASS" "php" "target: PHP version" "${target_php_version}" ""
              fi
              if [[ -n "$target_php_version" ]]; then
                if os_svc_is_active "php${target_php_version}-fpm"; then
                  doctor_add_result "PASS" "php" "target: php-fpm service" "active" ""
                else
                  doctor_add_result "WARN" "php" "target: php-fpm service" "inactive" "systemctl enable --now php${target_php_version}-fpm"
                fi
                local target_pool_file="/etc/php/${target_php_version}/fpm/pool.d/${target_socket_project}.conf"
                if [[ -f "$target_pool_file" ]]; then
                  doctor_add_result "PASS" "php" "target: Pool config" "$target_pool_file" ""
                else
                  doctor_add_result "FAIL" "php" "target: Pool config" "Missing $target_pool_file" "Recreate pool with site set-php or site add"
                fi
                if [[ ! -S "/run/php/php${target_php_version}-fpm-${target_socket_project}.sock" ]]; then
                  doctor_add_result "WARN" "php" "target: Socket" "Missing /run/php/php${target_php_version}-fpm-${target_socket_project}.sock" "Ensure php-fpm is running"
                else
                  doctor_add_result "PASS" "php" "target: Socket" "Present" ""
                fi
              fi
            fi
          fi
        fi
      fi
    fi
  fi

  doctor_print_report
  doctor_exit_code "$strict"
  return $?
}

register_cmd "site" "doctor" "Diagnose site against its profile contract (read-only)" "site_doctor_handler" "" "domain= strict=no include-target=yes"
