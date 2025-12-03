#!/usr/bin/env bash
set -euo pipefail

LOG_FILE=${LOG_FILE:-/var/log/simai-admin.log}
ADMIN_USER=${ADMIN_USER:-simai}

declare -Ag CMD_HANDLERS=()
declare -Ag CMD_DESCRIPTIONS=()
declare -Ag CMD_REQUIRED=()
declare -Ag CMD_OPTIONAL=()

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
    exit 1
  fi
  info "Running command ${section} ${name}"
  "$handler" "$@"
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
    exit 1
  fi
}

run_as_simai() {
  local cmd="$1"
  sudo -u "$ADMIN_USER" -H bash -lc "$cmd"
}
