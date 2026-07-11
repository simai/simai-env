#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_DIR="$ROOT_DIR"
export LOG_FILE="${TMPDIR:-/tmp}/simai-env-registry-dispatch.log"
export AUDIT_LOG_FILE="${TMPDIR:-/tmp}/simai-env-registry-dispatch-audit.log"

# shellcheck source=../../admin/core.sh
source "${ROOT_DIR}/admin/core.sh"
source "${ROOT_DIR}/admin/lib/profile_utils.sh"
source "${ROOT_DIR}/admin/lib/scheduler_utils.sh"
source "${ROOT_DIR}/admin/lib/perf_utils.sh"
source "${ROOT_DIR}/admin/lib/site_utils.sh"
source "${ROOT_DIR}/lib/update_channel.sh"
source "${ROOT_DIR}/admin/lib/profile_apply.sh"
source "${ROOT_DIR}/admin/lib/apt_utils.sh"
source "${ROOT_DIR}/admin/lib/php_utils.sh"
source "${ROOT_DIR}/admin/lib/fix_utils.sh"
source "${ROOT_DIR}/admin/lib/doctor_utils.sh"
source "${ROOT_DIR}/admin/lib/db_utils.sh"
source "${ROOT_DIR}/admin/lib/access_utils.sh"
load_command_modules "${ROOT_DIR}/admin/commands"

tested=0
for key in "${!CMD_HANDLERS[@]}"; do
  section="${key%%:*}"
  command="${key#*:}"
  if run_command "$section" "$command" --__coverage_unknown yes >/dev/null 2>&1; then
    echo "dispatcher unexpectedly accepted unknown option: ${key}" >&2
    exit 1
  fi
  tested=$((tested + 1))
done

[[ $tested -eq ${#CMD_HANDLERS[@]} ]]
printf '[registry-dispatch] ok commands=%d\n' "$tested"
