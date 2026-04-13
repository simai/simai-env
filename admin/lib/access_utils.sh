#!/usr/bin/env bash

SIMAI_ACCESS_DIR=${SIMAI_ACCESS_DIR:-/etc/simai-env/access}
SIMAI_ACCESS_GROUP_GLOBAL=${SIMAI_ACCESS_GROUP_GLOBAL:-simai-access-global}
SIMAI_ACCESS_GROUP_PROJECT=${SIMAI_ACCESS_GROUP_PROJECT:-simai-access-project}
SIMAI_ACCESS_SSHD_SNIPPET=${SIMAI_ACCESS_SSHD_SNIPPET:-/etc/ssh/sshd_config.d/90-simai-access.conf}
SIMAI_ACCESS_JAIL_BASE=${SIMAI_ACCESS_JAIL_BASE:-/var/lib/simai-access/jails}
SIMAI_ACCESS_HOME_BASE=${SIMAI_ACCESS_HOME_BASE:-/var/lib/simai-access/home}

access_dir() {
  echo "$SIMAI_ACCESS_DIR"
}

access_metadata_file() {
  local login="$1"
  echo "$(access_dir)/${login}.env"
}

access_validate_login() {
  local login="$1"
  if [[ ! "$login" =~ ^[a-z][a-z0-9-]{2,31}$ ]]; then
    error "Invalid login '${login}'. Use lowercase letters, numbers, and dashes only (3-32 chars, must start with a letter)."
    return 1
  fi
  if [[ "$login" == "root" || "$login" == "$SIMAI_USER" ]]; then
    error "Login '${login}' is reserved; choose another name."
    return 1
  fi
}

access_generate_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '\n'
  else
    date +%s%N | sha256sum | awk '{print substr($1,1,24)}'
  fi
}

access_ensure_prereqs() {
  local missing=()
  command -v useradd >/dev/null 2>&1 || missing+=("useradd")
  command -v usermod >/dev/null 2>&1 || missing+=("usermod")
  command -v chpasswd >/dev/null 2>&1 || missing+=("chpasswd")
  command -v setfacl >/dev/null 2>&1 || missing+=("setfacl (install package 'acl')")
  command -v sshd >/dev/null 2>&1 || missing+=("sshd")
  command -v mount >/dev/null 2>&1 || missing+=("mount")
  command -v getent >/dev/null 2>&1 || missing+=("getent")
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required system tools: ${missing[*]}"
    return 1
  fi
}

access_ensure_global_group() {
  if ! getent group "$SIMAI_ACCESS_GROUP_GLOBAL" >/dev/null 2>&1; then
    groupadd "$SIMAI_ACCESS_GROUP_GLOBAL"
  fi
}

access_ensure_project_group() {
  if ! getent group "$SIMAI_ACCESS_GROUP_PROJECT" >/dev/null 2>&1; then
    groupadd "$SIMAI_ACCESS_GROUP_PROJECT"
  fi
}

access_reload_ssh() {
  sshd -t || return 1
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
}

access_write_sshd_snippet() {
  local dir
  dir=$(dirname "$SIMAI_ACCESS_SSHD_SNIPPET")
  mkdir -p "$dir"
  cat >"$SIMAI_ACCESS_SSHD_SNIPPET" <<EOF
# simai-managed: access subsystem
Match Group ${SIMAI_ACCESS_GROUP_GLOBAL}
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PubkeyAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
Match Group ${SIMAI_ACCESS_GROUP_PROJECT}
    ChrootDirectory ${SIMAI_ACCESS_JAIL_BASE}/%u
    ForceCommand internal-sftp
    PasswordAuthentication yes
    PubkeyAuthentication yes
    PermitTTY no
    X11Forwarding no
    AllowTcpForwarding no
    PermitTunnel no
EOF
  chmod 0644 "$SIMAI_ACCESS_SSHD_SNIPPET"
  chown root:root "$SIMAI_ACCESS_SSHD_SNIPPET" 2>/dev/null || true
  access_reload_ssh
}

access_exists() {
  local login="$1"
  [[ -f "$(access_metadata_file "$login")" ]]
}

