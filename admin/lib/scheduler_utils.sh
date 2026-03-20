#!/usr/bin/env bash
set -euo pipefail

scheduler_config_file() {
  echo "/etc/simai-env.conf"
}

scheduler_state_dir() {
  echo "/var/lib/simai-env/scheduler"
}

scheduler_jobs_state_dir() {
  echo "$(scheduler_state_dir)/jobs"
}

scheduler_lock_file() {
  echo "$(scheduler_state_dir)/scheduler.lock"
}

scheduler_log_file() {
  echo "/var/log/simai-scheduler.log"
}

scheduler_cron_file() {
  echo "/etc/cron.d/simai-scheduler"
}

scheduler_scheduler_cmd() {
  local root="${SIMAI_ENV_ROOT:-${SCRIPT_DIR:-/root/simai-env}}"
  echo "${root}/simai-admin.sh self scheduler"
}

scheduler_replace_managed_block() {
  local file="$1" begin="$2" end="$3" content="$4"
  local tmp
  tmp=$(mktemp)
  if [[ -f "$file" ]]; then
    awk -v begin="$begin" -v end="$end" '
      $0 == begin { skip=1; next }
      $0 == end { skip=0; next }
      !skip { print }
    ' "$file" >"$tmp"
  fi
  {
    cat "$tmp"
    [[ -s "$tmp" ]] && printf "\n"
    printf "%s\n" "$begin"
    printf "%s\n" "$content"
    printf "%s\n" "$end"
  } >"${tmp}.new"
  install -m 0644 /dev/null "$file"
  cat "${tmp}.new" >"$file"
  rm -f "$tmp" "${tmp}.new"
}

scheduler_install_defaults() {
  scheduler_write_config \
    "${SIMAI_SCHEDULER_ENABLED:-yes}" \
    "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}" \
    "${SIMAI_AUTO_OPTIMIZE_MODE:-assist}" \
    "${SIMAI_AUTO_OPTIMIZE_INTERVAL_MINUTES:-5}" \
    "${SIMAI_AUTO_OPTIMIZE_COOLDOWN_MINUTES:-60}" \
    "${SIMAI_AUTO_OPTIMIZE_LIMIT:-3}" \
    "${SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE:-auto}"
}

scheduler_write_config() {
  local scheduler_enabled="${1:-yes}"
  local auto_enabled="${2:-yes}"
  local auto_mode="${3:-assist}"
  local auto_interval="${4:-5}"
  local auto_cooldown="${5:-60}"
  local auto_limit="${6:-3}"
  local auto_rebalance_mode="${7:-auto}"
  local file content
  file=$(scheduler_config_file)
  content=$(cat <<EOF
SIMAI_SCHEDULER_ENABLED=${scheduler_enabled}
SIMAI_AUTO_OPTIMIZE_ENABLED=${auto_enabled}
SIMAI_AUTO_OPTIMIZE_MODE=${auto_mode}
SIMAI_AUTO_OPTIMIZE_INTERVAL_MINUTES=${auto_interval}
SIMAI_AUTO_OPTIMIZE_COOLDOWN_MINUTES=${auto_cooldown}
SIMAI_AUTO_OPTIMIZE_LIMIT=${auto_limit}
SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE=${auto_rebalance_mode}
EOF
)
  scheduler_replace_managed_block "$file" "# simai-scheduler-begin" "# simai-scheduler-end" "$content"
}

scheduler_install_cron() {
  local cron_file cmd
  cron_file=$(scheduler_cron_file)
  cmd=$(scheduler_scheduler_cmd)
  cat >"$cron_file" <<EOF
# managed by simai-env scheduler
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
* * * * * root flock -n $(scheduler_lock_file) ${cmd} >> $(scheduler_log_file) 2>&1
EOF
  chmod 0644 "$cron_file"
  chown root:root "$cron_file" 2>/dev/null || true
  if declare -F reload_cron_daemon >/dev/null 2>&1; then
    reload_cron_daemon
  fi
}

scheduler_bootstrap_install() {
  install -d "$(scheduler_state_dir)" "$(scheduler_jobs_state_dir)" "$(dirname "$(scheduler_log_file)")"
  touch "$(scheduler_log_file)"
  chmod 0640 "$(scheduler_log_file)" 2>/dev/null || true
  chown root:root "$(scheduler_log_file)" 2>/dev/null || true
  scheduler_install_defaults
  scheduler_install_cron
}

scheduler_normalize_bool() {
  local raw="${1:-}"
  raw=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    1|yes|true|on|enabled|active) echo "yes" ;;
    *) echo "no" ;;
  esac
}

