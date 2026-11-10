#!/usr/bin/env bash
# One-click fixes of a site's profile rules (rules: admin/lib/site_checks.sh).

site_checks_site_ok() {
  local domain="$1"
  [[ -n "$domain" ]] || { require_args "domain"; return 1; }
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
}

# Refuses an unknown rule, a rule of another profile and a rule that holds.
# Prints the refusal code on stdout for the JSON answer of check-state.
site_check_fix_refusal() {
  local id="$1" domain="$2"
  if ! site_check_known "$id"; then
    echo "unknown_check"; return 0
  fi
  site_check_state "$id" "$domain"
  case "$SC_STATE" in
    n/a) echo "unknown_check" ;;
    ok) echo "check_ok" ;;
  esac
}

site_check_state_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" id="${PARSED_ARGS[id]:-}" refusal
  site_checks_site_ok "$domain" || return 1
  [[ "$id" =~ ^[a-z0-9]+\.[a-z0-9-]+$ ]] || { error "--id must look like bitrix.db-charset"; return 1; }
  refusal=$(site_check_fix_refusal "$id" "$domain")
  if site_check_known "$id"; then site_check_state "$id" "$domain"; else SC_STATE="n/a"; SC_DETAIL=""; fi
  local title="" plan=""
  title=$(site_check_title "$id" 2>/dev/null || true)
  plan=$(site_check_plan_text "$id" 2>/dev/null || true)
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    python3 -c 'import json,sys; i,s,d,t,p,r=sys.argv[1:]; print(json.dumps({"schema":"simai-site-check/1","id":i,"state":s,"detail":d,"title":t or None,"plan":p or None,"refusal":r or None}, indent=2))' \
      "$id" "$SC_STATE" "$SC_DETAIL" "$title" "$plan" "$refusal"
    return 0
  fi
  ui_header "SIMAI ENV · Site check"
  ui_result_table "Domain|${domain}" "Check|${id}" "Title|${title:-unknown}" "State|${SC_STATE}" "Detail|${SC_DETAIL:--}"
  [[ -z "$refusal" && -n "$plan" ]] && ui_kv "Fix" "$plan"
  return 0
}

site_check_fix_plan_check() {
  local domain id refusal
  domain=$(command_arg domain "$@")
  id=$(command_arg id "$@")
  site_checks_site_ok "$domain" || return 1
  refusal=$(site_check_fix_refusal "$id" "$domain")
  case "$refusal" in
    unknown_check) error "No check ${id} applies to ${domain}"; return 1 ;;
    check_ok) error "Check ${id} already holds for ${domain}; nothing to fix"; return 1 ;;
  esac
  return 0
}

site_check_fix_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}" id="${PARSED_ARGS[id]:-}" refusal
  site_checks_site_ok "$domain" || return 1
  refusal=$(site_check_fix_refusal "$id" "$domain")
  case "$refusal" in
    unknown_check) error "No check ${id} applies to ${domain}"; return 1 ;;
    check_ok)
      info "Check ${id} already holds for ${domain}; nothing to fix"
      return 0 ;;
  esac
  local title rc=0
  title=$(site_check_title "$id")
  info "Fixing ${id}: $(site_check_plan_text "$id")"
  site_check_apply "$id" "$domain" || rc=$?
  local result="$SC_RESULT"
  site_check_state "$id" "$domain"
  ui_header "SIMAI ENV · Site check fix"
  ui_result_table "Domain|${domain}" "Check|${id}" "Title|${title}" "Result|${result}" "State now|${SC_STATE}"
  if (( rc != 0 )); then
    error "Fix ${id} failed for ${domain}: ${result}"
    return 1
  fi
  if [[ "$SC_STATE" == needed ]]; then
    error "Fix ${id} ran but the check still fails for ${domain}: ${SC_DETAIL}"
    return 1
  fi
  return 0
}

register_cmd "site" "check-state" "Show one profile rule of a site: state, what its fix does, why a fix would be refused" "site_check_state_handler" "domain id" "" "effects:read"
register_cmd "site" "check-fix" "Fix one profile rule reported by site doctor (fix id from the report)" "site_check_fix_handler" "domain id" "" "tier:advanced"
