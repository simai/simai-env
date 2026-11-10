#!/usr/bin/env bash
# One-click WordPress, the way Bitrix has it: `wp install` installs a new
# site end to end, `wp restore-ready` brings a copy in from a files archive
# and a database dump, and `wp status --output json` (wp.sh) tells the panel
# the route and step of a site. Both end with `wp finalize`.
#
# The generated admin password exists only in the command result: the human
# output, `admin_password` of the JSON data, or the panel job result
# (SIMAI_JOB_RESULT, handed out once by job:status). It never reaches the
# log, the audit log, a job log or a file kept on disk.

# Route of a site that went through wp install (new) or wp restore-ready
# (restore); read by wp status.
wp_flow_marker_path() {
  printf '%s/%s/wp-flow.env\n' "$(site_sites_config_dir)" "$1"
}

wp_flow_marker_write() {
  local domain="$1" route="$2" marker
  marker=$(wp_flow_marker_path "$domain")
  install -d -m 0750 "$(dirname "$marker")" 2>/dev/null || return 0
  printf 'ROUTE=%s\nAT=%s\n' "$route" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$marker"
  chmod 0640 "$marker" 2>/dev/null || true
}

wp_flow_marker_route() {
  local marker line
  marker=$(wp_flow_marker_path "$1")
  [[ -f "$marker" ]] || return 0
  while IFS= read -r line; do
    [[ "$line" == ROUTE=* ]] && { printf '%s\n' "${line#ROUTE=}"; return 0; }
  done <"$marker"
}

