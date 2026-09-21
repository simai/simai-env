#!/usr/bin/env bash

observer_slug() {
  project_slug_from_domain "$1"
}

observer_base() {
  printf '%s\n' "${SIMAI_OBSERVER_ROOT:-/var/lib/simai-env/runtime-observer}"
}

observer_root() {
  printf '%s/%s\n' "$(observer_base)" "$(observer_slug "$1")"
}

# The observer runs as root from cron, so every directory it trusts must be
# root-owned and not writable by site users (PHP-FPM runs as SIMAI_USER).
observer_path_is_trusted() {
  local path="$1" owner mode
  [[ -e "$path" && ! -L "$path" ]] || return 1
  owner=$(stat -c '%u' "$path" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$path" 2>/dev/null) || return 1
  [[ "$owner" == 0 ]] || return 1
  (( (8#$mode & 8#022) == 0 ))
}

observer_assert_trusted_root() {
  local root="$1" path
  path="$root"
  while [[ -n "$path" && "$path" != / ]]; do
    if [[ -e "$path" || -L "$path" ]]; then
      observer_path_is_trusted "$path" || {
        error "Observer path is not root-owned or is writable by others: ${path}"
        return 1
      }
    fi
    path=$(dirname "$path")
  done
}

observer_prepare_base() {
  local base
  base=$(observer_base)
  install -d -m 0700 -o root -g root "$base" || return 1
  observer_assert_trusted_root "$base"
}

observer_git() {
  git -c core.hooksPath=/dev/null -c core.fsmonitor=false "$@"
}

# Reads state/active.env without executing it. Sets SESSION_* variables.
observer_read_session() {
  local file="$1" key value
  SESSION_ACTOR='' SESSION_STARTED_AT='' SESSION_BASE_COMMIT=''
  [[ -f "$file" && ! -L "$file" ]] || return 1
  while IFS='=' read -r key value; do
    case "$key" in
      SESSION_ACTOR) [[ "$value" =~ ^[A-Za-z0-9._@-]+$ ]] && SESSION_ACTOR="$value" ;;
      SESSION_STARTED_AT) [[ "$value" =~ ^[0-9T:Z-]+$ ]] && SESSION_STARTED_AT="$value" ;;
      SESSION_BASE_COMMIT) [[ "$value" =~ ^[0-9a-f]{40,64}$ ]] && SESSION_BASE_COMMIT="$value" ;;
    esac
  done <"$file"
  [[ -n "$SESSION_ACTOR" && -n "$SESSION_BASE_COMMIT" ]]
}

observer_load_site() {
  local domain="$1" out_name="$2"
  validate_domain "$domain" || return 1
  require_site_exists "$domain" || return 1

  local cfg="/etc/nginx/sites-available/${domain}.conf"
  site_nginx_metadata_parse "$cfg" "$out_name" || {
    error "Cannot read SIMAI metadata from ${cfg}"
    return 1
  }
  local -n out="$out_name"
  [[ -n "${out[root]:-}" && -d "${out[root]}" ]] || {
    error "Invalid project root in ${cfg}: ${out[root]:-missing}"
    return 1
  }
}

observer_require_tools() {
  local tool
  for tool in git rsync mysql mysqldump flock sha256sum find; do
    command -v "$tool" >/dev/null 2>&1 || {
      error "Runtime observer requires ${tool}"
      return 1
    }
  done
}

observer_write_config() {
  local domain="$1" root="$2" project_root="$3"
  install -d -m 0700 -o root -g root "$root" || return 1
  mkdir -p "${root}/state" "${root}/repo/files" "${root}/repo/database" "${root}/repo/evidence"
  cat >"${root}/state/config.env" <<EOF
OBSERVER_DOMAIN=${domain}
OBSERVER_PROJECT_ROOT=${project_root}
OBSERVER_CREATED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
  chmod 0700 "$root" "${root}/state"
  chmod 0600 "${root}/state/config.env"
}

observer_assert_no_secrets() {
  local files_root="$1"
  local forbidden
  forbidden=$(find "$files_root" -type f \( \
    -name '.env' -o -name '.env.*' -o -name '.settings.php' -o \
    -name 'dbconn.php' -o -name 'wp-config.php' -o -name '*.pem' -o -name '*.key' -o \
    -name 'id_rsa' -o -name 'id_ed25519' \
  \) -print -quit)
  if [[ -n "$forbidden" ]]; then
    error "Secret-bearing file entered observer snapshot: ${forbidden}"
    return 1
  fi
}

observer_sync_files() {
  local project_root="$1" repo="$2"
  mkdir -p "${repo}/files"
  rsync -a --delete --links \
    --exclude='/.git/' \
    --exclude='/.env' --exclude='/.env.*' \
    --exclude='/public/bitrix/' --exclude='/public/upload/' \
    --exclude='/public/local/cache/' --exclude='/public/local/managed_cache/' \
    --exclude='/public/local/stack_cache/' --exclude='/public/local/logs/' \
    --exclude='/public/bitrix/cache/' --exclude='/public/bitrix/managed_cache/' \
    --exclude='/public/bitrix/stack_cache/' --exclude='/public/bitrix/backup/' \
    --exclude='/public/bitrix/php_interface/dbconn.php' \
    --exclude='/public/bitrix/.settings.php' \
    --exclude='wp-config.php' \
    --exclude='/storage/logs/' --exclude='/var/' --exclude='/tmp/' \
    --exclude='*.log' --exclude='*.sql' --exclude='*.sql.gz' \
    --exclude='*.tar' --exclude='*.tar.gz' --exclude='*.zip' \
    "${project_root}/" "${repo}/files/" || return 1
  observer_assert_no_secrets "${repo}/files" || return 1

  {
    printf 'path\ttarget\tresolved\tgit_commit\n'
    while IFS= read -r -d '' link; do
      local rel target resolved commit='-'
      rel="${link#"${project_root}"/}"
      target=$(readlink "$link")
      resolved=$(readlink -f "$link" 2>/dev/null || true)
      if [[ -n "$resolved" ]]; then
        local candidate="$resolved"
        [[ -f "$candidate" ]] && candidate=$(dirname "$candidate")
        commit=$(observer_git -C "$candidate" rev-parse HEAD 2>/dev/null || printf '-')
      fi
      printf '%s\t%s\t%s\t%s\n' "$rel" "$target" "$resolved" "$commit"
    done < <(find "$project_root" -type l -print0 | sort -z)
  } >"${repo}/evidence/symlinks.tsv" || return 1
}

observer_db_env() {
  local domain="$1"
  local env_file="/etc/simai-env/sites/${domain}/db.env"
  [[ -r "$env_file" ]] || {
    error "DB environment not found: ${env_file}"
    return 1
  }
  # shellcheck disable=SC1090
  set -a; source "$env_file"; set +a
  : "${DB_NAME:?DB_NAME missing in ${env_file}}"
  : "${DB_USER:?DB_USER missing in ${env_file}}"
  DB_PASSWORD="${DB_PASSWORD:-${DB_PASS:-}}"
  : "${DB_PASSWORD:?DB_PASS or DB_PASSWORD missing in ${env_file}}"
  DB_HOST="${DB_HOST:-127.0.0.1}"
}

observer_mysql() {
  MYSQL_PWD="$DB_PASSWORD" mysql --batch --raw --skip-column-names \
    -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" "$@"
}

observer_dump_table() {
  local out="$1" table="$2" where="${3:-}"
  local args=(--skip-comments --compact --no-create-info --skip-triggers --hex-blob --no-tablespaces
    --complete-insert --order-by-primary -h "$DB_HOST" -u "$DB_USER" "$DB_NAME" "$table")
  [[ -n "$where" ]] && args+=(--where="$where")
  MYSQL_PWD="$DB_PASSWORD" mysqldump "${args[@]}" >"$out"
}

observer_sync_database() {
  local domain="$1" repo="$2"
  observer_db_env "$domain" || return 1
  local db_dir="${repo}/database"
  rm -rf "$db_dir"
  mkdir -p "$db_dir/metadata" "$db_dir/camp"

  local structural=(b_iblock_type b_iblock b_iblock_property b_iblock_property_enum
    b_user_field b_user_field_lang b_highloadblock_highload_block
    b_hlblock_entity b_hlblock_entity_lang b_hlblock_entity_rights)
  local table
  for table in "${structural[@]}"; do
    if observer_mysql -e "SHOW TABLES LIKE '${table}'" | grep -Fxq "$table"; then
      observer_dump_table "${db_dir}/metadata/${table}.sql" "$table"
    fi
  done

  local camp_ids camp_id_csv
  camp_ids=$(observer_mysql -e "SELECT ID FROM b_iblock WHERE IBLOCK_TYPE_ID='camp' OR CODE LIKE 'camp-%' ORDER BY ID" | tr '\n' ' ' | xargs || true)
  camp_id_csv=${camp_ids// /,}
  printf 'camp_iblock_ids=%s\n' "$camp_ids" >"${db_dir}/camp/scope.txt"
  if [[ -n "$camp_id_csv" ]]; then
    observer_dump_table "${db_dir}/camp/b_iblock.sql" b_iblock "ID IN (${camp_id_csv})"
    observer_dump_table "${db_dir}/camp/b_iblock_property.sql" b_iblock_property "IBLOCK_ID IN (${camp_id_csv})"
    observer_dump_table "${db_dir}/camp/b_iblock_section.sql" b_iblock_section "IBLOCK_ID IN (${camp_id_csv})"
    observer_dump_table "${db_dir}/camp/b_iblock_element.sql" b_iblock_element "IBLOCK_ID IN (${camp_id_csv})"
    local property_ids property_id_csv
    property_ids=$(observer_mysql -e "SELECT ID FROM b_iblock_property WHERE IBLOCK_ID IN (${camp_id_csv}) ORDER BY ID" | tr '\n' ' ' | xargs || true)
    property_id_csv=${property_ids// /,}
    if [[ -n "$property_id_csv" ]]; then
      observer_dump_table "${db_dir}/camp/b_iblock_property_enum.sql" b_iblock_property_enum "PROPERTY_ID IN (${property_id_csv})"
    fi
  fi

  if observer_mysql -e "SHOW TABLES LIKE 'b_option'" | grep -Fxq b_option; then
    observer_mysql -e "SELECT MODULE_ID,NAME,COALESCE(SITE_ID,''),SHA2(VALUE,256) FROM b_option WHERE MODULE_ID LIKE 'simai.%' ORDER BY MODULE_ID,NAME,SITE_ID" \
      >"${db_dir}/metadata/simai_option_hashes.tsv"
  fi

  local hl_registry=''
  if observer_mysql -e "SHOW TABLES LIKE 'b_highloadblock_highload_block'" | grep -Fxq b_highloadblock_highload_block; then
    hl_registry='b_highloadblock_highload_block'
  elif observer_mysql -e "SHOW TABLES LIKE 'b_hlblock_entity'" | grep -Fxq b_hlblock_entity; then
    hl_registry='b_hlblock_entity'
  fi
  if [[ -n "$hl_registry" ]]; then
    observer_mysql -e "SELECT ID,NAME,TABLE_NAME FROM ${hl_registry} WHERE LOWER(NAME) LIKE '%camp%' OR LOWER(TABLE_NAME) LIKE '%camp%' ORDER BY ID" \
      >"${db_dir}/camp/highload_blocks.tsv"
    while IFS=$'\t' read -r hl_id _hl_name hl_table; do
      [[ -n "$hl_id" ]] || continue
      observer_dump_table "${db_dir}/camp/hl_${hl_id}_user_fields.sql" b_user_field "ENTITY_ID='HLBLOCK_${hl_id}'"
      while IFS= read -r data_table; do
        [[ -n "$data_table" ]] || continue
        observer_mysql -e "SHOW CREATE TABLE \`${data_table}\`" >"${db_dir}/camp/hl_${hl_id}_${data_table}_schema.tsv"
        observer_dump_table "${db_dir}/camp/hl_${hl_id}_${data_table}_data.sql" "$data_table"
      done < <(observer_mysql -e "SHOW TABLES LIKE '${hl_table}%'")
    done <"${db_dir}/camp/highload_blocks.tsv"
  fi

  unset DB_PASSWORD DB_PASS MYSQL_PWD
}

observer_snapshot_sync() {
  local domain="$1" root="$2"
  declare -A meta=()
  observer_assert_trusted_root "$root" || return 1
  observer_load_site "$domain" meta || return 1
  observer_sync_files "${meta[root]}" "${root}/repo" || return 1
  observer_sync_database "$domain" "${root}/repo" || return 1
  rm -f "${root}/repo/evidence/last_snapshot_at.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${root}/state/last_snapshot_at.txt"
}

observer_actor() {
  local root="$1" requested="${2:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
  elif [[ -e "${root}/state/active.env" ]]; then
    if observer_read_session "${root}/state/active.env"; then
      printf '%s\n' "$SESSION_ACTOR"
    else
      printf '%s\n' unknown
    fi
  else
    printf '%s\n' unattributed
  fi
}

observer_commit() {
  local root="$1" actor="$2" reason="$3"
  local repo="${root}/repo"
  observer_git -C "$repo" add -A || return 1
  if observer_git -C "$repo" diff --cached --quiet; then
    return 0
  fi
  observer_git -C "$repo" -c user.name='SIMAI Runtime Observer' -c user.email='runtime-observer@localhost' \
    commit -m "snapshot: ${reason}" -m "Actor: ${actor}" >/dev/null
}

observer_init_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" schedule="${PARSED_ARGS[schedule]:-yes}"
  require_args domain || return 1
  observer_require_tools || return 1
  declare -A meta=()
  observer_load_site "$domain" meta || return 1
  observer_prepare_base || return 1
  local root
  root=$(observer_root "$domain")
  [[ ! -e "$root" ]] || {
    error "Observer already exists: ${root}"
    return 1
  }
  observer_write_config "$domain" "$root" "${meta[root]}" || return 1
  observer_git -C "${root}/repo" init -q || return 1
  printf '%s\n' 'Private runtime evidence. Do not publish this repository.' >"${root}/repo/README"
  observer_snapshot_sync "$domain" "$root" || return 1
  observer_commit "$root" system baseline || return 1
  chmod -R go-rwx "$root"
  if [[ "${schedule,,}" == yes ]]; then
    local cron
    cron="/etc/cron.d/simai-runtime-observer-$(observer_slug "$domain")"
    printf '*/5 * * * * root %q observer snapshot --domain %q >/dev/null 2>&1\n' "${SIMAI_ENV_ROOT}/simai-admin.sh" "$domain" >"$cron"
    chmod 0644 "$cron"
  fi
  info "Runtime observer initialized at ${root}"
}

observer_start_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" actor="${PARSED_ARGS[actor]:-}" note="${PARSED_ARGS[note]:-}"
  require_args domain actor || return 1
  [[ "$actor" =~ ^[A-Za-z0-9._@-]+$ ]] || { error 'Actor contains unsupported characters'; return 1; }
  local root lock
  root=$(observer_root "$domain")
  [[ -d "${root}/repo/.git" ]] || { error "Observer is not initialized for ${domain}"; return 1; }
  observer_assert_trusted_root "$root" || return 1
  lock="${root}/state/lock"
  exec 9>"$lock"; flock -n 9 || { error "Observer is busy"; return 1; }
  [[ ! -e "${root}/state/active.env" ]] || { error "A change session is already active"; return 1; }
  observer_snapshot_sync "$domain" "$root" || return 1
  observer_commit "$root" unattributed pre-session || return 1
  (umask 077; cat >"${root}/state/active.env" <<EOF
SESSION_ACTOR=${actor}
SESSION_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SESSION_BASE_COMMIT=$(observer_git -C "${root}/repo" rev-parse HEAD)
SESSION_NOTE_B64=$(printf '%s' "$note" | base64 | tr -d '\n')
EOF
  ) || return 1
  chmod 0600 "${root}/state/active.env"
  info "Change session started for ${actor}; base=$(observer_git -C "${root}/repo" rev-parse --short HEAD)"
}

observer_snapshot_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" actor="${PARSED_ARGS[actor]:-}" reason="${PARSED_ARGS[reason]:-periodic}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  [[ -d "${root}/repo/.git" ]] || { error "Observer is not initialized for ${domain}"; return 1; }
  observer_assert_trusted_root "$root" || return 1
  lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
  actor=$(observer_actor "$root" "$actor")
  observer_snapshot_sync "$domain" "$root" || return 1
  observer_commit "$root" "$actor" "$reason" || return 1
  info "Snapshot complete; head=$(observer_git -C "${root}/repo" rev-parse --short HEAD), actor=${actor}"
}

