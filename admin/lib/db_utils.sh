#!/usr/bin/env bash

mysql_root_query_stdin() {
  local sql="${1:-}"
  mysql_root_detect_cli || return 1
  if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    printf "%s\n" "$sql" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" -N -B 2>>"$LOG_FILE"
  else
    printf "%s\n" "$sql" | "${MYSQL_ROOT_CLI[@]}" -N -B 2>>"$LOG_FILE"
  fi
}

mysql_root_exec_stdin() {
  local sql="$1"
  mysql_root_detect_cli || return 1
  if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    printf "%s\n" "$sql" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" 1>>"$LOG_FILE" 2>>"$LOG_FILE"
  else
    printf "%s\n" "$sql" | "${MYSQL_ROOT_CLI[@]}" 1>>"$LOG_FILE" 2>>"$LOG_FILE"
  fi
}

normalize_db_identifier() {
  local input="$1" max_len="${2:-48}"
  local norm
  norm=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
  norm="${norm%%_}"
  norm="${norm#__}"
  norm="${norm:0:$max_len}"
  norm=$(echo "$norm" | sed 's/^_\\+//; s/_\\+$//')
  if [[ -z "$norm" ]]; then
    error "Invalid database identifier from '${input}'"
    return 1
  fi
  echo "$norm"
}

db_exists() {
  local name="$1"
  mysql_root_query_stdin "SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='${name}'" | grep -qx "$name"
}

db_user_exists() {
  local user="$1"
  mysql_root_query_stdin "SELECT User FROM mysql.user WHERE User='${user}' AND Host='localhost'" | grep -qx "$user"
}

db_user_has_grant_on() {
  local user="$1" db="$2"
  mysql_root_query_stdin "SHOW GRANTS FOR '${user}'@'localhost'" | grep -q "\`${db}\`"
}

db_default_privileges() {
  printf "%s\n" "SELECT" "INSERT" "UPDATE" "DELETE" "CREATE" "DROP" "INDEX" "ALTER" "CREATE TEMPORARY TABLES" "LOCK TABLES" "EXECUTE"
}

site_db_env_file() {
  local domain="$1"
  echo "$(site_sites_config_dir)/${domain}/db.env"
}

