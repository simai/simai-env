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
    "${SIMAI_AUTO_OPTIMIZE_REBALANCE_MODE:-auto}" \
    "${SIMAI_HEALTH_REVIEW_ENABLED:-yes}" \
    "${SIMAI_HEALTH_REVIEW_INTERVAL_MINUTES:-30}" \
    "${SIMAI_SITE_REVIEW_ENABLED:-yes}" \
    "${SIMAI_SITE_REVIEW_INTERVAL_MINUTES:-360}" \
    "${SIMAI_SITE_REVIEW_STALE_DAYS:-3}"
}

scheduler_write_config() {
  local scheduler_enabled="${1:-yes}"
  local auto_enabled="${2:-yes}"
  local auto_mode="${3:-assist}"
  local auto_interval="${4:-5}"
  local auto_cooldown="${5:-60}"
  local auto_limit="${6:-3}"
  local auto_rebalance_mode="${7:-auto}"
  local health_enabled="${8:-yes}"
  local health_interval="${9:-30}"
  local site_review_enabled="${10:-yes}"
  local site_review_interval="${11:-360}"
  local site_review_stale_days="${12:-3}"
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
SIMAI_HEALTH_REVIEW_ENABLED=${health_enabled}
SIMAI_HEALTH_REVIEW_INTERVAL_MINUTES=${health_interval}
SIMAI_SITE_REVIEW_ENABLED=${site_review_enabled}
SIMAI_SITE_REVIEW_INTERVAL_MINUTES=${site_review_interval}
SIMAI_SITE_REVIEW_STALE_DAYS=${site_review_stale_days}
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
    health_review) echo "health_review" ;;
    site_review) echo "site_review" ;;
    *) return 1 ;;
  esac
}

scheduler_jobs_list() {
  printf "%s\n" "auto_optimize" "health_review" "site_review"
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
    health_review)
      [[ "$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" == "yes" ]] || {
        echo "no"
        return 0
      }
      echo "$(scheduler_normalize_bool "${SIMAI_HEALTH_REVIEW_ENABLED:-yes}")"
      ;;
    site_review)
      [[ "$(scheduler_normalize_bool "${SIMAI_SCHEDULER_ENABLED:-yes}")" == "yes" ]] || {
        echo "no"
        return 0
      }
      echo "$(scheduler_normalize_bool "${SIMAI_SITE_REVIEW_ENABLED:-yes}")"
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
    health_review)
      echo "report"
      ;;
    site_review)
      echo "report"
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
    health_review)
      local value="${SIMAI_HEALTH_REVIEW_INTERVAL_MINUTES:-30}"
      [[ "$value" =~ ^[0-9]+$ ]] || value=30
      (( value < 1 )) && value=1
      echo "$value"
      ;;
    site_review)
      local value="${SIMAI_SITE_REVIEW_INTERVAL_MINUTES:-360}"
      [[ "$value" =~ ^[0-9]+$ ]] || value=360
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
    health_review)
      echo "0"
      ;;
    site_review)
      echo "0"
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
    health_review)
      echo "0"
      ;;
    site_review)
      echo "0"
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
    health_review)
      echo "n/a"
      ;;
    site_review)
      echo "n/a"
      ;;
  esac
}

scheduler_site_review_stale_days() {
  local value="${SIMAI_SITE_REVIEW_STALE_DAYS:-3}"
  [[ "$value" =~ ^[0-9]+$ ]] || value=3
  (( value < 1 )) && value=1
  echo "$value"
}

scheduler_job_state_file() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  echo "$(scheduler_jobs_state_dir)/${job}.state"
}

scheduler_job_report_file() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  echo "$(scheduler_jobs_state_dir)/${job}.report"
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

scheduler_job_report_write() {
  local job
  job=$(scheduler_job_normalize "$1") || return 1
  shift
  install -d "$(scheduler_jobs_state_dir)"
  local file tmp entry
  file=$(scheduler_job_report_file "$job")
  tmp=$(mktemp)
  for entry in "$@"; do
    [[ -z "$entry" ]] && continue
    printf "%s=%s\n" "${entry%%|*}" "${entry#*|}" >>"$tmp"
  done
  mv "$tmp" "$file"
  chmod 0644 "$file"
  chown root:root "$file" 2>/dev/null || true
}

