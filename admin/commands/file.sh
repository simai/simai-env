#!/usr/bin/env bash
set -euo pipefail

# Files of one site for the panel's file manager. Every operation runs as the
# site's user inside the site directory (lib/site_files.py walks each path
# without following links), never as root.

FILE_HELPER=/usr/local/lib/simai-env/site-files.py

# Sets FILE_ROOT and FILE_USER for a domain.
file_site() {
  local domain="$1"
  validate_domain "$domain" || return 1
  require_site_exists "$domain" || return 1
  declare -A meta=()
  site_nginx_metadata_parse "/etc/nginx/sites-available/${domain}.conf" meta || { error "Nginx metadata not found for ${domain}"; return 1; }
  [[ -n "${meta[slug]:-}" && -d "${meta[root]:-}" ]] || { error "Site metadata incomplete for ${domain}"; return 1; }
  [[ "${meta[profile]:-}" != alias ]] || { error "An alias site has no files of its own; use its target site"; return 1; }
  FILE_ROOT="${meta[root]}"
  FILE_USER=$(site_effective_user "${meta[project]:-${meta[slug]}}")
}

# Runs the helper as the site user; its own stdin and stdout pass through.
file_helper() {
  cmp -s "${SIMAI_ENV_ROOT}/lib/site_files.py" "$FILE_HELPER" 2>/dev/null \
    || install -D -m 0755 -o root -g root "${SIMAI_ENV_ROOT}/lib/site_files.py" "$FILE_HELPER" || return 1
  (cd / && runuser -u "$FILE_USER" -- python3 -I "$FILE_HELPER" "$1" "$FILE_ROOT" "${@:2}")
}

file_prepare() {
  parse_kv_args "$@"
  require_args "domain" || return 1
  file_site "${PARSED_ARGS[domain]}"
}

file_show() {
  local json
  json=$(file_helper "$@") || return 1
  if [[ "${SIMAI_COMMAND_OUTPUT:-human}" == json ]]; then
    printf '%s\n' "$json"
  else
    python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
if "entries" in d:
    for e in d["entries"]:
        print("{:<5} {:>12} {}{}".format(e["type"], e["size"], e["name"], " -> " + str(e.get("target")) if e["type"] == "link" else ""))
    if d["truncated"]:
        print("(more entries not shown)")
elif "content" in d:
    sys.stdout.write(d["content"])
else:
    for k, v in d.items():
        if k != "schema":
            print("{:<8} {}".format(k, v))' "$json"
  fi
}

file_list_handler() { file_prepare "$@" && file_show list "${PARSED_ARGS[path]:-}"; }
file_stat_handler() { file_prepare "$@" && file_show stat "${PARSED_ARGS[path]:-}"; }

file_read_handler() {
  file_prepare "$@" && require_args "path" && file_show read "${PARSED_ARGS[path]}"
}

# Raw bytes of one file to stdout (the gateway streams them as a download).
file_cat_handler() {
  file_prepare "$@" && require_args "path" && file_helper cat "${PARSED_ARGS[path]}"
}

# Replace or create a text file with the content of --content-file. With
# --expect-sha256 the write fails if the file changed since it was read
# ("new": it must not exist yet).
file_write_handler() {
  file_prepare "$@" && require_args "path content-file" || return 1
  local expect="${PARSED_ARGS[expect-sha256]:-any}" src="${PARSED_ARGS[content-file]}"
  [[ "$expect" =~ ^([0-9a-f]{64}|new|any)$ ]] || { error "--expect-sha256 must be a sha256, new or any"; return 1; }
  [[ -f "$src" && ! -L "$src" ]] || { error "--content-file must be a file"; return 1; }
  file_show write "${PARSED_ARGS[path]}" "$expect" <"$src"
}

file_mkdir_handler() { file_prepare "$@" && require_args "path" && file_show mkdir "${PARSED_ARGS[path]}"; }
file_rename_handler() { file_prepare "$@" && require_args "path to" && file_show rename "${PARSED_ARGS[path]}" "${PARSED_ARGS[to]}"; }
file_remove_handler() { file_prepare "$@" && require_args "path" && file_show remove "${PARSED_ARGS[path]}"; }

register_cmd "file" "list" "List a directory of a site (as the site user, inside the site directory)" "file_list_handler" "domain" "path=" "tier:advanced effects:read"
register_cmd "file" "stat" "Show one file or directory of a site" "file_stat_handler" "domain" "path=" "tier:advanced effects:read"
register_cmd "file" "read" "Show a text file of a site (UTF-8, up to 1 MiB)" "file_read_handler" "domain path" "" "tier:advanced effects:read"
register_cmd "file" "cat" "Write the raw bytes of a site file to stdout" "file_cat_handler" "domain path" "" "tier:advanced effects:read"
register_cmd "file" "write" "Replace or create a text file of a site from --content-file" "file_write_handler" "domain path content-file" "expect-sha256=" "tier:advanced"
register_cmd "file" "mkdir" "Create a directory in a site" "file_mkdir_handler" "domain path" "" "tier:advanced"
register_cmd "file" "rename" "Rename or move a file or directory within a site" "file_rename_handler" "domain path to" "" "tier:advanced"
register_cmd "file" "remove" "Remove a file, a link or a directory with its contents from a site" "file_remove_handler" "domain path" "" "tier:advanced"