read_site_db_env() {
  local domain="$1"
  local file
  file=$(site_db_env_file "$domain")
  [[ -f "$file" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ "$line" == *=* ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      val="${val#"${val%%[![:space:]]*}"}"
      val="${val%"${val##*[![:space:]]}"}"
      [[ -z "$key" ]] && continue
      printf "%s|%s\n" "$key" "$val"
    fi
  done <"$file"
}

write_site_db_env() {
  local domain="$1"
  local db_name="$2" db_user="$3" db_pass="$4" db_charset="$5" db_collation="$6"
  local dir
  dir="$(site_sites_config_dir)/${domain}"
  mkdir -p "$dir"
  local file="${dir}/db.env"
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
DB_NAME=${db_name}
DB_USER=${db_user}
DB_PASS=${db_pass}
DB_HOST=localhost
DB_CHARSET=${db_charset}
DB_COLLATION=${db_collation}
EOF
  mv "$tmp" "$file"
  chmod 0640 "$file"
  chown root:root "$file" 2>/dev/null || true
}

site_db_export_to_env() {
  local domain="$1" project_dir="$2" target="$3"
  [[ -z "$target" ]] && target=".env"
  if [[ "$target" == /* || "$target" == *".."* || "$target" =~ [[:space:]] ]]; then
    error "Invalid target path ${target} (must be relative, no spaces/..)"
    return 1
  fi
  local db_env_file
  db_env_file="$(site_db_env_file "$domain")"
  if [[ ! -f "$db_env_file" ]]; then
    error "db.env not found for ${domain} at ${db_env_file}"
    return 1
  fi
  local db_name="" db_user="" db_pass="" db_host="localhost"
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    local k="${entry%%|*}" v="${entry#*|}"
    case "$k" in
      DB_NAME) db_name="$v" ;;
      DB_USER) db_user="$v" ;;
      DB_PASS) db_pass="$v" ;;
      DB_HOST) db_host="$v" ;;
    esac
  done < <(read_site_db_env "$domain")
  if [[ -z "$db_name" || -z "$db_user" || -z "$db_pass" ]]; then
    error "db.env missing required fields for ${domain}"
    return 1
  fi
  local env_file="${project_dir}/${target}"
  env_set_kv "$env_file" "DB_HOST" "$db_host"
  env_set_kv "$env_file" "DB_DATABASE" "$db_name"
  env_set_kv "$env_file" "DB_USERNAME" "$db_user"
  env_set_kv "$env_file" "DB_PASSWORD" "$db_pass"
  return 0
}

# shellcheck disable=SC2034 # DB_CREDS_* are set for callers to read after invocation
site_db_load_or_generate_creds() {
  local domain="$1" project_slug="$2" charset_default="$3" coll_default="$4"
  DB_CREDS_NAME="" DB_CREDS_USER="" DB_CREDS_PASS=""
  # shellcheck disable=SC2034 # exposed as globals for caller consumption
  DB_CREDS_CHARSET="${charset_default:-utf8mb4}"
  # shellcheck disable=SC2034 # exposed as globals for caller consumption
  DB_CREDS_COLLATION="${coll_default:-utf8mb4_unicode_ci}"
  if read_env=$(read_site_db_env "$domain"); then
    while IFS= read -r entry; do
      local k="${entry%%|*}" v="${entry#*|}"
      case "$k" in
        DB_NAME) DB_CREDS_NAME="$v" ;;
        DB_USER) DB_CREDS_USER="$v" ;;
        DB_PASS) DB_CREDS_PASS="$v" ;;
        DB_CHARSET) DB_CREDS_CHARSET="$v" ;;
        DB_COLLATION) DB_CREDS_COLLATION="$v" ;;
      esac
    done <<<"$read_env"
    if ! db_validate_db_name "$DB_CREDS_NAME"; then return 1; fi
    if ! db_validate_db_user "$DB_CREDS_USER"; then return 1; fi
    if [[ -z "$DB_CREDS_PASS" ]]; then
      error "DB_PASS missing in db.env for ${domain}"
      return 1
    fi
    return 0
  fi
  local base="$project_slug"
  if [[ -z "$base" || ! "$base" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; then
    base=$(normalize_db_identifier "$domain" 48) || return 1
  fi
  DB_CREDS_NAME=$(normalize_db_identifier "$base" 48) || return 1
  DB_CREDS_USER=$(normalize_db_identifier "$base" 32) || return 1
  DB_CREDS_PASS=$(generate_password)
  return 0
}

site_db_apply_create() {
  local domain="$1" db_name="$2" db_user="$3" db_pass="$4" charset="$5" coll="$6"
  shift 6
  local privs=("$@")
  mysql_root_detect_cli || return 1
  local priv_str
  priv_str=$(printf "%s, " "${privs[@]}"); priv_str="${priv_str%, }"

  local created_db=0 created_user=0
  if ! db_exists "$db_name"; then
    if ! mysql_root_exec_stdin "CREATE DATABASE \`${db_name}\` DEFAULT CHARACTER SET ${charset} COLLATE ${coll}"; then
      error "Failed to create database ${db_name}"
      return 1
    fi
    created_db=1
  fi
  if db_user_exists "$db_user"; then
    if ! mysql_root_exec_stdin "ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}'"; then
      error "Failed to reconcile user ${db_user}"
      [[ $created_db -eq 1 ]] && mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${db_name}\`" || true
      return 1
    fi
  else
    if ! mysql_root_exec_stdin "CREATE USER '${db_user}'@'localhost' IDENTIFIED BY '${db_pass}'"; then
      error "Failed to create user ${db_user}"
      [[ $created_db -eq 1 ]] && mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${db_name}\`" || true
      return 1
    fi
    created_user=1
  fi
  if ! mysql_root_exec_stdin "GRANT ${priv_str} ON \`${db_name}\`.* TO '${db_user}'@'localhost'"; then
    error "Failed to grant privileges to ${db_user}"
    [[ $created_user -eq 1 ]] && mysql_root_exec_stdin "DROP USER IF EXISTS '${db_user}'@'localhost'" || true
    [[ $created_db -eq 1 ]] && mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${db_name}\`" || true
    return 1
  fi
  if ! mysql_root_exec_stdin "FLUSH PRIVILEGES"; then
    error "Failed to flush privileges"
    [[ $created_user -eq 1 ]] && mysql_root_exec_stdin "DROP USER IF EXISTS '${db_user}'@'localhost'" || true
    [[ $created_db -eq 1 ]] && mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${db_name}\`" || true
    return 1
  fi
  write_site_db_env "$domain" "$db_name" "$db_user" "$db_pass" "$charset" "$coll"
}

site_db_apply_drop() {
  local domain="$1" db_name="$2" db_user="$3" remove_env="${4:-no}"
  mysql_root_detect_cli || return 1
  if [[ -n "$db_name" ]]; then
    if ! mysql_root_exec_stdin "DROP DATABASE IF EXISTS \`${db_name}\`"; then
      error "Failed to drop database ${db_name}"
      return 1
    fi
  fi
  if [[ -n "$db_user" ]]; then
    mysql_root_exec_stdin "DROP USER IF EXISTS '${db_user}'@'localhost'" || error "Failed to drop user ${db_user}@localhost"
    mysql_root_exec_stdin "DROP USER IF EXISTS '${db_user}'@'127.0.0.1'" || error "Failed to drop user ${db_user}@127.0.0.1"
    mysql_root_exec_stdin "DROP USER IF EXISTS '${db_user}'@'%'" || true
  fi
  mysql_root_exec_stdin "FLUSH PRIVILEGES" || true
  if [[ "${remove_env,,}" == "yes" ]]; then
    rm -f "$(site_db_env_file "$domain")"
  fi
}

site_db_apply_rotate() {
  local domain="$1" db_name="$2" db_user="$3" new_pass="$4" charset="$5" coll="$6"
  mysql_root_detect_cli || return 1
  if ! mysql_root_exec_stdin "ALTER USER '${db_user}'@'localhost' IDENTIFIED BY '${new_pass}'"; then
    error "Failed to rotate password for ${db_user}"
    return 1
  fi
  if ! mysql_root_exec_stdin "FLUSH PRIVILEGES"; then
    error "Failed to flush privileges after rotation"
    return 1
  fi
  write_site_db_env "$domain" "$db_name" "$db_user" "$new_pass" "$charset" "$coll"
}
