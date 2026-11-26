#!/usr/bin/env bash

site_db_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain" || return 1
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  local db_name="" db_user="" db_charset="" db_collation=""
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
        DB_CHARSET) db_charset="$v" ;;
        DB_COLLATION) db_collation="$v" ;;
      esac
    done <<<"$read_env"
  fi
  echo "Site: ${domain}"
  if [[ -z "$db_name" ]]; then
    echo "db.env    : not present"
  else
    echo "db.env    : present"
    echo "DB_NAME   : ${db_name}"
    echo "DB_USER   : ${db_user}"
    echo "DB_ENGINE : $(site_db_engine "$domain")"
    local extra_names
    extra_names=$(site_db_extra_names "$domain" | sed "s/^/${db_name}_/" | paste -sd, - || true)
    [[ -z "$extra_names" ]] || echo "DB_EXTRA  : ${extra_names//,/, }"
    if [[ "$(site_db_engine "$domain")" == mysql ]]; then
      echo "DB_HOST   : localhost"
      echo "DB_CHARSET: ${db_charset:-utf8mb4}"
      echo "DB_COLL   : ${db_collation:-utf8mb4_unicode_ci}"
    fi
  fi
  if [[ -n "$db_name" && "$(site_db_engine "$domain")" == pgsql ]]; then
    pgsql_require || return 1
    pgsql_db_exists "$db_name" && echo "Database  : exists" || echo "Database  : missing"
    if [[ -n "$db_user" ]]; then
      pgsql_role_exists "$db_user" && echo "Role      : exists" || echo "Role      : missing"
      [[ "$(pgsql_query "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = $(pgsql_literal "$db_name")")" == "$db_user" ]] \
        && echo "Owner     : ${db_user}" || echo "Owner     : not ${db_user}"
    fi
    return 0
  fi
  if [[ -n "$db_name" ]]; then
    if db_exists "$db_name"; then
      echo "Database  : exists"
    else
      echo "Database  : missing"
    fi
  fi
  if [[ -n "$db_user" ]]; then
    if db_user_exists "$db_user"; then
      echo "User      : exists"
      if [[ -n "$db_name" ]]; then
        if db_user_has_grant_on "$db_user" "$db_name"; then
          echo "Grants    : present on ${db_name}"
        else
          echo "Grants    : missing on ${db_name}"
        fi
      fi
    else
      echo "User      : missing"
    fi
  fi
}

