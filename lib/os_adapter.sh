#!/usr/bin/env bash
set -euo pipefail

# Ensure platform helpers are available
if ! declare -F platform_detect_os >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/platform.sh"
fi

OS_ADAPTER_ID="${OS_ADAPTER_ID:-}"
declare -ag OS_CMD=()

_os_run() {
  local log="${LOG_FILE:-}"
  if [[ -n "$log" ]]; then
    "$@" >>"$log" 2>&1
  else
    "$@"
  fi
}

os_adapter_init() {
  platform_detect_os
  if ! platform_is_supported_os "$PLATFORM_OS_ID" "$PLATFORM_OS_VERSION_ID"; then
    return 1
  fi
  if [[ -n "$OS_ADAPTER_ID" ]]; then
    return 0
  fi
  case "$PLATFORM_OS_ID" in
    ubuntu)
      # shellcheck disable=SC1091
      source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/os/ubuntu.sh"
      OS_ADAPTER_ID="ubuntu"
      return 0
      ;;
  esac
  return 1
}

os_cmd_pkg_update() {
  OS_CMD=(apt-get update -y)
}

os_cmd_pkg_install() {
  OS_CMD=(DEBIAN_FRONTEND=noninteractive apt-get install -y "$@")
}

os_cmd_pkg_install_deb() {
  local deb="$1"
  OS_CMD=(dpkg -i "$deb")
}

os_cmd_pkg_add_ppa() {
  local ppa="$1"
  OS_CMD=(DEBIAN_FRONTEND=noninteractive add-apt-repository -y "$ppa")
}

os_svc_enable_now() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl enable --now "$svc"
  else
    _os_run service "$svc" start
  fi
}

os_svc_disable_now() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl disable --now "$svc"
  else
    _os_run service "$svc" stop
  fi
}

os_svc_daemon_reload() {
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl daemon-reload
  fi
}

os_svc_restart() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl restart "$svc"
  else
    _os_run service "$svc" restart
  fi
}

os_svc_reload() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl reload "$svc"
  else
    _os_run service "$svc" reload
  fi
}

os_svc_reload_or_restart() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    _os_run systemctl reload "$svc" || _os_run systemctl restart "$svc"
  else
    _os_run service "$svc" reload || _os_run service "$svc" restart
  fi
}

os_svc_is_active() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$svc"
  else
    service "$svc" status >/dev/null 2>&1
  fi
}

os_svc_has_unit() {
  local svc="$1"
  if command -v systemctl >/dev/null 2>&1; then
    local state=""
    state=$(systemctl show -p LoadState --value "$svc" 2>/dev/null || true)
    [[ "$state" == "loaded" ]]
  elif command -v service >/dev/null 2>&1; then
    service "$svc" status >/dev/null 2>&1
    local rc=$?
    [[ $rc -ne 4 ]]
  else
    return 1
  fi
}
