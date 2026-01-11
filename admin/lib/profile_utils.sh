#!/usr/bin/env bash

profiles_dir() {
  echo "${SIMAI_PROFILES_DIR:-${SIMAI_ENV_ROOT}/profiles}"
}

profiles_config_dir() {
  echo "/etc/simai-env"
}

profiles_enabled_file() {
  echo "$(profiles_config_dir)/profiles.enabled"
}

profiles_core_ids() {
  printf "%s\n" "static" "generic" "alias"
}

profiles_allowlist_exists() {
  [[ -f "$(profiles_enabled_file)" ]]
}

read_profiles_allowlist() {
  local f
  f="$(profiles_enabled_file)"
  [[ ! -f "$f" ]] && return 1
  grep -v '^[[:space:]]*$' "$f" | grep -v '^[[:space:]]*#' | sed 's/[[:space:]]\+$//' | sort -u
}

list_enabled_profile_ids() {
  if profiles_allowlist_exists; then
    read_profiles_allowlist || true
  else
    list_profile_ids
  fi
}

is_profile_enabled() {
  local id="$1"
  if ! profiles_allowlist_exists; then
    return 0
  fi
  read_profiles_allowlist | grep -qx "$id"
}

ensure_profiles_allowlist_initialized_from_legacy() {
  local f dir
  f="$(profiles_enabled_file)"
  if [[ -f "$f" ]]; then
    return 0
  fi
  dir="$(profiles_config_dir)"
  mkdir -p "$dir"
  local tmp
  tmp="$(mktemp)"
  list_profile_ids >"$tmp"
  mv "$tmp" "$f"
  chmod 0644 "$f"
  return 0
}

write_profiles_allowlist() {
  local dir f tmp
  dir="$(profiles_config_dir)"
  f="$(profiles_enabled_file)"
  mkdir -p "$dir"
  tmp="$(mktemp)"
  cat | sed '/^[[:space:]]*$/d' | sort -u >"$tmp"
  mv "$tmp" "$f"
  chmod 0644 "$f"
}

