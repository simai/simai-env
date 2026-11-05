#!/usr/bin/env bash
# shellcheck disable=SC2034 # BACKUP_OFFSITE_RESULT is read by backup data
set -euo pipefail

# Off-site storages for data backups: S3 and S3-compatible object storage
# (AWS, Yandex Object Storage, Selectel, VK Cloud, Cloudflare R2, Backblaze B2,
# MinIO). Each data backup is uploaded to the default storage after it is
# made; the storage keeps the newest --keep backups of each site. Copies can be
# listed and fetched back, also on a new server, then restored as usual.
# Transfers use rclone with its configuration in the environment only.
#
# Storages: /etc/simai-env/backup-storages/<name>.env (root, 0600; holds the
# access keys). Upload results: /var/lib/simai-env/backup-offsite/<domain>.json.

BACKUP_STORAGE_DIR="${SIMAI_BACKUP_STORAGE_DIR:-/etc/simai-env/backup-storages}"
BACKUP_OFFSITE_STATE="${SIMAI_BACKUP_OFFSITE_STATE:-/var/lib/simai-env/backup-offsite}"
BACKUP_STORAGE_TEST_STATE="${SIMAI_BACKUP_STORAGE_TEST_STATE:-/var/lib/simai-env/backup-storage-tests}"

backup_storage_valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]]; }
backup_storage_file() { echo "${BACKUP_STORAGE_DIR}/$1.env"; }

backup_storage_get() {  # name key
  sed -n "s/^${2}=//p" "$(backup_storage_file "$1")" 2>/dev/null | tail -n1
}

