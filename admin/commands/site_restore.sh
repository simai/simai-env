#!/usr/bin/env bash
# Restore a plain PHP site (generic profile) from a files archive and, when
# the site has a MySQL database, an SQL dump. Bitrix and WordPress have
# their own restore (bitrix restore-ready, wp restore-ready).
#
# The archive and the dump are files inside the site directory (uploaded with
# file upload or over SFTP). Everything runs as the site user: unpacking,
# copying, the dump's import with the site's own credentials. Afterwards the
# archive and the dump go to the site's trash, out of the web root.

# Unpacks an archive into a directory as the site user. .tar.gz, .tgz, .tar
# with tar; .zip with Python's zipfile (no unzip package needed), refusing
# absolute paths, '..' parts and links.
restore_unpack_as_user() {
  local archive="$1" dest="$2" rc=0
  case "$archive" in
    *.tar.gz|*.tgz)
      # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
      sudo -u "$SIMAI_USER" -H tar --no-same-owner -xzf - -C "$dest" <"$archive" >>"$LOG_FILE" 2>&1 || rc=$? ;;
    *.tar)
      # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
      sudo -u "$SIMAI_USER" -H tar --no-same-owner -xf - -C "$dest" <"$archive" >>"$LOG_FILE" 2>&1 || rc=$? ;;
    *.zip)
      # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
      sudo -u "$SIMAI_USER" -H python3 -I -c '
import os, stat, sys, zipfile
dest = os.path.realpath(sys.argv[1])
with zipfile.ZipFile(sys.argv[2]) as z:
    for info in z.infolist():
        name = info.filename
        parts = name.replace("\\", "/").split("/")
        if name.startswith("/") or ".." in parts or stat.S_ISLNK(info.external_attr >> 16):
            sys.exit("refused entry: " + name)
        target = os.path.realpath(os.path.join(dest, name))
        if target != dest and not target.startswith(dest + os.sep):
            sys.exit("refused entry: " + name)
    z.extractall(dest)
' "$dest" "$archive" >>"$LOG_FILE" 2>&1 || rc=$? ;;
    *) rc=1 ;;
  esac
  return "$rc"
}

# The directory of the unpacked archive that holds the site: the archive's
# single top directory when it has nothing else, otherwise its top.
restore_archive_top() {
  local staging="$1" entries
  mapfile -t entries < <(find "$staging" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)
  if [[ ${#entries[@]} -eq 1 && -d "${staging}/${entries[0]}" && ! -L "${staging}/${entries[0]}" ]]; then
    printf '%s\n' "${staging}/${entries[0]}"
  else
    printf '%s\n' "$staging"
  fi
}

site_restore_kinds() {
  local files="$1" dump="$2"
  case "$files" in
    *.sql|*.sql.gz|*.sql.zip) SR_REFUSAL=files_is_dump; error "--files is the site's files; ${files##*/} is a dump (--dump)"; return 1 ;;
    *.tar.gz|*.tgz|*.tar|*.zip) ;;
    *) SR_REFUSAL=archive_kind; error "--files must be a .tar.gz, .tgz, .tar or .zip archive"; return 1 ;;
  esac
  SR_DUMP_GZ=no
  case "$dump" in
    "") ;;
    *.sql.gz) SR_DUMP_GZ=yes ;;
    *.sql.zip) SR_DUMP_GZ=zip ;;
    *.sql) ;;
    *) SR_REFUSAL=dump_kind; error "--dump must be a .sql, .sql.gz or .sql.zip file"; return 1 ;;
  esac
}

# The site's MySQL database, if any: SR_DB_EXISTS, SR_DB_NAME, SR_DB_ENGINE,
# SR_TABLES (-1 when root cannot read it).
site_restore_db_facts() {
  local domain="$1" entry
  SR_DB_EXISTS=no SR_DB_NAME="" SR_DB_ENGINE="" SR_TABLES=0
  read_site_db_env "$domain" >/dev/null 2>&1 || return 0
  SR_DB_EXISTS=yes
  SR_DB_ENGINE=$(site_db_engine "$domain")
  [[ "$SR_DB_ENGINE" == mysql ]] || return 0
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == DB_NAME ]] && SR_DB_NAME="${entry#*|}"
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  if db_validate_db_name "$SR_DB_NAME" >/dev/null 2>&1; then
    SR_TABLES=$(wp_db_table_count "$SR_DB_NAME")
  else
    SR_TABLES=-1
  fi
}

