#!/usr/bin/env bash

# site status: where a site stands on its creation route (self profiles
# routes), in one answer shape for every profile (simai-site-status/1):
#   route          new|restore|repo|installed|none
#   step           the id of a route step (prepare, upload, validate,
#                  run_restore, run_setup, deploy, configure, finalize) or done
#   next           the command of that step, open_url, or null
#   restore_url / installer_url   the address an open_url step opens
#   pending        what the next step will change (rule ids and the like)
#   detail         profile facts behind the answer (no secrets)
#
# Profile hook: a function site_status_profile_<profile> (bitrix and laravel
# below; WordPress adds its own) takes the domain, fills the SS_* variables
# and returns 0. A profile without a hook gets site_status_minimal.

site_status_reset() {
  SS_ROUTE="none" SS_STEP="prepare" SS_NEXT="" SS_RESTORE_URL="" SS_INSTALLER_URL=""
  SS_PENDING=() SS_DETAIL=()
}

# WordPress: the wp status flow (admin/commands/wp.sh).
site_status_profile_wordpress() {
  wp_prepare_site "$1" >/dev/null || return 1
  wp_state_summary
  wp_flow_state
  SS_ROUTE="$WP_FLOW_ROUTE"
  SS_STEP="$WP_FLOW_STEP"
  SS_NEXT="$WP_FLOW_NEXT"
  [[ "$WP_FLOW_ROUTE" == new && "$WP_FLOW_STEP" == install ]] && SS_INSTALLER_URL="$WP_FLOW_URL"
  SS_PENDING=("${WP_FLOW_PENDING[@]}")
  SS_DETAIL=("db_state=${WP_DB_STATE}" "web_state=${WP_WEB_STATE}")
  return 0
}

site_status_profile_bitrix() {
  local domain="$1" web_state
  bitrix_prepare_site "$domain" || return 1
  web_state=$(bitrix_web_state_probe "$domain")
  bitrix_flow_state "$domain" "$web_state"
  SS_ROUTE="$BX_FLOW_ROUTE"
  [[ "$SS_ROUTE" == setup ]] && SS_ROUTE="new"  # the wizard's route id
  SS_STEP="$BX_FLOW_STEP"
  SS_NEXT=$(bitrix_flow_next "$BX_FLOW_STEP")
  case "$BX_FLOW_STEP" in
    run_restore) SS_RESTORE_URL="$BX_FLOW_URL" ;;
    run_setup) SS_INSTALLER_URL="$BX_FLOW_URL" ;;
  esac
  SS_PENDING=("${BX_FLOW_PENDING[@]}")
  SS_DETAIL=("web_state=${web_state}" "archive=${BX_FLOW_ARCHIVE}")
  return 0
}

# Laravel: deploy (no application yet) -> configure (no APP_KEY in the shared
# .env: laravel finalize generates it) -> finalize (the scheduler the
# application wants is missing: cron add) -> done.
site_status_profile_laravel() {
  local domain="$1" root app_dir key_state scheduler="present" want_scheduler="yes"
  laravel_perf_prepare_site "$domain" || return 1
  root="$LARAVEL_PERF_ROOT" app_dir="$LARAVEL_PERF_ROOT" SS_ROUTE="installed"
  if deploy_layout_active "$root"; then
    app_dir="${root}/current" SS_ROUTE="repo"
  fi
  key_state=$(laravel_app_key_state "$root")
  [[ -f "$(cron_site_file_path "$LARAVEL_PERF_SLUG")" ]] || scheduler="missing"
  if laravel_queue_has_real_app "$app_dir"; then
    APP_SCHEDULER=""
    app_manifest_load "$app_dir" >/dev/null 2>&1 || true
    [[ "${APP_SCHEDULER:-}" == no ]] && want_scheduler="no"
    if [[ "$key_state" != set ]]; then
      SS_STEP="configure" SS_NEXT="laravel:finalize" SS_PENDING=("laravel.app-key")
    elif [[ "$want_scheduler" == yes && "$scheduler" == missing ]]; then
      SS_STEP="finalize" SS_NEXT="cron:add" SS_PENDING=("laravel.scheduler")
    else
      SS_STEP="done"
    fi
  else
    [[ "$SS_ROUTE" == repo ]] || SS_ROUTE="none"
    SS_STEP="deploy" SS_NEXT="site:deploy"
  fi
  SS_DETAIL=("app_key=${key_state}" "scheduler=${scheduler}" "release=$(deploy_state_get "$domain" CURRENT)")
  return 0
}

