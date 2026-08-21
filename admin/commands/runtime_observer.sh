#!/usr/bin/env bash

observer_slug() {
  project_slug_from_domain "$1"
}

observer_root() {
  printf '%s/%s\n' "${SIMAI_OBSERVER_ROOT:-/home/simai/runtime-observer}" "$(observer_slug "$1")"
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
    -name 'dbconn.php' -o -name '*.pem' -o -name '*.key' -o \
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
    --exclude='/storage/logs/' --exclude='/var/' --exclude='/tmp/' \
    --exclude='*.log' --exclude='*.sql' --exclude='*.sql.gz' \
    --exclude='*.tar' --exclude='*.tar.gz' --exclude='*.zip' \
    "${project_root}/" "${repo}/files/"
  observer_assert_no_secrets "${repo}/files"

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
        commit=$(git -C "$candidate" rev-parse HEAD 2>/dev/null || printf '-')
      fi
      printf '%s\t%s\t%s\t%s\n' "$rel" "$target" "$resolved" "$commit"
    done < <(find "$project_root" -type l -print0 | sort -z)
  } >"${repo}/evidence/symlinks.tsv"
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
  observer_db_env "$domain"
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
  observer_load_site "$domain" meta
  observer_sync_files "${meta[root]}" "${root}/repo"
  observer_sync_database "$domain" "${root}/repo"
  rm -f "${root}/repo/evidence/last_snapshot_at.txt"
  date -u +%Y-%m-%dT%H:%M:%SZ >"${root}/state/last_snapshot_at.txt"
}

observer_actor() {
  local root="$1" requested="${2:-}"
  if [[ -n "$requested" ]]; then
    printf '%s\n' "$requested"
  elif [[ -r "${root}/state/active.env" ]]; then
    # shellcheck disable=SC1090
    source "${root}/state/active.env"
    printf '%s\n' "${SESSION_ACTOR:-unknown}"
  else
    printf '%s\n' unattributed
  fi
}

observer_commit() {
  local root="$1" actor="$2" reason="$3"
  local repo="${root}/repo"
  git -C "$repo" add -A
  if git -C "$repo" diff --cached --quiet; then
    return 0
  fi
  git -C "$repo" -c user.name='SIMAI Runtime Observer' -c user.email='runtime-observer@localhost' \
    commit -m "snapshot: ${reason}" -m "Actor: ${actor}" >/dev/null
}

observer_init_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" schedule="${PARSED_ARGS[schedule]:-yes}"
  require_args domain || return 1
  observer_require_tools
  declare -A meta=()
  observer_load_site "$domain" meta
  local root
  root=$(observer_root "$domain")
  [[ ! -e "$root" ]] || {
    error "Observer already exists: ${root}"
    return 1
  }
  observer_write_config "$domain" "$root" "${meta[root]}"
  git -C "${root}/repo" init -q
  printf '%s\n' 'Private runtime evidence. Do not publish this repository.' >"${root}/repo/README"
  observer_snapshot_sync "$domain" "$root"
  observer_commit "$root" system baseline
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
  lock="${root}/state/lock"
  exec 9>"$lock"; flock -n 9 || { error "Observer is busy"; return 1; }
  [[ ! -e "${root}/state/active.env" ]] || { error "A change session is already active"; return 1; }
  observer_snapshot_sync "$domain" "$root"
  observer_commit "$root" unattributed pre-session
  cat >"${root}/state/active.env" <<EOF
SESSION_ACTOR=${actor}
SESSION_STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SESSION_BASE_COMMIT=$(git -C "${root}/repo" rev-parse HEAD)
SESSION_NOTE_B64=$(printf '%s' "$note" | base64 | tr -d '\n')
EOF
  chmod 0600 "${root}/state/active.env"
  info "Change session started for ${actor}; base=$(git -C "${root}/repo" rev-parse --short HEAD)"
}

observer_snapshot_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" actor="${PARSED_ARGS[actor]:-}" reason="${PARSED_ARGS[reason]:-periodic}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  [[ -d "${root}/repo/.git" ]] || { error "Observer is not initialized for ${domain}"; return 1; }
  lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
  actor=$(observer_actor "$root" "$actor")
  observer_snapshot_sync "$domain" "$root"
  observer_commit "$root" "$actor" "$reason"
  info "Snapshot complete; head=$(git -C "${root}/repo" rev-parse --short HEAD), actor=${actor}"
}