scheduler_job_normalize() {
  local job="${1:-}"
  job=$(printf '%s' "$job" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
  case "$job" in
    auto_optimize) echo "auto_optimize" ;;
    *) return 1 ;;
  esac
}

scheduler_jobs_list() {
  printf "%s\n" "auto_optimize"
}

scheduler_job_enabled() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      [[ "$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" == "yes" ]] || {
        echo "no"
        return 0
      }
      echo "$(scheduler_normalize_bool "${SIMAI_AUTO_OPTIMIZE_ENABLED:-yes}")"
      ;;
  esac
}

scheduler_job_mode() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      local mode="${SIMAI_AUTO_OPTIMIZE_MODE:-assist}"
      mode=$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')
      case "$mode" in
        observe|assist|manual) echo "$mode" ;;
        *) echo "assist" ;;
      esac
      ;;
  esac
}

scheduler_job_interval_minutes() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      local value="${SIMAI_AUTO_OPTIMIZE_INTERVAL_MINUTES:-5}"
      [[ "$value" =~ ^[0-9]+$ ]] || value=5
      (( value < 1 )) && value=1
      echo "$value"
      ;;
  esac
}

scheduler_job_cooldown_minutes() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      local value="${SIMAI_AUTO_OPTIMIZE_COOLDOWN_MINUTES:-60}"
      [[ "$value" =~ ^[0-9]+$ ]] || value=60
      (( value < 1 )) && value=1
      echo "$value"
      ;;
  esac
}

scheduler_job_limit() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      local value="${SIMAI_AUTO_OPTIMIZE_LIMIT:-3}"
      [[ "$value" =~ ^[0-9]+$ ]] || value=3
      (( value < 1 )) && value=1
      echo "$value"
      ;;
  esac
}

scheduler_job_rebalance_mode() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  case "$job" in
    auto_optimize)
      local value="${SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE:-safe}"
      value=$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')
      case "$value" in
        auto|safe|parked) echo "$value" ;;
        *) echo "auto" ;;
      esac
      ;;
  esac
}

scheduler_job_state_file() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  echo "$(scheduler_jobs_state_dir)/${job}.state"
}

scheduler_job_state_get() {
  local job key
  job=$(scheduler_job_normalize "$1") || return 1
  key="$2"
  local file
  file=$(scheduler_job_state_file "$job")
  [[ -f "$file" ]] || return 1
  awk -F= -v target="$key" '
    $1 == target {
      val=substr($0, index($0, "=")+1)
      sub(/^[[:space:]]+/, "", val)
      sub(/[[:space:]]+$/, "", val)
      print val
      found=1
      exit
    }
    END { if (!found) exit 1 }
  ' "$file"
}

scheduler_job_state_set() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  shift
  install -d "$(scheduler_jobs_state_dir)"
  local file tmp entry
  file=$(scheduler_job_state_file "$job")
  tmp=$(mktemp)
  for entry in "$@"; do
    [[ -z "$entry" ]] && continue
    printf "%s=%s\n" "${entry%%|*}" "${entry#*|}" >>"$tmp"
  done
  mv "$tmp" "$file"
  chmod 0644 "$file"
  chown root:root "$file" 2>/dev/null || true
}

scheduler_job_is_due() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  local enabled last_run interval now
  enabled=$(scheduler_job_enabled "$job")
  [[ "$enabled" == "yes" ]] || return 1
  interval=$(scheduler_job_interval_minutes "$job")
  last_run=$(scheduler_job_state_get "$job" "last_run_epoch" 2>/dev/null || true)
  now=$(date +%s)
  if [[ -z "$last_run" || ! "$last_run" =~ ^[0-9]+$ ]]; then
    return 0
  fi
  (( now - last_run >= interval * 60 ))
}

scheduler_job_next_due_epoch() {
  local job last_run interval
  job=$(scheduler_job_normalize "$1") || return 1
  last_run=$(scheduler_job_state_get "$job" "last_run_epoch" 2>/dev/null || true)
  interval=$(scheduler_job_interval_minutes "$job")
  if [[ -z "$last_run" || ! "$last_run" =~ ^[0-9]+$ ]]; then
    echo "now"
    return 0
  fi
  echo $(( last_run + interval * 60 ))
}

scheduler_epoch_human() {
  local raw="${1:-}"
  if [[ "$raw" == "now" ]]; then
    echo "now"
    return 0
  fi
  [[ "$raw" =~ ^[0-9]+$ ]] || {
    echo "n/a"
    return 0
  }
  date -d "@${raw}" +"%Y-%m-%d %H:%M:%S"
}