# Sets SR_* for a generic site; refuses what the restore cannot do, with the
# reason's code in SR_REFUSAL and what was found for the plan.
site_restore_precheck() {
  local domain="$1" files="$2" dump="$3" overwrite="$4" f
  SR_REFUSAL="" SR_DOMAIN="$domain" SR_ROOT="" SR_DOC_ROOT="" SR_PUBLIC_DIR="" SR_FILES="" SR_DUMP=""
  SR_DB_EXISTS=no SR_DB_NAME="" SR_DB_ENGINE="" SR_TABLES=0 SR_HAS_FILES=no SR_BACKUP=no SR_OVERWRITE="$overwrite"
  validate_domain "$domain" "allow" || { SR_REFUSAL=site_missing; return 1; }
  require_site_exists "$domain" || { SR_REFUSAL=site_missing; return 1; }
  read_site_metadata "$domain" || { SR_REFUSAL=site_missing; error "Failed to read site metadata for ${domain}"; return 1; }
  local profile="${SITE_META[profile]:-}"
  case "$profile" in
    generic) ;;
    bitrix) SR_REFUSAL=profile_bitrix; error "${domain} is a Bitrix site: use bitrix restore-ready"; return 1 ;;
    wordpress) SR_REFUSAL=profile_wordpress; error "${domain} is a WordPress site: use wp restore-ready"; return 1 ;;
    *) SR_REFUSAL=profile_unsupported; error "site restore-ready is for PHP sites (generic profile); ${domain} is ${profile:-unknown}"; return 1 ;;
  esac
  SR_ROOT="${SITE_META[root]:-}"
  validate_path "$SR_ROOT" || { SR_REFUSAL=root_missing; return 1; }
  [[ -d "$SR_ROOT" ]] || { SR_REFUSAL=root_missing; error "Site directory ${SR_ROOT} is missing"; return 1; }
  if deploy_layout_active "$SR_ROOT"; then
    SR_REFUSAL=releases; error "${domain} is deployed in releases; restore it with site deploy --archive"
    return 1
  fi
  SR_PUBLIC_DIR="${SITE_META[public_dir]-public}"
  SR_DOC_ROOT=$(site_compute_doc_root "$SR_ROOT" "$SR_PUBLIC_DIR") || { SR_REFUSAL=root_missing; return 1; }
  site_restore_db_facts "$domain"
  # Files of the site's own besides the placeholder, the archive and the dump.
  local files_real="" dump_real=""
  files_real=$(realpath -e -- "${SR_ROOT}/${files#"${SR_ROOT%/}"/}" 2>/dev/null || true)
  [[ -z "$dump" ]] || dump_real=$(realpath -e -- "${SR_ROOT}/${dump#"${SR_ROOT%/}"/}" 2>/dev/null || true)
  while IFS= read -r f; do
    [[ "$f" == "$files_real" || ( -n "$dump_real" && "$f" == "$dump_real" ) ]] && continue
    [[ "$f" == "${SR_DOC_ROOT}/healthcheck.php" ]] && continue
    grep -qE "SIMAI placeholder|Placeholder: site is configured" "$f" 2>/dev/null && continue
    SR_HAS_FILES=yes; break
  done < <(find "$SR_DOC_ROOT" -mindepth 1 -maxdepth 2 -type f 2>/dev/null | head -n 50)
  site_file_resolve "$SR_ROOT" "$files" files || { SR_REFUSAL="$SITE_FILE_REFUSAL"; return 1; }
  SR_FILES="$SITE_FILE_PATH"
  if [[ -n "$dump" ]]; then
    site_file_resolve "$SR_ROOT" "$dump" dump || { SR_REFUSAL="$SITE_FILE_REFUSAL"; return 1; }
    SR_DUMP="$SITE_FILE_PATH"
  fi
  site_restore_kinds "$SR_FILES" "$SR_DUMP" || return 1
  if [[ -n "$SR_DUMP" ]]; then
    if [[ "$SR_DB_EXISTS" != yes ]]; then
      SR_REFUSAL=no_database; error "${domain} has no database for the dump: simai-admin.sh site db-create --domain ${domain} --confirm yes"
      return 1
    fi
    if [[ "$SR_DB_ENGINE" != mysql ]]; then
      SR_REFUSAL=engine_unsupported; error "The dump can be imported into MySQL only; ${domain} uses ${SR_DB_ENGINE}"
      return 1
    fi
    if [[ "$SR_TABLES" == -1 ]]; then
      SR_REFUSAL=database_unreadable; error "Cannot read the site database as root"
      return 1
    fi
  fi
  if [[ "$overwrite" != yes ]]; then
    if [[ -n "$SR_DUMP" ]] && (( SR_TABLES > 0 )); then
      SR_REFUSAL=database_not_empty; error "The database ${SR_DB_NAME} is not empty (${SR_TABLES} tables); rerun with --overwrite yes (a backup is taken first)"
      return 1
    fi
    if [[ "$SR_HAS_FILES" == yes ]]; then
      SR_REFUSAL=files_present; error "${SR_DOC_ROOT} already has files; rerun with --overwrite yes (a backup is taken first)"
      return 1
    fi
  fi
  if [[ "$overwrite" == yes ]] && { { [[ -n "$SR_DUMP" ]] && (( SR_TABLES > 0 )); } || [[ "$SR_HAS_FILES" == yes ]]; }; then
    SR_BACKUP=yes
  fi
  return 0
}

