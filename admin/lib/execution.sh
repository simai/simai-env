#!/usr/bin/env bash

# Conservative defaults: newly registered commands mutate until explicitly
# declared read-only. Metadata lives in the existing registry, not a second list.
command_register_policy() {
  local key="$1" flags="${CMD_FLAGS[$1]:-}" effect=write token
  case "$key" in
    *:remove|*:drop|*:db-drop|*:purge|*:*-remove) effect=delete ;;
  esac
  for token in $flags; do
    [[ "$token" == effects:* ]] && effect="${token#effects:}"
  done
  CMD_EFFECTS["$key"]="$effect"
  # shellcheck disable=SC2034 # exported by describe.sh
  CMD_AUTHORIZATION["$key"]=root
  # shellcheck disable=SC2034 # exported by describe.sh
  if [[ "$effect" == read || " $flags " == *" confirm:none "* ]]; then
    # confirm:none is reserved for idempotent reconciliation that older
    # toolkits invoke without --confirm (self migrate after self update).
    CMD_CONFIRMATION["$key"]=not-required
    [[ " $flags " == *" confirm:none "* ]] && CMD_CONFIRM_EXEMPT["$key"]=1
  else
    CMD_CONFIRMATION["$key"]=required
  fi
  CMD_LOCK["$key"]=host
  [[ " ${CMD_REQUIRED[$key]} ${CMD_OPTIONAL[$key]} " == *" domain"* ]] && CMD_LOCK["$key"]=site
  # Creation/adoption can install host packages and change profile/owner state.
  # set-php may install a PHP version (a host operation) on the way.
  case "$key" in site:add|site:adopt|site:set-php) CMD_LOCK["$key"]=host ;; esac
  # lock:none: the handler takes the lock itself, only when it has work to do.
  [[ " $flags " == *" lock:none "* ]] && CMD_LOCK["$key"]=none
  # plan:handler: the handler prints its own plan unless --confirm yes.
  # shellcheck disable=SC2034 # read by run_command in core.sh
  [[ " $flags " == *" plan:handler "* ]] && CMD_PLAN_HANDLER["$key"]=1
  CMD_VERIFICATION["$key"]='exit status; inspect the target with site describe/doctor or self describe'
}

command_arg() {
  local wanted="$1" arg
  shift
  while (( $# )); do
    arg="$1"; shift
    case "$arg" in
      --"$wanted"=*) printf '%s\n' "${arg#*=}"; return 0 ;;
      --"$wanted")
        if [[ $# -eq 0 || "$1" == --* ]]; then
          printf '%s\n' yes
        else
          printf '%s\n' "$1"
        fi
        return 0 ;;
    esac
  done
  return 0
}

command_effect() {
  local key="$1" effect="${CMD_EFFECTS[$1]:-write}"
  shift
  case "$key" in
    observer:status|self:version|self:auto-update-status) command_arg_yes refresh "$@" && effect='write' ;;
    site:drift) command_arg_yes fix "$@" && effect='write' ;;
    backup:import) command_arg_yes apply "$@" && effect='write' ;;
    backup:data-verify) command_arg_yes restore-test "$@" && effect='write' ;;
  esac
  printf '%s\n' "$effect"
}

command_arg_yes() {
  local value
  value=$(command_arg "$@")
  [[ "${value,,}" == yes ]]
}

command_preview() {
  local key="$1" target="$2"
  shift 2
  printf 'Plan: %s\nTarget: %s\nAction: %s\n' "${key/:/ }" "${target:-host}" "${CMD_DESCRIPTIONS[$key]}"
  printf 'Effects: %s; execution identity: root; lock: %s\n' "$(command_effect "$key" "$@")" "${CMD_LOCK[$key]}"
  printf 'Arguments: %s\n' "$(redact_args "$@")"
  printf 'Verify: %s\n' "${CMD_VERIFICATION[$key]}"
  printf 'No handler was executed. Rerun with --confirm yes to apply.\n'
}

command_lock() {
  local domain="${1:-}" base="/run/lock/simai-env" path saved_umask
  [[ -n "$domain" ]] && validate_domain "$domain" allow
  # Never put root lock state below an application-writable directory.
  [[ ! -L "$base" ]] || { error 'Unsafe command lock directory'; return 1; }
  install -d -m 0700 -o root -g root "$base"
  [[ "$(stat -c '%u:%a' "$base")" == 0:700 ]] || { error 'Unsafe command lock permissions'; return 1; }
  path="${base}/${domain:-host}.lock"
  [[ ! -L "$path" ]] || { error 'Unsafe command lock file'; return 1; }
  if [[ -n "${SIMAI_LOCK_TARGET:-}" ]]; then
    [[ "$SIMAI_LOCK_TARGET" == "${domain:-host}" || "$SIMAI_LOCK_TARGET" == host ]] && return 0
    error 'Nested mutation targets a different site; run it as a separate operation'
    return 1
  fi
  # Interactive callers get "busy" at once; cron/automation waits for the
  # running operation (SIMAI_LOCK_WAIT seconds, default 600) instead of
  # silently skipping a scheduled backup.
  local wait="${SIMAI_LOCK_WAIT:-}"
  if [[ -z "$wait" ]]; then
    if [[ -t 0 || -t 1 ]]; then wait=0; else wait=600; fi
  fi
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=0
  saved_umask=$(umask)
  umask 077
  [[ ! -L "${base}/global.lock" ]] || { error 'Unsafe global lock'; return 1; }
  exec {SIMAI_GLOBAL_LOCK_FD}>"${base}/global.lock"
  if [[ -n "$domain" ]]; then
    flock -s -w "$wait" "$SIMAI_GLOBAL_LOCK_FD" || { error 'A host operation is running'; return 75; }
  else
    flock -w "$wait" "$SIMAI_GLOBAL_LOCK_FD" || { error 'A site or host operation is running'; return 75; }
  fi
  exec {SIMAI_COMMAND_LOCK_FD}>"$path"
  umask "$saved_umask"
  flock -w "$wait" "$SIMAI_COMMAND_LOCK_FD" || { error "Another operation is running for ${domain:-host}"; return 75; }
  export SIMAI_LOCK_TARGET="${domain:-host}"
}

command_result() {
  local status="$1" rc="$2" key="$3" target="$4" operation="$5" effect="$6" output="$7"
  python3 "${SIMAI_ENV_ROOT}/lib/command_contract.py" result "$status" "$rc" "$key" "$target" "$operation" "$effect" "$output"
}