# JSON string literal of a value, without running a program (secrets stay
# off argv).
wp_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Edits wp-config.php as the site user: JSON on stdin, {"defines": {NAME:
# value}, "table_prefix": "..."}. Values never pass through argv.
wordpress_config_edit() {
  local file="$1"
  [[ -f "$file" && ! -L "$file" ]] || return 1
  sudo -u "$SIMAI_USER" -H python3 -I -c '
import json, os, re, stat, sys, tempfile
path = sys.argv[1]
spec = json.load(sys.stdin)
st = os.lstat(path)
if not stat.S_ISREG(st.st_mode):
    sys.exit(2)
with open(path, encoding="utf-8", errors="surrogateescape") as f:
    text = f.read()
def lit(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return "'"'"'" + str(v).replace("\\", "\\\\").replace("'"'"'", "\\'"'"'") + "'"'"'"
VALUE = r"""(?:'"'"'(?:[^'"'"'\\]|\\.)*'"'"'|"(?:[^"\\]|\\.)*"|[^;]*?)"""
for name, value in spec.get("defines", {}).items():
    line = "define( '"'"'%s'"'"', %s );" % (name, lit(value))
    pat = re.compile(r"define\s*\(\s*['"'"'\"]" + re.escape(name) + r"['"'"'\"]\s*,\s*" + VALUE + r"\s*\)\s*;")
    if pat.search(text):
        seen = []  # the first define gets the value, later ones (a PHP warning) go
        text = pat.sub(lambda m: "" if seen else seen.append(1) or line, text)
        continue
    for marker in (r"/\*\s*That'"'"'s all, stop editing!", r"if\s*\(\s*!\s*defined\(\s*['"'"'\"]ABSPATH", r"require_once\s*\(?\s*ABSPATH"):
        m = re.search(marker, text)
        if m:
            text = text[:m.start()] + line + "\n\n" + text[m.start():]
            break
    else:
        sys.exit(3)
prefix = spec.get("table_prefix")
if prefix:
    text, n = re.subn(r"\$table_prefix\s*=\s*(['"'"'\"])[^'"'"'\"]*\1\s*;", lambda m: "$table_prefix = '"'"'%s'"'"';" % prefix, text, count=1)
    if not n:
        sys.exit(3)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".wp-config.")
with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as out:
    out.write(text)
os.chmod(tmp, stat.S_IMODE(st.st_mode))
os.replace(tmp, path)
' "$file"
}

# Sets constants to PHP booleans (true/false), e.g. WP_DEBUG=false.
wordpress_config_set_bools() {
  local file="$1" pair json="" sep=""
  shift
  for pair in "$@"; do
    json+="${sep}$(wp_json_str "${pair%%=*}"): ${pair#*=}"
    sep=", "
  done
  printf '{"defines": {%s}}' "$json" | wordpress_config_edit "$file"
}

# The same, as the owner of the file (rules and finalize run outside the
# site user context too).
wordpress_config_owner_set_bools() {
  local file="$1" owner
  shift
  [[ -f "$file" && ! -L "$file" ]] || return 1
  owner=$(stat -c %U "$file" 2>/dev/null) || return 1
  SIMAI_USER="$owner" wordpress_config_set_bools "$file" "$@"
}

# 0 when wp-config.php defines NAME as true.
wordpress_config_define_true() {
  grep -Eqi "define[[:space:]]*\\([[:space:]]*['\"]$2['\"][[:space:]]*,[[:space:]]*true[[:space:]]*\\)" "$1" 2>/dev/null
}

# Copies, dumps and backup archives at the top of the web root (and dumps in
# wp-content): downloadable, or at least readable by anyone with a link.
wordpress_leftovers_list() {
  local doc_root="$1" path
  shopt -s nullglob nocaseglob
  for path in "${doc_root}"/*.sql "${doc_root}"/*.sql.gz "${doc_root}"/*.tar "${doc_root}"/*.tar.gz "${doc_root}"/*.tgz \
    "${doc_root}"/*.zip "${doc_root}"/*.wpress "${doc_root}"/wp-content/*.sql "${doc_root}"/wp-content/*.sql.gz; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    # A site may serve its own zip or tar files: an archive counts only when
    # its name says it is a copy of the site (dumps and .wpress always do).
    case "${path,,}" in
      *.sql|*.sql.gz|*.wpress) ;;
      *) [[ "$(basename "${path,,}")" =~ (backup|bak|dump|duplicator|wordpress|wp-content|wp_content|full|site) ]] || continue ;;
    esac
    printf '%s\n' "$path"
  done | awk '!seen[$0]++'
  shopt -u nullglob nocaseglob
}

# DB_NAME, DB_USER, DB_PASSWORD and DB_HOST from the site's db.env.
wordpress_config_set_db() {
  local domain="$1" file="$2" prefix="${3:-}" entry k v name="" user="" pass="" host="localhost"
  while IFS= read -r entry; do
    k="${entry%%|*}"; v="${entry#*|}"
    case "$k" in
      DB_NAME) name="$v" ;; DB_USER) user="$v" ;; DB_PASS) pass="$v" ;; DB_HOST) host="$v" ;;
    esac
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  [[ -n "$name" && -n "$user" && -n "$pass" ]] || return 1
  local extra=""
  [[ -n "$prefix" ]] && extra=", \"table_prefix\": $(wp_json_str "$prefix")"
  printf '{"defines": {"DB_NAME": %s, "DB_USER": %s, "DB_PASSWORD": %s, "DB_HOST": %s}%s}' \
    "$(wp_json_str "$name")" "$(wp_json_str "$user")" "$(wp_json_str "$pass")" "$(wp_json_str "${host:-localhost}")" "$extra" \
    | wordpress_config_edit "$file"
}

wp_install_validate() {
  local title="$1" user="$2" email="$3" locale="$4"
  if [[ -z "$title" || ${#title} -gt 200 || "$title" =~ [[:cntrl:]] || "$title" == -* ]]; then
    error "--title must be 1-200 printable characters and not start with '-'"
    return 1
  fi
  if [[ ! "$user" =~ ^[A-Za-z0-9._@-]{1,60}$ ]]; then
    error "--admin-user may use letters, digits and . _ @ - (up to 60)"
    return 1
  fi
  if [[ ! "$email" =~ ^[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9.-]{1,253}\.[A-Za-z]{2,63}$ ]]; then
    error "--admin-email is not an e-mail address"
    return 1
  fi
  if [[ ! "$locale" =~ ^[a-z]{2,3}(_[A-Z]{2})?(_[a-z0-9]{2,12})?$ ]]; then
    error "--locale must look like en_US, ru_RU or de_DE_formal"
    return 1
  fi
  return 0
}

# A WordPress site with a MySQL database and no installed WordPress yet.
wp_site_db_precheck() {
  local domain="$1" rc=0
  wp_prepare_site "$domain" || { rc=$?; return $rc; }
  if [[ "$(site_db_engine "$WP_DOMAIN")" != mysql ]]; then
    error "WordPress needs a MySQL database; ${WP_DOMAIN} uses $(site_db_engine "$WP_DOMAIN")."
    return 1
  fi
  if ! read_site_db_env "$WP_DOMAIN" >/dev/null 2>&1; then
    error "${WP_DOMAIN} has no database yet: simai-admin.sh site db-create --domain ${WP_DOMAIN} --confirm yes"
    return 1
  fi
  WP_DB_NAME=""
  local entry
  while IFS= read -r entry; do
    [[ "${entry%%|*}" == DB_NAME ]] && WP_DB_NAME="${entry#*|}"
  done < <(read_site_db_env "$WP_DOMAIN" 2>/dev/null || true)
  db_validate_db_name "$WP_DB_NAME" >/dev/null 2>&1 || { error "The site database name is not valid"; return 1; }
  WP_DB_STATE=$(wordpress_db_state_probe "$WP_DOMAIN")
  return 0
}

wp_install_precheck() {
  wp_site_db_precheck "$1" || return $?
  case "$WP_DB_STATE" in
    installed)
      error "WordPress is already installed on ${WP_DOMAIN}; see simai-admin.sh wp status --domain ${WP_DOMAIN}"
      return 1 ;;
    schema)
      error "The database of ${WP_DOMAIN} already has WordPress tables; restore with wp restore-ready or empty it first"
      return 1 ;;
    unknown)
      error "Cannot read the database of ${WP_DOMAIN} with its own credentials (db.env)"
      return 1 ;;
  esac
  return 0
}

wp_install_plan_check() {
  local title user email locale
  title=$(command_arg title "$@"); user=$(command_arg admin-user "$@"); email=$(command_arg admin-email "$@")
  locale=$(command_arg locale "$@"); [[ -n "$locale" ]] || locale=en_US
  wp_install_validate "$title" "$user" "$email" "$locale" || return 1
  wp_install_precheck "$(command_arg domain "$@")" || return 1
}

# A new admin password: 24 URL-safe characters from /dev/urandom.
wp_generate_password() {
  local pw
  pw=$(head -c 18 /dev/urandom | base64 | tr '+/' '-_')
  pw="${pw//=/}"
  [[ ${#pw} -ge 20 ]] || return 1
  printf '%s' "$pw"
}

# Core files in the docroot: kept when present, otherwise the official
# package for the locale, checked against its published SHA-1.
# Sets WP_CORE_STATUS.
wp_core_ensure() {
  local locale="$1"
  WP_CORE_STATUS="present (kept)"
  if [[ -d "${WP_DOC_ROOT}/wp-includes" && -f "${WP_DOC_ROOT}/wp-includes/version.php" ]]; then
    return 0
  fi
  if ! wordpress_core_resolve "$locale"; then
    WP_CORE_STATUS="failed (no package for ${locale})"
    error "No official WordPress package for locale ${locale}"
    return 1
  fi
  local tmpd rc=0
  tmpd=$(mktemp -d)
  chmod 0700 "$tmpd"
  info "Downloading WordPress ${WP_CORE_VERSION} (${locale}) from ${WP_CORE_URL}"
  if ! wordpress_core_fetch "$WP_CORE_URL" "${tmpd}/core.tar.gz"; then
    rm -rf "$tmpd"
    WP_CORE_STATUS="failed (download or checksum)"
    error "WordPress package download or checksum check failed: ${WP_CORE_URL}"
    return 1
  fi
  wordpress_unpack_distribution_archive "$WP_DOC_ROOT" yes "${tmpd}/core.tar.gz" || rc=$?
  rm -rf "$tmpd"
  if (( rc != 0 )); then
    WP_CORE_STATUS="failed (unpack)"
    error "Cannot unpack WordPress into ${WP_DOC_ROOT}"
    return 1
  fi
  WP_HAS_CORE="yes"
  WP_CORE_STATUS="WordPress ${WP_CORE_VERSION} (${locale}), sha1 verified"
  return 0
}

# Writes the one-time result of a panel job (root-only file in the job
# directory; job:status hands it out once and removes the password).
wp_job_result_write() {
  local pw="$1" user="$2" login="$3"
  [[ -n "${SIMAI_JOB_RESULT:-}" ]] || return 1
  printf '%s' "$pw" | python3 -I -c '
import json, os, sys
path, user, login = sys.argv[1:4]
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, "w") as out:
    json.dump({"admin_user": user, "admin_password": sys.stdin.read(), "login_url": login}, out)
' "$SIMAI_JOB_RESULT" "$user" "$login"
}

wp_install_handler() {
  parse_kv_args "$@"
  require_args "domain title admin-user admin-email" || return 1
  local domain="${PARSED_ARGS[domain]}" title="${PARSED_ARGS[title]}"
  local admin_user="${PARSED_ARGS[admin-user]}" admin_email="${PARSED_ARGS[admin-email]}"
  local locale="${PARSED_ARGS[locale]:-en_US}" confirm="${PARSED_ARGS[confirm]:-no}"
  wp_install_validate "$title" "$admin_user" "$admin_email" "$locale" || return 1
  local rc=0
  wp_install_precheck "$domain" || { rc=$?; return $rc; }
  local url
  url=$(site_primary_url "$WP_DOMAIN")

  if [[ "${confirm,,}" != yes ]]; then
    ui_header "SIMAI ENV · WordPress install (plan)"
    ui_result_table \
      "Domain|${WP_DOMAIN}" \
      "Site URL|${url}" \
      "Core|$([[ "$WP_HAS_CORE" == yes ]] && echo "keep the files in ${WP_DOC_ROOT}" || echo "official WordPress package (${locale}), checked against its SHA-1")" \
      "WP-CLI|$(wordpress_wp_cli_bin >/dev/null && echo present || echo "official phar, checked against its SHA-512")" \
      "wp-config.php|$([[ "$WP_CONFIG_READY" == yes ]] && echo kept || echo "from db.env, new salts")" \
      "Database|${WP_DB_NAME} (${WP_DB_STATE})" \
      "Title|${title}" \
      "Admin|${admin_user} <${admin_email}>" \
      "Admin password|generated, shown once in the result" \
      "Then|wp finalize (scheduler, wp-config rules)"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  # JSON output: everything but the final answer goes to stderr.
  local json=no
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    json=yes
    exec 3>&1 1>&2
  fi
  progress_init 5
  progress_step "WP-CLI"
  if ! wordpress_wp_cli_install; then
    error "WP-CLI could not be installed (download or SHA-512 check failed)"
    return 1
  fi
  progress_step "WordPress core"
  wp_core_ensure "$locale" || return 1
  progress_step "wp-config.php"
  if ! wordpress_write_config "$WP_DOMAIN" "$WP_DOC_ROOT" no; then
    error "Cannot write wp-config.php from db.env"
    return 1
  fi
  progress_step "Installing WordPress as ${SIMAI_USER}"
  local pw out
  pw=$(wp_generate_password) || { error "Cannot generate a password"; return 1; }
  rc=0
  out=$(printf '%s\n' "$pw" | wordpress_wp_cli_run "$WP_DOC_ROOT" "$WP_PHP_VERSION" core install \
    --url="$url" --title="$title" --admin_user="$admin_user" --admin_email="$admin_email" \
    --skip-email --prompt=admin_password 2>&1) || rc=$?
  out="${out//"$pw"/***}"
  printf '%s\n' "$out" >>"$LOG_FILE"
  if (( rc != 0 )); then
    pw=""
    error "WordPress install failed for ${WP_DOMAIN} (WP-CLI exit ${rc}; details in ${LOG_FILE})"
    return 1
  fi
  if [[ "$locale" != en_US ]]; then
    wordpress_wp_cli_run "$WP_DOC_ROOT" "$WP_PHP_VERSION" option update WPLANG "$locale" >>"$LOG_FILE" 2>&1 \
      || warn "Could not set the site language ${locale}"
  fi
  wp_flow_marker_write "$WP_DOMAIN" new
  progress_step "Finalize"
  local finalize_status="ok"
  run_command wp finalize --domain "$WP_DOMAIN" --confirm yes || finalize_status="failed (run wp finalize again)"
  progress_done "WordPress installed"
  local login_url="${url}/wp-login.php" login_code
  login_code=$(curl -ks -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${WP_DOMAIN}:80:127.0.0.1" \
    --resolve "${WP_DOMAIN}:443:127.0.0.1" "$login_url" 2>/dev/null || true)

  if [[ "$json" == yes ]]; then
    printf '%s' "$pw" | python3 -I -c '
import json, sys
domain, url, login, user, email, locale, core, finalize, code = sys.argv[1:10]
print(json.dumps({"schema": "simai-wp-install/1", "domain": domain, "url": url, "login_url": login,
                  "admin_user": user, "admin_email": email, "admin_password": sys.stdin.read(),
                  "locale": locale, "core": core, "finalize": finalize, "login_status": code}, indent=2))' \
      "$WP_DOMAIN" "$url" "$login_url" "$admin_user" "$admin_email" "$locale" "$WP_CORE_STATUS" "$finalize_status" "${login_code:-000}" >&3
    pw=""
    # WordPress is installed: success, so the envelope carries the password;
    # a failed finalize is named in the data.
    return 0
  fi
  local shown="$pw"
  if [[ -n "${SIMAI_JOB_RESULT:-}" ]]; then
    if wp_job_result_write "$pw" "$admin_user" "$login_url"; then
      shown="in the job result (job:status shows it once)"
    else
      shown="not delivered: reset it with wp user update"
      warn "Could not write the job result"
    fi
  fi
  pw=""
  ui_header "SIMAI ENV · WordPress install"
  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Core|${WP_CORE_STATUS}" \
    "Site URL|${url}" \
    "Login|${login_url} (HTTP ${login_code:-000})" \
    "Admin user|${admin_user}" \
    "Admin password|${shown}" \
    "Finalize|${finalize_status}"
  [[ -n "${SIMAI_JOB_RESULT:-}" ]] || echo "The password is shown only here and is not stored; save it now."
  ui_next_steps
  ui_kv "Open admin" "${url}/wp-admin/"
  ui_kv "Status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
  [[ "$finalize_status" == ok ]] || return 1
  return 0
}

# A file inside the site directory given relative to it (or absolute
# below it): no "..", no symlink anywhere on the way, a regular file.
# Prints the absolute path.
wp_site_file() {
  local root="$1" path="$2" what="$3" rel real_root real
  if [[ -z "$path" || "$path" =~ [[:cntrl:]] ]]; then
    error "--${what} is empty or has control characters"
    return 1
  fi
  if [[ "/${path}/" == *"/../"* || "/${path}/" == *"/./"* ]]; then
    error "--${what} must not contain '.' or '..' parts"
    return 1
  fi
  real_root=$(realpath -e -- "$root" 2>/dev/null) || { error "Site directory ${root} is missing"; return 1; }
  if [[ "$path" == /* ]]; then
    case "$path" in
      "${root%/}"/*) rel="${path#"${root%/}"/}" ;;
      "${real_root}"/*) rel="${path#"${real_root}"/}" ;;
      *) error "--${what} must be inside ${root}"; return 1 ;;
    esac
  else
    rel="$path"
  fi
  rel="${rel#./}"
  real=$(realpath -e -- "${real_root}/${rel}" 2>/dev/null) || { error "--${what}: ${rel} not found in ${root}"; return 1; }
  if [[ "$real" != "${real_root}/${rel%/}" ]]; then
    error "--${what}: ${rel} goes through a symlink; refused"
    return 1
  fi
  if [[ ! -f "$real" || -L "$real" ]]; then
    error "--${what}: ${rel} is not a regular file"
    return 1
  fi
  printf '%s\n' "$real"
}

wp_restore_kinds() {
  local files="$1" dump="$2"
  case "$files" in
    *.tar.gz|*.tgz) WP_RESTORE_TAR="z" ;;
    *.tar) WP_RESTORE_TAR="" ;;
    *) error "--files must be a .tar.gz, .tgz or .tar archive"; return 1 ;;
  esac
  case "$dump" in
    *.sql.gz) WP_RESTORE_DUMP_GZ=yes ;;
    *.sql) WP_RESTORE_DUMP_GZ=no ;;
    *) error "--dump must be a .sql or .sql.gz file"; return 1 ;;
  esac
}

wp_db_table_count() {
  local n
  n=$(mysql_root_query_stdin "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$1'" 2>/dev/null || echo "")
  [[ "$n" =~ ^[0-9]+$ ]] || n=-1
  printf '%s\n' "$n"
}

wp_restore_precheck() {
  local domain="$1" files="$2" dump="$3" overwrite="$4"
  wp_site_db_precheck "$domain" || return $?
  WP_RESTORE_FILES=$(wp_site_file "$WP_ROOT" "$files" files) || return 1
  WP_RESTORE_DUMP=$(wp_site_file "$WP_ROOT" "$dump" dump) || return 1
  wp_restore_kinds "$WP_RESTORE_FILES" "$WP_RESTORE_DUMP" || return 1
  WP_RESTORE_TABLES=$(wp_db_table_count "$WP_DB_NAME")
  if [[ "$WP_RESTORE_TABLES" == -1 ]]; then
    error "Cannot read the database ${WP_DB_NAME} as root"
    return 1
  fi
  if [[ "$overwrite" != yes ]]; then
    if (( WP_RESTORE_TABLES > 0 )); then
      error "The database ${WP_DB_NAME} is not empty (${WP_RESTORE_TABLES} tables); rerun with --overwrite yes (a backup is taken first)"
      return 1
    fi
    if [[ -f "${WP_DOC_ROOT}/wp-includes/version.php" ]]; then
      error "${WP_DOC_ROOT} already holds WordPress; rerun with --overwrite yes (a backup is taken first)"
      return 1
    fi
  fi
  return 0
}

wp_restore_plan_check() {
  local overwrite
  overwrite=$(command_arg overwrite "$@")
  [[ "${overwrite,,}" == yes ]] && overwrite=yes || overwrite=no
  wp_restore_precheck "$(command_arg domain "$@")" "$(command_arg files "$@")" "$(command_arg dump "$@")" "$overwrite"
}

# The directory of the extracted archive that holds WordPress (the
# shallowest one with wp-includes, or with wp-content when the archive has
# only the site's own files).
wp_restore_find_root() {
  local staging="$1" found
  found=$(find "$staging" -maxdepth 4 -type d -name wp-includes -printf '%d %h\n' 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2- || true)
  if [[ -z "$found" ]]; then
    found=$(find "$staging" -maxdepth 4 -type d -name wp-content -printf '%d %h\n' 2>/dev/null | sort -n | head -n1 | cut -d' ' -f2- || true)
  fi
  [[ -n "$found" && ! -L "$found" ]] || return 1
  printf '%s\n' "$found"
}

# Imports a dump as the site user with the site's own credentials (a
# defaults file readable only by that user, removed afterwards): a dump's
# client commands never run as root and no password is on argv.
wp_restore_import_dump() {
  local domain="$1" dump="$2" gz="$3" entry k v user="" pass="" host="localhost" name=""
  while IFS= read -r entry; do
    k="${entry%%|*}"; v="${entry#*|}"
    case "$k" in DB_NAME) name="$v" ;; DB_USER) user="$v" ;; DB_PASS) pass="$v" ;; DB_HOST) host="$v" ;; esac
  done < <(read_site_db_env "$domain" 2>/dev/null || true)
  [[ -n "$name" && -n "$user" && -n "$pass" ]] || return 1
  local d cnf rc=0 saved
  d=$(mktemp -d)
  chmod 0711 "$d"
  cnf="${d}/client.cnf"
  saved=$(umask); umask 077
  {
    printf '[client]\n'
    printf 'user="%s"\n' "${user//\"/\\\"}"
    printf 'password="%s"\n' "$(printf '%s' "$pass" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
    printf 'host="%s"\n' "${host:-localhost}"
  } >"$cnf"
  umask "$saved"
  chown "$SIMAI_USER" "$cnf" && chmod 0400 "$cnf" || { rm -rf "$d"; return 1; }
  if [[ "$gz" == yes ]]; then
    # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
    gzip -dc -- "$dump" | sudo -u "$SIMAI_USER" -H mysql --defaults-extra-file="$cnf" --default-character-set=utf8mb4 \
      --binary-mode "$name" >>"$LOG_FILE" 2>&1 || rc=$?
  else
    # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
    sudo -u "$SIMAI_USER" -H mysql --defaults-extra-file="$cnf" --default-character-set=utf8mb4 \
      --binary-mode "$name" <"$dump" >>"$LOG_FILE" 2>&1 || rc=$?
  fi
  rm -rf "$d"
  return "$rc"
}

# Table prefix of the restored database: the one in wp-config.php when its
# options table exists, otherwise the one prefix with options and users.
wp_restore_prefix() {
  local db="$1" want="$2" p
  if [[ "$want" =~ ^[A-Za-z0-9_]+$ ]] && [[ "$(mysql_root_query_stdin "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${want}options'")" == 1 ]]; then
    printf '%s\n' "$want"
    return 0
  fi
  while IFS= read -r p; do
    [[ "$p" =~ ^[A-Za-z0-9_]+$ ]] || continue
    if [[ "$(mysql_root_query_stdin "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${db}' AND table_name='${p}users'")" == 1 ]]; then
      printf '%s\n' "$p"
      return 0
    fi
  done < <(mysql_root_query_stdin "SELECT LEFT(table_name, CHAR_LENGTH(table_name) - 7) FROM information_schema.tables WHERE table_schema='${db}' AND table_name LIKE '%options'" 2>/dev/null || true)
  return 1
}

wp_option_get_sql() {
  local db="$1" prefix="$2" name="$3"
  mysql_root_query_stdin "SELECT option_value FROM \`${db}\`.\`${prefix}options\` WHERE option_name='${name}' LIMIT 1" 2>/dev/null | head -n1 || true
}

# home/siteurl (and every link in the content) moved to the site's own URL.
# Sets WP_RESTORE_URL_RESULT.
wp_restore_rewrite_url() {
  local db="$1" prefix="$2" new="$3" old old_host new_host rc=0
  local url_re='^https?://[^[:space:]'\''"\\]+$'
  old=$(wp_option_get_sql "$db" "$prefix" home)
  WP_RESTORE_URL_RESULT="kept ${new}"
  if [[ -z "$old" ]]; then
    WP_RESTORE_URL_RESULT="no home option"
    return 1
  fi
  old="${old%/}"
  [[ "$old" == "$new" ]] && return 0
  if [[ ! "$old" =~ $url_re ]]; then
    WP_RESTORE_URL_RESULT="home is not a URL; not rewritten"
    return 1
  fi
  old_host="${old#*://}"; old_host="${old_host%%/*}"
  new_host="${new#*://}"; new_host="${new_host%%/*}"
  if wordpress_wp_cli_bin >/dev/null; then
    wordpress_wp_cli_run "$WP_DOC_ROOT" "$WP_PHP_VERSION" search-replace "$old" "$new" --all-tables-with-prefix \
      --skip-columns=guid --skip-plugins --skip-themes --report-changed-only >>"$LOG_FILE" 2>&1 || rc=$?
    if (( rc == 0 )) && [[ "$old_host" != "$new_host" ]]; then
      wordpress_wp_cli_run "$WP_DOC_ROOT" "$WP_PHP_VERSION" search-replace "//${old_host}" "//${new_host}" --all-tables-with-prefix \
        --skip-columns=guid --skip-plugins --skip-themes --report-changed-only >>"$LOG_FILE" 2>&1 || rc=$?
    fi
    if (( rc == 0 )); then
      WP_RESTORE_URL_RESULT="${old} -> ${new} (WP-CLI search-replace)"
    fi
  else
    rc=1
  fi
  if (( rc != 0 )); then
    # Without WP-CLI only the two options move; links in posts keep the old URL.
    mysql_root_exec_stdin "UPDATE \`${db}\`.\`${prefix}options\` SET option_value='${new}' WHERE option_name IN ('home','siteurl')" || return 1
    WP_RESTORE_URL_RESULT="${old} -> ${new} (home and siteurl only)"
  fi
  [[ "$(wp_option_get_sql "$db" "$prefix" home)" == "$new" ]] \
    || mysql_root_exec_stdin "UPDATE \`${db}\`.\`${prefix}options\` SET option_value='${new}' WHERE option_name IN ('home','siteurl')"
}

wp_restore_ready_handler() {
  parse_kv_args "$@"
  require_args "domain files dump" || return 1
  local domain="${PARSED_ARGS[domain]}" files="${PARSED_ARGS[files]}" dump="${PARSED_ARGS[dump]}"
  local overwrite="${PARSED_ARGS[overwrite]:-no}" confirm="${PARSED_ARGS[confirm]:-no}"
  [[ "${overwrite,,}" == yes ]] && overwrite=yes || overwrite=no
  local rc=0
  wp_restore_precheck "$domain" "$files" "$dump" "$overwrite" || { rc=$?; return $rc; }
  local url
  url=$(site_primary_url "$WP_DOMAIN")
  if [[ "${confirm,,}" != yes ]]; then
    ui_header "SIMAI ENV · WordPress restore (plan)"
    ui_result_table \
      "Domain|${WP_DOMAIN}" \
      "Files|${WP_RESTORE_FILES} -> ${WP_DOC_ROOT} (unpacked as ${SIMAI_USER:-the site user})" \
      "Dump|${WP_RESTORE_DUMP} -> database ${WP_DB_NAME} (site credentials)" \
      "Database now|${WP_RESTORE_TABLES} table(s)$([[ "$overwrite" == yes && "$WP_RESTORE_TABLES" -gt 0 ]] && echo ", backed up, then replaced")" \
      "wp-config.php|DB constants from db.env (salts and table prefix kept)" \
      "Site URL|home/siteurl and links rewritten to ${url} when they differ" \
      "Then|wp finalize (scheduler, wp-config rules, archive and dump out of the web root)"
    echo "Rerun with --confirm yes to apply."
    return 0
  fi

  ui_header "SIMAI ENV · WordPress restore"
  progress_init 6
  local backup_status="not needed"
  if [[ "$overwrite" == yes ]] && { (( WP_RESTORE_TABLES > 0 )) || [[ -f "${WP_DOC_ROOT}/wp-includes/version.php" ]]; }; then
    progress_step "Backing up the current site"
    run_command backup data --domain "$WP_DOMAIN" --db yes --files yes --confirm yes || { error "Backup failed; nothing restored"; return 1; }
    backup_status="taken (backup data)"
    if (( WP_RESTORE_TABLES > 0 )); then
      mysql_root_exec_stdin "DROP DATABASE \`${WP_DB_NAME}\`; CREATE DATABASE \`${WP_DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" \
        || { error "Cannot empty the database ${WP_DB_NAME}"; return 1; }
    fi
  fi
  wordpress_wp_cli_install || warn "WP-CLI is not available; only home and siteurl will be rewritten"

  progress_step "Unpacking files as ${SIMAI_USER}"
  local staging src
  staging="${WP_ROOT}/.wp-restore-$(date +%Y%m%d%H%M%S)-$$"
  install -d -m 0700 -o "$SIMAI_USER" -g "$SIMAI_WEB_GROUP" "$staging" || { error "Cannot create ${staging}"; return 1; }
  rc=0
  # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
  sudo -u "$SIMAI_USER" -H tar --no-same-owner -x${WP_RESTORE_TAR}f - -C "$staging" <"$WP_RESTORE_FILES" >>"$LOG_FILE" 2>&1 || rc=$?
  if (( rc != 0 )); then
    rm -rf --one-file-system -- "$staging"
    error "Cannot unpack ${WP_RESTORE_FILES}"
    return 1
  fi
  if ! src=$(wp_restore_find_root "$staging"); then
    rm -rf --one-file-system -- "$staging"
    error "No WordPress (wp-includes or wp-content) in ${WP_RESTORE_FILES}"
    return 1
  fi
  local core_status="from the archive"
  if [[ ! -d "${src}/wp-includes" ]]; then
    progress_step "WordPress core (the archive has only the site's files)"
    wp_core_ensure en_US || { rm -rf --one-file-system -- "$staging"; return 1; }
    core_status="$WP_CORE_STATUS"
  fi
  rc=0
  # shellcheck disable=SC2024 # root opens the file or the log; only the reader runs as the site user
  sudo -u "$SIMAI_USER" -H cp -af -- "${src}/." "${WP_DOC_ROOT}/" >>"$LOG_FILE" 2>&1 || rc=$?
  rm -rf --one-file-system -- "$staging"
  if (( rc != 0 )); then
    error "Cannot copy the restored files into ${WP_DOC_ROOT} (see ${LOG_FILE})"
    return 1
  fi

  progress_step "wp-config.php from db.env"
  local config="${WP_DOC_ROOT}/wp-config.php" config_status prefix
  if [[ -L "$config" ]]; then
    error "${config} is a symlink; refused"
    return 1
  fi
  if [[ -f "$config" ]] && ! grep -q "SIMAI placeholder" "$config" 2>/dev/null; then
    prefix=$(wordpress_config_table_prefix "$config")
    wordpress_config_set_db "$WP_DOMAIN" "$config" || { error "Cannot set the DB constants in ${config}"; return 1; }
    config_status="archive's file, DB constants from db.env"
    # Fixed URLs in the copy's config would override the rewritten options.
    local name
    for name in WP_HOME WP_SITEURL; do
      if grep -Eq "define[[:space:]]*\\([[:space:]]*['\"]${name}['\"]" "$config"; then
        printf '{"defines": {"%s": %s}}' "$name" "$(wp_json_str "$url")" | wordpress_config_edit "$config" \
          || { error "Cannot set ${name} in ${config}"; return 1; }
        config_status+=", ${name} ${url}"
      fi
    done
  else
    prefix=""
    wordpress_write_config "$WP_DOMAIN" "$WP_DOC_ROOT" yes || { error "Cannot write wp-config.php"; return 1; }
    config_status="new from db.env (the archive had none)"
  fi

  progress_step "Importing the dump as ${SIMAI_USER}"
  if ! wp_restore_import_dump "$WP_DOMAIN" "$WP_RESTORE_DUMP" "$WP_RESTORE_DUMP_GZ"; then
    error "Database import failed (see ${LOG_FILE})"
    return 1
  fi
  local found_prefix
  if ! found_prefix=$(wp_restore_prefix "$WP_DB_NAME" "${prefix:-wp_}"); then
    error "The dump has no WordPress tables (no <prefix>options with <prefix>users)"
    return 1
  fi
  if [[ "$found_prefix" != "${prefix:-wp_}" || -z "$prefix" ]]; then
    printf '{"table_prefix": %s}' "$(wp_json_str "$found_prefix")" | wordpress_config_edit "$config" \
      || { error "Cannot set the table prefix in ${config}"; return 1; }
  fi

  progress_step "Site URL"
  wp_restore_rewrite_url "$WP_DB_NAME" "$found_prefix" "$url" || warn "Site URL: ${WP_RESTORE_URL_RESULT}"
  wp_flow_marker_write "$WP_DOMAIN" restore
  local finalize_status="ok"
  run_command wp finalize --domain "$WP_DOMAIN" --confirm yes || finalize_status="failed (run wp finalize again)"
  progress_done "WordPress restored"

  ui_result_table \
    "Domain|${WP_DOMAIN}" \
    "Backup before|${backup_status}" \
    "Files|${WP_RESTORE_FILES} -> ${WP_DOC_ROOT}" \
    "Core|${core_status}" \
    "wp-config.php|${config_status}" \
    "Database|${WP_DB_NAME} from $(basename "$WP_RESTORE_DUMP") (prefix ${found_prefix})" \
    "Site URL|${WP_RESTORE_URL_RESULT}" \
    "Finalize|${finalize_status}"
  ui_next_steps
  ui_kv "Open admin" "${url}/wp-admin/ (the copy's own users and passwords)"
  ui_kv "Status" "simai-admin.sh wp status --domain ${WP_DOMAIN}"
  [[ "$finalize_status" == ok ]] || return 1
  return 0
}

register_cmd "wp" "install" "Install WordPress end to end: core, wp-config, admin (password shown once), finalize" "wp_install_handler" "domain title admin-user admin-email" "locale= confirm=" "plan:handler"
register_cmd "wp" "restore-ready" "Restore a WordPress copy from a files archive and a database dump, then finalize" "wp_restore_ready_handler" "domain files dump" "overwrite= confirm=" "plan:handler"