site_db_create_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain" || return 1
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain"
  local project="${SITE_META[project]:-$(project_slug_from_domain "$domain")}"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not require DB; creation blocked."
    return 1
  fi

  local charset="${PROFILE_DB_CHARSET:-utf8mb4}"
  local coll="${PROFILE_DB_COLLATION:-utf8mb4_unicode_ci}"
  site_db_load_or_generate_creds "$domain" "$project" "$charset" "$coll" || return 1
  local db_exists_before="no"
  local user_exists_before="no"
  local grants_before="no"
  if db_exists "$DB_CREDS_NAME"; then
    db_exists_before="yes"
  fi
  if db_user_exists "$DB_CREDS_USER"; then
    user_exists_before="yes"
  fi
  if [[ "$db_exists_before" == "yes" && "$user_exists_before" == "yes" ]] && db_user_has_grant_on "$DB_CREDS_USER" "$DB_CREDS_NAME"; then
    grants_before="yes"
  fi

  local privs=()
  if [[ -n "${PROFILE_DB_REQUIRED_PRIVILEGES+x}" && ${#PROFILE_DB_REQUIRED_PRIVILEGES[@]} -gt 0 ]]; then
    privs=("${PROFILE_DB_REQUIRED_PRIVILEGES[@]}")
  else
    mapfile -t privs < <(db_default_privileges)
  fi
  local priv_str
  priv_str=$(printf "%s, " "${privs[@]}")
  priv_str="${priv_str%, }"

  echo "Plan for ${domain}:"
  echo "- DB name : ${DB_CREDS_NAME}"
  echo "- DB user : ${DB_CREDS_USER}@localhost"
  echo "- Charset : ${DB_CREDS_CHARSET}"
  echo "- Collation: ${DB_CREDS_COLLATION}"
  echo "- Privileges: ${priv_str}"
  echo "- Existing DB: ${db_exists_before}"
  echo "- Existing user: ${user_exists_before}"
  echo "- Existing grants: ${grants_before}"
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to create database resources."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with DB/user creation?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || {
      command_cancelled
      return $?
    }
  fi

  if ! site_db_apply_create "$domain" "$DB_CREDS_NAME" "$DB_CREDS_USER" "$DB_CREDS_PASS" "$DB_CREDS_CHARSET" "$DB_CREDS_COLLATION" "${privs[@]}"; then
    return 1
  fi

  echo "Database prepared for ${domain}"
  echo "DB_NAME=${DB_CREDS_NAME}"
  echo "DB_USER=${DB_CREDS_USER}"
  echo "DB_HOST=localhost"
  echo "DB_PASS=created (hidden)"
  echo "DB already existed : ${db_exists_before}"
  echo "User already existed: ${user_exists_before}"
  echo "Grants existed     : ${grants_before}"
  return 0
}

site_db_drop_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  local remove_files="${PARSED_ARGS[remove_files]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"
  [[ "${remove_files,,}" == "yes" ]] && remove_files="yes" || remove_files="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain" || return 1
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not use DB; drop blocked."
    return 1
  fi
  if [[ "${PROFILE_ALLOW_DB_REMOVAL:-no}" != "yes" ]]; then
    error "Profile ${SITE_META[profile]:-} does not allow DB removal (PROFILE_ALLOW_DB_REMOVAL!=yes)."
    return 1
  fi

  local db_name="" db_user=""
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
      esac
    done <<<"$read_env"
  fi
  if [[ -z "$db_name" || -z "$db_user" ]]; then
    error "db.env not found or incomplete for ${domain}; cannot drop."
    return 1
  fi
  if ! db_validate_db_name "$db_name"; then return 1; fi
  if ! db_validate_db_user "$db_user"; then return 1; fi

  echo "Plan to drop DB resources for ${domain}:"
  echo "- Drop database: ${db_name}"
  echo "- Drop user    : ${db_user}@localhost"
  [[ "$remove_files" == "yes" ]] && echo "- Remove db.env file"
  # The last backup of the database first (1.64.0); --last-backup no
  # (console only) skips it.
  local last_backup="${PARSED_ARGS[last-backup]:-yes}"
  if [[ "$last_backup" != no ]]; then
    echo "- First: last backup of the database, kept ${BACKUP_HOLD_DAYS:-7} days (backup data-list, backup data-restore)"
  fi
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to drop database resources."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with drop?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || {
      command_cancelled
      return $?
    }
  fi

  if [[ "$last_backup" != no ]]; then
    backup_data_last "$domain" db-drop yes no || return 1
  fi
  if ! site_db_apply_drop "$domain" "$db_name" "$db_user" "$remove_files"; then
    return 1
  fi
  echo "Database resources dropped for ${domain}"
}

