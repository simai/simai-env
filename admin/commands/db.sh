#!/usr/bin/env bash
set -euo pipefail

db_create_handler() {
  parse_kv_args "$@"
  require_args "name user pass"

  local name="${PARSED_ARGS[name]}"
  local user="${PARSED_ARGS[user]}"
  local pass="${PARSED_ARGS[pass]}"
  if ! db_validate_db_name "$name"; then
    return 1
  fi
  if ! db_validate_db_user "$user"; then
    return 1
  fi
  progress_init 3
  progress_step "Checking MySQL availability and root access"
  if ! mysql_root_exec "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Creating database ${name}"
  mysql_root_exec "CREATE DATABASE IF NOT EXISTS \\\`${name}\\\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
  local esc_pass
  esc_pass=$(db_sql_escape "$pass")
  progress_step "Creating/updating user ${user} and grants"
  mysql_root_exec "CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "GRANT ALL PRIVILEGES ON \\\`${name}\\\`.* TO '${user}'@'127.0.0.1';"
  mysql_root_exec "GRANT ALL PRIVILEGES ON \\\`${name}\\\`.* TO '${user}'@'localhost';"
  mysql_root_exec "FLUSH PRIVILEGES;"
  progress_done "DB created/updated"
  echo "===== DB create summary ====="
  echo "Database : ${name}"
  echo "User     : ${user}"
}

db_drop_handler() {
  parse_kv_args "$@"
  require_args "name"

  local name="${PARSED_ARGS[name]}"
  local drop_user="${PARSED_ARGS[drop-user]:-no}"
  local user="${PARSED_ARGS[user]:-}"
  local confirm="${PARSED_ARGS[confirm]:-}"
  case "${drop_user,,}" in
    1|yes|true) drop_user="yes" ;;
    0|no|false|"") drop_user="no" ;;
    *) drop_user="no" ;;
  esac
  if ! db_validate_db_name "$name"; then
    return 1
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" ]]; then
    if [[ "${confirm,,}" != "yes" ]]; then
      error "Destructive action; add --confirm yes"
      return 1
    fi
    if [[ "$drop_user" == "yes" && -z "$user" ]]; then
      error "When --drop-user yes, you must provide --user <db_user> (or set --drop-user no)."
      return 1
    fi
  else
    local sure
    sure=$(select_from_list "Drop database ${name}?" "no" "no" "yes")
    [[ "$sure" != "yes" ]] && return 0
    if [[ -z "${PARSED_ARGS[drop-user]:-}" ]]; then
      drop_user=$(select_from_list "Drop DB user?" "no" "no" "yes")
      [[ -z "$drop_user" ]] && drop_user="no"
    fi
    if [[ "$drop_user" == "yes" && -z "$user" ]]; then
      read -r -p "DB user to drop: " user || true
      if [[ -z "$user" ]]; then
        warn "DB user will be kept"
        drop_user="no"
      fi
    fi
  fi
  if [[ "$drop_user" == "yes" ]]; then
    if ! db_validate_db_user "$user"; then
      return 1
    fi
  fi
  progress_init 3
  progress_step "Checking MySQL availability and root access"
  if ! mysql_root_exec "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Dropping database ${name}"
  mysql_root_exec "DROP DATABASE IF EXISTS \\\`${name}\\\`;"
  if [[ "$drop_user" == "yes" ]]; then
    progress_step "Dropping user ${user}"
    mysql_root_exec "DROP USER IF EXISTS '${user}'@'127.0.0.1';"
    mysql_root_exec "DROP USER IF EXISTS '${user}'@'localhost';"
    mysql_root_exec "DROP USER IF EXISTS '${user}'@'%';"
    mysql_root_exec "FLUSH PRIVILEGES;"
  fi
  progress_done "DB drop completed"
  echo "===== DB drop summary ====="
  echo "Database : ${name}"
  if [[ "$drop_user" == "yes" ]]; then
    echo "User     : dropped (${user})"
  else
    echo "User     : kept"
  fi
}

db_pass_handler() {
  parse_kv_args "$@"
  require_args "user pass"

  local user="${PARSED_ARGS[user]}"
  local pass="${PARSED_ARGS[pass]}"
  if ! db_validate_db_user "$user"; then
    return 1
  fi
  local esc_pass
  esc_pass=$(db_sql_escape "$pass")
  progress_init 2
  progress_step "Checking MySQL availability and root access"
  if ! mysql_root_exec "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Updating password for ${user}"
  mysql_root_exec "ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';"
  mysql_root_exec "FLUSH PRIVILEGES;"
  progress_done "Password updated"
  echo "===== DB password summary ====="
  echo "User     : ${user}"
}

register_cmd "db" "create" "Create database and user" "db_create_handler" "name user pass" ""
register_cmd "db" "drop" "Drop database" "db_drop_handler" "name" "drop-user=0 user= confirm="
register_cmd "db" "set-pass" "Change DB user password" "db_pass_handler" "user pass" ""