observer_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" refresh="${PARSED_ARGS[refresh]:-yes}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  [[ -d "${root}/repo/.git" ]] || { error "Observer is not initialized for ${domain}"; return 1; }
  if [[ "${refresh,,}" == yes ]]; then
    lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
    observer_snapshot_sync "$domain" "$root"
  fi
  local session='none' base='HEAD'
  if [[ -r "${root}/state/active.env" ]]; then
    # shellcheck disable=SC1090
    source "${root}/state/active.env"
    session="${SESSION_ACTOR} since ${SESSION_STARTED_AT}"
    base="${SESSION_BASE_COMMIT}"
  fi
  print_kv_table "Observer|${root}" "Session|${session}" "HEAD|$(git -C "${root}/repo" rev-parse --short HEAD)"
  git -C "${root}/repo" status --short
  echo "Diff from session base:"
  git -C "${root}/repo" diff --stat "$base" -- .
}

observer_finish_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" note="${PARSED_ARGS[note]:-completed}"
  require_args domain || return 1
  local root lock
  root=$(observer_root "$domain")
  [[ -r "${root}/state/active.env" ]] || { error "No active change session"; return 1; }
  lock="${root}/state/lock"; exec 9>"$lock"; flock -w 60 9 || { error "Observer is busy"; return 1; }
  # shellcheck disable=SC1090
  source "${root}/state/active.env"
  observer_snapshot_sync "$domain" "$root"
  observer_commit "$root" "$SESSION_ACTOR" "session-finish ${note}"
  local head
  head=$(git -C "${root}/repo" rev-parse HEAD)
  {
    printf 'actor=%s\nstarted_at=%s\nfinished_at=%s\nbase=%s\nhead=%s\nnote=%s\n' \
      "$SESSION_ACTOR" "$SESSION_STARTED_AT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$SESSION_BASE_COMMIT" "$head" "$note"
    printf '\nchanged_files:\n'
    git -C "${root}/repo" diff --name-status "$SESSION_BASE_COMMIT" "$head"
  } >"${root}/repo/evidence/session-${head:0:12}.txt"
  git -C "${root}/repo" add "evidence/session-${head:0:12}.txt"
  git -C "${root}/repo" -c user.name='SIMAI Runtime Observer' -c user.email='runtime-observer@localhost' \
    commit -m "evidence: close session ${SESSION_ACTOR}" >/dev/null
  rm -f "${root}/state/active.env"
  info "Change session closed; head=$(git -C "${root}/repo" rev-parse --short HEAD)"
}

observer_doctor_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args domain || return 1
  local root cron failed=0
  root=$(observer_root "$domain")
  cron="/etc/cron.d/simai-runtime-observer-$(observer_slug "$domain")"
  if [[ -d "${root}/repo/.git" ]]; then echo 'PASS repository'; else echo 'FAIL repository'; failed=1; fi
  if [[ -r "${root}/state/config.env" ]]; then echo 'PASS config'; else echo 'FAIL config'; failed=1; fi
  if [[ ! -e "${root}/repo/files/.env" ]]; then echo 'PASS secret exclusions'; else echo 'FAIL secret exclusions'; failed=1; fi
  if git -C "${root}/repo" fsck --no-progress >/dev/null 2>&1; then echo 'PASS git fsck'; else echo 'FAIL git fsck'; failed=1; fi
  [[ -f "$cron" ]] && echo 'PASS schedule' || echo 'WARN schedule missing'
  return "$failed"
}

register_cmd observer init 'Initialize private file and Bitrix DB shadow repository' observer_init_handler domain 'schedule=yes' 'tier:advanced'
register_cmd observer start 'Start an attributed developer change session' observer_start_handler 'domain actor' 'note=' 'tier:advanced'
register_cmd observer snapshot 'Capture and commit the current runtime state' observer_snapshot_handler domain 'actor= reason=periodic' 'tier:advanced menu:hidden'
register_cmd observer status 'Show changes from the active session baseline' observer_status_handler domain 'refresh=yes' 'tier:advanced'
register_cmd observer finish 'Finish a change session and write evidence' observer_finish_handler domain 'note=completed' 'tier:advanced'
register_cmd observer doctor 'Validate observer repository and schedule' observer_doctor_handler domain '' 'tier:advanced'