site_db_run_as() {
  local user="$1" dir="$2"
  shift 2
  sudo -u "$user" -H bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

# A Laravel config cache keeps the old password: rebuild it, then let workers
# reconnect.
site_db_rotate_reload_app() {
  local domain="$1" root="$2" app user php_bin
  app="$root"
  [[ -L "${root}/current" ]] && app="${root}/current"
  [[ -f "${app}/artisan" ]] || return 0
  user=$(site_effective_user "${SITE_META[project]:-$(project_slug_from_domain "$domain")}")
  php_bin=$(resolve_php_bin "${SITE_META[php]:-}")
  [[ -n "$user" && -n "$php_bin" ]] || return 0
  if [[ -f "${app}/bootstrap/cache/config.php" ]]; then
    site_db_run_as "$user" "$app" "$php_bin" artisan config:cache >>"$LOG_FILE" 2>&1 \
      || warn "config:cache failed; run it as ${user} to use the new password"
  fi
  site_db_run_as "$user" "$app" "$php_bin" artisan queue:restart >>"$LOG_FILE" 2>&1 || true
}

# The PHP files that hold a Bitrix or WordPress site's database password,
# as "kind|path" (lib/db_config_password.py kinds); dbconn.php only when it
# sets $DBPassword.
site_db_rotate_config_files() {
  local domain="$1" root doc_root f public_dir="public"
  ROTATE_CONFIG_FILES=()
  root="${SITE_META[root]:-}"
  # An empty public_dir means the site root itself.
  [[ -z "${SITE_META[public_dir]+x}" ]] || public_dir="${SITE_META[public_dir]}"
  doc_root=$(site_compute_doc_root "$root" "$public_dir") || return 1
  case "${SITE_META[profile]:-}" in
    wordpress)
      for f in "${doc_root}/wp-config.php" "$(dirname "$doc_root")/wp-config.php"; do
        [[ -f "$f" && ! -L "$f" ]] && { ROTATE_CONFIG_FILES+=("wp|${f}"); break; }
      done
      ;;
    bitrix)
      f="${doc_root}/bitrix/.settings.php"
      [[ -f "$f" && ! -L "$f" ]] && ROTATE_CONFIG_FILES+=("bitrix-settings|${f}")
      f="${doc_root}/bitrix/php_interface/dbconn.php"
      [[ -f "$f" && ! -L "$f" ]] && grep -q 'DBPassword' "$f" && ROTATE_CONFIG_FILES+=("bitrix-dbconn|${f}")
      ;;
  esac
  if (( ${#ROTATE_CONFIG_FILES[@]} == 0 )); then
    error "${domain} has no ${SITE_META[profile]} configuration with a database password yet; nothing to rotate"
    return 1
  fi
}

# Runs lib/db_config_password.py as the file's owner; passwords on stdin.
site_db_rotate_config_run() {
  local mode="$1" kind="$2" file="$3" old="$4" new="$5" owner
  owner=$(stat -c %U "$file") || return 2
  (cd / && printf '%s\n%s\n' "$old" "$new" | sudo -n -u "$owner" python3 -I -c "$(cat "${SIMAI_ENV_ROOT}/lib/db_config_password.py")" \
    "$mode" "$kind" "$file")
}

site_db_rotate_config_check() {
  local old="$1" item rc
  for item in "${ROTATE_CONFIG_FILES[@]}"; do
    rc=0
    site_db_rotate_config_run check "${item%%|*}" "${item#*|}" "$old" "Check0000check" || rc=$?
    case "$rc" in
      0) ;;
      4) error "${item#*|} uses another database password than the site's db.env; rotation blocked"; return 1 ;;
      3) error "${item#*|} has no database password setting; rotation blocked"; return 1 ;;
      *) error "Cannot read ${item#*|}; rotation blocked"; return 1 ;;
    esac
  done
}

# Rewrites every file; on a failure the files already rewritten go back.
site_db_rotate_config_apply() {
  local old="$1" new="$2" item done_items=()
  for item in "${ROTATE_CONFIG_FILES[@]}"; do
    if ! site_db_rotate_config_run apply "${item%%|*}" "${item#*|}" "$old" "$new"; then
      local back
      for back in "${done_items[@]}"; do
        site_db_rotate_config_run apply "${back%%|*}" "${back#*|}" "$new" "$old" || true
      done
      return 1
    fi
    done_items+=("$item")
  done
}

