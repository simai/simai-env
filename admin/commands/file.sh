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
if d.get("schema") == "simai-file-trash/1" and "entries" in d:
    for e in d["entries"]:
        print("{}  {:<5} {:>12} {}".format(e["id"], e["type"], e["size"], e["path"] or "(unknown path)"))
    print("{} entries, {} bytes; kept {} days".format(d["count"], d["total_bytes"], d["retention_days"]))
elif "entries" in d:
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

# Put an uploaded file (any bytes, up to 1 GiB) at --path; --sha256 is
# checked before anything is written.
file_upload_handler() {
  file_prepare "$@" && require_args "path source sha256" || return 1
  local expect="${PARSED_ARGS[expect-sha256]:-new}" src="${PARSED_ARGS[source]}" sum="${PARSED_ARGS[sha256]}"
  [[ "$expect" =~ ^([0-9a-f]{64}|new|any)$ ]] || { error "--expect-sha256 must be a sha256, new or any"; return 1; }
  [[ "$sum" =~ ^[0-9a-f]{64}$ ]] || { error "--sha256 must be a sha256"; return 1; }
  [[ -f "$src" && ! -L "$src" ]] || { error "--source must be a file"; return 1; }
  [[ "$(sha256sum "$src" | cut -d' ' -f1)" == "$sum" ]] || { error "The upload does not match --sha256"; return 1; }
  file_show put "${PARSED_ARGS[path]}" "$expect" <"$src"
}

file_archive_handler() { file_prepare "$@" && require_args "path to" && file_show archive "${PARSED_ARGS[path]}" "${PARSED_ARGS[to]}"; }

file_extract_handler() {
  file_prepare "$@" && require_args "path to" || return 1
  local overwrite="${PARSED_ARGS[overwrite]:-no}"
  [[ "$overwrite" =~ ^(yes|no)$ ]] || { error "--overwrite must be yes or no"; return 1; }
  file_show extract "${PARSED_ARGS[path]}" "${PARSED_ARGS[to]}" "$overwrite"
}

file_mkdir_handler() { file_prepare "$@" && require_args "path" && file_show mkdir "${PARSED_ARGS[path]}"; }
file_rename_handler() { file_prepare "$@" && require_args "path to" && file_show rename "${PARSED_ARGS[path]}" "${PARSED_ARGS[to]}"; }

# Into the site's trash (<root>/.simai-trash) unless --permanent yes.
file_remove_handler() {
  file_prepare "$@" && require_args "path" || return 1
  local permanent="${PARSED_ARGS[permanent]:-no}"
  [[ "$permanent" =~ ^(yes|no)$ ]] || { error "--permanent must be yes or no"; return 1; }
  if [[ "$permanent" == yes ]]; then
    file_show remove "${PARSED_ARGS[path]}"
  else
    file_show trash "${PARSED_ARGS[path]}"
  fi
}

file_copy_handler() { file_prepare "$@" && require_args "path to" && file_show copy "${PARSED_ARGS[path]}" "${PARSED_ARGS[to]}"; }

FILE_TRASH_ID_RE='^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$'

file_trash_id_arg() {
  [[ -z "${1:-}" || "$1" =~ $FILE_TRASH_ID_RE ]] || { error "--id must be a trash id such as 20261116T120000Z-1a2b3c"; return 1; }
}

file_trash_list_handler() { file_prepare "$@" && file_show trash-list ""; }

file_trash_restore_handler() {
  file_prepare "$@" && require_args "id" && file_trash_id_arg "${PARSED_ARGS[id]}" || return 1
  file_show trash-restore "" "${PARSED_ARGS[id]}" "${PARSED_ARGS[to]:-}"
}

file_trash_empty_handler() {
  file_prepare "$@" && file_trash_id_arg "${PARSED_ARGS[id]:-}" || return 1
  file_show trash-empty "" "${PARSED_ARGS[id]:-}"
}

# Plan checks (admin/lib/execution.sh): what the copy or restore would refuse
# (missing source or entry, a target that exists, a bad path), seen before
# confirming. They change nothing.
file_copy_plan_check() {
  local domain path to
  domain=$(command_arg domain "$@"); path=$(command_arg path "$@"); to=$(command_arg to "$@")
  [[ -n "$path" && -n "$to" ]] || return 0
  file_site "$domain" || return 1
  file_helper copy-check "$path" "$to" >/dev/null
}

file_trash_restore_plan_check() {
  local domain id to
  domain=$(command_arg domain "$@"); id=$(command_arg id "$@"); to=$(command_arg to "$@")
  [[ -n "$id" ]] || return 0
  file_trash_id_arg "$id" || return 1
  file_site "$domain" || return 1
  file_helper trash-restore-check "" "$id" "$to" >/dev/null
}

register_cmd "file" "list" "List a directory of a site (as the site user, inside the site directory)" "file_list_handler" "domain" "path=" "tier:advanced effects:read"
register_cmd "file" "stat" "Show one file or directory of a site" "file_stat_handler" "domain" "path=" "tier:advanced effects:read"
register_cmd "file" "read" "Show a text file of a site (UTF-8, up to 1 MiB)" "file_read_handler" "domain path" "" "tier:advanced effects:read"
register_cmd "file" "cat" "Write the raw bytes of a site file to stdout" "file_cat_handler" "domain path" "" "tier:advanced effects:read"
register_cmd "file" "write" "Replace or create a text file of a site from --content-file" "file_write_handler" "domain path content-file" "expect-sha256=" "tier:advanced"
register_cmd "file" "upload" "Put an uploaded file into a site (up to 1 GiB, checked against --sha256)" "file_upload_handler" "domain path source sha256" "expect-sha256=" "tier:advanced"
register_cmd "file" "archive" "Pack a file or directory of a site into a new .tar.gz, .tgz, .tar or .zip" "file_archive_handler" "domain path to" "" "tier:advanced"
register_cmd "file" "extract" "Unpack an archive of a site into a directory (files and directories only)" "file_extract_handler" "domain path to" "overwrite=" "tier:advanced"
register_cmd "file" "mkdir" "Create a directory in a site" "file_mkdir_handler" "domain path" "" "tier:advanced"
register_cmd "file" "rename" "Rename or move a file or directory within a site" "file_rename_handler" "domain path to" "" "tier:advanced"
register_cmd "file" "remove" "Move a file, a link or a directory of a site into its trash (--permanent yes deletes for good)" "file_remove_handler" "domain path" "permanent=" "tier:advanced"
register_cmd "file" "copy" "Copy a file or directory within a site (links copied as links)" "file_copy_handler" "domain path to" "" "tier:advanced"
register_cmd "file" "trash-list" "List the site's trash (entries are kept 30 days)" "file_trash_list_handler" "domain" "" "tier:advanced effects:read"
register_cmd "file" "trash-restore" "Put a trash entry back where it was or at --to" "file_trash_restore_handler" "domain id" "to=" "tier:advanced"
register_cmd "file" "trash-empty" "Delete one trash entry (--id) or the whole trash of a site for good" "file_trash_empty_handler" "domain" "id=" "tier:advanced effects:delete"
