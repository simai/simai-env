#!/usr/bin/env bash

# Server resources a site needs before it is created or restored: free disk
# on the filesystem that will hold it and memory against the profile's need
# (PROFILE_MIN_RAM_MB refuses, PROFILE_RECOMMENDED_RAM_MB warns). Used by the
# plans of site add and bitrix restore-ready (command_plan_check), by their
# handlers, and through those plans by the panel gateway ("resources").

# Free bytes on the filesystem of path (its nearest existing parent).
site_resources_disk_free() {
  local path="$1"
  while [[ -n "$path" && "$path" != / && ! -e "$path" ]]; do
    path=$(dirname "$path")
  done
  [[ -n "$path" ]] || path=/
  df -B1 --output=avail "$path" 2>/dev/null | awk 'NR == 2 { gsub(/ /, ""); print; exit }'
}

site_resources_ram_mb() {
  awk '/^MemTotal:/ { printf "%d\n", $2 / 1024; exit }' /proc/meminfo 2>/dev/null
}

# Sets RES_RAM_MIN and RES_RAM_REC (MB, 0 when the profile names none). The
# profile is read in a subshell so the caller's PROFILE_* stay as they were.
site_resources_profile_ram() {
  local profile="$1" line
  RES_RAM_MIN=0
  RES_RAM_REC=0
  is_profile_known "$profile" 2>/dev/null || return 0
  line=$(source_profile_file_raw "$profile" >/dev/null 2>&1 && printf '%s %s\n' "${PROFILE_MIN_RAM_MB:-0}" "${PROFILE_RECOMMENDED_RAM_MB:-0}") || line="0 0"
  # shellcheck disable=SC2034 # read by the caller
  read -r RES_RAM_MIN RES_RAM_REC <<<"$line"
  [[ "$RES_RAM_MIN" =~ ^[0-9]{1,7}$ ]] || RES_RAM_MIN=0
  [[ "$RES_RAM_REC" =~ ^[0-9]{1,7}$ ]] || RES_RAM_REC=0
  (( RES_RAM_REC >= RES_RAM_MIN )) || RES_RAM_REC=$RES_RAM_MIN
  return 0
}

# site_resources_check <path> <needed bytes> <profile>
# Sets RES_DISK_FREE, RES_NEEDED, RES_RAM_MB, RES_RAM_MIN, RES_RAM_REC,
# RES_REFUSAL (not_enough_disk | not_enough_ram | empty), RES_REFUSAL_TEXT
# and RES_WARNINGS ("code|message" rows). Fails when something refuses.
site_resources_check() {
  local path="$1" needed="${2:-0}" profile="${3:-}"
  RES_WARNINGS=()
  RES_REFUSAL=""
  RES_REFUSAL_TEXT=""
  [[ "$needed" =~ ^[0-9]{1,19}$ ]] || needed=0
  RES_NEEDED="$needed"
  RES_DISK_FREE=$(site_resources_disk_free "$path")
  [[ "$RES_DISK_FREE" =~ ^[0-9]+$ ]] || RES_DISK_FREE=""
  RES_RAM_MB=$(site_resources_ram_mb)
  [[ "$RES_RAM_MB" =~ ^[0-9]+$ ]] || RES_RAM_MB=""
  site_resources_profile_ram "$profile"
  if [[ -n "$RES_DISK_FREE" ]] && (( needed > 0 && RES_DISK_FREE < needed )); then
    RES_REFUSAL="not_enough_disk"
    RES_REFUSAL_TEXT="Not enough free disk: $(site_resources_human "$RES_DISK_FREE") free on the site filesystem, $(site_resources_human "$needed") needed (three times the archive)"
  elif [[ -z "$RES_DISK_FREE" ]]; then
    RES_WARNINGS+=("disk_unknown|Free disk space of ${path} could not be read")
  fi
  if [[ -n "$RES_RAM_MB" ]]; then
    if (( RES_RAM_MIN > 0 && RES_RAM_MB < RES_RAM_MIN )); then
      if [[ -z "$RES_REFUSAL" ]]; then
        RES_REFUSAL="not_enough_ram"
        RES_REFUSAL_TEXT="Not enough memory for the ${profile} profile: ${RES_RAM_MB} MB, at least ${RES_RAM_MIN} MB needed (${RES_RAM_REC} MB recommended)"
      fi
    elif (( RES_RAM_REC > 0 && RES_RAM_MB < RES_RAM_REC )); then
      RES_WARNINGS+=("ram_below_recommended|The server has ${RES_RAM_MB} MB of memory; the ${profile} profile recommends ${RES_RAM_REC} MB. Heavy jobs (restore, backups) can run out of memory")
    fi
  fi
  [[ -z "$RES_REFUSAL" ]]
}

site_resources_human() {
  local bytes="${1:-0}"
  if (( bytes >= 1073741824 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f GB\n", b / 1073741824 }'
  else
    awk -v b="$bytes" 'BEGIN { printf "%d MB\n", b / 1048576 }'
  fi
}

# The "resources" object of a plan (docs/architecture/panel-gate.md).
site_resources_json() {
  python3 -I -c '
import json, sys
free, needed, ram, ram_min, ram_rec, refusal = sys.argv[1:7]
num = lambda v: int(v) if v.isdigit() else None
warnings = [dict(zip(("code", "message"), w.split("|", 1))) for w in sys.argv[7:] if w]
print(json.dumps({"disk_free_bytes": num(free), "needed_bytes": num(needed), "ram_mb": num(ram),
                  "ram_min_mb": num(ram_min), "ram_recommended_mb": num(ram_rec),
                  "ok": not refusal, "refusal": refusal or None, "warnings": warnings}))' \
    "${RES_DISK_FREE:-}" "${RES_NEEDED:-0}" "${RES_RAM_MB:-}" "${RES_RAM_MIN:-0}" "${RES_RAM_REC:-0}" "${RES_REFUSAL:-}" \
    ${RES_WARNINGS[@]+"${RES_WARNINGS[@]}"}
}

# Warnings and the refusal on stderr (plans and handlers alike).
site_resources_report() {
  local w
  for w in ${RES_WARNINGS[@]+"${RES_WARNINGS[@]}"}; do
    warn "${w#*|}"
  done
  [[ -z "${RES_REFUSAL:-}" ]] || error "$RES_REFUSAL_TEXT"
  return 0
}

# A plan check may leave data for the JSON plan answer (core.sh run_command
# sets SIMAI_PLAN_DATA in plan mode only).
site_plan_data_write() {
  [[ -n "${SIMAI_PLAN_DATA:-}" && -f "$SIMAI_PLAN_DATA" && ! -L "$SIMAI_PLAN_DATA" ]] || return 0
  printf '%s\n' "$1" >"$SIMAI_PLAN_DATA"
}
