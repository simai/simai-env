#!/usr/bin/env bash
# PostgreSQL backend for site databases. SQL always goes through stdin as the
# postgres superuser (peer auth); passwords never appear in process arguments.

PGSQL_PGDG_KEY_FPR="B97B0AFCAA1A47F044F244A07FCC7D46ACCC4CF8"

pgsql_available() {
  command -v psql >/dev/null 2>&1 && id -u postgres >/dev/null 2>&1
}

pgsql_require() {
  pgsql_available && return 0
  error "PostgreSQL is not installed. Install it with: simai-admin.sh db pgsql-install --version <major> --confirm yes"
  return 1
}

# Runs SQL from the first argument as postgres; prints unaligned tuples.
pgsql_query() {
  local sql="$1" db="${2:-postgres}"
  printf '%s\n' "$sql" | runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -At -d "$db" 2>>"$LOG_FILE"
}

pgsql_exec() {
  pgsql_query "$@" >>"$LOG_FILE"
}

pgsql_literal() {
  local value="$1"
  printf "'%s'" "${value//\'/\'\'}"
}

pgsql_db_exists() {
  [[ "$(pgsql_query "SELECT 1 FROM pg_database WHERE datname = $(pgsql_literal "$1")")" == 1 ]]
}

pgsql_role_exists() {
  [[ "$(pgsql_query "SELECT 1 FROM pg_roles WHERE rolname = $(pgsql_literal "$1")")" == 1 ]]
}

pgsql_server_major() {
  pgsql_query "SHOW server_version_num" | awk '{print int($1 / 10000)}'
}

# Role owns only its database; PUBLIC loses CONNECT so other site roles
# cannot even open it.
pgsql_site_create() {
  local db_name="$1" db_user="$2" db_pass="$3"
  pgsql_require || return 1
  if [[ "$db_user" == pg_* || "$db_name" == pg_* ]]; then
    error "PostgreSQL reserves names starting with pg_; choose another --db-name/--db-user"
    return 1
  fi
  SITE_DB_APPLY_CREATED_DB=0
  SITE_DB_APPLY_CREATED_USER=0
  local created_user=0
  if pgsql_role_exists "$db_user"; then
    pgsql_exec "ALTER ROLE \"${db_user}\" WITH LOGIN PASSWORD $(pgsql_literal "$db_pass")" || {
      error "Failed to reconcile role ${db_user}"
      return 1
    }
  else
    pgsql_exec "CREATE ROLE \"${db_user}\" WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD $(pgsql_literal "$db_pass")" || {
      error "Failed to create role ${db_user}"
      return 1
    }
    created_user=1
    # shellcheck disable=SC2034 # transaction ownership signal consumed by site add
    SITE_DB_APPLY_CREATED_USER=1
  fi
  if ! pgsql_db_exists "$db_name"; then
    if ! pgsql_exec "CREATE DATABASE \"${db_name}\" OWNER \"${db_user}\" ENCODING 'UTF8' TEMPLATE template0"; then
      error "Failed to create database ${db_name}"
      (( created_user )) && pgsql_exec "DROP ROLE IF EXISTS \"${db_user}\""
      return 1
    fi
    # shellcheck disable=SC2034 # transaction ownership signal consumed by site add
    SITE_DB_APPLY_CREATED_DB=1
  fi
  pgsql_exec "ALTER DATABASE \"${db_name}\" OWNER TO \"${db_user}\"" || return 1
  pgsql_exec "REVOKE ALL ON DATABASE \"${db_name}\" FROM PUBLIC" || return 1
  pgsql_exec "ALTER SCHEMA public OWNER TO \"${db_user}\"" "$db_name" || return 1
}

pgsql_site_drop() {
  local db_name="$1" db_user="$2"
  pgsql_require || return 1
  if [[ -n "$db_name" ]]; then
    pgsql_exec "DROP DATABASE IF EXISTS \"${db_name}\" WITH (FORCE)" || {
      error "Failed to drop database ${db_name}"
      return 1
    }
  fi
  if [[ -n "$db_user" ]]; then
    pgsql_exec "DROP ROLE IF EXISTS \"${db_user}\"" || {
      error "Failed to drop role ${db_user}"
      return 1
    }
  fi
}

pgsql_site_rotate() {
  local db_user="$1" new_pass="$2"
  pgsql_require || return 1
  pgsql_exec "ALTER ROLE \"${db_user}\" WITH PASSWORD $(pgsql_literal "$new_pass")" || {
    error "Failed to rotate password for ${db_user}"
    return 1
  }
}

