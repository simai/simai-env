#!/usr/bin/env bash

# Site data backups: database dump + project files + site config, with
# retention, integrity checks, optional age encryption and rsync off-site copy.
# Layout: <dest>/<domain>/<YYYYmmdd-HHMMSS>/{db.sql.gz,files.tar.gz,config.tar.gz,manifest.txt,SHA256SUMS}

BACKUP_DATA_DEFAULT_DEST="${SIMAI_BACKUP_DEST:-/var/backups/simai}"
BACKUP_DATA_LOG="/var/log/simai-backup.log"

backup_data_validate_keep() {
  local keep="$1"
  if [[ ! "$keep" =~ ^[0-9]+$ ]] || (( keep < 1 || keep > 365 )); then
    error "--keep must be a number between 1 and 365"
    return 1
  fi
}

backup_data_validate_dest() {
  local dest="$1" normalized
  validate_path "$dest" || return 1
  normalized=$(realpath -m "$dest")
  if [[ -n "${WWW_ROOT:-}" && ( "$normalized" == "${WWW_ROOT%/}" || "$normalized" == "${WWW_ROOT%/}/"* ) ]]; then
    error "Backup destination must not be inside the web root ${WWW_ROOT}"
    return 1
  fi
}

# Destination for rsync over SSH: user@host:/absolute/path
backup_data_validate_offsite() {
  local target="$1"
  [[ -z "$target" ]] && return 0
  if [[ ! "$target" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:/[A-Za-z0-9._/-]+$ ]]; then
    error "--offsite must look like user@host:/absolute/path"
    return 1
  fi
}

backup_data_dump_cli() {
  mysql_root_detect_cli || return 1
  BACKUP_DATA_DUMP_CLI=("${MYSQL_ROOT_CLI[@]}")
  BACKUP_DATA_DUMP_CLI[0]="mysqldump"
}

backup_data_file_excludes() {
  local profile="$1"
  printf '%s\n' './.git' '*/node_modules' './storage/logs' './storage/framework/cache' \
    './storage/framework/sessions' './storage/framework/views'
  if [[ "$profile" == "bitrix" ]]; then
    printf '%s\n' './public/bitrix/cache' './public/bitrix/managed_cache' './public/bitrix/stack_cache' \
      './public/bitrix/backup' './public/upload/resize_cache'
  fi
}

backup_data_dump_db() {
  local db_name="$1" out="$2" engine="${3:-mysql}"
  if [[ "$engine" == pgsql ]]; then
    pgsql_dump_gz "$db_name" "$out"
    return
  fi
  backup_data_dump_cli || return 1
  local rc=0
  if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
    MYSQL_PWD="$MYSQL_ROOT_PWD" "${BACKUP_DATA_DUMP_CLI[@]}" --single-transaction --quick --routines --triggers \
      --events --hex-blob --no-tablespaces --default-character-set=utf8mb4 "$db_name" 2>>"$LOG_FILE" | gzip -c >"$out" || rc=$?
  else
    "${BACKUP_DATA_DUMP_CLI[@]}" --single-transaction --quick --routines --triggers \
      --events --hex-blob --no-tablespaces --default-character-set=utf8mb4 "$db_name" 2>>"$LOG_FILE" | gzip -c >"$out" || rc=$?
  fi
  return "$rc"
}

