#!/usr/bin/env bash

db_network_plan_handler() {
  parse_kv_args "$@"
  echo 'MySQL network restriction plan (no settings changed):'
  echo '  bind-address = 127.0.0.1; mysqlx-bind-address = 127.0.0.1'
  echo '  Existing local TCP/socket applications continue using localhost.'
  echo '  Before apply: review external consumers, monitoring and SSH recovery.'
  echo '  External consumers require an agreed explicit address allowlist; do not enable UFW blindly.'
  echo '  Back up the managed MySQL config, validate it, restart MySQL, verify local applications and external denial.'
  echo '  Rollback: restore the backed-up config, validate, restart and verify connections.'
  echo 'Current database listeners:'
  ss -lnt '( sport = :3306 or sport = :33060 )'
  echo 'Current established database connections (absence is not historical evidence):'
  ss -nt state established '( sport = :3306 or sport = :33060 )'
}

db_network_localize_handler() {
  parse_kv_args "$@"
  [[ "${PARSED_ARGS[ack-no-external]:-no}" == yes ]] || { error 'Review consumers first, then use --ack-no-external yes'; return 1; }
  local binary
  binary=$(command -v mysqld) || { error 'mysqld not found'; return 1; }
  "$binary" --version | grep -Eq 'Ver 8\.' || { error 'This change supports MySQL/Percona 8 only'; return 1; }
  # Refuse an obvious active remote consumer even after acknowledgement.
  if ss -ntH state established '( sport = :3306 or sport = :33060 )' | awk '{print $NF}' | grep -Ev '^(127\.|\[?::1\]?|\[?::ffff:127\.)' | grep -q .; then
    error 'External database connections are active; prepare an address allowlist instead'
    return 1
  fi
  # Sites whose db.env points at a non-local host would lose the database.
  local env_file host
  for env_file in /etc/simai-env/sites/*/db.env; do
    [[ -f "$env_file" ]] || continue
    host=$(sed -n 's/^DB_HOST=//p' "$env_file" | tail -n1)
    case "${host:-localhost}" in
      localhost|127.0.0.1|::1) ;;
      *) error "$(basename "$(dirname "$env_file")") uses DB_HOST=${host}; prepare an address allowlist instead"; return 1 ;;
    esac
  done
  local conf=/etc/mysql/conf.d/99-simai-network.cnf backup
  [[ -d /etc/mysql/conf.d && ! -L "$conf" ]] || { error 'Unsupported or unsafe MySQL config layout'; return 1; }
  backup="/var/backups/simai-system/mysql-network/$(date -u +%Y%m%d%H%M%S)-$$"
  install -d -m 0700 -o root -g root "$backup"
  tar -czf "${backup}/mysql-config.tar.gz" -C /etc mysql
  chmod 0600 "${backup}/mysql-config.tar.gz"
  gzip -t "${backup}/mysql-config.tar.gz"
  tar -tzf "${backup}/mysql-config.tar.gz" >/dev/null
  if [[ -f "$conf" ]]; then cp -p "$conf" "${backup}/network.cnf"; fi
  DB_NETWORK_BACKUP="$backup" DB_NETWORK_CONFIG="$conf" DB_NETWORK_SUCCESS=no
  trap db_network_cleanup EXIT
  printf '[mysqld]\nbind-address = 127.0.0.1\nmysqlx-bind-address = 127.0.0.1\n' >"$conf"
  chmod 0644 "$conf"
  "$binary" --validate-config >>"$LOG_FILE" 2>&1 || { error 'MySQL rejected the proposed configuration'; return 1; }
  # Later config files (e.g. mysql.conf.d/mysqld.cnf) can override ours;
  # check the effective values before restarting anything.
  local effective
  effective=$(my_print_defaults mysqld 2>/dev/null || true)
  if [[ "$(grep -E '^--bind-address=' <<<"$effective" | tail -n1)" != --bind-address=127.0.0.1 ]] \
    || [[ "$(grep -E '^--mysqlx-bind-address=' <<<"$effective" | tail -n1)" != --mysqlx-bind-address=127.0.0.1 ]]; then
    error 'Another MySQL config file overrides the local bind; nothing was restarted'
    return 1
  fi
  os_svc_restart mysql
  mysql_root_detect_cli || { error 'MySQL local connection failed after restart'; return 1; }
  mysql_root_exec 'SELECT 1' >/dev/null
  if ss -lntH '( sport = :3306 or sport = :33060 )' | awk '{print $4}' | grep -Ev '^127\.' | grep -q .; then
    error 'A database listener is still non-local'; return 1
  fi
  DB_NETWORK_SUCCESS=yes
  trap - EXIT
  info "MySQL now listens locally; configuration recovery archive: ${backup}"
}

db_network_cleanup() {
  set +e  # restore every file even if one step fails
  [[ "$DB_NETWORK_SUCCESS" == yes ]] && return 0
  if [[ -f "${DB_NETWORK_BACKUP}/network.cnf" ]]; then
    cp -p "${DB_NETWORK_BACKUP}/network.cnf" "$DB_NETWORK_CONFIG"
  else
    rm -f "$DB_NETWORK_CONFIG"
  fi
  if mysqld --validate-config >>"$LOG_FILE" 2>&1; then
    os_svc_restart mysql || error 'MySQL restart after rollback failed'
  else
    error 'Restored MySQL configuration did not validate; manual recovery is required'
  fi
}

register_cmd "db" "network-plan" "Inspect MySQL exposure and show a restriction/rollback plan" "db_network_plan_handler" "" "" "tier:advanced effects:read"
register_cmd db network-localize 'Bind MySQL classic and X listeners locally after consumer review; includes config backup and rollback' db_network_localize_handler '' 'ack-no-external=no' 'tier:advanced'