# The default storage, if one is marked.
backup_storage_default() {
  local f
  for f in "${BACKUP_STORAGE_DIR}"/*.env; do
    [[ -f "$f" ]] || continue
    [[ "$(sed -n 's/^DEFAULT=//p' "$f" | tail -n1)" == yes ]] && { basename "$f" .env; return 0; }
  done
  return 0
}

backup_storage_require() {
  backup_storage_valid_name "$1" || { error "--name must be lowercase letters, digits and dashes (up to 32)"; return 1; }
  [[ -f "$(backup_storage_file "$1")" ]] || { error "No backup storage named $1 (backup storage-list)"; return 1; }
}

backup_rclone_ensure() {
  command -v rclone >/dev/null 2>&1 && return 0
  run_long "Installing rclone" env DEBIAN_FRONTEND=noninteractive apt-get install -y rclone || { error "Cannot install rclone"; return 1; }
}

# rclone with the storage as remote "simai:", configured from the environment
# only (keys never appear in the process arguments).
backup_rclone() {  # name args...
  local name="$1"; shift
  local endpoint provider=AWS
  endpoint=$(backup_storage_get "$name" ENDPOINT)
  [[ -z "$endpoint" ]] || provider=Other
  RCLONE_CONFIG=/dev/null \
  RCLONE_CONFIG_SIMAI_TYPE=s3 \
  RCLONE_CONFIG_SIMAI_PROVIDER="$provider" \
  RCLONE_CONFIG_SIMAI_ENV_AUTH=false \
  RCLONE_CONFIG_SIMAI_ACCESS_KEY_ID="$(backup_storage_get "$name" ACCESS_KEY_ID)" \
  RCLONE_CONFIG_SIMAI_SECRET_ACCESS_KEY="$(backup_storage_get "$name" SECRET_ACCESS_KEY)" \
  RCLONE_CONFIG_SIMAI_ENDPOINT="$endpoint" \
  RCLONE_CONFIG_SIMAI_REGION="$(backup_storage_get "$name" REGION)" \
  RCLONE_CONFIG_SIMAI_NO_CHECK_BUCKET=true \
    rclone --retries 3 --low-level-retries 5 --contimeout 15s --timeout 5m "$@"
}

# simai:<bucket>/<prefix>/<rest>
backup_storage_path() {  # name rest
  local bucket prefix
  bucket=$(backup_storage_get "$1" BUCKET); prefix=$(backup_storage_get "$1" PREFIX)
  printf 'simai:%s%s%s\n' "$bucket" "${prefix:+/${prefix}}" "${2:+/$2}"
}

# Writes, reads back and deletes a small object; prints the rclone error on failure.
backup_storage_probe() {
  local name="$1" tmp out probe
  tmp=$(mktemp -d)
  probe="simai-probe-$(date +%s)-$$.txt"
  echo "simai-env storage check $(date -u +%Y-%m-%dT%H:%M:%SZ)" >"${tmp}/${probe}"
  if ! out=$(backup_rclone "$name" copyto "${tmp}/${probe}" "$(backup_storage_path "$name" ".simai-probe/${probe}")" 2>&1) \
    || ! out=$(backup_rclone "$name" cat "$(backup_storage_path "$name" ".simai-probe/${probe}")" 2>&1 >/dev/null) \
    || ! out=$(backup_rclone "$name" deletefile "$(backup_storage_path "$name" ".simai-probe/${probe}")" 2>&1); then
    rm -rf -- "$tmp"
    grep -E 'ERROR|error|Failed|denied|NoSuch|InvalidAccessKey|SignatureDoesNotMatch' <<<"$out" | tail -n 3 | sed -E 's/[A-Za-z0-9/+=]{32,}/[hidden]/g' >&2 || true
    return 1
  fi
  rm -rf -- "$tmp"
}

backup_storage_record_test() {  # name ok error
  install -d -m 0700 "$BACKUP_STORAGE_TEST_STATE"
  ERR="$3" python3 -I -c 'import json,os,sys,time
print(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ok": sys.argv[1] == "yes",
                  "error": os.environ.get("ERR") or None}))' "$2" >"${BACKUP_STORAGE_TEST_STATE}/$1.json"
}

backup_storage_read_key_file() {  # option file pattern
  local opt="$1" f="$2" v
  [[ -n "$f" && -f "$f" && ! -L "$f" ]] || { error "--${opt} must be a file with the key"; return 1; }
  v=$(head -c 512 "$f" | tr -d '\r\n')
  [[ "$v" =~ ^[A-Za-z0-9/+=._-]{8,256}$ ]] || { error "The key in --${opt} does not look like an access key"; return 1; }
  printf '%s' "$v"
}

backup_storage_add_handler() {
  parse_kv_args "$@"
  require_args "name bucket access-key-file secret-key-file" || return 1
  local name="${PARSED_ARGS[name]}" type="${PARSED_ARGS[type]:-s3}" bucket="${PARSED_ARGS[bucket]}"
  local endpoint="${PARSED_ARGS[endpoint]:-}" region="${PARSED_ARGS[region]:-}" prefix="${PARSED_ARGS[prefix]:-}"
  local keep="${PARSED_ARGS[keep]:-30}" default="${PARSED_ARGS[default]:-}" confirm="${PARSED_ARGS[confirm]:-no}"
  backup_storage_valid_name "$name" || { error "--name must be lowercase letters, digits and dashes (up to 32)"; return 1; }
  [[ "$type" == s3 ]] || { error "--type must be s3"; return 1; }
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$ ]] || { error "--bucket is not a valid bucket name"; return 1; }
  [[ -z "$endpoint" || "$endpoint" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?/?$ ]] || { error "--endpoint must be https://host[:port]"; return 1; }
  [[ -z "$region" || "$region" =~ ^[a-z0-9-]{1,32}$ ]] || { error "--region must be like eu-central-1 or ru-central1"; return 1; }
  [[ -z "$prefix" || ( "$prefix" =~ ^[A-Za-z0-9._-][A-Za-z0-9._/-]{0,127}$ && "$prefix" != *..* ) ]] || { error "--prefix must be a path like servers/web1"; return 1; }
  prefix="${prefix%/}"
  backup_data_validate_keep "$keep" || return 1
  [[ -z "$default" || "$default" =~ ^(yes|no)$ ]] || { error "--default must be yes or no"; return 1; }
  local current_default
  current_default=$(backup_storage_default)
  [[ -n "$default" ]] || { [[ -z "$current_default" || "$current_default" == "$name" ]] && default=yes || default=no; }
  local exists=no
  [[ -f "$(backup_storage_file "$name")" ]] && exists=yes
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: $([[ $exists == yes ]] && echo "replace" || echo "add") backup storage ${name}: S3 bucket ${bucket}${prefix:+/${prefix}} at ${endpoint:-AWS}${region:+ (${region})}"
    echo "      checks the keys by writing, reading and deleting a small object; nothing is saved if that fails"
    echo "      keeps the newest ${keep} backups of each site there$([[ $default == yes ]] && echo "; every data backup is uploaded to it (default storage)")"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  local access secret
  access=$(backup_storage_read_key_file access-key-file "${PARSED_ARGS[access-key-file]}") || return 1
  secret=$(backup_storage_read_key_file secret-key-file "${PARSED_ARGS[secret-key-file]}") || return 1
  backup_rclone_ensure || return 1
  install -d -m 0700 "$BACKUP_STORAGE_DIR"
  local tmp="${BACKUP_STORAGE_DIR}/.${name}.env.new"
  ( umask 077; printf 'TYPE=s3\nBUCKET=%s\nENDPOINT=%s\nREGION=%s\nPREFIX=%s\nKEEP=%s\nDEFAULT=%s\nACCESS_KEY_ID=%s\nSECRET_ACCESS_KEY=%s\n' \
      "$bucket" "$endpoint" "$region" "$prefix" "$keep" "$default" "$access" "$secret" >"$tmp" )
  # Probe with the new settings before they replace anything.
  local saved="" err
  [[ $exists == yes ]] && { saved=$(mktemp); cp -p "$(backup_storage_file "$name")" "$saved"; }
  mv -f "$tmp" "$(backup_storage_file "$name")"
  if ! err=$(backup_storage_probe "$name" 2>&1); then
    if [[ -n "$saved" ]]; then mv -f "$saved" "$(backup_storage_file "$name")"; else rm -f -- "$(backup_storage_file "$name")"; fi
    error "The storage did not accept the keys or the bucket; nothing saved:"
    sed 's/^/  /' <<<"$err" >&2
    return 1
  fi
  rm -f -- "$saved"
  if [[ "$default" == yes ]]; then
    local f
    for f in "${BACKUP_STORAGE_DIR}"/*.env; do
      [[ "$f" == "$(backup_storage_file "$name")" ]] || sed -i 's/^DEFAULT=yes$/DEFAULT=no/' "$f"
    done
  fi
  backup_storage_record_test "$name" yes ""
  ui_result_table "Storage|${name}" "Bucket|${bucket}${prefix:+/${prefix}}" "Endpoint|${endpoint:-AWS}" "Keeps|last ${keep} per site" \
    "Default|${default}" "Check|write, read and delete ok"
}

backup_storage_list_handler() {
  parse_kv_args "$@"
  python3 -I "${SIMAI_ENV_ROOT}/lib/backup_storage.py" list "$BACKUP_STORAGE_DIR" "$BACKUP_STORAGE_TEST_STATE" "${SIMAI_COMMAND_OUTPUT:-human}"
}


backup_storage_test_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" err
  backup_storage_require "$name" || return 1
  backup_rclone_ensure || return 1
  if ! err=$(backup_storage_probe "$name" 2>&1); then
    backup_storage_record_test "$name" no "$(head -n1 <<<"$err")"
    error "The storage ${name} does not accept writes:"
    sed 's/^/  /' <<<"$err" >&2
    return 1
  fi
  backup_storage_record_test "$name" yes ""
  ui_result_table "Storage|${name}" "Check|write, read and delete ok"
}

backup_storage_remove_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" confirm="${PARSED_ARGS[confirm]:-no}"
  backup_storage_require "$name" || return 1
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: remove backup storage ${name}: its settings and keys on this server"
    echo "      the copies already in the bucket stay there; new backups are no longer uploaded to it"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  rm -f -- "$(backup_storage_file "$name")" "${BACKUP_STORAGE_TEST_STATE}/${name}.json"
  ui_result_table "Storage|${name}" "Removed|settings and keys" "Copies|stay in the bucket"
}

# Backups of a site in a storage, newest first (directory names <ts>).
backup_storage_remote_backups() {  # name domain
  backup_rclone "$1" lsf --dirs-only "$(backup_storage_path "$1" "$2")" 2>/dev/null | sed 's#/$##' | grep -E '^[0-9]{8}-[0-9]{6}$' | sort -r || true
}

# Called by backup data after a local backup: upload it, keep the newest KEEP
# there, record the result. Never fails the local backup.
backup_storage_upload() {  # domain dir
  local domain="$1" dir="$2" name ts keep ok=no err="" kept
  name="${BACKUP_DATA_STORAGE:-$(backup_storage_default)}"
  [[ -n "$name" && "$name" != none ]] || { BACKUP_OFFSITE_RESULT="not configured"; return 0; }
  ts=$(basename "$dir")
  if ! backup_storage_valid_name "$name" || [[ ! -f "$(backup_storage_file "$name")" ]]; then
    err="no storage named ${name}"
  elif ! backup_rclone_ensure >/dev/null 2>&1; then
    err="rclone is not installed"
  else
    info "Uploading to storage ${name}"
    if err=$(backup_rclone "$name" copy "$dir" "$(backup_storage_path "$name" "${domain}/${ts}")" 2>&1); then
      ok=yes; err=""
      keep=$(backup_storage_get "$name" KEEP); keep="${keep:-30}"
      while IFS= read -r kept; do
        [[ -n "$kept" ]] || continue
        backup_rclone "$name" purge "$(backup_storage_path "$name" "${domain}/${kept}")" >>"$LOG_FILE" 2>&1 || warn "Could not remove old copy ${kept} from ${name}"
      done < <(backup_storage_remote_backups "$name" "$domain" | tail -n +"$((keep + 1))")
    else
      err=$(grep -E 'ERROR|Failed' <<<"$err" | tail -n1 | sed -E 's/[A-Za-z0-9/+=]{32,}/[hidden]/g' | cut -c1-300 || true)
      err="${err:-upload failed}"
    fi
  fi
  install -d -m 0755 "$BACKUP_OFFSITE_STATE"
  ERR="$err" python3 -I -c 'import json,os,sys,time
print(json.dumps({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "ok": sys.argv[1] == "yes",
                  "storage": sys.argv[2], "backup": sys.argv[3], "error": os.environ.get("ERR") or None}))' \
    "$ok" "$name" "$ts" >"${BACKUP_OFFSITE_STATE}/${domain}.json"
  if [[ "$ok" == yes ]]; then
    BACKUP_OFFSITE_RESULT="uploaded to ${name}"
  else
    BACKUP_OFFSITE_RESULT="FAILED (${name}): ${err}"
    warn "The local backup is complete, but the upload to storage ${name} failed: ${err}"
  fi
}

backup_storage_copies_handler() {
  parse_kv_args "$@"
  require_args "name" || return 1
  local name="${PARSED_ARGS[name]}" domain="${PARSED_ARGS[domain]:-}" d out
  backup_storage_require "$name" || return 1
  [[ -z "$domain" ]] || validate_domain "$domain" "allow" || return 1
  backup_rclone_ensure >/dev/null || return 1
  local -a domains=()
  if [[ -n "$domain" ]]; then
    domains=("$domain")
  else
    if ! out=$(backup_rclone "$name" lsf --dirs-only "$(backup_storage_path "$name")" 2>&1); then
      error "Cannot list storage ${name}"; return 1
    fi
    mapfile -t domains < <(sed 's#/$##' <<<"$out" | grep -E '^[a-z0-9.-]+\.[a-z0-9-]+$' || true)
  fi
  {
    for d in "${domains[@]}"; do
      backup_storage_remote_backups "$name" "$d" | sed "s#^#${d}\t#"
    done
  } | python3 -I "${SIMAI_ENV_ROOT}/lib/backup_storage.py" copies "$name" "${SIMAI_COMMAND_OUTPUT:-human}"
}


# Downloads a copy into the local backups and checks it, so backup
# data-restore (and data-verify) can use it, also on a new server.
backup_storage_fetch_handler() {
  parse_kv_args "$@"
  require_args "name domain backup" || return 1
  local name="${PARSED_ARGS[name]}" domain="${PARSED_ARGS[domain]}" ts="${PARSED_ARGS[backup]}"
  local dest="${PARSED_ARGS[dest]:-$BACKUP_DATA_DEFAULT_DEST}" confirm="${PARSED_ARGS[confirm]:-no}"
  backup_storage_require "$name" || return 1
  validate_domain "$domain" "allow" || return 1
  [[ "$ts" =~ ^[0-9]{8}-[0-9]{6}$ ]] || { error "--backup must be a backup name like 20261106-033000"; return 1; }
  backup_data_validate_dest "$dest" || return 1
  local target="${dest%/}/${domain}/${ts}"
  [[ ! -e "$target" ]] || { error "${target} already exists on this server; use it directly"; return 1; }
  if [[ "${confirm,,}" != yes ]]; then
    echo "Plan: download backup ${ts} of ${domain} from storage ${name} into ${target} and check its checksums"
    echo "      then restore it with: simai-admin.sh backup data-restore --domain ${domain} --backup ${ts}"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi
  backup_rclone_ensure || return 1
  install -d -m 0700 -o root -g root "$dest" "${dest%/}/${domain}"
  local tmp="${dest%/}/${domain}/.fetch-${ts}"
  rm -rf -- "$tmp"; install -d -m 0700 "$tmp"
  if ! backup_rclone "$name" copy "$(backup_storage_path "$name" "${domain}/${ts}")" "$tmp" >>"$LOG_FILE" 2>&1 || [[ ! -f "${tmp}/SHA256SUMS" ]]; then
    rm -rf -- "$tmp"
    error "Cannot download ${ts} of ${domain} from ${name} (is it in backup storage-copies?)"
    return 1
  fi
  if ! (cd "$tmp" && sha256sum -c --quiet SHA256SUMS >>"$LOG_FILE" 2>&1); then
    rm -rf -- "$tmp"
    error "The downloaded copy does not match its checksums; nothing kept"
    return 1
  fi
  chmod -R go-rwx "$tmp"
  mv -T "$tmp" "$target"
  ui_result_table "Domain|${domain}" "Backup|${target}" "From|${name}" "Checksums|ok"
  ui_next_steps
  ui_kv "Restore" "simai-admin.sh backup data-restore --domain ${domain} --backup ${ts} --confirm yes"
}

register_cmd "backup" "storage-add" "Add or replace an S3 storage for off-site copies of data backups (keys checked first)" "backup_storage_add_handler" "name bucket access-key-file secret-key-file" "type= endpoint= region= prefix= keep= default= confirm=" "tier:advanced plan:handler"
register_cmd "backup" "storage-list" "List backup storages (no keys) with their last check" "backup_storage_list_handler" "" "" "tier:advanced effects:read"
register_cmd "backup" "storage-test" "Check that a backup storage accepts writes" "backup_storage_test_handler" "name" "" "tier:advanced"
register_cmd "backup" "storage-remove" "Remove a backup storage's settings and keys (its copies stay)" "backup_storage_remove_handler" "name" "confirm=" "tier:advanced plan:handler effects:delete"
register_cmd "backup" "storage-copies" "List the backups kept in a storage" "backup_storage_copies_handler" "name" "domain=" "tier:advanced effects:read"
register_cmd "backup" "storage-fetch" "Download a backup from a storage into the local backups (then data-restore)" "backup_storage_fetch_handler" "name domain backup" "dest= confirm=" "tier:advanced plan:handler"