# Any other profile: done once the site serves something of its own.
site_status_minimal() {
  local domain="$1" profile="$2" root doc_root index="" f
  case "$profile" in
    redirect|proxy|alias) SS_ROUTE="installed" SS_STEP="done"; return 0 ;;
  esac
  root="${SITE_META[root]:-}"
  if [[ -n "$root" ]] && deploy_layout_active "$root"; then
    SS_ROUTE="repo" SS_STEP="done"
    SS_DETAIL=("release=$(deploy_state_get "$domain" CURRENT)")
    return 0
  fi
  doc_root=$(site_compute_doc_root "$root" "${SITE_META[public_dir]-public}" 2>/dev/null) || doc_root=""
  for f in index.html index.htm index.php; do
    [[ -n "$doc_root" && -f "${doc_root}/${f}" ]] && { index="${doc_root}/${f}"; break; }
  done
  if [[ -n "$index" ]] && ! grep -q "SIMAI placeholder" "$index" 2>/dev/null; then
    SS_ROUTE="installed" SS_STEP="done"
  else
    SS_ROUTE="none" SS_STEP="prepare"
    case "$profile" in
      static|node) SS_NEXT="site:deploy" ;;
      *) SS_NEXT="file:upload" ;;
    esac
  fi
  SS_DETAIL=("index=$([[ -n "$index" ]] && basename "$index" || echo missing)")
  return 0
}

site_status_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" profile hook rc=0
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  read_site_metadata "$domain" || { error "Failed to read site metadata for ${domain}"; return 1; }
  profile="${SITE_META[profile]:-generic}"
  site_status_reset
  hook="site_status_profile_${profile//-/_}"
  if declare -F "$hook" >/dev/null; then
    "$hook" "$domain" || rc=$?
  else
    site_status_minimal "$domain" "$profile" || rc=$?
  fi
  (( rc == 0 )) || return "$rc"
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" != json ]]; then
    ui_header "SIMAI ENV · Site status"
    print_kv_table "Domain|${domain}" "Profile|${profile}" "Route|${SS_ROUTE}" "Step|${SS_STEP}" \
      "Next|${SS_NEXT:-none}" "Open|${SS_RESTORE_URL:-${SS_INSTALLER_URL:-none}}" \
      "Pending|$(IFS=,; echo "${SS_PENDING[*]:-none}")"
    return 0
  fi
  python3 -c '
import json, sys
domain, profile, route, step, nxt, restore_url, installer_url, n = sys.argv[1:9]
pending = sys.argv[9:9 + int(n)]
detail = dict(kv.split("=", 1) for kv in sys.argv[9 + int(n):])
print(json.dumps({"schema": "simai-site-status/1", "domain": domain, "profile": profile, "route": route,
                  "step": step, "next": nxt or None, "restore_url": restore_url or None,
                  "installer_url": installer_url or None, "pending": [p for p in pending if p],
                  "detail": {k: (v or None) for k, v in detail.items()}}, indent=2))' \
    "$domain" "$profile" "$SS_ROUTE" "$SS_STEP" "$SS_NEXT" "$SS_RESTORE_URL" "$SS_INSTALLER_URL" \
    "${#SS_PENDING[@]}" "${SS_PENDING[@]}" "${SS_DETAIL[@]}"
}

register_cmd "site" "status" "Show where a site stands on its creation route: route, step, next command (JSON with --output json)" "site_status_handler" "domain" "" "tier:advanced effects:read"