observer_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" refresh="${PARSED_ARGS[refresh]:-yes}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  [[ -d "${root}/repo/.git" ]] || { error "Observer is not initialized for ${domain}"; return 1; }
  observer_assert_trusted_root "$root" || return 1
  if [[ "${refresh,,}" == yes ]]; then
    lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
    observer_snapshot_sync "$domain" "$root" || return 1
  fi
  local session='none' base='HEAD'
  if [[ -e "${root}/state/active.env" ]] && observer_read_session "${root}/state/active.env"; then
    session="${SESSION_ACTOR} since ${SESSION_STARTED_AT}"
    base="${SESSION_BASE_COMMIT}"
  fi
  print_kv_table "Observer|${root}" "Session|${session}" "HEAD|$(observer_git -C "${root}/repo" rev-parse --short HEAD)"
  observer_git -C "${root}/repo" status --short
  echo "Diff from session base:"
  observer_git -C "${root}/repo" diff --stat "$base" -- .
}

observer_finish_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" note="${PARSED_ARGS[note]:-completed}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  observer_assert_trusted_root "$root" || return 1
  [[ -e "${root}/state/active.env" ]] || { error "No active change session"; return 1; }
  lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
  observer_read_session "${root}/state/active.env" || { error "Active session file is invalid"; return 1; }
  observer_snapshot_sync "$domain" "$root" || return 1
  observer_commit "$root" "$SESSION_ACTOR" "session-finish ${note}" || return 1
  local head
  head=$(observer_git -C "${root}/repo" rev-parse HEAD)
  {
    printf 'actor=%s\nstarted_at=%s\nfinished_at=%s\nbase=%s\nhead=%s\nnote=%s\n' \
      "$SESSION_ACTOR" "$SESSION_STARTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$SESSION_BASE_COMMIT" "$head" "$note"
    printf '\nchanged_files:\n'
    observer_git -C "${root}/repo" diff --name-status "$SESSION_BASE_COMMIT" "$head"
  } >"${root}/repo/evidence/session-${head:0:12}.txt"
  observer_git -C "${root}/repo" add "evidence/session-${head:0:12}.txt"
  observer_git -C "${root}/repo" -c user.name='SIMAI Runtime Observer' -c user.email='runtime-observer@localhost' \
    commit -m "evidence: close session ${SESSION_ACTOR}" >/dev/null
  rm -f "${root}/state/active.env"
  info "Change session closed; head=$(observer_git -C "${root}/repo" rev-parse --short HEAD)"
}

