#!/usr/bin/env bash
# A fresh interpreter keeps errexit active even when the caller is an if/pipeline.
set -euo pipefail
export SIMAI_SOURCE_ONLY=1
source "$(dirname "${BASH_SOURCE[0]}")/../simai-admin.sh"
# Only this interpreter loads definitions without dispatching. Handlers that
# start simai-admin.sh again (self update -> self migrate) must dispatch.
unset SIMAI_SOURCE_ONLY
section="$1"; name="$2"; shift 2
key="${section}:${name}"
handler="${CMD_HANDLERS[$key]:-}"
[[ -n "$handler" ]] || exit 2
effect=$(command_effect "$key" "$@")
domain=$(command_arg domain "$@")
if [[ "$effect" != read ]]; then
  case "${CMD_LOCK[$key]}" in
    none) ;;
    host) command_lock '' ;;
    *) command_lock "$domain" ;;
  esac
fi
site_command_context "$@"
export SIMAI_OPERATION_ACTIVE=1
if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json && "$key" == site:doctor ]]; then
  # Diagnostics prints progress/UI separately from its structured report.
  # Override only presentation in this isolated interpreter.
  progress_step() { :; }
  progress_done() { :; }
  ui_header() { :; }
  print_kv_table() { :; }
fi
# Do not wrap this invocation in a conditional: it must retain errexit.
"$handler" "$@"
