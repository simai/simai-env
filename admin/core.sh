#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${LOG_FILE:-/var/log/simai-admin.log}
AUDIT_LOG_FILE=${AUDIT_LOG_FILE:-/var/log/simai-audit.log}
ADMIN_USER=${ADMIN_USER:-simai}
# shellcheck disable=SC2034 # used by sourced command handlers
SIMAI_RC_MENU_RELOAD=88
SIMAI_ENV_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "${SIMAI_ENV_ROOT}/lib/platform.sh"
source "${SIMAI_ENV_ROOT}/lib/os_adapter.sh"
if [[ -f /etc/simai-env.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/simai-env.conf
fi

declare -Ag CMD_HANDLERS=()
declare -Ag CMD_DESCRIPTIONS=()
declare -Ag CMD_REQUIRED=()
declare -Ag CMD_OPTIONAL=()

select_from_list() {
  local prompt="$1"
  local default="${2:-}"
  shift 2
  local options=("$@")
  if [[ ${#options[@]} -eq 0 ]]; then
    echo ""
    return 1
  fi
  echo "$prompt" >&2
  local i=1
  for opt in "${options[@]}"; do
    echo "  [$i] $opt" >&2
    ((i++))
  done
  if [[ -n "$default" ]]; then
    read -r -p "Enter choice [${default}]: " choice || true
    [[ -z "$choice" ]] && choice="$default"
  else
    read -r -p "Enter choice: " choice || true
  fi
  if [[ "$choice" =~ ^[0-9]+$ ]]; then
    local idx=$((choice-1))
    if [[ $idx -ge 0 && $idx -lt ${#options[@]} ]]; then
      echo "${options[$idx]}"
      return 0
    fi
  fi
  # fallback: if choice matches an option exactly, accept
  for opt in "${options[@]}"; do
    if [[ "$choice" == "$opt" ]]; then
      echo "$choice"
      return 0
    fi
  done
  echo ""
  return 1
}

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts=$(date +"%Y-%m-%dT%H:%M:%S")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "${ts} [${level}] ${msg}" >>"$LOG_FILE"
  echo "${ts} [${level}] ${msg}"
}

info() { log "INFO" "$@"; }
warn() { log "WARN" "$@"; }
error() { log "ERROR" "$@"; }

run_long() {
  local desc="$1"; shift
  local has_tty=0
  [[ -t 1 && -r /dev/tty && -w /dev/tty ]] && has_tty=1
  local start
  start=$(date +%s)
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$(date +"%Y-%m-%dT%H:%M:%S") [INFO] ${desc}" >>"$LOG_FILE"
  if command -v env >/dev/null 2>&1; then
    env "$@" >>"$LOG_FILE" 2>&1 &
  else
    "$@" >>"$LOG_FILE" 2>&1 &
  fi
  local cmd_pid=$!
  local spinner='|/-\\'
  local i=0
  local interrupted=0
  trap 'interrupted=1; kill '"$cmd_pid"' 2>/dev/null || true' INT TERM
  while kill -0 "$cmd_pid" 2>/dev/null; do
    if [[ $has_tty -eq 1 ]]; then
      local elapsed=$(( $(date +%s) - start ))
      printf "\r[%s] %s... %ss" "${spinner:i%4:1}" "$desc" "$elapsed" >/dev/tty
      i=$((i+1))
    fi
    sleep 1
  done
  wait "$cmd_pid"
  local rc=$?
  trap - INT TERM
  local elapsed=$(( $(date +%s) - start ))
  if [[ $has_tty -eq 1 ]]; then
    printf "\r" >/dev/tty
  fi
  if [[ $interrupted -eq 1 ]]; then
    [[ $has_tty -eq 1 ]] && echo "Interrupted" >/dev/tty || echo "Interrupted"
    return 130
  fi
  if [[ $rc -ne 0 ]]; then
    [[ $has_tty -eq 1 ]] && echo "[ERROR] ${desc}" >/dev/tty || echo "[ERROR] ${desc}"
    tail -n 80 "$LOG_FILE" 2>/dev/null || true
    return $rc
  fi
  if [[ $has_tty -eq 1 ]]; then
    printf "[OK] %s (%.0fs)\n" "$desc" "$elapsed" >/dev/tty
  else
    echo "[OK] ${desc} (${elapsed}s)"
  fi
  return 0
}

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root" >&2
    exit 1
  fi
}

require_supported_os() {
  platform_detect_os
  if ! platform_is_supported_os; then
    platform_print_os_support_status
    echo "Unsupported OS. Supported: $(platform_supported_matrix_string)" >&2
    exit 1
  fi
  if ! os_adapter_init; then
    error "Failed to initialize OS adapter"
    exit 1
  fi
}

register_cmd() {
  local section="$1" name="$2" desc="$3" handler="$4" required="$5" optional="$6"
  local key="${section}:${name}"
  CMD_HANDLERS["$key"]="$handler"
  CMD_DESCRIPTIONS["$key"]="$desc"
  CMD_REQUIRED["$key"]="${required:-}"
  CMD_OPTIONAL["$key"]="${optional:-}"
}

load_command_modules() {
  local dir="$1"
  shopt -s nullglob
  for f in "$dir"/*.sh; do
    source "$f"
  done
  shopt -u nullglob
}

list_sections() {
  local section
  for key in "${!CMD_HANDLERS[@]}"; do
    section="${key%%:*}"
    echo "$section"
  done | sort -u
}

list_commands_for_section() {
  local section="$1" key name
  for key in "${!CMD_HANDLERS[@]}"; do
    if [[ $key == "${section}:"* ]]; then
      name="${key#*:}"
      echo "$name"
    fi
  done | sort
}

get_command_desc() {
  local section="$1" name="$2"
  echo "${CMD_DESCRIPTIONS["${section}:${name}"]:-}"
}

get_required_opts() {
  local section="$1" name="$2"
  echo "${CMD_REQUIRED["${section}:${name}"]:-}"
}

get_optional_opts() {
  local section="$1" name="$2"
  echo "${CMD_OPTIONAL["${section}:${name}"]:-}"
}

run_command() {
  local section="$1" name="$2"
  shift 2
  local key="${section}:${name}"
  local handler="${CMD_HANDLERS[$key]:-}"
  if [[ -z $handler ]]; then
    error "Unknown command: ${section} ${name}"
    return 1
  fi
  ensure_audit_log
  local corr_id
  corr_id=$(uuidgen 2>/dev/null || date +"%Y%m%d%H%M%S%N")
  local caller="${SUDO_USER:-$USER}"
  local args_redacted
  args_redacted=$(redact_args "$@")
  audit_log "start" "$caller" "$section" "$name" "$args_redacted" "" "$corr_id"
  info "Running command ${section} ${name} (corr_id=${corr_id})"
  set +e
  ( "$handler" "$@" )
  local rc=$?
  set -e
  audit_log "finish" "$caller" "$section" "$name" "$args_redacted" "$rc" "$corr_id"
  return $rc
}

parse_kv_args() {
  declare -Ag PARSED_ARGS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --*=*)
        local k="${1%%=*}"
        local v="${1#*=}"
        PARSED_ARGS["${k#--}"]="$v"
        shift
        ;;
      --*)
        local key="${1#--}"
        local val="${2:-}"
        PARSED_ARGS["$key"]="$val"
        shift 2
        ;;
      *)
        shift
        ;;
    esac
  done
}

progress_init() {
  PROGRESS_TOTAL=$1
  PROGRESS_CURRENT=0
}

progress_step() {
  local msg="$*"
  if [[ -z "${PROGRESS_TOTAL:-}" ]]; then
    info "[?/?] ${msg}"
    return
  fi
  PROGRESS_CURRENT=$((PROGRESS_CURRENT+1))
  info "[${PROGRESS_CURRENT}/${PROGRESS_TOTAL}] ${msg}"
}

progress_done() {
  local msg="${1:-Done}"
  if [[ -n "${PROGRESS_TOTAL:-}" && -n "${PROGRESS_CURRENT:-}" ]]; then
    info "[${PROGRESS_TOTAL}/${PROGRESS_TOTAL}] ${msg}"
  else
    info "${msg}"
  fi
  unset PROGRESS_TOTAL PROGRESS_CURRENT
}

require_args() {
  local required_list="$1"
  local missing=()
  local key
  for key in $required_list; do
    if [[ -z "${PARSED_ARGS[$key]:-}" ]]; then
      missing+=("$key")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    error "Missing required options: ${missing[*]}"
    return 1
  fi
}

run_as_simai() {
  local cmd="$1"
  sudo -u "$ADMIN_USER" -H bash -lc "$cmd"
}

ensure_audit_log() {
  local dir
  dir=$(dirname "$AUDIT_LOG_FILE")
  mkdir -p "$dir"
  touch "$AUDIT_LOG_FILE"
  chmod 640 "$AUDIT_LOG_FILE" 2>/dev/null || true
  chown root:root "$AUDIT_LOG_FILE" 2>/dev/null || true
}

redact_by_key() {
  local key="$1" value="$2"
  if [[ "$key" =~ (pass|password|secret|token|key|cert|value) ]]; then
    echo "***"
  else
    echo "$value"
  fi
}

redact_args() {
  local out=()
  while [[ $# -gt 0 ]]; do
    local arg="$1"
    shift
    if [[ "$arg" == --* ]]; then
      if [[ "$arg" =~ ^--([^=]+)=(.*)$ ]]; then
        local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
        out+=("--${k}=$(redact_by_key "$k" "$v")")
      else
        local k="${arg#--}"
        local v="${1:-}"
        if [[ -n "$v" && "$v" != --* ]]; then
          v=$(redact_by_key "$k" "$v")
          out+=("--${k} ${v}")
          shift
        else
          out+=("$arg")
        fi
      fi
    else
      out+=("$arg")
    fi
  done
  echo "${out[*]}"
}

audit_log() {
  local phase="$1" user="$2" section="$3" cmd="$4" args="$5" exit_code="${6:-}" corr_id="${7:-}"
  local ts
  ts=$(date +"%Y-%m-%dT%H:%M:%S%z")
  ensure_audit_log
  echo "${ts} user=${user} section=${section} cmd=${cmd} phase=${phase} exit=${exit_code:-n/a} corr_id=${corr_id:-n/a} args=\"${args}\"" >>"$AUDIT_LOG_FILE"
}