# What the check found, for the panel (simai-site-restore-plan/1).
site_restore_plan_json() {
  python3 -I -c '
import json, sys
(refusal, root, doc_root, public_dir, files, dump, db_exists, engine, name, tables, has_files, backup, overwrite) = sys.argv[1:14]
def rel(p):
    return p[len(root) + 1:] if root and p.startswith(root + "/") else (p or None)
print(json.dumps({"refusal": refusal or None, "restore": {
    "schema": "simai-site-restore-plan/1", "root": root or None, "doc_root": doc_root or None,
    "public_dir": public_dir or None, "files": rel(files), "dump": rel(dump),
    "database": {"exists": db_exists == "yes", "engine": engine or None, "name": name or None,
                 "tables": int(tables) if tables.lstrip("-").isdigit() and int(tables) >= 0 and engine == "mysql" else None},
    "files_present": has_files == "yes", "overwrite": overwrite == "yes", "backup": backup == "yes"}}))' \
    "$SR_REFUSAL" "$SR_ROOT" "$SR_DOC_ROOT" "$SR_PUBLIC_DIR" "$SR_FILES" "$SR_DUMP" "$SR_DB_EXISTS" "$SR_DB_ENGINE" \
    "$SR_DB_NAME" "$SR_TABLES" "$SR_HAS_FILES" "$SR_BACKUP" "$SR_OVERWRITE"
}

site_restore_plan_check() {
  local overwrite rc=0
  overwrite=$(command_arg overwrite "$@")
  [[ "${overwrite,,}" == yes ]] && overwrite=yes || overwrite=no
  site_restore_precheck "$(command_arg domain "$@")" "$(command_arg files "$@")" "$(command_arg dump "$@")" "$overwrite" || rc=$?
  site_plan_data_write "$(site_restore_plan_json)"
  return "$rc"
}

# Where the archive goes: the site root when it carries the web root folder
# itself (for example public/index.php), the web root otherwise.
site_restore_target() {
  local src="$1"
  if [[ -n "$SR_PUBLIC_DIR" && "$SR_DOC_ROOT" != "$SR_ROOT" && -d "${src}/${SR_PUBLIC_DIR}" && ! -L "${src}/${SR_PUBLIC_DIR}" ]] \
    && [[ ! -f "${src}/index.php" && ! -f "${src}/index.html" ]]; then
    printf '%s\n' "$SR_ROOT"
  else
    printf '%s\n' "$SR_DOC_ROOT"
  fi
}

# Moves a restore source out of the web root into the site's trash.
site_restore_trash_source() {
  local path="$1" rel
  [[ -n "$path" && -f "$path" ]] || return 0
  rel="${path#"$(realpath -e -- "$SR_ROOT")"/}"
  run_command file remove --domain "$SR_DOMAIN" --path "$rel" --confirm yes >/dev/null 2>&1
}

