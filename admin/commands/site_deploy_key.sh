#!/usr/bin/env bash

# Per-site deploy keys for CI. Each key belongs to the system account
# simai-deploy and has a forced command: the gate (admin/deploy_gate.sh, run
# through one sudo rule) maps the key to exactly one site and accepts only
# deploy-artifact <sha256>, deploy-git <commit>, status and rollback.

SIMAI_DEPLOY_USER="${SIMAI_DEPLOY_USER:-simai-deploy}"
SIMAI_DEPLOY_KEYS_DIR="${SIMAI_DEPLOY_KEYS_DIR:-/etc/ssh/simai-deploy-keys}"
SIMAI_DEPLOY_REGISTRY="${SIMAI_DEPLOY_REGISTRY:-/etc/simai-env/deploy-keys}"
SIMAI_DEPLOY_GATE="${SIMAI_DEPLOY_GATE:-/usr/local/sbin/simai-deploy-gate}"
SIMAI_DEPLOY_SSHD_SNIPPET="${SIMAI_DEPLOY_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/92-simai-deploy.conf}"
SIMAI_DEPLOY_SUDOERS="${SIMAI_DEPLOY_SUDOERS:-/etc/sudoers.d/simai-deploy}"

deploy_key_infra_ensure() {
  if ! id -u "$SIMAI_DEPLOY_USER" >/dev/null 2>&1; then
    useradd --system --create-home --home-dir "/var/lib/${SIMAI_DEPLOY_USER}" --shell /bin/sh --user-group "$SIMAI_DEPLOY_USER" || return 1
  fi
  passwd -l "$SIMAI_DEPLOY_USER" >/dev/null 2>&1 || true
  install -d -m 0755 -o root -g root "$SIMAI_DEPLOY_KEYS_DIR" || return 1
  install -d -m 0700 -o root -g root "$SIMAI_DEPLOY_REGISTRY" /var/lib/simai-env/deploy-incoming || return 1
  local keys="${SIMAI_DEPLOY_KEYS_DIR}/${SIMAI_DEPLOY_USER}"
  [[ -f "$keys" ]] || install -m 0644 -o root -g root /dev/null "$keys"
  # The gate runs the toolkit's own script; root owns both.
  printf '#!/bin/sh\n# simai-env deploy gate (forced command of CI deploy keys)\nexec /bin/bash %s/admin/deploy_gate.sh "$@"\n' "$SIMAI_ENV_ROOT" >"${SIMAI_DEPLOY_GATE}.tmp" \
    && chmod 0755 "${SIMAI_DEPLOY_GATE}.tmp" && mv -f "${SIMAI_DEPLOY_GATE}.tmp" "$SIMAI_DEPLOY_GATE" || return 1
  if ! grep -qs 'simai-deploy-v1' "$SIMAI_DEPLOY_SUDOERS"; then
    local tmp
    tmp=$(mktemp) || return 1
    printf '# simai-deploy-v1 (managed by simai-env): CI deploy keys may run the gate only.\n%s ALL=(root) NOPASSWD: %s\n' "$SIMAI_DEPLOY_USER" "$SIMAI_DEPLOY_GATE" >"$tmp"
    visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; error "sudoers rule for ${SIMAI_DEPLOY_USER} rejected by visudo"; return 1; }
    install -m 0440 -o root -g root "$tmp" "$SIMAI_DEPLOY_SUDOERS" && rm -f "$tmp" || return 1
  fi
  if ! grep -qs 'simai-deploy-v1' "$SIMAI_DEPLOY_SSHD_SNIPPET"; then
    install -d -m 0755 "$(dirname "$SIMAI_DEPLOY_SSHD_SNIPPET")"
    cat >"$SIMAI_DEPLOY_SSHD_SNIPPET" <<EOF
# simai-deploy-v1 (managed by simai-env)
Match User ${SIMAI_DEPLOY_USER}
    AuthorizedKeysFile ${SIMAI_DEPLOY_KEYS_DIR}/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
EOF
    chmod 0644 "$SIMAI_DEPLOY_SSHD_SNIPPET"
    if command -v sshd >/dev/null 2>&1; then
      if ! sshd -t 2>>"$LOG_FILE"; then
        rm -f -- "$SIMAI_DEPLOY_SSHD_SNIPPET"
        error "sshd rejected the deploy key configuration; it was removed"
        return 1
      fi
      systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    fi
  fi
}

deploy_key_registry_get() {
  sed -n "s/^${2}=//p" "${SIMAI_DEPLOY_REGISTRY}/$1" 2>/dev/null | tail -n1
}