# Plain SQL with DROP ... IF EXISTS so the same file restores into an empty
# scratch database and over the live one.
pgsql_dump_gz() {
  local db_name="$1" out="$2"
  pgsql_require || return 1
  runuser -u postgres -- pg_dump --clean --if-exists --no-password "$db_name" 2>>"$LOG_FILE" | gzip -c >"$out"
}

pgsql_restore_gz() {
  local db_name="$1" file="$2"
  pgsql_require || return 1
  gzip -dc "$file" | runuser -u postgres -- psql -X -q -v ON_ERROR_STOP=1 -d "$db_name" >>"$LOG_FILE" 2>&1
}

pgsql_table_count() {
  pgsql_query "SELECT count(*) FROM information_schema.tables WHERE table_schema NOT IN ('pg_catalog','information_schema')" "$1"
}

# Scratch database for restore tests; ownership statements in the dump refer
# to the site role, which exists on this host.
pgsql_create_scratch() {
  pgsql_exec "CREATE DATABASE \"$1\" ENCODING 'UTF8' TEMPLATE template0"
}

pgsql_drop_scratch() {
  pgsql_exec "DROP DATABASE IF EXISTS \"$1\" WITH (FORCE)"
}

pgsql_public_listeners() {
  command -v ss >/dev/null 2>&1 || return 0
  ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':5432$' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true
}

pgsql_ubuntu_major() {
  local codename
  codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
  case "$codename" in
    jammy) echo 14 ;;
    noble) echo 16 ;;
    *) echo "" ;;
  esac
}

# Adds the PGDG apt repository with a fingerprint-pinned key (signed-by).
pgsql_add_pgdg_repo() {
  local keyring="/etc/apt/keyrings/postgresql.gpg" tmpdir fpr codename
  codename=$(. /etc/os-release && printf '%s' "${VERSION_CODENAME:-}")
  [[ -n "$codename" ]] || { error "Cannot detect Ubuntu codename"; return 1; }
  command -v gpg >/dev/null 2>&1 || apt-get install -y gnupg >>"$LOG_FILE" 2>&1 || return 1
  tmpdir=$(mktemp -d) || return 1
  if ! curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc -o "${tmpdir}/key.asc"; then
    rm -rf "$tmpdir"; error "Cannot download the PGDG signing key"; return 1
  fi
  fpr=$(gpg --show-keys --with-colons "${tmpdir}/key.asc" 2>/dev/null | awk -F: '/^fpr/ {print $10; exit}')
  if [[ "$fpr" != "$PGSQL_PGDG_KEY_FPR" ]]; then
    rm -rf "$tmpdir"; error "PGDG signing key fingerprint mismatch: ${fpr:-none}"; return 1
  fi
  install -d -m 0755 /etc/apt/keyrings
  gpg --dearmor <"${tmpdir}/key.asc" >"${tmpdir}/postgresql.gpg" && install -m 0644 "${tmpdir}/postgresql.gpg" "$keyring"
  rm -rf "$tmpdir"
  printf 'deb [signed-by=%s] https://apt.postgresql.org/pub/repos/apt %s-pgdg main\n' "$keyring" "$codename" \
    >/etc/apt/sources.list.d/pgdg.list
  apt-get update >>"$LOG_FILE" 2>&1
}

pgsql_install() {
  local major="$1" allow_pgdg="${2:-no}" native
  native=$(pgsql_ubuntu_major)
  if [[ -z "$major" ]]; then
    major="$native"
  fi
  [[ "$major" =~ ^[0-9]{2}$ ]] || { error "PostgreSQL major version must look like 16 or 17"; return 1; }
  if [[ "$major" != "$native" && ! -f /etc/apt/sources.list.d/pgdg.list ]]; then
    if [[ "${allow_pgdg,,}" != "yes" ]]; then
      error "PostgreSQL ${major} is not in the Ubuntu repository (native: ${native:-unknown}). Rerun with --pgdg yes to add the signed PGDG repository."
      return 1
    fi
    pgsql_add_pgdg_repo || return 1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get install -y "postgresql-${major}" "postgresql-client-${major}" >>"$LOG_FILE" 2>&1 || {
    error "Failed to install postgresql-${major}"
    return 1
  }
  systemctl enable --now postgresql >>"$LOG_FILE" 2>&1 || true
  pgsql_available
}
