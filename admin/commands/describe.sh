#!/usr/bin/env bash

# AI-first discovery: an agent that connects to a server runs
#   simai-admin.sh self describe      (host, services, owners, sites)
#   simai-admin.sh site describe ...  (one site: layout, database, workers, how-to)
#   simai-admin.sh self commands      (every command with its options)
# All output is JSON on stdout; logs go to stderr. Secrets are never included.

self_describe_handler() {
  parse_kv_args "$@"
  python3 "${SIMAI_ENV_ROOT}/lib/host_describe.py" "$SIMAI_ENV_ROOT" host
}

site_describe_handler() {
  parse_kv_args "$@"
  local domain="${PARSED_ARGS[domain]:-}"
  require_args "domain" || return 1
  validate_domain "$domain" "allow" || return 1
  require_site_exists "$domain" || return 1
  python3 "${SIMAI_ENV_ROOT}/lib/host_describe.py" "$SIMAI_ENV_ROOT" site "$domain"
}

self_commands_handler() {
  parse_kv_args "$@"
  local key
  for key in "${!CMD_HANDLERS[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\n' "$key" "${CMD_DESCRIPTIONS[$key]:-}" "${CMD_REQUIRED[$key]:-}" \
      "${CMD_OPTIONAL[$key]:-}" "${CMD_FLAGS[$key]:-}"
  done | sort | python3 -c '
import json, sys
out = []
for line in sys.stdin:
    key, desc, required, optional, flags = (line.rstrip("\n").split("\t") + [""] * 5)[:5]
    section, name = key.split(":", 1)
    opts = [o.split("=", 1) for o in optional.split()]
    out.append({
        "command": f"simai-admin.sh {section} {name}",
        "description": desc,
        "required": [f"--{r}" for r in required.split()],
        "optional": {f"--{o[0]}": (o[1] if len(o) > 1 and o[1] else None) for o in opts},
        "flags": flags.split(),
    })
json.dump({"schema": "simai-commands/1", "count": len(out), "commands": out}, sys.stdout, indent=2, ensure_ascii=False)
print()'
}

register_cmd "self" "describe" "Describe this host for humans and AI agents (JSON)" "self_describe_handler" "" "" "tier:advanced"
register_cmd "site" "describe" "Describe one site: layout, database, workers, how-to (JSON)" "site_describe_handler" "domain" "" "tier:advanced"
register_cmd "self" "commands" "List every command with its options (JSON)" "self_commands_handler" "" "" "tier:advanced"