maybe_init_profiles_allowlist_core_defaults() {
  local f
  f="$(profiles_enabled_file)"

  if profiles_allowlist_exists; then
    info "Profile activation allowlist already exists at ${f} (no changes)."
    return 0
  fi

  if command -v has_simai_sites >/dev/null 2>&1 && has_simai_sites; then
    info "Detected existing simai-managed sites; leaving legacy profile activation (all enabled)."
    return 0
  fi

  info "Initializing profile activation allowlist (core profiles enabled by default)."
  local ids=()
  local id
  while IFS= read -r id; do
    if is_profile_known "$id"; then
      ids+=("$id")
    else
      warn "Core profile '${id}' not found in registry; skipping."
    fi
  done < <(profiles_core_ids)

  if [[ ${#ids[@]} -eq 0 ]]; then
    warn "No core profiles found; skipping allowlist initialization."
    return 0
  fi

  printf "%s\n" "${ids[@]}" | write_profiles_allowlist
  info "Enabled profiles: ${ids[*]}"
  info "You can enable more profiles later: simai-admin.sh profile enable --id <profile>"
  return 0
}

validate_profile_file() {
  local path="$1"
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [[ ! "$line" =~ ^[[:space:]]*PROFILE_[A-Z0-9_]+= ]]; then
      error "Profile file ${path} contains forbidden syntax: ${line}"
      return 1
    fi
    if [[ "$line" == *'$('* ]] || [[ "$line" == *'`'* ]] || [[ "$line" == *'$'* ]]; then
      error "Profile file ${path} contains forbidden syntax: ${line}"
      return 1
    fi

    local in_single=0 in_double=0 escaped=0 i ch
    for ((i=0; i<${#line}; i++)); do
      ch=${line:i:1}
      if ((escaped)); then
        escaped=0
        continue
      fi
      if [[ "$ch" == "\\" && $in_single -eq 0 ]]; then
        escaped=1
        continue
      fi
      if [[ "$ch" == "'" && $in_double -eq 0 ]]; then
        ((in_single = 1 - in_single))
        continue
      fi
      if [[ "$ch" == '"' && $in_single -eq 0 ]]; then
        ((in_double = 1 - in_double))
        continue
      fi
      if [[ $in_single -eq 0 && $in_double -eq 0 ]]; then
        case "$ch" in
          ';'|'|'|'&'|'>'|'<')
            error "Profile file ${path} contains forbidden syntax: ${line}"
            return 1
            ;;
        esac
      fi
    done
  done < "$path"
  return 0
}

validate_profile_public_dir() {
  local dir="$1"
  if [[ -z "$dir" || "$dir" == "." ]]; then
    return 0
  fi
  if [[ "$dir" == /* ]]; then
    error "PROFILE_PUBLIC_DIR must be relative (got absolute: ${dir})"
    return 1
  fi
  if [[ "$dir" == *".."* ]]; then
    error "PROFILE_PUBLIC_DIR must not contain '..' (${dir})"
    return 1
  fi
  if [[ "$dir" =~ [[:space:]] || "$dir" =~ [[:cntrl:]] ]]; then
    error "PROFILE_PUBLIC_DIR must not contain whitespace/control characters (${dir})"
    return 1
  fi
  if [[ "$dir" == *"\\"* ]]; then
    error "PROFILE_PUBLIC_DIR must not contain backslashes (${dir})"
    return 1
  fi
  if [[ "$dir" == *"//"* ]]; then
    error "PROFILE_PUBLIC_DIR must not contain double slashes (${dir})"
    return 1
  fi
  if [[ "$dir" == */ ]]; then
    error "PROFILE_PUBLIC_DIR must not end with '/' (${dir})"
    return 1
  fi
  if [[ ! "$dir" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    error "PROFILE_PUBLIC_DIR contains invalid characters (${dir}); allowed: A-Za-z0-9._/-"
    return 1
  fi
  return 0
}

list_profile_ids() {
  local dir
  dir=$(profiles_dir)
  shopt -s nullglob
  local files=("$dir"/*.profile.sh)
  if [[ ${#files[@]} -eq 0 ]]; then
    shopt -u nullglob
    return 1
  fi
  for f in "${files[@]}"; do
    basename "$f" | sed 's/\.profile\.sh$//'
  done | sort
  shopt -u nullglob
}

is_profile_known() {
  local id="$1" dir
  dir=$(profiles_dir)
  [[ -f "${dir}/${id}.profile.sh" ]]
}

source_profile_file_raw() {
  local id="$1" dir file
  dir=$(profiles_dir)
  file="${dir}/${id}.profile.sh"
  if [[ ! -f "$file" ]]; then
    return 1
  fi
  validate_profile_file "$file" || return 1
  # shellcheck disable=SC1090
  source "$file"
  return 0
}

load_profile() {
  local id="$1" dir file
  dir=$(profiles_dir)
  file="${dir}/${id}.profile.sh"
  if [[ ! -f "$file" ]]; then
    error "Profile file not found for ${id}"
    return 1
  fi
  if ! is_profile_enabled "$id"; then
    error "Profile '${id}' is disabled. Enable it: simai-admin.sh profile enable --id ${id}"
    return 1
  fi
  source_profile_file_raw "$id" || {
    error "Failed to load profile ${id}"
    return 1
  }
  if [[ "${PROFILE_ID:-}" != "$id" ]]; then
    error "Profile ID mismatch in ${file}: expected ${id}, got ${PROFILE_ID:-<empty>}"
    return 1
  fi
  PROFILE_NGINX_TEMPLATE=${PROFILE_NGINX_TEMPLATE:-""}
  if [[ -z "${PROFILE_PUBLIC_DIR+x}" ]]; then
    PROFILE_PUBLIC_DIR="public"
  else
    PROFILE_PUBLIC_DIR="${PROFILE_PUBLIC_DIR}"
  fi
  if ! validate_profile_public_dir "$PROFILE_PUBLIC_DIR"; then
    return 1
  fi
  PROFILE_REQUIRES_PHP=${PROFILE_REQUIRES_PHP:-"yes"}
  PROFILE_REQUIRES_DB=${PROFILE_REQUIRES_DB:-"no"}
  PROFILE_HEALTHCHECK_ENABLED=${PROFILE_HEALTHCHECK_ENABLED:-"no"}
  PROFILE_HEALTHCHECK_MODE=${PROFILE_HEALTHCHECK_MODE:-"php"}
  PROFILE_SUPPORTS_CRON=${PROFILE_SUPPORTS_CRON:-"no"}
  PROFILE_SUPPORTS_QUEUE=${PROFILE_SUPPORTS_QUEUE:-"no"}
  PROFILE_QUEUE_SYSTEM=${PROFILE_QUEUE_SYSTEM:-"none"}
  PROFILE_ALLOW_ALIAS=${PROFILE_ALLOW_ALIAS:-"no"}
  PROFILE_ALLOW_PHP_SWITCH=${PROFILE_ALLOW_PHP_SWITCH:-"yes"}
  PROFILE_ALLOW_SHARED_POOL=${PROFILE_ALLOW_SHARED_POOL:-"no"}
  PROFILE_ALLOW_DB_REMOVAL=${PROFILE_ALLOW_DB_REMOVAL:-"no"}
  PROFILE_IS_ALIAS=${PROFILE_IS_ALIAS:-"no"}
  [[ -z "${PROFILE_BOOTSTRAP_FILES+x}" ]] && PROFILE_BOOTSTRAP_FILES=()
  [[ -z "${PROFILE_WRITABLE_PATHS+x}" ]] && PROFILE_WRITABLE_PATHS=()
  [[ -z "${PROFILE_ALLOWED_PHP_VERSIONS+x}" ]] && PROFILE_ALLOWED_PHP_VERSIONS=()
  [[ -z "${PROFILE_PHP_EXTENSIONS_REQUIRED+x}" ]] && PROFILE_PHP_EXTENSIONS_REQUIRED=()
  [[ -z "${PROFILE_PHP_EXTENSIONS_RECOMMENDED+x}" ]] && PROFILE_PHP_EXTENSIONS_RECOMMENDED=()
  [[ -z "${PROFILE_PHP_EXTENSIONS_OPTIONAL+x}" ]] && PROFILE_PHP_EXTENSIONS_OPTIONAL=()
  [[ -z "${PROFILE_PHP_INI_REQUIRED+x}" ]] && PROFILE_PHP_INI_REQUIRED=()
  [[ -z "${PROFILE_PHP_INI_RECOMMENDED+x}" ]] && PROFILE_PHP_INI_RECOMMENDED=()
  [[ -z "${PROFILE_PHP_INI_FORBIDDEN+x}" ]] && PROFILE_PHP_INI_FORBIDDEN=()
  [[ -z "${PROFILE_DB_REQUIRED_PRIVILEGES+x}" ]] && PROFILE_DB_REQUIRED_PRIVILEGES=()
  [[ -z "${PROFILE_CRON_RECOMMENDED+x}" ]] && PROFILE_CRON_RECOMMENDED=()
  [[ -z "${PROFILE_REQUIRED_MARKERS+x}" ]] && PROFILE_REQUIRED_MARKERS=()
  [[ -z "${PROFILE_HOOKS_PRE_CREATE+x}" ]] && PROFILE_HOOKS_PRE_CREATE=()
  [[ -z "${PROFILE_HOOKS_POST_CREATE+x}" ]] && PROFILE_HOOKS_POST_CREATE=()
  [[ -z "${PROFILE_HOOKS_PRE_REMOVE+x}" ]] && PROFILE_HOOKS_PRE_REMOVE=()
  [[ -z "${PROFILE_HOOKS_POST_REMOVE+x}" ]] && PROFILE_HOOKS_POST_REMOVE=()
  return 0
}