site_db_rotate_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dry_run="${PARSED_ARGS[dry_run]:-no}"
  local confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${dry_run,,}" == "yes" ]] && dry_run="yes" || dry_run="no"
  [[ "${confirm,,}" == "yes" ]] && confirm="yes" || confirm="no"

  if [[ -z "$domain" && "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    mapfile -t _sites < <(list_sites)
    if [[ ${#_sites[@]} -eq 0 ]]; then
      warn "No sites found"
      return 0
    fi
    domain=$(select_from_list "Select site" "" "${_sites[@]}")
    if [[ -z "$domain" ]]; then
      command_cancelled
      return $?
    fi
    PARSED_ARGS[domain]="$domain"
  fi
  require_args "domain" || return 1
  if ! validate_domain "$domain" "allow"; then return 1; fi
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain"
  if ! load_profile "${SITE_META[profile]:-}"; then
    return 1
  fi
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    error "Profile ${SITE_META[profile]:-} does not use DB; rotation blocked."
    return 1
  fi
  local db_name="" db_user="" db_pass="" db_charset="utf8mb4" db_coll="utf8mb4_unicode_ci"
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) db_name="$v" ;;
        DB_USER) db_user="$v" ;;
        DB_PASS) db_pass="$v" ;;
        DB_CHARSET) db_charset="$v" ;;
        DB_COLLATION) db_coll="$v" ;;
      esac
    done <<<"$read_env"
  fi
  # Bitrix and WordPress keep the password in PHP files: they are checked
  # before anything changes and rewritten right after the database (1.59.0).
  local config_profile=no
  case "${SITE_META[profile]:-}" in
    bitrix|wordpress)
      config_profile=yes
      site_db_rotate_config_files "$domain" || return 1
      site_db_rotate_config_check "$db_pass" || return 1
      ;;
  esac
  if [[ -z "$db_name" || -z "$db_user" ]]; then
    error "db.env not found or incomplete for ${domain}; cannot rotate."
    return 1
  fi
  if ! db_validate_db_name "$db_name"; then return 1; fi
  if ! db_validate_db_user "$db_user"; then return 1; fi

  echo "Plan to rotate password for ${db_user}@localhost on ${db_name}"
  if [[ "$config_profile" == yes ]]; then
    local f
    for f in "${ROTATE_CONFIG_FILES[@]}"; do echo "- update the password in ${f#*|}"; done
  fi
  if [[ "$dry_run" == "yes" ]]; then
    echo "Dry-run only; no changes made."
    return 0
  fi

  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" && "$confirm" != "yes" ]]; then
    error "Use --confirm yes to rotate password."
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    local choice
    choice=$(select_from_list "Proceed with password rotation?" "no" "no" "yes")
    [[ "$choice" == "yes" ]] || {
      command_cancelled
      return $?
    }
  fi

  local new_pass
  new_pass=$(generate_password)
  if ! site_db_apply_rotate "$domain" "$db_name" "$db_user" "$new_pass" "$db_charset" "$db_coll"; then
    return 1
  fi
  if [[ "$config_profile" == yes ]]; then
    if ! site_db_rotate_config_apply "$db_pass" "$new_pass"; then
      # The site must keep working: the old password goes back.
      site_db_apply_rotate "$domain" "$db_name" "$db_user" "$db_pass" "$db_charset" "$db_coll" \
        || error "Could not restore the old password of ${db_user}; set it in the site configuration now"
      error "The site configuration could not be updated; the old password was restored"
      return 1
    fi
  fi
  echo "Password rotated for ${db_user}"
  echo "DB_NAME=${db_name}"
  echo "DB_USER=${db_user}"
  echo "DB_HOST=localhost"
  echo "DB_PASS=updated (hidden)"
  if [[ "$config_profile" == yes ]]; then
    for f in "${ROTATE_CONFIG_FILES[@]}"; do echo "Updated: ${f#*|}"; done
    return 0
  fi
  read_site_metadata "$domain" || return 1
  local project_root="${SITE_META[root]:-}"
  if [[ -z "$project_root" || ! -d "$project_root" ]]; then
    warn "Project root not found; update the application DB password manually."
    return 0
  fi
  local export_choice="yes"
  if [[ "${SIMAI_ADMIN_MENU:-0}" == "1" ]]; then
    export_choice=$(select_from_list "Update project .env with the new password?" "yes" "yes" "no")
  fi
  if [[ "$export_choice" == "yes" ]]; then
    local env_owner=""
    [[ -f "${project_root}/.env" ]] && env_owner=$(stat -c '%U:%G %a' "${project_root}/.env")
    if site_db_export_to_env "$domain" "$project_root" ".env"; then
      # Keep the owner the application reads .env as.
      if [[ -n "$env_owner" ]]; then
        chown "${env_owner% *}" "${project_root}/.env" && chmod "${env_owner##* }" "${project_root}/.env"
      fi
      echo "Project .env updated: ${project_root}/.env"
      site_db_rotate_reload_app "$domain" "$project_root"
    else
      error "Password rotated, but failed to update ${project_root}/.env; the application cannot connect until it is updated."
      return 1
    fi
  fi
}

# Refusals the plan can name: a Bitrix or WordPress configuration that does
# not hold the db.env password (command_plan_check).
# The plan already sees a site whose profile has no database (a static or a
# redirect site): the gateway answers it as the refusal profile_no_database.
site_db_create_plan_check() {
  local domain
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  load_profile "${SITE_META[profile]:-}" || return 1
  [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]] || return 0
  error "Profile ${SITE_META[profile]:-} does not require DB; creation blocked."
  site_plan_data_write "$(python3 -I -c 'import json,sys; print(json.dumps({"refusal": "profile_no_database", "detail": sys.argv[1]}))' \
    "Sites of profile ${SITE_META[profile]:-} have no database")"
  return 1
}

