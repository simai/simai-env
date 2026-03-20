#!/usr/bin/env bash
set -euo pipefail

db_create_handler() {
  parse_kv_args "$@"
  require_args "name user pass" || return 1

  local name="${PARSED_ARGS[name]:-}"
  local user="${PARSED_ARGS[user]:-}"
  local pass="${PARSED_ARGS[pass]:-}"
  if ! db_validate_db_name "$name"; then
    return 1
  fi
  if ! db_validate_db_user "$user"; then
    return 1
  fi
  progress_init 3
  progress_step "Checking MySQL availability and root access"
  if ! mysql_root_exec_stdin "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Creating database ${name}"
  mysql_root_exec_stdin "CREATE DATABASE IF NOT EXISTS \`${name}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" || return 1
  local esc_pass
  esc_pass=$(db_sql_escape "$pass")
  progress_step "Creating/updating user ${user} and grants"
  mysql_root_exec_stdin "CREATE USER IF NOT EXISTS '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "CREATE USER IF NOT EXISTS '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'127.0.0.1';" || return 1
  mysql_root_exec_stdin "GRANT ALL PRIVILEGES ON \`${name}\`.* TO '${user}'@'localhost';" || return 1
  mysql_root_exec_stdin "GRANT SESSION_VARIABLES_ADMIN ON *.* TO '${user}'@'127.0.0.1';" || true
  mysql_root_exec_stdin "GRANT SESSION_VARIABLES_ADMIN ON *.* TO '${user}'@'localhost';" || true
  mysql_root_exec_stdin "FLUSH PRIVILEGES;" || return 1
  progress_done "DB created/updated"
  echo "===== DB create summary ====="
  echo "Database : ${name}"
  echo "User     : ${user}"
}