access_load_metadata() {
  local login="$1"
  local file
  file=$(access_metadata_file "$login")
  [[ -f "$file" ]] || return 1
  unset ACCESS_META
  declare -gA ACCESS_META=()
  local key value
  while IFS='=' read -r key value; do
    [[ -z "$key" ]] && continue
    value="${value%\"}"
    value="${value#\"}"
    # shellcheck disable=SC2034 # ACCESS_META is a shared global associative array read by access commands.
    ACCESS_META["$key"]="$value"
  done <"$file"
}

access_write_metadata() {
  local login="$1"
  shift
  local file dir tmp
  file=$(access_metadata_file "$login")
  dir=$(dirname "$file")
  mkdir -p "$dir"
  tmp=$(mktemp)
  local entry key value
  for entry in "$@"; do
    key="${entry%%|*}"
    value="${entry#*|}"
    printf '%s="%s"\n' "$key" "${value//\"/\\\"}" >>"$tmp"
  done
  chmod 0640 "$tmp"
  chown root:root "$tmp" 2>/dev/null || true
  mv "$tmp" "$file"
}

access_list_logins() {
  local dir
  dir=$(access_dir)
  [[ -d "$dir" ]] || return 0
  local file
  shopt -s nullglob
  for file in "$dir"/*.env; do
    basename "$file" .env
  done | sort
  shopt -u nullglob
}

access_pick_login() {
  local login="${1:-}"
  if [[ -n "$login" ]]; then
    printf '%s\n' "$login"
    return 0
  fi
  if [[ "${SIMAI_ADMIN_MENU:-0}" != "1" ]]; then
    return 1
  fi
  local logins=()
  mapfile -t logins < <(access_list_logins 2>/dev/null || true)
  if [[ ${#logins[@]} -eq 0 ]]; then
    warn "No access entries found"
    return 1
  fi
  login=$(select_from_list "Select access login" "" "${logins[@]}")
  if [[ -z "$login" ]]; then
    command_cancelled
    return $?
  fi
  printf '%s\n' "$login"
}

access_grant_traverse_acl() {
  local login="$1" path="$2"
  local current parent
  current=$(dirname "$path")
  while [[ -n "$current" && "$current" != "/" && "$current" != "." ]]; do
    setfacl -m "u:${login}:--x" "$current"
    parent=$(dirname "$current")
    [[ "$parent" == "$current" ]] && break
    current="$parent"
  done
  setfacl -m "u:${login}:--x" "/home" 2>/dev/null || true
}

access_grant_global_acl() {
  local login="$1"
  access_grant_traverse_acl "$login" "$WWW_ROOT"
  setfacl -R -m "u:${login}:rwX" -m "u:${SIMAI_USER}:rwX" "$WWW_ROOT"
  find "$WWW_ROOT" -type d -print0 2>/dev/null | xargs -0 -r setfacl -m "d:u:${login}:rwX" -m "d:u:${SIMAI_USER}:rwX"
}

access_global_home() {
  local login="$1"
  echo "${SIMAI_ACCESS_HOME_BASE}/${login}"
}

access_ensure_global_home() {
  local login="$1" group="$2"
  local home
  home=$(access_global_home "$login")
  mkdir -p "$home"
  chmod 0750 "$home"
  chown "${login}:${group}" "$home" 2>/dev/null || true
}

access_project_jail_root() {
  local login="$1"
  echo "${SIMAI_ACCESS_JAIL_BASE}/${login}"
}

access_project_site_dir() {
  local login="$1"
  echo "$(access_project_jail_root "$login")/site"
}

access_systemd_available() {
  command -v systemctl >/dev/null 2>&1 || return 1
  [[ -d /run/systemd/system ]]
}

access_mount_unit_name() {
  local site_dir="$1"
  if command -v systemd-escape >/dev/null 2>&1; then
    systemd-escape --path --suffix=mount "$site_dir"
    return 0
  fi
  echo "$(echo "$site_dir" | sed 's#/#-#g;s#^-##').mount"
}

access_mount_unit_path() {
  local site_dir="$1"
  echo "/etc/systemd/system/$(access_mount_unit_name "$site_dir")"
}

access_write_mount_unit() {
  local login="$1" project_path="$2"
  local site_dir unit_path
  site_dir=$(access_project_site_dir "$login")
  unit_path=$(access_mount_unit_path "$site_dir")
  cat >"$unit_path" <<EOF
[Unit]
Description=SIMAI access bind mount for ${login}
After=local-fs.target

[Mount]
What=${project_path}
Where=${site_dir}
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$unit_path"
  chown root:root "$unit_path" 2>/dev/null || true
}

access_enable_mount_unit() {
  local login="$1" project_path="$2"
  access_systemd_available || return 1
  access_prepare_project_jail "$login"
  access_write_mount_unit "$login" "$project_path" || return 1
  local site_dir unit
  site_dir=$(access_project_site_dir "$login")
  unit=$(access_mount_unit_name "$site_dir")
  systemctl daemon-reload
  systemctl enable --now "$unit"
}

access_disable_mount_unit() {
  local login="$1"
  access_systemd_available || return 1
  local site_dir unit
  site_dir=$(access_project_site_dir "$login")
  unit=$(access_mount_unit_name "$site_dir")
  systemctl disable --now "$unit" 2>/dev/null || true
}

access_mount_is_active() {
  local target="$1"
  if command -v mountpoint >/dev/null 2>&1; then
    mountpoint -q "$target"
    return $?
  fi
  grep -qs " ${target} " /proc/mounts
}

access_prepare_project_jail() {
  local login="$1"
  local jail_root site_dir
  jail_root=$(access_project_jail_root "$login")
  site_dir=$(access_project_site_dir "$login")
  mkdir -p "$site_dir"
  chmod 0755 "$SIMAI_ACCESS_JAIL_BASE"
  chown root:root "$SIMAI_ACCESS_JAIL_BASE" 2>/dev/null || true
  chmod 0755 "$jail_root"
  chown root:root "$jail_root" 2>/dev/null || true
  chmod 0755 "$site_dir"
  chown root:root "$site_dir" 2>/dev/null || true
}

access_mount_project_root() {
  local login="$1" project_path="$2"
  access_prepare_project_jail "$login"
  local site_dir
  site_dir=$(access_project_site_dir "$login")
  if access_mount_is_active "$site_dir"; then
    return 0
  fi
  if access_enable_mount_unit "$login" "$project_path"; then
    access_mount_is_active "$site_dir" && return 0
  fi
  mount --bind "$project_path" "$site_dir"
}

access_grant_project_acl() {
  local login="$1" project_path="$2"
  access_grant_traverse_acl "$login" "$project_path"
  setfacl -R -m "u:${login}:rwX" -m "u:${SIMAI_USER}:rwX" "$project_path"
  find "$project_path" -type d -print0 2>/dev/null | xargs -0 -r setfacl -m "d:u:${login}:rwX" -m "d:u:${SIMAI_USER}:rwX"
}

access_create_system_user() {
  local login="$1" home="$2" group="$3"
  if id -u "$login" >/dev/null 2>&1; then
    error "User ${login} already exists"
    return 1
  fi
  useradd -M -d "$home" -g "$group" -s /usr/sbin/nologin "$login"
}

access_set_password() {
  local login="$1" password="$2"
  printf '%s:%s\n' "$login" "$password" | chpasswd
}

access_user_home() {
  local login="$1"
  getent passwd "$login" | awk -F: '{print $6}'
}

access_user_group() {
  local login="$1"
  local gid group
  gid=$(getent passwd "$login" | awk -F: '{print $4}')
  [[ -z "$gid" ]] && return 1
  group=$(getent group "$gid" | awk -F: '{print $1}')
  [[ -z "$group" ]] && return 1
  echo "$group"
}

access_ensure_ssh_dir() {
  local login="$1"
  local home group
  home=$(access_user_home "$login")
  [[ -z "$home" ]] && return 1
  group=$(access_user_group "$login")
  [[ -z "$group" ]] && group="$login"
  local ssh_dir="${home}/.ssh"
  local auth_file="${ssh_dir}/authorized_keys"
  mkdir -p "$ssh_dir"
  chmod 0700 "$ssh_dir"
  chown "${login}:${group}" "$ssh_dir" 2>/dev/null || true
  touch "$auth_file"
  chmod 0600 "$auth_file"
  chown "${login}:${group}" "$auth_file" 2>/dev/null || true
}

access_install_pubkey() {
  local login="$1" pubkey="$2"
  access_ensure_ssh_dir "$login" || return 1
  local home ssh_dir auth_file
  home=$(access_user_home "$login")
  ssh_dir="${home}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  grep -qxF "$pubkey" "$auth_file" 2>/dev/null && return 0
  printf "%s\n" "$pubkey" >>"$auth_file"
}
