#!/usr/bin/env bash
set -euo pipefail

backup_sha256() {
  local path="$1"
  sha256sum "$path" | awk '{print $1}'
}

backup_require_python3() {
  if ! command -v python3 >/dev/null 2>&1; then
    error "python3 is required for backup commands"
    return 1
  fi
  return 0
}

backup_is_simai_cron() {
  local file="$1" slug="$2" domain="$3"
  [[ ! -f "$file" ]] && return 1
  grep -q "^# simai-managed: yes" "$file" || return 1
  grep -q "^# simai-slug: ${slug}\>" "$file" || return 1
  if [[ -n "$domain" ]]; then
    grep -q "^# simai-domain: ${domain}\>" "$file" || true
  fi
  return 0
}

backup_stage_files() {
  local dst_root="$1"; shift
  local -n _src_ref="$1"; shift
  local -n _dst_ref="$1"
  for idx in "${!_src_ref[@]}"; do
    local src="${_src_ref[$idx]}"
    local rel="${_dst_ref[$idx]}"
    local dst="${dst_root}/${rel}"
    mkdir -p "$(dirname "$dst")"
    cp -p "$src" "$dst"
  done
}

backup_write_manifest() {
  local root="$1" domain="$2" slug="$3" profile="$4" php="$5" public_dir="$6" doc_root="$7" enabled="$8"
  backup_require_python3 || return 1
  python3 - "$root" "$domain" "$slug" "$profile" "$php" "$public_dir" "$doc_root" "$enabled" <<'PY'
import json, os, sys, hashlib, datetime
root, domain, slug, profile, php, public_dir, doc_root, enabled = sys.argv[1:]
enabled = enabled.lower() == "true"
items=[]
for dirpath, _, filenames in os.walk(root):
    for fn in filenames:
        path=os.path.join(dirpath, fn)
        rel=os.path.relpath(path, root)
        if rel=="manifest.json":
            continue
        h=hashlib.sha256()
        with open(path,"rb") as f:
            for chunk in iter(lambda: f.read(1024*1024), b""):
                if not chunk:
                    break
                h.update(chunk)
        mode=f"{os.stat(path).st_mode & 0o777:04o}"
        items.append({"path":rel,"sha256":h.hexdigest(),"mode":mode})
manifest={
  "schema": 1,
  "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
  "domain": domain,
  "slug": slug,
  "profile": profile,
  "php": php,
  "public_dir": public_dir,
  "doc_root": doc_root,
  "enabled": enabled,
  "files": items,
}
with open(os.path.join(root,"manifest.json"),"w",encoding="utf-8") as f:
  json.dump(manifest,f,ensure_ascii=False,indent=2)
  f.write("\n")
PY
}

backup_pack_archive() {
  local src="$1" out="$2"
  tar -czf "$out" -C "$src" .
}

backup_print_manifest() {
  local manifest="$1"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$manifest" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    d=json.load(f)
print(f"domain: {d.get('domain')}")
print(f"slug: {d.get('slug')}")
print(f"profile: {d.get('profile')}")
print(f"php: {d.get('php')}")
print(f"public_dir: {d.get('public_dir')}")
print(f"doc_root: {d.get('doc_root')}")
print(f"enabled: {d.get('enabled')}")
print("files:")
for f in d.get("files",[]):
    print(f" - {f.get('path')} (sha256 {f.get('sha256')})")
PY
  else
    cat "$manifest"
  fi
}

backup_verify_checksums() {
  local root="$1" manifest="$2"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not available; skipping checksum verification"
    return 0
  fi
  local result
  result=$(python3 - "$root" "$manifest" <<'PY'
import sys, json, os, hashlib
root, manifest = sys.argv[1], sys.argv[2]
with open(manifest, encoding="utf-8") as f:
    data=json.load(f)
ok=True
for fdesc in data.get("files",[]):
    rel=fdesc.get("path")
    expected=fdesc.get("sha256")
    path=os.path.join(root, rel)
    if not os.path.exists(path):
        ok=False
        print(f"MISS {rel}")
        continue
    h=hashlib.sha256()
    with open(path,"rb") as f:
        h.update(f.read())
    if h.hexdigest()!=expected:
        ok=False
        print(f"FAIL {rel}")
print("OK" if ok else "BAD")
PY
)
  if [[ "$result" != "OK" ]]; then
    echo "$result"
    return 1
  fi
  return 0
}

backup_manifest_fields() {
  local manifest="$1"
  backup_require_python3 || return 1
  python3 - "$manifest" <<'PY'
import json,sys
with open(sys.argv[1],encoding="utf-8") as f:
    d=json.load(f)
fields=[
  d.get("domain",""),
  d.get("slug",""),
  d.get("profile",""),
  d.get("php",""),
  d.get("public_dir",""),
  d.get("doc_root",""),
  str(d.get("enabled", False)).lower(),
]
for item in fields:
    print(item)
PY
}