site_restore_ready_handler() {
  parse_kv_args "$@"
  require_args "domain files" || return 1
  local domain="${PARSED_ARGS[domain]}" files="${PARSED_ARGS[files]}" dump="${PARSED_ARGS[dump]:-}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}" confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${overwrite,,}" == yes ]] && overwrite=yes || overwrite=no
  site_restore_precheck "$domain" "$files" "$dump" "$overwrite" || return 1
  if [[ "${confirm,,}" != yes ]]; then
    ui_header "SIMAI ENV · PHP site restore (plan)"
    local -a rows=("Domain|${SR_DOMAIN}" "Files|${SR_FILES} -> ${SR_DOC_ROOT} (or the site root when the archive has ${SR_PUBLIC_DIR}/), unpacked as ${SIMAI_USER}")
    if [[ -n "$SR_DUMP" ]]; then
      rows+=("Dump|${SR_DUMP} -> database ${SR_DB_NAME} (site credentials)")
      local db_now="${SR_TABLES} table(s)"
      if [[ "$SR_BACKUP" == yes && "$SR_TABLES" -gt 0 ]]; then db_now+=", backed up, then replaced"; fi
      rows+=("Database now|${db_now}")
    else
      rows+=("Dump|none")
    fi
    local files_now="none"
    [[ "$SR_HAS_FILES" != yes ]] || files_now="present, backed up, then overwritten"
    rows+=("Files now|${files_now}")
    rows+=("Then|archive and dump to the site's trash; the site's config must use the credentials of db.env")
    ui_result_table "${rows[@]}"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  ui_header "SIMAI ENV · PHP site restore"
  progress_init 4
  local backup_status="not needed" rc=0
  if [[ "$SR_BACKUP" == yes ]]; then
    progress_step "Backing up the current site"
    local -a b=(backup data --domain "$SR_DOMAIN" --files yes --confirm yes)
    [[ -n "$SR_DUMP" && -n "$SR_DB_NAME" ]] && b+=(--db yes)
    run_command "${b[@]}" || { error "Backup failed; nothing restored"; return 1; }
    backup_status="taken (backup data)"
    if [[ -n "$SR_DUMP" ]] && (( SR_TABLES > 0 )); then
      mysql_root_exec_stdin "DROP DATABASE \`${SR_DB_NAME}\`; CREATE DATABASE \`${SR_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        || { error "Cannot empty the database ${SR_DB_NAME}"; return 1; }
    fi
  fi

  progress_step "Unpacking files as ${SIMAI_USER}"
  local staging src target
  staging="${SR_ROOT}/.site-restore-$(date +%Y%m%d%H%M%S)-$$"
  install -d -m 0700 -o "$SIMAI_USER" -g "$SIMAI_WEB_GROUP" "$staging" || { error "Cannot create ${staging}"; return 1; }
  if ! restore_unpack_as_user "$SR_FILES" "$staging"; then
    rm -rf --one-file-system -- "$staging"
    error "Cannot unpack ${SR_FILES} (see ${LOG_FILE})"
    return 1
  fi
  src=$(restore_archive_top "$staging")
  target=$(site_restore_target "$src")
  rc=0
  # Copy the entries, not "${src}/.": that would give the target the
  # staging directory's 0700 mode. From inside $src: the site user cannot
  # return to root's working directory.
  # shellcheck disable=SC2024 # root opens the log; the copy runs as the site user
  (cd "$src" && sudo -u "$SIMAI_USER" -H find . -mindepth 1 -maxdepth 1 -exec cp -af -- {} "${target}/" \;) >>"$LOG_FILE" 2>&1 || rc=$?
  rm -rf --one-file-system -- "$staging"
  (( rc == 0 )) || { error "Cannot copy the restored files into ${target} (see ${LOG_FILE})"; return 1; }

  local db_status="no dump"
  if [[ -n "$SR_DUMP" ]]; then
    progress_step "Importing the dump as ${SIMAI_USER}"
    wp_restore_import_dump "$SR_DOMAIN" "$SR_DUMP" "$SR_DUMP_GZ" || { error "Database import failed (see ${LOG_FILE})"; return 1; }
    db_status="${SR_DB_NAME}: $(wp_db_table_count "$SR_DB_NAME") table(s) from $(basename "$SR_DUMP")"
  fi

  progress_step "Moving the archive and the dump to the site's trash"
  site_restore_trash_source "$SR_FILES" || warn "The archive stays at ${SR_FILES}"
  site_restore_trash_source "$SR_DUMP" || warn "The dump stays at ${SR_DUMP}"
  progress_done "PHP site restored"

  ui_result_table \
    "Domain|${SR_DOMAIN}" \
    "Backup before|${backup_status}" \
    "Files|$(basename "$SR_FILES") -> ${target}" \
    "Database|${db_status}"
  ui_next_steps
  [[ -z "$SR_DUMP" ]] || ui_kv "Config" "point the site's own config at the database of /etc/simai-env/sites/${SR_DOMAIN}/db.env (names: site db-status)"
  ui_kv "Check" "simai-admin.sh site doctor --domain ${SR_DOMAIN}"
  return 0
}

register_cmd "site" "restore-ready" "Restore a PHP site (generic profile) from a files archive and an optional SQL dump" "site_restore_ready_handler" "domain files" "dump= overwrite= confirm=" "plan:handler"