backup_data_archive_files() {
  local root="$1" profile="$2" out="$3"
  local -a excludes=()
  local pattern
  while IFS= read -r pattern; do
    excludes+=("--exclude=${pattern}")
  done < <(backup_data_file_excludes "$profile")
  # Release layout: keep only the release that is live.
  if [[ -L "${root}/current" && -d "${root}/releases" ]]; then
    local live release
    live=$(basename "$(readlink "${root}/current")")
    for release in "${root}"/releases/*/; do
      release=$(basename "$release")
      [[ "$release" == "$live" ]] || excludes+=("--exclude=./releases/${release}")
    done
  fi
  local rc=0
  tar -czf "$out" --warning=no-file-changed --warning=no-file-removed "${excludes[@]}" -C "$root" . 2>>"$LOG_FILE" || rc=$?
  # GNU tar exits 1 when files changed while being read on a live site.
  (( rc == 0 || rc == 1 ))
}

backup_data_prune() {
  local domain_dir="$1" keep="$2"
  local old
  find "$domain_dir" -mindepth 1 -maxdepth 1 -type d -name '[0-9]*-[0-9]*' -printf '%f\n' 2>/dev/null \
    | sort -r | awk -v keep="$keep" 'NR > keep' \
    | while IFS= read -r old; do
      [[ "$old" =~ ^[0-9]{8}-[0-9]{6}$ ]] && rm -rf --one-file-system -- "${domain_dir:?}/${old}"
    done
}

backup_data_encrypt() {
  local dir="$1" recipient="$2" f
  command -v age >/dev/null 2>&1 || { error "age is not installed (apt-get install age)"; return 1; }
  for f in db.sql.gz files.tar.gz config.tar.gz; do
    [[ -f "${dir}/${f}" ]] || continue
    age -r "$recipient" -o "${dir}/${f}.age" "${dir}/${f}" || return 1
    rm -f -- "${dir:?}/${f}"
  done
}

backup_data_write_checksums() {
  local dir="$1"
  (cd "$dir" && find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%f\n' | sort | xargs -r sha256sum >SHA256SUMS)
}

# Backup directories live under the default destination or the one the
# site's schedule writes to; a backup is named by its directory.
backup_data_dests() {
  local domain="$1" slug cron
  printf '%s\n' "$BACKUP_DATA_DEFAULT_DEST"
  slug=$(project_slug_from_domain "$domain")
  cron="/etc/cron.d/simai-backup-${slug}"
  [[ -f "$cron" ]] && grep -v '^#' "$cron" | grep -o -- '--dest [^ ]*' | head -n1 | cut -d' ' -f2
  return 0
}

backup_data_schedule_keep() {
  local cron
  cron="/etc/cron.d/simai-backup-$(project_slug_from_domain "$1")"
  [[ -f "$cron" ]] && grep -v '^#' "$cron" | grep -o -- '--keep [0-9]*' | head -n1 | cut -d' ' -f2
  return 0
}

backup_data_resolve() {
  local domain="$1" name="$2" dest
  if [[ ! "$name" =~ ^[0-9]{8}-[0-9]{6}$ ]]; then
    error "--backup must be a backup name like 20260101-033000"
    return 1
  fi
  while IFS= read -r dest; do
    [[ -n "$dest" && -d "${dest%/}/${domain}/${name}" ]] && { printf '%s\n' "${dest%/}/${domain}/${name}"; return 0; }
  done < <(backup_data_dests "$domain" | sort -u)
  error "Backup ${name} of ${domain} not found"
  return 1
}

backup_data_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  local dest="${PARSED_ARGS[dest]:-$BACKUP_DATA_DEFAULT_DEST}"
  local keep="${PARSED_ARGS[keep]:-}"
  local with_db="${PARSED_ARGS[db]:-yes}" with_files="${PARSED_ARGS[files]:-yes}"
  local offsite="${PARSED_ARGS[offsite]:-${SIMAI_BACKUP_OFFSITE:-}}"
  local encrypt_to="${PARSED_ARGS[encrypt-to]:-${SIMAI_BACKUP_AGE_RECIPIENT:-}}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  # Without --keep a manual backup keeps as many as the site's schedule does.
  [[ -n "$keep" ]] || keep=$(backup_data_schedule_keep "$domain")
  keep="${keep:-7}"
  backup_data_validate_keep "$keep" || return 1
  backup_data_validate_dest "$dest" || return 1
  backup_data_validate_offsite "$offsite" || return 1
  if [[ -n "$encrypt_to" && ! "$encrypt_to" =~ ^age1[a-z0-9]{58}$ ]]; then
    error "--encrypt-to must be an age public key (age1...)"
    return 1
  fi
  read_site_metadata "$domain" || return 1
  local profile="${SITE_META[profile]:-generic}" root="${SITE_META[root]:-}"
  if [[ "$profile" == "alias" ]]; then
    error "Alias sites have no own data; back up the target site instead."
    return 1
  fi
  load_profile "$profile" >/dev/null 2>&1 || true
  [[ "${PROFILE_REQUIRES_DB:-no}" == "no" ]] && with_db="no"

  local db_name=""
  if [[ "${with_db,,}" == "yes" ]]; then
    local entry
    while IFS= read -r entry; do
      [[ "${entry%%|*}" == DB_NAME ]] && db_name="${entry#*|}"
    done < <(read_site_db_env "$domain" || true)
    if [[ -z "$db_name" ]] || ! db_validate_db_name "$db_name"; then
      error "Cannot determine the database for ${domain} (db.env missing or invalid)."
      return 1
    fi
  fi
  if [[ "${with_files,,}" == "yes" && ( -z "$root" || ! -d "$root" ) ]]; then
    error "Project root not found for ${domain}: ${root:-unknown}"
    return 1
  fi

  local domain_dir="${dest%/}/${domain}" ts dir
  install -d -m 0700 -o root -g root "$dest" "$domain_dir" || return 1
  exec 8>"${domain_dir}/.lock"
  flock -n 8 || { error "Another backup of ${domain} is running"; return 1; }
  ts=$(date +%Y%m%d-%H%M%S)
  # Names are per second: never write into an existing backup.
  while [[ -e "${domain_dir}/${ts}" ]]; do
    sleep 1
    ts=$(date +%Y%m%d-%H%M%S)
  done
  dir="${domain_dir}/${ts}"
  install -d -m 0700 "$dir" || return 1

  ui_header "SIMAI ENV · Data backup"
  local failed=""
  if [[ -n "$db_name" ]]; then
    info "Dumping database ${db_name}"
    backup_data_dump_db "$db_name" "${dir}/db.sql.gz" "$(site_db_engine "$domain")" || failed="database dump"
  fi
  if [[ -z "$failed" && "${with_files,,}" == "yes" ]]; then
    info "Archiving ${root}"
    backup_data_archive_files "$root" "$profile" "${dir}/files.tar.gz" || failed="files archive"
  fi
  if [[ -z "$failed" ]]; then
    SIMAI_ADMIN_MENU=0 backup_export_handler --domain "$domain" --out "${dir}/config.tar.gz" >/dev/null 2>&1 \
      || warn "Site config export failed; data files are still complete"
    {
      printf 'domain=%s\nprofile=%s\ncreated_at=%s\ndatabase=%s\nproject_root=%s\nsimai_env_version=%s\n' \
        "$domain" "$profile" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${db_name:-none}" "$root" \
        "$(cat "${SIMAI_ENV_ROOT}/VERSION" 2>/dev/null || echo unknown)"
      printf 'db_engine=%s\n' "$([[ -n "$db_name" ]] && site_db_engine "$domain" || echo none)"
      printf 'encrypted=%s\n' "$([[ -n "$encrypt_to" ]] && echo age || echo no)"
    } >"${dir}/manifest.txt"
  fi
  if [[ -z "$failed" && -n "$encrypt_to" ]]; then
    backup_data_encrypt "$dir" "$encrypt_to" || failed="encryption"
  fi
  [[ -z "$failed" ]] && { backup_data_write_checksums "$dir" || failed="checksums"; }
  if [[ -n "$failed" ]]; then
    rm -rf --one-file-system -- "${dir:?}"
    error "Backup of ${domain} failed at: ${failed}. Partial files were removed."
    return 1
  fi
  chmod -R go-rwx "$dir"
  [[ "${BACKUP_DATA_NO_PRUNE:-0}" == 1 ]] || backup_data_prune "$domain_dir" "$keep"

  local offsite_state="not configured"
  if [[ -n "$offsite" ]]; then
    info "Copying to ${offsite}"
    if rsync -a --delete -e "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes" \
      --exclude='.lock' "${domain_dir}/" "${offsite%/}/${domain}/" >>"$LOG_FILE" 2>&1; then
      offsite_state="copied"
    else
      error "Local backup is complete, but the off-site copy to ${offsite} failed."
      return 1
    fi
  fi
  ui_result_table \
    "Domain|${domain}" \
    "Backup|${dir}" \
    "Database|${db_name:-skipped}" \
    "Files|${with_files}" \
    "Size|$(du -sh "$dir" | awk '{print $1}')" \
    "Kept|last ${keep}" \
    "Off-site|${offsite_state}"
  ui_next_steps
  ui_kv "Verify" "simai-admin.sh backup data-verify --path ${dir} --restore-test yes --confirm yes"
}

backup_data_verify_handler() {
  parse_kv_args "$@"
  local dir="${PARSED_ARGS[path]:-}" restore_test="${PARSED_ARGS[restore-test]:-no}"
  local domain="${PARSED_ARGS[domain]:-}" name="${PARSED_ARGS[backup]:-}"
  if [[ -z "$dir" && -n "$domain" && -n "$name" ]]; then
    validate_domain "$domain" "allow" || return 1
    dir=$(backup_data_resolve "$domain" "$name") || return 1
  fi
  [[ -n "$dir" ]] || { error "Give --path, or --domain with --backup"; return 1; }
  validate_path "$dir" || return 1
  [[ -f "${dir}/SHA256SUMS" ]] || { error "SHA256SUMS not found in ${dir}"; return 1; }
  ui_header "SIMAI ENV · Verify data backup"
  (cd "$dir" && sha256sum --quiet -c SHA256SUMS) || { error "Checksum mismatch in ${dir}"; return 1; }
  echo "PASS checksums"
  if [[ -f "${dir}/db.sql.gz" ]]; then
    gzip -t "${dir}/db.sql.gz" || { error "db.sql.gz is corrupt"; return 1; }
    echo "PASS db.sql.gz integrity"
  fi
  if [[ -f "${dir}/files.tar.gz" ]]; then
    tar -tzf "${dir}/files.tar.gz" >/dev/null || { error "files.tar.gz is corrupt"; return 1; }
    echo "PASS files.tar.gz integrity"
  fi
  if [[ "${restore_test,,}" == "yes" ]]; then
    [[ -f "${dir}/db.sql.gz" ]] || { error "No plain db.sql.gz to test (encrypted or files-only backup)"; return 1; }
    local scratch engine
    scratch="simai_restore_check_$(date +%s)_$$"
    engine=$(sed -n 's/^db_engine=//p' "${dir}/manifest.txt" 2>/dev/null | head -n1)
    if [[ "$engine" == pgsql ]]; then
      pgsql_require || return 1
      pgsql_create_scratch "$scratch" || { error "Cannot create scratch database"; return 1; }
      local prc=0 ptables=0
      pgsql_restore_gz "$scratch" "${dir}/db.sql.gz" || prc=$?
      ptables=$(pgsql_table_count "$scratch" || echo 0)
      pgsql_drop_scratch "$scratch" || warn "Drop scratch database ${scratch} manually"
      if (( prc != 0 )); then
        error "Restore test failed: the dump does not import cleanly"
        return 1
      fi
      echo "PASS restore test (${ptables} tables imported into a scratch database)"
      return 0
    fi
    mysql_root_exec_stdin "CREATE DATABASE \`${scratch}\` CHARACTER SET utf8mb4;" || { error "Cannot create scratch database"; return 1; }
    local rc=0 tables=0
    if [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
      gzip -dc "${dir}/db.sql.gz" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" "$scratch" 2>>"$LOG_FILE" || rc=$?
    else
      gzip -dc "${dir}/db.sql.gz" | "${MYSQL_ROOT_CLI[@]}" "$scratch" 2>>"$LOG_FILE" || rc=$?
    fi
    tables=$(mysql_root_query_stdin "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${scratch}'" || echo 0)
    mysql_root_exec_stdin "DROP DATABASE \`${scratch}\`;" || warn "Drop scratch database ${scratch} manually"
    if (( rc != 0 )); then
      error "Restore test failed: the dump does not import cleanly"
      return 1
    fi
    echo "PASS restore test (${tables} tables imported into a scratch database)"
  fi
}

backup_data_schedule_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" enabled="${PARSED_ARGS[enabled]:-yes}"
  local at="${PARSED_ARGS[time]:-03:30}" keep="${PARSED_ARGS[keep]:-7}"
  local dest="${PARSED_ARGS[dest]:-$BACKUP_DATA_DEFAULT_DEST}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  local slug cron
  slug=$(project_slug_from_domain "$domain")
  cron="/etc/cron.d/simai-backup-${slug}"
  if [[ "${enabled,,}" != "yes" ]]; then
    rm -f -- "$cron"
    ui_result_table "Domain|${domain}" "Schedule|disabled"
    return 0
  fi
  backup_data_validate_keep "$keep" || return 1
  backup_data_validate_dest "$dest" || return 1
  if [[ ! "$at" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
    error "--time must be HH:MM"
    return 1
  fi
  local hh="${BASH_REMATCH[1]#0}" mm="${BASH_REMATCH[2]#0}"
  {
    printf '# simai-managed backup domain=%s\n' "$domain"
    printf '%s %s * * * root %q backup data --domain %q --keep %q --dest %q --confirm yes >>%s 2>&1\n' \
      "${mm:-0}" "${hh:-0}" "${SIMAI_ENV_ROOT}/simai-admin.sh" "$domain" "$keep" "$dest" "$BACKUP_DATA_LOG"
  } >"${cron}.tmp" && chmod 0644 "${cron}.tmp" && mv -f "${cron}.tmp" "$cron" || return 1
  ui_result_table "Domain|${domain}" "Schedule|daily at ${at}" "Keep|${keep}" "Destination|${dest}" "Log|${BACKUP_DATA_LOG}"
  ui_next_steps
  ui_kv "Off-site copy" "set SIMAI_BACKUP_OFFSITE=user@host:/path in /etc/simai-env.conf"
}

backup_data_restore_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" dir="${PARSED_ARGS[path]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  local name="${PARSED_ARGS[backup]:-}" want_db="${PARSED_ARGS[db]:-yes}" want_files="${PARSED_ARGS[files]:-yes}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  if [[ -z "$dir" ]]; then
    [[ -n "$name" ]] || { error "Give --path or --backup"; return 1; }
    dir=$(backup_data_resolve "$domain" "$name") || return 1
  fi
  validate_path "$dir" || return 1
  [[ "${want_db,,}" == yes || "${want_db,,}" == no ]] || { error "--db must be yes or no"; return 1; }
  [[ "${want_files,,}" == yes || "${want_files,,}" == no ]] || { error "--files must be yes or no"; return 1; }
  backup_data_verify_handler --path "$dir" >/dev/null || { error "Backup failed verification; nothing restored"; return 1; }
  read_site_metadata "$domain" || return 1
  local db_name="" entry
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == DB_NAME ]] && db_name="${entry#*|}"
  done < <(read_site_db_env "$domain" || true)
  local do_db=no do_files=no
  [[ "${want_db,,}" == yes && -f "${dir}/db.sql.gz" && -n "$db_name" ]] && do_db=yes
  [[ "${want_files,,}" == yes && -f "${dir}/files.tar.gz" ]] && do_files=yes
  if [[ "$do_db" == no && "$do_files" == no ]]; then
    error "Nothing to restore: the backup has no plain database dump or files archive for the parts asked"
    return 1
  fi
  if [[ "${confirm,,}" != "yes" ]]; then
    echo "Plan for ${domain}:"
    [[ "$do_db" == yes ]] && echo "  - back up the current database ${db_name} as a new backup, then replace it with ${dir}/db.sql.gz"
    [[ "$do_files" == yes ]] && echo "  - extract files into ${SITE_META[root]}.restore-<timestamp> for review; live files are not replaced"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  ui_header "SIMAI ENV · Restore data backup"
  if [[ "$do_db" == yes ]]; then
    db_validate_db_name "$db_name" || return 1
    # The current state becomes an ordinary backup next to the restored one,
    # so it can be restored back the same way; nothing is pruned meanwhile.
    info "Backing up the current database before the restore"
    BACKUP_DATA_NO_PRUNE=1 backup_data_handler --domain "$domain" --dest "$(dirname "$(dirname "$dir")")" \
      --db yes --files no || { error "Backup of the current state failed; nothing restored"; return 1; }
    local engine rc=0
    engine=$(site_db_engine "$domain")
    [[ "$engine" == pgsql ]] || mysql_root_detect_cli || return 1
    if [[ "$engine" == pgsql ]]; then
      pgsql_restore_gz "$db_name" "${dir}/db.sql.gz" || rc=$?
    elif [[ -n "${MYSQL_ROOT_PWD:-}" ]]; then
      gzip -dc "${dir}/db.sql.gz" | MYSQL_PWD="$MYSQL_ROOT_PWD" "${MYSQL_ROOT_CLI[@]}" "$db_name" 2>>"$LOG_FILE" || rc=$?
    else
      gzip -dc "${dir}/db.sql.gz" | "${MYSQL_ROOT_CLI[@]}" "$db_name" 2>>"$LOG_FILE" || rc=$?
    fi
    if (( rc != 0 )); then
      error "Database import failed. Restore the backup taken just before it to return to the previous state."
      return 1
    fi
    echo "Database ${db_name} restored from $(basename "$dir")"
  fi
  if [[ "$do_files" == yes ]]; then
    local staging
    staging="${SITE_META[root]}.restore-$(date +%Y%m%d-%H%M%S)"
    install -d -m 0750 "$staging" || return 1
    tar --no-same-owner -xzf "${dir}/files.tar.gz" -C "$staging" || { error "File extraction failed"; return 1; }
    chown -R "${SIMAI_USER}:${SIMAI_WEB_GROUP:-www-data}" "$staging" 2>/dev/null || true
    echo "Files extracted to ${staging}"
    echo "Review them, then swap directories during a maintenance window."
  fi
}

register_cmd "backup" "data" "Back up site database and files (with retention)" "backup_data_handler" "domain" "dest= keep= db= files= offsite= encrypt-to=" "tier:advanced"
register_cmd "backup" "data-verify" "Verify a data backup (checksums, archives, optional restore test)" "backup_data_verify_handler" "" "path= domain= backup= restore-test=" "tier:advanced effects:read"
register_cmd "backup" "data-schedule" "Enable or disable the daily data backup for a site" "backup_data_schedule_handler" "domain" "enabled= time= keep= dest=" "tier:advanced"
register_cmd "backup" "data-restore" "Restore a site database and stage its files from a data backup" "backup_data_restore_handler" "domain" "path= backup= db= files= confirm=" "tier:advanced"