# known_hosts lines for CI: the server's host keys under the given name.
deploy_key_known_hosts() {
  local host="$1" pub
  for pub in /etc/ssh/ssh_host_ed25519_key.pub /etc/ssh/ssh_host_ecdsa_key.pub /etc/ssh/ssh_host_rsa_key.pub; do
    [[ -f "$pub" ]] && printf '%s %s\n' "$host" "$(awk '{print $1" "$2}' "$pub")"
  done
  return 0
}

site_deploy_key_add_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" key_file="${PARSED_ARGS[pubkey-file]:-}" git_url="${PARSED_ARGS[git]:-}"
  local host="${PARSED_ARGS[host]:-}"
  require_args "domain pubkey-file" || return 1
  require_site_exists "$domain" || return 1
  [[ -f "$key_file" ]] || { error "Public key file not found: ${key_file}"; return 1; }
  local key
  key=$(grep -v '^[[:space:]]*\(#\|$\)' "$key_file" | head -n1) || key=""
  [[ "$key" =~ ^(ssh-ed25519|ecdsa-sha2-nistp(256|384|521)|ssh-rsa)\ [A-Za-z0-9+/=]{40,}(\ .*)?$ ]] || { error "Not an SSH public key (ssh-ed25519 recommended)"; return 1; }
  key=$(awk '{print $1" "$2}' <<<"$key")
  ssh-keygen -l -f /dev/stdin <<<"$key" >/dev/null 2>&1 || { error "Not a valid SSH public key"; return 1; }
  local mode=artifact
  if [[ -n "$git_url" ]]; then
    [[ "$git_url" =~ ^(https://|ssh://|git@)[A-Za-z0-9@:/._~-]+$ ]] || { error "Unsupported git URL"; return 1; }
    mode=git
  fi
  if grep -qF " ${key} " "${SIMAI_DEPLOY_KEYS_DIR}/${SIMAI_DEPLOY_USER}" 2>/dev/null || grep -qF "\" ${key}" "${SIMAI_DEPLOY_KEYS_DIR}/${SIMAI_DEPLOY_USER}" 2>/dev/null; then
    error "This key is already a deploy key; use one key per site"
    return 1
  fi
  deploy_key_infra_ensure || return 1
  local id fpr
  id=$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')
  fpr=$(ssh-keygen -l -f /dev/stdin <<<"$key" | awk '{print $2}')
  {
    printf 'DOMAIN=%s\nMODE=%s\nFINGERPRINT=%s\nCREATED=%s\n' "$domain" "$mode" "$fpr" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    [[ -n "$git_url" ]] && printf 'GIT_URL=%s\n' "$git_url"
  } >"${SIMAI_DEPLOY_REGISTRY}/${id}"
  chmod 0600 "${SIMAI_DEPLOY_REGISTRY}/${id}"
  # sshd runs the forced command through the account's shell; the quoted
  # $SSH_ORIGINAL_COMMAND reaches the gate as one argument and is parsed there.
  printf 'restrict,command="sudo -n %s %s \\"$SSH_ORIGINAL_COMMAND\\"" %s simai-deploy:%s:%s\n' \
    "$SIMAI_DEPLOY_GATE" "$id" "$key" "$domain" "$id" >>"${SIMAI_DEPLOY_KEYS_DIR}/${SIMAI_DEPLOY_USER}"
  [[ -n "$host" ]] || host=$(site_best_effort_primary_ip 2>/dev/null || hostname -I | awk '{print $1}')
  ui_result_table "Domain|${domain}" "Key id|${id}" "Fingerprint|${fpr}" "Allows|$([[ $mode == git ]] && echo "deploy-git <commit> from ${git_url}" || echo "deploy-artifact <sha256>"), status, rollback" "Login|${SIMAI_DEPLOY_USER}@${host}"
  echo "SIMAI_DEPLOY_KNOWN_HOSTS (repository secret):"
  deploy_key_known_hosts "$host"
}

site_deploy_key_list_handler() {
  parse_kv_args "$@"
  local filter="${PARSED_ARGS[domain]:-}" f id rows=()
  for f in "$SIMAI_DEPLOY_REGISTRY"/*; do
    [[ -f "$f" ]] || continue
    id=$(basename "$f")
    [[ -z "$filter" || "$(deploy_key_registry_get "$id" DOMAIN)" == "$filter" ]] || continue
    rows+=("${id}|$(deploy_key_registry_get "$id" DOMAIN) $(deploy_key_registry_get "$id" MODE) $(deploy_key_registry_get "$id" FINGERPRINT) $(deploy_key_registry_get "$id" CREATED)")
  done
  [[ ${#rows[@]} -gt 0 ]] || rows=("Deploy keys|none")
  ui_result_table "${rows[@]}"
}

# Extra gate commands of one key (1.66.0): artisan <name> for the listed
# names, env-set <NAME> for names starting with the prefix. Empty clears.
site_deploy_key_allow_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[key-id]:-}" artisan="${PARSED_ARGS[artisan]-__keep__}" prefix="${PARSED_ARGS[env-prefix]-__keep__}"
  require_args "key-id" || return 1
  [[ "$id" =~ ^[a-f0-9]{12}$ && -f "${SIMAI_DEPLOY_REGISTRY}/${id}" ]] || { error "Unknown deploy key ${id}"; return 1; }
  [[ "$artisan" == __keep__ ]] && artisan=$(deploy_key_registry_get "$id" ARTISAN)
  [[ "$prefix" == __keep__ ]] && prefix=$(deploy_key_registry_get "$id" ENV_PREFIX)
  artisan="${artisan// /}"
  [[ -z "$artisan" || "$artisan" =~ ^[a-z0-9:_-]+(,[a-z0-9:_-]+){0,49}$ ]] || { error "--artisan is a comma list of artisan command names"; return 1; }
  local name
  for name in ${artisan//,/ }; do
    case "$name" in
      tinker|db|db:*|down|up|env|key:generate|migrate:fresh|migrate:reset|migrate:rollback|schedule:run|queue:work|serve)
        error "artisan ${name} cannot be given to a deploy key"; return 1 ;;
    esac
  done
  [[ -z "$prefix" || "$prefix" =~ ^[A-Z][A-Z0-9]*_([A-Z0-9]+_)*$ ]] || { error "--env-prefix is like LARENA_SERVER_ (upper case, ends with _)"; return 1; }
  case "$prefix" in APP_|DB_|MAIL_|REDIS_|AWS_|SESSION_|CACHE_|QUEUE_|LOG_) error "--env-prefix ${prefix} would reach the application's own settings"; return 1 ;; esac
  local f="${SIMAI_DEPLOY_REGISTRY}/${id}" tmp
  tmp=$(mktemp) || return 1
  grep -v '^\(ARTISAN\|ENV_PREFIX\)=' "$f" >"$tmp" || true
  [[ -n "$artisan" ]] && printf 'ARTISAN=%s\n' "$artisan" >>"$tmp"
  [[ -n "$prefix" ]] && printf 'ENV_PREFIX=%s\n' "$prefix" >>"$tmp"
  install -m 0600 -o root -g root "$tmp" "$f" && rm -f "$tmp" || return 1
  ui_result_table "Key id|${id}" "Domain|$(deploy_key_registry_get "$id" DOMAIN)" "Artisan|${artisan:-none}" "Env prefix|${prefix:-none}"
}

site_deploy_key_remove_handler() {
  parse_kv_args "$@"
  local id="${PARSED_ARGS[key-id]:-}" keys tmp
  require_args "key-id" || return 1
  [[ "$id" =~ ^[a-f0-9]{12}$ && -f "${SIMAI_DEPLOY_REGISTRY}/${id}" ]] || { error "Unknown deploy key ${id}"; return 1; }
  keys="${SIMAI_DEPLOY_KEYS_DIR}/${SIMAI_DEPLOY_USER}"
  tmp=$(mktemp) || return 1
  grep -v " simai-deploy:[^:]*:${id}\$" "$keys" >"$tmp" || true
  install -m 0644 -o root -g root "$tmp" "$keys" && rm -f "$tmp" || return 1
  local domain
  domain=$(deploy_key_registry_get "$id" DOMAIN)
  rm -f -- "${SIMAI_DEPLOY_REGISTRY:?}/${id}"
  ui_result_table "Removed|${id}" "Domain|${domain}"
}

register_cmd "site" "deploy-key-add" "Add a CI deploy key that can only deploy this site (artifact, or --git commit)" "site_deploy_key_add_handler" "domain pubkey-file" "git= host=" "tier:advanced"
register_cmd "site" "deploy-key-allow" "Let a deploy key run named artisan commands and set .env names with a prefix (replaces the lists)" "site_deploy_key_allow_handler" "key-id" "artisan= env-prefix=" "tier:advanced"
register_cmd "site" "deploy-key-list" "List CI deploy keys" "site_deploy_key_list_handler" "" "domain=" "effects:read"
register_cmd "site" "deploy-key-remove" "Revoke a CI deploy key" "site_deploy_key_remove_handler" "key-id" "" "tier:advanced"