scheduler_job_report_get() {
  local job key
  job=$(scheduler_job_normalize "$1") || return 1
  key="$2"
  local file
  file=$(scheduler_job_report_file "$job")
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

scheduler_health_review_run() {
  local total=0 active=0 suspended=0 auto_disabled=0 setup_pending=0 ssl_expiring_soon=0 ssl_disabled=0
  local setup_domains=() expiring_domains=() manual_domains=()
  local domain ssl_info ssl_type ssl_expires exp_ts now_ts days_left
  local profile runtime_state auto_effective web_state root project
  now_ts=$(date +%s)

  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    total=$((total + 1))
    if ! read_site_metadata "$domain" >/dev/null 2>&1; then
      continue
    fi
    profile="${SITE_META[profile]:-unknown}"
    runtime_state=$(site_runtime_state "$domain")
    if [[ "$runtime_state" == "suspended" ]]; then
      suspended=$((suspended + 1))
    else
      active=$((active + 1))
    fi

    auto_effective=$(site_auto_optimize_effective_enabled "$domain")
    if [[ "$auto_effective" != yes* ]]; then
      auto_disabled=$((auto_disabled + 1))
      if (( ${#manual_domains[@]} < 5 )); then
        manual_domains+=("$domain")
      fi
    fi

    ssl_info=$(site_ssl_brief "$domain")
    ssl_type="${ssl_info%%:*}"
    ssl_expires="${ssl_info#*:}"
    if [[ "$ssl_type" == "none" ]]; then
      ssl_disabled=$((ssl_disabled + 1))
    elif [[ "$ssl_expires" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
      exp_ts=$(date -d "$ssl_expires" +%s 2>/dev/null || echo "")
      if [[ -n "$exp_ts" && "$exp_ts" =~ ^[0-9]+$ ]]; then
        days_left=$(( (exp_ts - now_ts) / 86400 ))
        if (( days_left <= 14 )); then
          ssl_expiring_soon=$((ssl_expiring_soon + 1))
          if (( ${#expiring_domains[@]} < 5 )); then
            expiring_domains+=("${domain}(${days_left}d)")
          fi
        fi
      fi
    fi

    case "$profile" in
      laravel)
        root="${SITE_META[root]:-$(site_root_path "$domain")}"
        web_state=$(laravel_web_state_probe "$domain" "$root")
        if [[ "$web_state" != "app" ]]; then
          setup_pending=$((setup_pending + 1))
          if (( ${#setup_domains[@]} < 5 )); then
            setup_domains+=("${domain}(${web_state})")
          fi
        fi
        ;;
      wordpress)
        web_state=$(wordpress_web_state_probe "$domain")
        if [[ "$web_state" != "installed" ]]; then
          setup_pending=$((setup_pending + 1))
          if (( ${#setup_domains[@]} < 5 )); then
            setup_domains+=("${domain}(${web_state})")
          fi
        fi
        ;;
      bitrix)
        web_state=$(bitrix_web_state_probe "$domain")
        if [[ "$web_state" != "installed" ]]; then
          setup_pending=$((setup_pending + 1))
          if (( ${#setup_domains[@]} < 5 )); then
            setup_domains+=("${domain}(${web_state})")
          fi
        fi
        ;;
    esac
  done < <(list_sites 2>/dev/null || true)

  local total_children budget oversub summary
  total_children=$(perf_fpm_total_max_children)
  budget=$(perf_fpm_recommended_total_children)
  oversub=$(perf_fpm_oversubscription_risk "$total_children" "$budget")

  scheduler_job_report_write "health_review" \
    "generated_at|$(date +%s)" \
    "sites_total|${total}" \
    "sites_active|${active}" \
    "sites_suspended|${suspended}" \
    "sites_auto_disabled|${auto_disabled}" \
    "sites_setup_pending|${setup_pending}" \
    "sites_ssl_expiring_soon|${ssl_expiring_soon}" \
    "sites_ssl_disabled|${ssl_disabled}" \
    "fpm_children|${total_children}" \
    "fpm_budget|${budget}" \
    "fpm_oversubscription|${oversub}" \
    "setup_domains|$(IFS=', '; echo "${setup_domains[*]:-}")" \
    "expiring_domains|$(IFS=', '; echo "${expiring_domains[*]:-}")" \
    "manual_domains|$(IFS=', '; echo "${manual_domains[*]:-}")"

  summary="sites=${total}, active=${active}, suspended=${suspended}, setup=${setup_pending}, ssl_soon=${ssl_expiring_soon}, oversub=${oversub}"
  echo "$summary"
}

scheduler_site_setup_state() {
  local domain="$1" profile="$2"
  local root="" web_state=""
  case "$profile" in
    laravel)
      root="${SITE_META[root]:-$(site_root_path "$domain")}"
      web_state=$(laravel_web_state_probe "$domain" "$root")
      if [[ "$web_state" == "app" ]]; then
        echo "ready"
      else
        echo "$web_state"
      fi
      ;;
    wordpress)
      web_state=$(wordpress_web_state_probe "$domain")
      if [[ "$web_state" == "installed" ]]; then
        echo "ready"
      else
        echo "$web_state"
      fi
      ;;
    bitrix)
      web_state=$(bitrix_web_state_probe "$domain")
      if [[ "$web_state" == "installed" ]]; then
        echo "ready"
      else
        echo "$web_state"
      fi
      ;;
    static|generic|alias)
      echo "ready"
      ;;
    *)
      echo "unknown"
      ;;
  esac
}

scheduler_site_review_run() {
  local total=0 setup_pending=0 setup_stale=0 pause_candidates=0 suspended=0 manual_sites=0
  local stale_days now_ts updated_ts age_days
  local setup_domains=() stale_domains=() pause_domains=() suspended_domains=()
  local domain profile runtime_state auto_effective usage_class setup_state updated_at
  stale_days=$(scheduler_site_review_stale_days)
  now_ts=$(date +%s)

  while IFS= read -r domain; do
    [[ -z "$domain" ]] && continue
    total=$((total + 1))
    if ! read_site_metadata "$domain" >/dev/null 2>&1; then
      continue
    fi

    profile="${SITE_META[profile]:-unknown}"
    runtime_state=$(site_runtime_state "$domain")
    auto_effective=$(site_auto_optimize_effective_enabled "$domain")
    usage_class=$(site_usage_class_get "$domain")
    setup_state=$(scheduler_site_setup_state "$domain" "$profile")
    updated_at="${SITE_META[updated_at]:-}"

    if [[ "$runtime_state" == "suspended" ]]; then
      suspended=$((suspended + 1))
      if (( ${#suspended_domains[@]} < 5 )); then
        suspended_domains+=("$domain")
      fi
    fi

    if [[ "$auto_effective" != yes* ]]; then
      manual_sites=$((manual_sites + 1))
    fi

    if [[ "$setup_state" != "ready" ]]; then
      setup_pending=$((setup_pending + 1))
      if (( ${#setup_domains[@]} < 5 )); then
        setup_domains+=("${domain}(${setup_state})")
      fi
      if [[ -n "$updated_at" && "$updated_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        updated_ts=$(date -d "$updated_at" +%s 2>/dev/null || echo "")
        if [[ -n "$updated_ts" && "$updated_ts" =~ ^[0-9]+$ ]]; then
          age_days=$(( (now_ts - updated_ts) / 86400 ))
          if (( age_days >= stale_days )); then
            setup_stale=$((setup_stale + 1))
            if (( ${#stale_domains[@]} < 5 )); then
              stale_domains+=("${domain}(${age_days}d)")
            fi
          fi
        fi
      fi
      continue
    fi

    if [[ "$runtime_state" == "active" && "$usage_class" == "rarely-used" ]]; then
      pause_candidates=$((pause_candidates + 1))
      if (( ${#pause_domains[@]} < 5 )); then
        if [[ "$auto_effective" == yes* ]]; then
          pause_domains+=("${domain}(auto)")
        else
          pause_domains+=("${domain}(manual)")
        fi
      fi
    fi
  done < <(list_sites 2>/dev/null || true)

  scheduler_job_report_write "site_review" \
    "generated_at|$(date +%s)" \
    "sites_total|${total}" \
    "sites_setup_pending|${setup_pending}" \
    "sites_setup_stale|${setup_stale}" \
    "sites_pause_candidates|${pause_candidates}" \
    "sites_suspended|${suspended}" \
    "sites_manual|${manual_sites}" \
    "setup_pending_domains|$(IFS=', '; echo "${setup_domains[*]:-}")" \
    "setup_stale_domains|$(IFS=', '; echo "${stale_domains[*]:-}")" \
    "pause_candidate_domains|$(IFS=', '; echo "${pause_domains[*]:-}")" \
    "suspended_domains|$(IFS=', '; echo "${suspended_domains[*]:-}")"

  echo "sites=${total}, setup_pending=${setup_pending}, setup_stale=${setup_stale}, pause_candidates=${pause_candidates}, suspended=${suspended}"
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
    health_review)
      if message=$(scheduler_health_review_run); then
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
    site_review)
      if message=$(scheduler_site_review_run); then
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