db_drop_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1

  local name="${PARSED_ARGS[name]:-}"
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
  if ! mysql_root_exec_stdin "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Dropping database ${name}"
  mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${name}\`;" || return 1
  if [[ "$drop_user" == "yes" ]]; then
    progress_step "Dropping user ${user}"
    mysql_root_exec_stdin "DROP USER IF EXISTS '${user}'@'127.0.0.1';" || return 1
    mysql_root_exec_stdin "DROP USER IF EXISTS '${user}'@'localhost';" || return 1
    mysql_root_exec_stdin "DROP USER IF EXISTS '${user}'@'%';" || return 1
    mysql_root_exec_stdin "FLUSH PRIVILEGES;" || return 1
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
  require_args "user pass" || return 1

  local user="${PARSED_ARGS[user]:-}"
  local pass="${PARSED_ARGS[pass]:-}"
  if ! db_validate_db_user "$user"; then
    return 1
  fi
  local esc_pass
  esc_pass=$(db_sql_escape "$pass")
  progress_init 2
  progress_step "Checking MySQL availability and root access"
  if ! mysql_root_exec_stdin "SELECT 1;"; then
    error "Cannot connect as MySQL root"
    return 1
  fi
  progress_step "Updating password for ${user}"
  mysql_root_exec_stdin "ALTER USER '${user}'@'127.0.0.1' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "ALTER USER '${user}'@'localhost' IDENTIFIED BY '${esc_pass}';" || return 1
  mysql_root_exec_stdin "FLUSH PRIVILEGES;" || return 1
  progress_done "Password updated"
  echo "===== DB password summary ====="
  echo "User     : ${user}"
}

db_status_handler() {
  ui_header "SIMAI ENV · Database status"
  local service="mysql"
  local active="unknown"
  local enabled="unknown"
  local version="n/a"
  local ping="fail"
  local socket="/var/run/mysqld/mysqld.sock"
  local socket_status="missing"
  local port="default 3306"
  local datadir="unknown"
  local disk_free="unknown"

  if os_svc_has_unit "$service"; then
    if os_svc_is_active "$service"; then
      active="active"
    else
      active="inactive"
    fi
    if command -v systemctl >/dev/null 2>&1; then
      if systemctl is-enabled --quiet "$service"; then
        enabled="enabled"
      else
        enabled="disabled"
      fi
    fi
  else
    active="not installed"
    enabled="not installed"
  fi

  if command -v mysql >/dev/null 2>&1; then
    version=$(mysql --version 2>/dev/null || true)
  elif command -v mysqld >/dev/null 2>&1; then
    version=$(mysqld --version 2>/dev/null || true)
  fi
  [[ -z "$version" ]] && version="unknown"

  if [[ -S "$socket" || -e "$socket" ]]; then
    socket_status="exists"
  else
    local alt_socket="/run/mysqld/mysqld.sock"
    if [[ -S "$alt_socket" || -e "$alt_socket" ]]; then
      socket="$alt_socket"
      socket_status="exists"
    fi
  fi

  if command -v mysqld >/dev/null 2>&1; then
    local port_hint
    port_hint=$(mysqld --verbose --help 2>/dev/null | awk '$1=="port"{print $2; exit}')
    [[ -n "$port_hint" ]] && port="$port_hint"
    local datadir_hint
    datadir_hint=$(mysqld --verbose --help 2>/dev/null | awk '$1=="datadir"{print $2; exit}')
    [[ -n "$datadir_hint" ]] && datadir="$datadir_hint"
  fi
  if [[ "$datadir" == "unknown" ]]; then
    local cfg="/etc/mysql/mysql.conf.d/mysqld.cnf"
    if [[ -f "$cfg" ]]; then
      local val
      val=$(grep -E '^[[:space:]]*port[[:space:]]*=' "$cfg" | tail -n1 | awk -F= '{print $2}' | tr -d '[:space:]')
      [[ -n "$val" ]] && port="$val"
      val=$(grep -E '^[[:space:]]*datadir[[:space:]]*=' "$cfg" | tail -n1 | awk -F= '{print $2}' | tr -d '[:space:]')
      [[ -n "$val" ]] && datadir="$val"
    fi
  fi

  if [[ "$active" != "not installed" && "$ping" != "not installed" ]]; then
    if mysql_root_detect_cli; then
      ping="ok"
    fi
  else
    ping="not installed"
  fi

  local df_target="$datadir"
  if [[ "$df_target" == "unknown" || ! -d "$df_target" ]]; then
    df_target="/var/lib/mysql"
  fi
  if [[ -d "$df_target" ]]; then
    disk_free=$(df -h "$df_target" 2>/dev/null | awk 'NR==2{print $4}')
    [[ -z "$disk_free" ]] && disk_free="unknown"
  fi

  ui_section "Result"
  print_kv_table \
    "Service|${active}" \
    "Enabled|${enabled}" \
    "Version|${version}" \
    "Ping|${ping}" \
    "Socket|${socket} (${socket_status})" \
    "Port|${port}" \
    "Datadir|${datadir}" \
    "Disk free|${disk_free}"
  ui_section "Next steps"
  ui_kv "List databases" "simai-admin.sh db list"
  ui_kv "Platform diagnostics" "simai-admin.sh self platform-status"

  if [[ "$active" == "not installed" || "$ping" != "ok" ]]; then
    return 1
  fi
}

db_list_handler() {
  ui_header "SIMAI ENV · Database list"
  if ! mysql_root_detect_cli; then
    return 1
  fi
  local dbs
  dbs=$(mysql_root_query_stdin "SHOW DATABASES;")
  if [[ -z "$dbs" ]]; then
    warn "No databases found"
    return 0
  fi
  ui_section "Result"
  local -a rows=()
  while IFS= read -r db; do
    [[ -z "$db" ]] && continue
    rows+=("${db}|present")
  done <<<"$dbs"
  print_kv_table "${rows[@]}"
  ui_section "Next steps"
  ui_kv "Service status" "simai-admin.sh db status"
  ui_kv "Platform diagnostics" "simai-admin.sh self platform-status"
}

register_cmd "db" "create" "Legacy: Create database and user (use 'site db-create')" "db_create_handler" "name user pass" "" "menu:hidden"
register_cmd "db" "drop" "Legacy: Drop database (use 'site db-drop')" "db_drop_handler" "name" "drop-user=0 user= confirm=" "menu:hidden"
register_cmd "db" "set-pass" "Legacy: Change DB user password (use 'site db-rotate')" "db_pass_handler" "user pass" "" "menu:hidden"
register_cmd "db" "status" "Show MySQL/Percona service status" "db_status_handler" "" ""
register_cmd "db" "list" "List databases" "db_list_handler" "" ""