site_db_rotate_plan_check() {
  local domain entry pass=""
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || return 1
  case "${SITE_META[profile]:-}" in bitrix|wordpress) ;; *) return 0 ;; esac
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == DB_PASS ]] && pass="${entry#*|}"
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  [[ -n "$pass" ]] || { error "${domain} has no database of its own"; return 1; }
  site_db_rotate_config_files "$domain" || return 1
  site_db_rotate_config_check "$pass"
}

# Connection details of a site's database (1.59.0). Through the panel the
# password is in the job result only, handed out once; the job log and the
# audit log never carry it.
site_db_credentials_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" entry engine name="" user="" pass="" host="" port=""
  require_args "domain" || return 1
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || return 1
  while IFS= read -r entry; do
    case "${entry%%|*}" in
      DB_NAME) name="${entry#*|}" ;;
      DB_USER) user="${entry#*|}" ;;
      DB_PASS) pass="${entry#*|}" ;;
      DB_HOST) host="${entry#*|}" ;;
      DB_PORT) port="${entry#*|}" ;;
    esac
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  if [[ -z "$name" || -z "$user" || -z "$pass" ]]; then
    error "${domain} has no database of its own (site db-create --domain ${domain} creates one)"
    return 1
  fi
  engine=$(site_db_engine "$domain")
  [[ -n "$host" ]] || host=localhost
  [[ -n "$port" ]] || port=$(db_engine_default_port "$engine")
  # Extra databases (1.70.0) use the same user and password.
  local extra="" n
  while IFS= read -r n; do
    [[ -n "$n" ]] && extra+="${extra:+,}${name}_${n}"
  done < <(site_db_extra_names "$domain")
  info "Database credentials of ${domain} handed out (${SUDO_USER:-${USER:-root}}${SIMAI_JOB_RESULT:+, panel job})"
  if [[ -n "${SIMAI_JOB_RESULT:-}" ]]; then
    python3 -I -c 'import json, sys
keys = ("engine", "host", "port", "database", "user", "db_password")
out = dict(zip(keys, sys.stdin.read().split("\n")[:6]))
out["extra_databases"] = [x for x in sys.argv[1].split(",") if x]
print(json.dumps(out))' "$extra" <<<"$(printf '%s\n%s\n%s\n%s\n%s\n%s' "$engine" "$host" "$port" "$name" "$user" "$pass")" >"$SIMAI_JOB_RESULT"
    ui_result_table "Domain|${domain}" "Database|${name} (${engine})" ${extra:+"Extra databases|${extra//,/, } (same user and password)"} "User|${user}" "Password|(handed to the panel once)"
    return 0
  fi
  ui_header "SIMAI ENV · Database credentials"
  ui_result_table "Domain|${domain}" "Engine|${engine}" "Host|${host}" "Port|${port}" "Database|${name}" \
    ${extra:+"Extra databases|${extra//,/, } (same user and password)"} "User|${user}" "Password|${pass}"
  echo "Keep the password secret. Change it with: simai-admin.sh site db-rotate --domain ${domain} --confirm yes"
}

