#!/usr/bin/env bash

# Server-level PostgreSQL: install a major version (Ubuntu or signed PGDG
# repository) and show its state. Site databases are managed by site add /
# site db-* with --db-engine pgsql.

db_pgsql_install_handler() {
  parse_kv_args "$@"
  local version="${PARSED_ARGS[version]:-}" pgdg="${PARSED_ARGS[pgdg]:-no}" confirm="${PARSED_ARGS[confirm]:-no}"
  local native
  native=$(pgsql_ubuntu_major)
  if [[ "${confirm,,}" != "yes" ]]; then
    echo "Plan: install PostgreSQL ${version:-$native} (Ubuntu ships ${native:-unknown})"
    [[ -n "$version" && "$version" != "$native" ]] && echo "      requires the PGDG apt repository (--pgdg yes; key pinned by fingerprint)"
    echo "      plus php<ver>-pgsql for every installed PHP-FPM version; server listens on localhost only"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  ui_header "SIMAI ENV · PostgreSQL install"
  pgsql_install "$version" "$pgdg" || return 1
  local ver_dir ver
  for ver_dir in /etc/php/*/fpm; do
    [[ -d "$ver_dir" ]] || continue
    ver=$(basename "$(dirname "$ver_dir")")
    DEBIAN_FRONTEND=noninteractive apt-get install -y "php${ver}-pgsql" >>"$LOG_FILE" 2>&1 \
      && os_svc_reload_or_restart "php${ver}-fpm" >/dev/null 2>&1 || warn "Could not install php${ver}-pgsql"
  done
  db_pgsql_status_handler "$@"
}

db_pgsql_status_handler() {
  parse_kv_args "$@"
  if ! pgsql_available; then
    ui_result_table "PostgreSQL|not installed" "Install|simai-admin.sh db pgsql-install --confirm yes"
    return 0
  fi
  local exposed
  exposed=$(pgsql_public_listeners | paste -sd, -)
  ui_result_table \
    "PostgreSQL|$(pgsql_query 'SHOW server_version' || echo unknown)" \
    "Service|$(systemctl is-active postgresql 2>/dev/null || echo unknown)" \
    "Databases|$(pgsql_query "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'" || echo '?')" \
    "Network|${exposed:+public listener: }${exposed:-localhost only}"
}

register_cmd "db" "pgsql-install" "Install PostgreSQL (Ubuntu or signed PGDG repository) and php-pgsql" "db_pgsql_install_handler" "" "version= pgdg= confirm=" "tier:advanced"
register_cmd "db" "pgsql-status" "Show PostgreSQL server state" "db_pgsql_status_handler" "" "" "tier:advanced"
