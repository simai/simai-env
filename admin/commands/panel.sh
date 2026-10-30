#!/usr/bin/env bash

# Larena Panel (docs/architecture/panel-gate.md). Two accounts may run
# exactly one program as root, the gateway (admin/panel_gate.py), which reads
# one JSON request on stdin: the account of the installed panel site
# (`panel install`), and simai-panel for a panel elsewhere that comes in over
# SSH or for the local stand (`panel gate-enable`).

SIMAI_PANEL_USER="${SIMAI_PANEL_USER:-simai-panel}"
SIMAI_PANEL_GATE="${SIMAI_PANEL_GATE:-/usr/local/sbin/simai-panel-gate}"
SIMAI_PANEL_SUDOERS="${SIMAI_PANEL_SUDOERS:-/etc/sudoers.d/simai-panel}"
SIMAI_PANEL_KEYS_DIR="${SIMAI_PANEL_KEYS_DIR:-/etc/ssh/simai-panel-keys}"
SIMAI_PANEL_SSHD_SNIPPET="${SIMAI_PANEL_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/93-simai-panel.conf}"
SIMAI_PANEL_GATE_LOG="${SIMAI_PANEL_GATE_LOG:-/var/log/simai-panel-gate.log}"
SIMAI_PANEL_STATE="${SIMAI_PANEL_STATE:-/etc/simai-env/panel.env}"

panel_state_get() {
  [[ -f "$SIMAI_PANEL_STATE" ]] || return 0
  sed -n "s/^${1}=//p" "$SIMAI_PANEL_STATE" | tail -n1
}

panel_state_set() {
  local key="$1" value="$2" tmp
  install -d -m 0755 "$(dirname "$SIMAI_PANEL_STATE")"
  tmp=$(mktemp) || return 1
  { grep -v "^${key}=" "$SIMAI_PANEL_STATE" 2>/dev/null || true; [[ -n "$value" ]] && printf '%s=%s\n' "$key" "$value"; } >"$tmp"
  install -m 0600 -o root -g root "$tmp" "$SIMAI_PANEL_STATE" && rm -f "$tmp"
}