observer_doctor_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args domain || return 1
  local root cron failed=0
  root=$(observer_root "$domain")
  cron="/etc/cron.d/simai-runtime-observer-$(observer_slug "$domain")"
  if observer_assert_trusted_root "$root" 2>/dev/null; then echo 'PASS root-owned storage'; else echo "FAIL storage is writable by non-root users: ${root}"; failed=1; fi
  if [[ -d "${root}/repo/.git" ]]; then echo 'PASS repository'; else echo 'FAIL repository'; failed=1; fi
  if [[ -r "${root}/state/config.env" ]]; then echo 'PASS config'; else echo 'FAIL config'; failed=1; fi
  if [[ ! -e "${root}/repo/files/.env" ]]; then echo 'PASS secret exclusions'; else echo 'FAIL secret exclusions'; failed=1; fi
  if observer_git -C "${root}/repo" fsck --no-progress >/dev/null 2>&1; then echo 'PASS git fsck'; else echo 'FAIL git fsck'; failed=1; fi
  [[ -f "$cron" ]] && echo 'PASS schedule' || echo 'WARN schedule missing'
  return "$failed"
}

register_cmd observer init 'Initialize private file and Bitrix DB shadow repository' observer_init_handler domain 'schedule=yes' 'tier:advanced'
register_cmd observer start 'Start an attributed developer change session' observer_start_handler 'domain actor' 'note=' 'tier:advanced'
register_cmd observer snapshot 'Capture and commit the current runtime state' observer_snapshot_handler domain 'actor= reason=periodic' 'tier:advanced menu:hidden'
register_cmd observer status 'Show changes from the active session baseline' observer_status_handler domain 'refresh=yes' 'tier:advanced'
register_cmd observer finish 'Finish a change session and write evidence' observer_finish_handler domain 'note=completed' 'tier:advanced'
register_cmd observer doctor 'Validate observer repository and schedule' observer_doctor_handler domain '' 'tier:advanced'
