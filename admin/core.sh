#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${LOG_FILE:-/var/log/simai-admin.log}
AUDIT_LOG_FILE=${AUDIT_LOG_FILE:-/var/log/simai-audit.log}
ADMIN_USER=${ADMIN_USER:-simai}
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

ensure_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root" >&2
    exit 1
  fi
}

require_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Cannot detect OS" >&2
    exit 1
  fi
  . /etc/os-release
  if [[ ${ID} != "ubuntu" ]]; then
    echo "Supported only on Ubuntu 20.04/22.04/24.04" >&2
    exit 1
  fi
  case ${VERSION_ID} in
    "20.04"|"22.04"|"24.04") ;;
    *) echo "Unsupported Ubuntu version ${VERSION_ID}" >&2; exit 1 ;;
  esac
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
  local keys section
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
  if [[ "$key" =~ (pass|password|secret|token|key|cert) ]]; then
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