scheduler_mark_job_run() {
  local job status message started_at ended_at
  job=$(scheduler_job_normalize "$1") || return 1
  status="${2:-unknown}"
  message="${3:-}"
  started_at="${4:-$(date +%s)}"
  ended_at="${5:-$(date +%s)}"
  scheduler_job_state_set "$job" \
    "last_run_epoch|${ended_at}" \
    "last_started_epoch|${started_at}" \
    "last_status|${status}" \
    "last_message|${message}"
}

scheduler_mark_job_action() {
  local job message now
  job=$(scheduler_job_normalize "$1") || return 1
  message="${2:-}"
  now=$(date +%s)
  local last_run started_at last_status
  last_run=$(scheduler_job_state_get "$job" "last_run_epoch" 2>/dev/null || true)
  started_at=$(scheduler_job_state_get "$job" "last_started_epoch" 2>/dev/null || true)
  last_status=$(scheduler_job_state_get "$job" "last_status" 2>/dev/null || true)
  [[ -z "$last_run" ]] && last_run="$now"
  [[ -z "$started_at" ]] && started_at="$now"
  [[ -z "$last_status" ]] && last_status="ok"
  scheduler_job_state_set "$job" \
    "last_run_epoch|${last_run}" \
    "last_started_epoch|${started_at}" \
    "last_status|${last_status}" \
    "last_message|${message}" \
    "last_action_epoch|${now}" \
    "last_action_message|${message}"
}

scheduler_auto_optimize_run() {
  local mode limit rebalance_mode total budget excess risk
  mode=$(scheduler_job_mode "auto_optimize")
  limit=$(scheduler_job_limit "auto_optimize")
  rebalance_mode=$(scheduler_job_rebalance_mode "auto_optimize")

  if [[ "$mode" == "manual" ]]; then
    echo "manual mode"
    return 0
  fi

  total=$(perf_fpm_total_max_children)
  budget=$(perf_fpm_recommended_total_children)
  excess=$(perf_fpm_excess_children "$total" "$budget")
  risk=$(perf_fpm_oversubscription_risk "$total" "$budget")

  if [[ "$excess" == "0" ]]; then
    echo "healthy (${risk})"
    return 0
  fi

  if [[ "$mode" == "observe" ]]; then
    echo "observe: oversubscribed ${risk}, excess=${excess}, suggested mode=${rebalance_mode}, limit=${limit}"
    return 0
  fi

  local cooldown last_action now
  cooldown=$(scheduler_job_cooldown_minutes "auto_optimize")
  last_action=$(scheduler_job_state_get "auto_optimize" "last_action_epoch" 2>/dev/null || true)
  now=$(date +%s)
  if [[ -n "$last_action" && "$last_action" =~ ^[0-9]+$ ]]; then
    if (( now - last_action < cooldown * 60 )); then
      echo "assist cooldown active: oversubscribed ${risk}, last action $(scheduler_epoch_human "$last_action")"
      return 0
    fi
  fi

  if self_perf_rebalance_handler --limit "$limit" --mode "$rebalance_mode" --confirm yes >>"${LOG_FILE:-/var/log/simai-admin.log}" 2>&1; then
    scheduler_mark_job_action "auto_optimize" "assist: applied ${rebalance_mode} rebalance"
    echo "assist: applied ${rebalance_mode} rebalance to up to ${limit} sites (risk=${risk}, excess=${excess})"
    return 0
  fi

  echo "assist failed: could not apply ${rebalance_mode} rebalance"
  return 1
}

scheduler_run_job() {
  local job started_at ended_at message
  job=$(scheduler_job_normalize "$1") || return 1
  started_at=$(date +%s)
  case "$job" in
    auto_optimize)
      if message=$(scheduler_auto_optimize_run); then
        ended_at=$(date +%s)
        scheduler_mark_job_run "$job" "ok" "$message" "$started_at" "$ended_at"
        ui_info "Scheduler job ${job}: ${message}"
        return 0
      fi
      ended_at=$(date +%s)
      scheduler_mark_job_run "$job" "failed" "$message" "$started_at" "$ended_at"
      ui_warn "Scheduler job ${job}: ${message}"
      return 1
      ;;
  esac
  return 1
}

scheduler_tick() {
  install -d "$(scheduler_state_dir)" "$(scheduler_jobs_state_dir)" "$(dirname "$(scheduler_log_file)")"
  local any_due=0 failures=0 job
  while IFS= read -r job; do
    [[ -z "$job" ]] && continue
    if scheduler_job_is_due "$job"; then
      any_due=1
      if ! scheduler_run_job "$job"; then
        failures=$((failures + 1))
      fi
    fi
  done < <(scheduler_jobs_list)
  if (( any_due == 0 )); then
    ui_info "Scheduler: no jobs due"
  fi
  (( failures == 0 ))
}