# Extra databases of a site (1.70.0): <main database>_<name> on the site's
# engine, for the site's own database user. Checks shared by the handlers
# and their plans (command_plan_check); they set XDB_* and, on refusal,
# XDB_REFUSAL (profile_no_database, no_database, name_invalid, name_too_long,
# name_taken, database_exists, name_unknown).
site_db_extra_context() {
  local domain="$1" action="$2" name="$3" entry
  XDB_REFUSAL="" XDB_MAIN="" XDB_USER="" XDB_CHARSET="utf8mb4" XDB_COLLATION="utf8mb4_unicode_ci" XDB_FULL=""
  validate_domain "$domain" allow || return 1
  require_site_exists "$domain" || { XDB_REFUSAL=site_missing; return 1; }
  read_site_metadata "$domain" || return 1
  load_profile "${SITE_META[profile]:-}" >/dev/null 2>&1 || true
  if [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]]; then
    XDB_REFUSAL=profile_no_database
    error "Profile ${SITE_META[profile]:-} has no database; extra databases are not available"
    return 1
  fi
  while IFS= read -r entry; do
    case "${entry%%|*}" in
      DB_NAME) XDB_MAIN="${entry#*|}" ;;
      DB_USER) XDB_USER="${entry#*|}" ;;
      DB_CHARSET) [[ -n "${entry#*|}" ]] && XDB_CHARSET="${entry#*|}" ;;
      DB_COLLATION) [[ -n "${entry#*|}" ]] && XDB_COLLATION="${entry#*|}" ;;
    esac
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  if [[ -z "$XDB_MAIN" || -z "$XDB_USER" ]] || ! db_validate_db_name "$XDB_MAIN" 2>/dev/null \
    || ! db_validate_db_user "$XDB_USER" 2>/dev/null; then
    XDB_REFUSAL=no_database
    error "${domain} has no database of its own (site db-create --domain ${domain} creates one)"
    return 1
  fi
  XDB_ENGINE=$(site_db_engine "$domain")
  [[ "$action" == list ]] && return 0
  if [[ ! "$name" =~ $SITE_DB_EXTRA_NAME_RE ]]; then
    XDB_REFUSAL=name_invalid
    error "--name must be 1-16 characters: lowercase letters, digits, underscore"
    return 1
  fi
  XDB_FULL="${XDB_MAIN}_${name}"
  local listed=no max n
  while IFS= read -r n; do
    [[ "$n" == "$name" ]] && listed=yes
  done < <(site_db_extra_names "$domain")
  max=$(site_db_extra_max_len "$XDB_ENGINE")
  if [[ "$action" == add ]]; then
    if (( ${#XDB_FULL} > max )); then
      XDB_REFUSAL=name_too_long
      error "Database name ${XDB_FULL} would be ${#XDB_FULL} characters; ${XDB_ENGINE} allows ${max}. Choose a shorter --name"
      return 1
    fi
    if [[ "$listed" == yes ]]; then
      XDB_REFUSAL=name_taken
      error "${domain} already has the extra database ${XDB_FULL}"
      return 1
    fi
    [[ "$XDB_ENGINE" == pgsql ]] && { pgsql_require || return 1; }
    if site_db_extra_exists "$XDB_ENGINE" "$XDB_FULL"; then
      XDB_REFUSAL=database_exists
      error "A database named ${XDB_FULL} already exists on this server and is not an extra database of ${domain}"
      return 1
    fi
    return 0
  fi
  if [[ "$listed" != yes ]]; then
    XDB_REFUSAL=name_unknown
    error "${domain} has no extra database named ${name} (site db-extra-list --domain ${domain})"
    return 1
  fi
  return 0
}

site_db_extra_plan_refusal() {
  [[ -n "${XDB_REFUSAL:-}" ]] || return 0
  site_plan_data_write "{\"refusal\": \"${XDB_REFUSAL}\"}"
}

site_db_extra_add_plan_check() {
  local domain
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  site_db_extra_context "$domain" add "$(command_arg name "$@")" || { site_db_extra_plan_refusal; return 1; }
}

site_db_extra_drop_plan_check() {
  local domain
  domain=$(command_arg domain "$@")
  [[ -n "$domain" ]] || return 0
  site_db_extra_context "$domain" drop "$(command_arg name "$@")" || { site_db_extra_plan_refusal; return 1; }
}

site_db_extra_add_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" name="${PARSED_ARGS[name]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  require_args "domain name" || return 1
  site_db_extra_context "$domain" add "$name" || return 1
  echo "Plan for ${domain}:"
  echo "- Create database ${XDB_FULL} (${XDB_ENGINE})"
  if [[ "$XDB_ENGINE" == pgsql ]]; then
    echo "- Owner: ${XDB_USER} (the site's database user; same password)"
  else
    echo "- Grant ${XDB_USER}@localhost (the site's database user; same password); charset ${XDB_CHARSET}"
  fi
  echo "- Record it in db.env (DB_EXTRA); backups include it"
  if [[ "${confirm,,}" != yes ]]; then
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  local -a privs=()
  if [[ -n "${PROFILE_DB_REQUIRED_PRIVILEGES+x}" && ${#PROFILE_DB_REQUIRED_PRIVILEGES[@]} -gt 0 ]]; then
    privs=("${PROFILE_DB_REQUIRED_PRIVILEGES[@]}")
  fi
  site_db_extra_create "$XDB_ENGINE" "$XDB_FULL" "$XDB_USER" "$XDB_CHARSET" "$XDB_COLLATION" ${privs[@]+"${privs[@]}"} || return 1
  if ! site_db_extra_record "$domain" add "$name"; then
    site_db_extra_drop_one "$XDB_ENGINE" "$XDB_FULL" "$XDB_USER" || true
    error "Could not record ${XDB_FULL} in db.env; the database was dropped again"
    return 1
  fi
  ui_result_table "Domain|${domain}" "Database|${XDB_FULL} (${XDB_ENGINE})" "User|${XDB_USER} (same password as the main database)"
}

site_db_extra_drop_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" name="${PARSED_ARGS[name]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  local last_backup="${PARSED_ARGS[last-backup]:-yes}"
  require_args "domain name" || return 1
  [[ "$last_backup" == yes || "$last_backup" == no ]] || { error "--last-backup must be yes or no"; return 1; }
  site_db_extra_context "$domain" drop "$name" || return 1
  echo "Plan for ${domain}:"
  [[ "$last_backup" == yes ]] \
    && echo "- First: last backup of the site's databases, kept ${BACKUP_HOLD_DAYS:-7} days (backup data-list, backup data-restore)"
  echo "- Drop database ${XDB_FULL} (${XDB_ENGINE}); the main database and its user stay"
  echo "- Remove it from db.env (DB_EXTRA)"
  if [[ "${confirm,,}" != yes ]]; then
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  if [[ "$last_backup" == yes ]]; then
    backup_data_last "$domain" db-extra-drop yes no || return 1
  fi
  site_db_extra_drop_one "$XDB_ENGINE" "$XDB_FULL" "$XDB_USER" || return 1
  site_db_extra_record "$domain" remove "$name" || return 1
  ui_result_table "Domain|${domain}" "Dropped|${XDB_FULL}" "Last backup|${BACKUP_DATA_DIR:-skipped}"
}

site_db_extra_list_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" n
  require_args "domain" || return 1
  site_db_extra_context "$domain" list "" || return 1
  local -a rows=()
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    rows+=("${n}"$'\t'"${XDB_MAIN}_${n}"$'\t'"$(site_db_extra_exists "$XDB_ENGINE" "${XDB_MAIN}_${n}" && echo yes || echo no)")
  done < <(site_db_extra_names "$domain")
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '%s\n' ${rows[@]+"${rows[@]}"} | python3 -I -c '
import json, sys
items = []
for line in sys.stdin:
    parts = line.rstrip("\n").split("\t")
    if len(parts) == 3:
        items.append({"name": parts[0], "database": parts[1], "exists": parts[2] == "yes"})
print(json.dumps({"schema": "simai-db-extra/1", "domain": sys.argv[1], "engine": sys.argv[2], "main": sys.argv[3],
                  "user": sys.argv[4], "items": items, "count": len(items)}))' "$domain" "$XDB_ENGINE" "$XDB_MAIN" "$XDB_USER"
    return 0
  fi
  echo "Site: ${domain} (${XDB_ENGINE}, main database ${XDB_MAIN}, user ${XDB_USER})"
  if (( ${#rows[@]} == 0 )); then
    echo "No extra databases (site db-extra-add --domain ${domain} --name <name>)"
    return 0
  fi
  local row full exists
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r n full exists <<<"$row"
    printf '%-18s %-66s %s\n' "$n" "$full" "$([[ "$exists" == yes ]] && echo present || echo MISSING)"
  done
}

register_cmd "site" "db-extra-add" "Add an extra database to a site (<main db>_<name>, the site's own DB user)" "site_db_extra_add_handler" "domain name" "confirm=" "tier:advanced plan:handler"
register_cmd "site" "db-extra-drop" "Drop an extra database of a site (a last backup first)" "site_db_extra_drop_handler" "domain name" "confirm= last-backup=" "tier:advanced plan:handler effects:delete"
register_cmd "site" "db-extra-list" "List a site's extra databases" "site_db_extra_list_handler" "domain" "" "tier:advanced effects:read"
register_cmd "site" "db-credentials" "Show the connection details of a site's database, password included" "site_db_credentials_handler" "domain" "" "menu:confirm"
register_cmd "site" "db-status" "Show DB status for a site" "site_db_status_handler" "" "domain=" "tier:advanced effects:read"
register_cmd "site" "db-create" "Create DB + user for a site" "site_db_create_handler" "" "domain= dry_run= confirm=" "tier:advanced"
register_cmd "site" "db-drop" "Drop DB + user for a site" "site_db_drop_handler" "" "domain= dry_run= confirm= remove_files= last-backup=" "tier:advanced"
register_cmd "site" "db-rotate" "Rotate DB user password for a site" "site_db_rotate_handler" "" "domain= dry_run= confirm=" "tier:advanced"