# The wrapper and one sudo line per account that may call the gateway; both
# go away when no account is left.
panel_gate_sync() {
  local -a accounts=()
  # Hosts that enabled the gateway before 1.23.0 have the sudo line but no state.
  if ! grep -qs '^GATE_ACCOUNT=' "$SIMAI_PANEL_STATE" && grep -qs "^${SIMAI_PANEL_USER} ALL=" "$SIMAI_PANEL_SUDOERS"; then
    panel_state_set GATE_ACCOUNT yes || return 1
  fi
  [[ "$(panel_state_get GATE_ACCOUNT)" == yes ]] && accounts+=("$SIMAI_PANEL_USER")
  [[ -n "$(panel_state_get PANEL_USER)" ]] && accounts+=("$(panel_state_get PANEL_USER)")
  if [[ ${#accounts[@]} -eq 0 ]]; then
    rm -f -- "$SIMAI_PANEL_SUDOERS" "$SIMAI_PANEL_GATE"
    return 0
  fi
  command -v python3 >/dev/null || { error "python3 is required for the panel gateway"; return 1; }
  # No arguments reach the gateway: the request comes on stdin only.
  printf '#!/bin/sh\n# simai-env panel gateway\nexec /usr/bin/python3 -I %s/admin/panel_gate.py\n' "$SIMAI_ENV_ROOT" >"${SIMAI_PANEL_GATE}.tmp" \
    && chmod 0755 "${SIMAI_PANEL_GATE}.tmp" && mv -f "${SIMAI_PANEL_GATE}.tmp" "$SIMAI_PANEL_GATE" || return 1
  local tmp account
  tmp=$(mktemp) || return 1
  printf '# simai-panel-v1 (managed by simai-env): these accounts may run the gateway only, without arguments.\n' >"$tmp"
  for account in "${accounts[@]}"; do
    printf '%s ALL=(root) NOPASSWD: %s ""\n' "$account" "$SIMAI_PANEL_GATE" >>"$tmp"
  done
  visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; error "sudoers rule for the panel gateway rejected by visudo"; return 1; }
  install -m 0440 -o root -g root "$tmp" "$SIMAI_PANEL_SUDOERS" && rm -f "$tmp" || return 1
  [[ -f "$SIMAI_PANEL_GATE_LOG" ]] || install -m 0600 -o root -g root /dev/null "$SIMAI_PANEL_GATE_LOG"
}

panel_gate_ssh_ensure() {
  install -d -m 0755 -o root -g root "$SIMAI_PANEL_KEYS_DIR" || return 1
  local keys="${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}"
  [[ -f "$keys" ]] || install -m 0644 -o root -g root /dev/null "$keys"
  grep -qs 'simai-panel-v1' "$SIMAI_PANEL_SSHD_SNIPPET" && return 0
  install -d -m 0755 "$(dirname "$SIMAI_PANEL_SSHD_SNIPPET")"
  cat >"$SIMAI_PANEL_SSHD_SNIPPET" <<EOF
# simai-panel-v1 (managed by simai-env)
Match User ${SIMAI_PANEL_USER}
    AuthorizedKeysFile ${SIMAI_PANEL_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
EOF
  chmod 0644 "$SIMAI_PANEL_SSHD_SNIPPET"
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>>"$LOG_FILE"; then
      rm -f -- "$SIMAI_PANEL_SSHD_SNIPPET"
      error "sshd rejected the panel key configuration; it was removed"
      return 1
    fi
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
}

panel_gate_enable_handler() {
  parse_kv_args "$@"
  local pubkey_file="${PARSED_ARGS[pubkey-file]:-}" fp=""
  if [[ -n "$pubkey_file" ]]; then
    [[ -f "$pubkey_file" ]] || { error "Public key file not found: ${pubkey_file}"; return 1; }
    [[ "$(grep -cv '^\s*$' "$pubkey_file")" -eq 1 ]] || { error "--pubkey-file must hold exactly one public key"; return 1; }
    fp=$(ssh-keygen -lf "$pubkey_file" 2>/dev/null | awk '{print $2}')
    [[ -n "$fp" ]] || { error "Not a valid SSH public key: ${pubkey_file}"; return 1; }
  fi
  if ! id -u "$SIMAI_PANEL_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${SIMAI_PANEL_USER}" --shell /bin/sh --user-group "$SIMAI_PANEL_USER" || return 1
  fi
  passwd -l "$SIMAI_PANEL_USER" >/dev/null 2>&1 || true
  panel_state_set GATE_ACCOUNT yes || return 1
  panel_gate_sync || return 1
  if [[ -n "$pubkey_file" ]]; then
    panel_gate_ssh_ensure || return 1
    local keys="${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" key
    key=$(awk 'NF {print $1" "$2; exit}' "$pubkey_file")
    if ! grep -qF " simai-panel:${fp}" "$keys"; then
      printf 'restrict,command="sudo -n %s" %s simai-panel:%s\n' "$SIMAI_PANEL_GATE" "$key" "$fp" >>"$keys"
    fi
  fi
  local -a rows=("Account|${SIMAI_PANEL_USER}" "Gateway|${SIMAI_PANEL_GATE}" "Call|sudo -n ${SIMAI_PANEL_GATE} < request.json")
  [[ -n "$fp" ]] && rows+=("SSH key|${fp}")
  ui_result_table "${rows[@]}"
}

panel_gate_disable_handler() {
  rm -f -- "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}"
  if [[ -f "$SIMAI_PANEL_SSHD_SNIPPET" ]]; then
    rm -f -- "$SIMAI_PANEL_SSHD_SNIPPET"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  fi
  # An explicit "no": the pre-1.23.0 migration in panel_gate_sync must not
  # read the old sudo line as still enabled.
  panel_state_set GATE_ACCOUNT no || return 1
  panel_gate_sync || return 1
  local rest="disabled"
  [[ -n "$(panel_state_get PANEL_USER)" ]] && rest="kept for the installed panel ($(panel_state_get PANEL_USER))"
  ui_result_table "Account ${SIMAI_PANEL_USER}|removed from the gateway" "Gateway|${rest}" "Log kept|${SIMAI_PANEL_GATE_LOG}"
}

panel_gate_status_handler() {
  local enabled=no keys=0
  [[ -x "$SIMAI_PANEL_GATE" && -f "$SIMAI_PANEL_SUDOERS" ]] && enabled=yes
  [[ -f "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" ]] && keys=$(grep -c ' simai-panel:' "${SIMAI_PANEL_KEYS_DIR}/${SIMAI_PANEL_USER}" || true)
  ui_result_table "Enabled|${enabled}" "Account|${SIMAI_PANEL_USER} ($([[ "$(panel_state_get GATE_ACCOUNT)" == yes ]] && echo enabled || echo off))" \
    "Panel site account|$(panel_state_get PANEL_USER | grep . || echo none)" "SSH keys|${keys}" "Log|${SIMAI_PANEL_GATE_LOG}"
}

# The panel is an ordinary isolated site. Without a source it gets the
# placeholder (templates/panel-placeholder, a generic PHP site); with --git or
# --archive the Larena build (a Laravel site with a database), which replaces
# the placeholder.
panel_admin() { SIMAI_ADMIN_MENU=0 bash "${SIMAI_ENV_ROOT}/simai-admin.sh" "$@"; }

panel_site_root() { printf '%s/%s\n' "$WWW_ROOT" "$1"; }

panel_setup_token_write() {
  local domain="$1" user="$2" root env token tmp
  root=$(panel_site_root "$domain"); env="${root}/.env"
  token=$(openssl rand -hex 32) || return 1
  tmp=$(mktemp) || return 1
  { grep -v '^SIMAI_PANEL_SETUP_TOKEN=' "$env" 2>/dev/null || true; printf 'SIMAI_PANEL_SETUP_TOKEN=%s\n' "$token"; } >"$tmp"
  install -m 0640 -o "$user" -g "$user" "$tmp" "$env" && rm -f "$tmp" || return 1
  printf '%s\n' "$token"
}

panel_print_setup_link() {
  local domain="$1" token="$2" scheme=http
  [[ -n "$(panel_state_get SSL)" ]] && scheme=https
  # The link is a one-time secret for the operator: stdout only, never the log.
  printf '\nFirst sign-in (one time): %s://%s/?setup=%s\n' "$scheme" "$domain" "$token"
}

# env_set_kv gives the file to SIMAI_USER; .env must stay with the panel's
# account, which reads it for every artisan call.
panel_env_set() {
  local domain="$1" key="$2" value="$3" project user env
  env="$(panel_site_root "$domain")/.env"
  project=$(site_project_for_domain "$domain") || return 1
  user=$(site_user_for_project "$project") || return 1
  env_set_kv "$env" "$key" "$value" && chown "${user}:${user}" "$env"
}

# A build becomes a site through adopt: requirements from its manifest, .env
# from its own template, database, APP_KEY and migrations. The caller then
# deploys the same source, so the site has releases to roll back to.
panel_adopt_build() {
  local domain="$1" git="$2" ref="$3" archive="$4" sha="$5" php="$6" engine="$7" root
  root=$(panel_site_root "$domain")
  [[ ! -e "$root" ]] || { error "${root} already exists; the panel needs a directory of its own"; return 1; }
  if [[ -n "$archive" ]]; then
    deploy_archive_safe "$archive" || return 1
    install -d -m 0755 "$root" && tar --no-same-owner --no-same-permissions -xzf "$archive" -C "$root" \
      || { error "Could not unpack ${archive}"; return 1; }
  else
    git clone -q --depth 1 --branch "$ref" -- "$git" "$root" >>"$LOG_FILE" 2>&1 || { error "Could not fetch ${ref}; see ${LOG_FILE}"; return 1; }
    rm -rf --one-file-system -- "${root}/.git"
  fi
  local -a adopt=(site adopt --domain "$domain" --path "$root" --profile laravel --create-db yes --confirm yes)
  [[ -n "$php" ]] && adopt+=(--php "$php")
  [[ -n "$engine" ]] && adopt+=(--db-engine "$engine")
  panel_admin "${adopt[@]}" >>"$LOG_FILE" 2>&1 || { error "Installing the panel build failed; see ${LOG_FILE}"; return 1; }
  # The panel shows server data: error pages must never carry debug output.
  panel_env_set "$domain" APP_ENV production && panel_env_set "$domain" APP_DEBUG false \
    && panel_env_set "$domain" APP_URL "http://${domain}"
}

# A failed first install leaves nothing behind: the domain and directory were
# checked to be new, and the panel holds no data yet.
panel_install_abort() {
  local domain="$1"
  [[ -f "/etc/nginx/sites-available/${domain}.conf" ]] && panel_remove_site "$domain"
  rm -rf --one-file-system -- "$(panel_site_root "$domain")"
  local key
  for key in PANEL_DOMAIN PANEL_USER SOURCE INSTALLED_AT SSL; do panel_state_set "$key" ""; done
  panel_gate_sync
}

# The health path of the release in current: 2xx or 3xx, as for service sites.
panel_health_ok() {
  local domain="$1" probe=/ code _
  if app_manifest_load "$(panel_site_root "$domain")/current" >/dev/null 2>&1; then probe="${APP_HEALTH_PATH:-/}"; fi
  for _ in {1..15}; do
    code=$(deploy_static_probe "$domain" "$probe")
    [[ "$code" =~ ^[23] ]] && return 0
    sleep 2
  done
  warn "${domain}${probe} answers ${code}"
  return 1
}

panel_install_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" git="${PARSED_ARGS[git]:-}" ref="${PARSED_ARGS[ref]:-}"
  local archive="${PARSED_ARGS[archive]:-}" sha="${PARSED_ARGS[sha256]:-}" php="${PARSED_ARGS[php]:-}"
  local email="${PARSED_ARGS[ssl-email]:-}" engine="${PARSED_ARGS[db-engine]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  [[ -z "$git" || -n "$ref" ]] || { error "--git needs --ref"; return 1; }
  [[ -z "$archive" || -n "$sha" ]] || { error "--archive needs --sha256"; return 1; }
  [[ -z "$git" || -z "$archive" ]] || { error "Use --git or --archive, not both"; return 1; }
  if [[ -n "$archive" ]]; then
    [[ -f "$archive" ]] || { error "Archive not found: ${archive}"; return 1; }
    [[ "$(sha256sum "$archive" | cut -d' ' -f1)" == "${sha,,}" ]] || { error "Archive checksum does not match --sha256"; return 1; }
  fi
  local installed source=placeholder profile=generic
  installed=$(panel_state_get PANEL_DOMAIN)
  [[ -n "$git$archive" ]] && { source=build; profile=laravel; }
  if [[ -n "$installed" && "$installed" != "$domain" ]]; then
    error "The panel is already installed at ${installed}; remove it first (panel remove)"
    return 1
  fi
  if [[ -n "$installed" ]]; then
    if [[ "$source" == placeholder ]]; then
      error "The panel is already installed at ${domain}; give --git/--ref or --archive/--sha256 to install the panel build"
      return 1
    fi
    if [[ "$(panel_state_get SOURCE)" != placeholder ]]; then
      error "The panel build is already installed at ${domain}; use panel update"
      return 1
    fi
    # The placeholder holds no data: replace it with a Laravel site.
    info "Replacing the panel placeholder at ${domain}"
    panel_remove_site "$domain" || return 1
    installed=""
  elif [[ -f "/etc/nginx/sites-available/${domain}.conf" ]]; then
    error "${domain} is an existing site; the panel needs a domain of its own"
    return 1
  fi
  local steps=3
  [[ -n "$email" ]] && steps=$((steps + 1))
  progress_init "$steps"
  progress_step "Creating the panel site ${domain} (${profile})"
  if [[ "$source" == build ]]; then
    panel_adopt_build "$domain" "$git" "$ref" "$archive" "$sha" "$php" "$engine" || { panel_install_abort "$domain"; return 1; }
  else
    local -a add=(site add --domain "$domain" --profile "$profile" --create-db no --confirm yes)
    [[ -n "$php" ]] && add+=(--php "$php")
    panel_admin "${add[@]}" >>"$LOG_FILE" 2>&1 || { error "Creating the panel site failed; see ${LOG_FILE}"; return 1; }
  fi
  local project user
  project=$(site_project_for_domain "$domain") || { error "Panel site ${domain} not found after creation"; return 1; }
  user=$(site_user_for_project "$project") || { error "The panel site must run as its own account (site isolation is off)"; return 1; }
  [[ -f "$(panel_site_root "$domain")/.env" ]] || install -m 0640 -o "$user" -g "$user" /dev/null "$(panel_site_root "$domain")/.env"
  progress_step "Deploying the panel (${source})"
  local -a deploy=(site deploy --domain "$domain" --confirm yes)
  if [[ -n "$git" ]]; then
    deploy+=(--git "$git" --ref "$ref")
  elif [[ -n "$archive" ]]; then
    deploy+=(--archive "$archive" --sha256 "$sha")
  else
    local tgz
    tgz=$(mktemp --suffix=.tar.gz) || return 1
    tar -C "${SIMAI_ENV_ROOT}/templates/panel-placeholder" -czf "$tgz" . || { rm -f "$tgz"; return 1; }
    chmod 0644 "$tgz"
    deploy+=(--archive "$tgz" --sha256 "$(sha256sum "$tgz" | cut -d' ' -f1)")
  fi
  local rc=0
  panel_admin "${deploy[@]}" >>"$LOG_FILE" 2>&1 || rc=$?
  [[ -n "${tgz:-}" ]] && rm -f "$tgz"
  (( rc == 0 )) || { error "Deploying the panel failed; see ${LOG_FILE}"; panel_install_abort "$domain"; return 1; }
  if [[ "$source" == build ]] && ! panel_health_ok "$domain"; then
    error "The panel build does not answer its health path; nothing was installed. See ${LOG_FILE}"
    panel_install_abort "$domain"
    return 1
  fi
  progress_step "Letting the panel account ${user} call the gateway"
  panel_state_set PANEL_DOMAIN "$domain" && panel_state_set PANEL_USER "$user" && panel_state_set SOURCE "$source" || return 1
  panel_state_set INSTALLED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
  panel_gate_sync || return 1
  if [[ -n "$email" ]]; then
    progress_step "Requesting a Let's Encrypt certificate"
    if panel_admin ssl letsencrypt --domain "$domain" --email "$email" --redirect yes --confirm yes >>"$LOG_FILE" 2>&1; then
      panel_state_set SSL letsencrypt || return 1
      [[ "$source" == build ]] && panel_env_set "$domain" APP_URL "https://${domain}"
    else
      warn "Certificate request failed (DNS must point to this server); retry: simai-admin.sh ssl letsencrypt --domain ${domain} --email ${email} --confirm yes"
    fi
  fi
  local token
  token=$(panel_setup_token_write "$domain" "$user") || return 1
  ui_result_table "Panel|${domain}" "Source|${source}" "Runs as|${user}" "Gateway|${SIMAI_PANEL_GATE}"
  panel_print_setup_link "$domain" "$token"
}

# A data backup first, then an ordinary deploy: it migrates before the switch
# and a failed release never replaces the current one. A release that does not
# answer its health path is rolled back; the database is not.
panel_update_handler() {
  parse_kv_args "$@"
  local git="${PARSED_ARGS[git]:-}" ref="${PARSED_ARGS[ref]:-}" archive="${PARSED_ARGS[archive]:-}" sha="${PARSED_ARGS[sha256]:-}"
  local domain
  domain=$(panel_state_get PANEL_DOMAIN)
  [[ -n "$domain" ]] || { error "The panel is not installed (panel install)"; return 1; }
  [[ "$(panel_state_get SOURCE)" == build ]] || { error "The placeholder has nothing to update; install a build: panel install --domain ${domain} --archive F --sha256 S"; return 1; }
  [[ -n "$git$archive" ]] || { error "Give --archive/--sha256 or --git/--ref"; return 1; }
  [[ -z "$git" || -n "$ref" ]] || { error "--git needs --ref"; return 1; }
  [[ -z "$archive" || -n "$sha" ]] || { error "--archive needs --sha256"; return 1; }
  [[ -z "$git" || -z "$archive" ]] || { error "Use --git or --archive, not both"; return 1; }
  local deploy_file previous current
  deploy_file="$(site_sites_config_dir)/${domain}/deploy.env"
  previous=$(sed -n 's/^CURRENT=//p' "$deploy_file" 2>/dev/null | tail -n1)
  progress_init 3
  progress_step "Backing up the panel's data"
  panel_admin backup data --domain "$domain" --confirm yes >>"$LOG_FILE" 2>&1 || { error "Backup failed; the panel was not updated. See ${LOG_FILE}"; return 1; }
  progress_step "Deploying the new release"
  local -a deploy=(site deploy --domain "$domain" --confirm yes)
  if [[ -n "$git" ]]; then deploy+=(--git "$git" --ref "$ref"); else deploy+=(--archive "$archive" --sha256 "$sha"); fi
  panel_admin "${deploy[@]}" >>"$LOG_FILE" 2>&1 || { error "The update failed; release ${previous} keeps serving. See ${LOG_FILE}"; return 1; }
  progress_step "Checking the panel answers"
  if ! panel_health_ok "$domain"; then
    panel_admin site deploy-rollback --domain "$domain" --release "$previous" --confirm yes >>"$LOG_FILE" 2>&1 || { error "The new release is broken and the rollback failed; see ${LOG_FILE}"; return 1; }
    error "The new release does not answer its health path; rolled back to ${previous}. The database is not rolled back: a backup was taken first (backup data-restore)"
    return 1
  fi
  current=$(sed -n 's/^CURRENT=//p' "$deploy_file" | tail -n1)
  ui_result_table "Panel|${domain}" "Release|${current}" "Previous|${previous}"
}

panel_setup_link_handler() {
  local domain user token
  domain=$(panel_state_get PANEL_DOMAIN); user=$(panel_state_get PANEL_USER)
  [[ -n "$domain" && -n "$user" ]] || { error "The panel is not installed (panel install)"; return 1; }
  token=$(panel_setup_token_write "$domain" "$user") || return 1
  ui_result_table "Panel|${domain}" "Setup link|replaced; the previous link no longer works"
  panel_print_setup_link "$domain" "$token"
}

panel_remove_site() {
  local domain="$1"
  local -a remove=(site remove --domain "$1" --remove-files yes --confirm yes)
  [[ -f "$(site_sites_config_dir)/${domain}/db.env" ]] && remove+=(--drop-db yes --drop-db-user yes)
  panel_admin "${remove[@]}" >>"$LOG_FILE" 2>&1 || { error "Removing the panel site ${domain} failed; see ${LOG_FILE}"; return 1; }
}

panel_remove_handler() {
  local domain
  domain=$(panel_state_get PANEL_DOMAIN)
  [[ -n "$domain" ]] || { error "The panel is not installed"; return 1; }
  progress_init 2
  progress_step "Removing the gateway access of the panel account"
  panel_state_set PANEL_USER "" && panel_gate_sync || return 1
  progress_step "Removing the panel site ${domain} (other sites are not touched)"
  panel_remove_site "$domain" || return 1
  local key
  for key in PANEL_DOMAIN SOURCE INSTALLED_AT SSL; do panel_state_set "$key" "" || return 1; done
  ui_result_table "Panel|removed (${domain})" "Other sites|unchanged" "Gateway log kept|${SIMAI_PANEL_GATE_LOG}"
}

panel_status_handler() {
  local domain
  domain=$(panel_state_get PANEL_DOMAIN)
  if [[ -z "$domain" ]]; then
    ui_result_table "Panel|not installed" "Install|simai-admin.sh panel install --domain <name> --confirm yes"
    return 0
  fi
  ui_result_table "Panel|${domain}" "Source|$(panel_state_get SOURCE)" "Runs as|$(panel_state_get PANEL_USER)" \
    "Installed|$(panel_state_get INSTALLED_AT)" "Release|$(sed -n 's/^CURRENT=//p' "$(site_sites_config_dir)/${domain}/deploy.env" 2>/dev/null | tail -n1)" \
    "Gateway|$([[ -x "$SIMAI_PANEL_GATE" ]] && echo enabled || echo missing)"
}

register_cmd "panel" "install" "Install Larena Panel as its own site (placeholder, or the build from --git/--archive)" "panel_install_handler" "domain" "git= ref= archive= sha256= php= db-engine= ssl-email=" "tier:advanced lock:none"
register_cmd "panel" "update" "Update the panel build: data backup, deploy, health check, rollback on failure" "panel_update_handler" "" "git= ref= archive= sha256=" "tier:advanced lock:none"
register_cmd "panel" "remove" "Remove the panel site and its gateway access (other sites are not touched)" "panel_remove_handler" "" "" "tier:advanced lock:none"
register_cmd "panel" "status" "Show the installed panel" "panel_status_handler" "" "" "effects:read"
register_cmd "panel" "setup-link" "Replace the panel's one-time first sign-in link" "panel_setup_link_handler" "" "" "tier:advanced"
register_cmd "panel" "gate-enable" "Let the panel account call the read-only gateway (optionally over SSH)" "panel_gate_enable_handler" "" "pubkey-file=" "tier:advanced"
register_cmd "panel" "gate-disable" "Remove the panel gateway, its sudo rule and SSH keys" "panel_gate_disable_handler" "" "" "tier:advanced"
register_cmd "panel" "gate-status" "Show whether the panel gateway is enabled" "panel_gate_status_handler" "" "" "effects:read"