backup_print_plan() {
  local root="$1" domain="$2" slug="$3" php="$4"
  echo "Would write:"
  find "$root" -type f | sed "s|$root/||" | while read -r f; do
    echo " - $f"
  done
  echo "Target paths:"
  echo " - /etc/nginx/sites-available/${domain}.conf"
  echo " - /etc/nginx/sites-enabled/${domain}.conf (if enable=yes)"
  if [[ "$php" != "none" ]]; then
    echo " - /etc/php/${php}/fpm/pool.d/${slug}.conf (if present in bundle)"
  fi
  echo " - /etc/cron.d/${slug} (if included and simai-managed)"
  echo " - systemd unit for queue (if included)"
}

backup_apply_files() {
  local root="$1" domain="$2" slug="$3" php="$4" enable_flag="$5" ts="$6"
  local -n rollback_ref="$7"
  local ok=0

  local nginx_src="${root}/nginx/sites-available/${domain}.conf"
  local nginx_dst="/etc/nginx/sites-available/${domain}.conf"
  if [[ ! -f "$nginx_src" ]]; then
    error "Nginx config missing in bundle"
    return 1
  fi
  mkdir -p "/etc/nginx/sites-available" "/etc/nginx/sites-enabled"
  backup_backup_if_exists "$nginx_dst" "$ts" rollback_ref
  cp "$nginx_src" "$nginx_dst"

  local nginx_enabled_src="${root}/nginx/sites-enabled/${domain}.conf.symlink"
  if [[ "$enable_flag" == "yes" ]]; then
    local symlink="/etc/nginx/sites-enabled/${domain}.conf"
    backup_backup_if_exists "$symlink" "$ts" rollback_ref
    ln -sf "$nginx_dst" "/etc/nginx/sites-enabled/${domain}.conf"
  fi

  if [[ "$php" != "none" ]]; then
    local pool_src="${root}/php-fpm/pool.d/php${php}/${slug}.conf"
    local pool_dst="/etc/php/${php}/fpm/pool.d/${slug}.conf"
    if [[ -f "$pool_src" ]]; then
      mkdir -p "$(dirname "$pool_dst")"
      backup_backup_if_exists "$pool_dst" "$ts" rollback_ref
      cp "$pool_src" "$pool_dst"
    fi
  fi

  local cron_src="${root}/cron.d/${slug}"
  local cron_dst="/etc/cron.d/${slug}"
  if [[ -f "$cron_src" ]]; then
    if backup_is_simai_cron "$cron_src" "$slug" "$domain"; then
      mkdir -p "/etc/cron.d"
      backup_backup_if_exists "$cron_dst" "$ts" rollback_ref
      cp "$cron_src" "$cron_dst"
    else
      warn "Skipping cron import: not simai-managed or slug mismatch"
    fi
  fi

  local systemd_dir="${root}/systemd"
  if [[ -d "$systemd_dir" ]]; then
    for unit in "$systemd_dir"/*.service; do
      [[ -f "$unit" ]] || continue
      local dst="/etc/systemd/system/$(basename "$unit")"
      backup_backup_if_exists "$dst" "$ts" rollback_ref
      cp "$unit" "$dst"
    done
  fi

  ok=1
  return $((1-ok))
}

backup_backup_if_exists() {
  local path="$1" ts="$2"
  local -n ref="$3"
  if [[ -e "$path" || -L "$path" ]]; then
    local backup="${path}.bak.${ts}"
    cp -a "$path" "$backup"
    ref+=("$path|$backup|exist")
  else
    ref+=("$path||new")
  fi
}

backup_rollback() {
  local -n ref="$1"
  for entry in "${ref[@]}"; do
    local path="${entry%%|*}"
    local rest="${entry#*|}"
    local backup="${rest%%|*}"
    local status="${rest##*|}"
    if [[ "$status" == "exist" && -n "$backup" && ( -e "$backup" || -L "$backup" ) ]]; then
      cp -a "$backup" "$path"
    elif [[ "$status" == "new" ]]; then
      rm -f "$path"
    fi
  done
}

backup_reload_services() {
  local domain="$1" php="$2"
  if ! nginx -t; then
    error "nginx -t failed; not reloading"
    return 1
  fi
  if ! os_svc_reload_or_restart nginx; then
    error "Failed to reload/restart nginx"
    return 1
  fi
  if [[ "$php" != "none" ]]; then
    if ! os_svc_reload_or_restart "php${php}-fpm"; then
      error "Failed to reload/restart php${php}-fpm"
      return 1
    fi
  fi
  return 0
}
backup_safe_extract_archive() {
  local file="$1" dst="$2"
  if [[ ! -f "$file" ]]; then
    error "Archive not found: ${file}"
    return 1
  fi
  local paths
  if ! paths=$(tar -tzf "$file" 2>/dev/null); then
    error "Failed to list archive contents"
    return 1
  fi
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    [[ "$p" == -* ]] && { error "Unsafe path in archive: ${p}"; return 1; }
    [[ "$p" == /* ]] && { error "Absolute path in archive: ${p}"; return 1; }
    [[ "$p" == *".."* ]] && { error "Path traversal detected in archive: ${p}"; return 1; }
    [[ "$p" == *\\* ]] && { error "Backslash in path not allowed: ${p}"; return 1; }
  done <<<"$paths"
  tar --no-same-owner --no-same-permissions -xzf "$file" -C "$dst"
}
