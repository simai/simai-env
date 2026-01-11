#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "SMOKE FAIL: $*" >&2
  exit 1
}

# 1) OS support matrix includes 22.04/24.04 and excludes 20.04
if ! grep -q 'platform_supported_matrix_string()' lib/platform.sh; then
  fail "platform_supported_matrix_string missing in lib/platform.sh"
fi
matrix_str=$(awk '/platform_supported_matrix_string\(\)/{flag=1;next}/^\}/{flag=0}flag{print}' lib/platform.sh | tr -d '\r')
for ver in "22.04" "24.04"; do
  echo "$matrix_str" | grep -q "$ver" || fail "platform_supported_matrix_string missing ${ver}"
done
echo "$matrix_str" | grep -q "20.04" && fail "platform_supported_matrix_string should not include 20.04"
grep -q '"22\.04"' lib/platform.sh || fail "platform_is_supported_os missing 22.04"
grep -q '"24\.04"' lib/platform.sh || fail "platform_is_supported_os missing 24.04"
! grep -q '"20\.04"' lib/platform.sh || fail "platform_is_supported_os should not include 20.04"

# 2) Nginx metadata includes version marker
grep -q "simai-meta-version: 2" lib/site_metadata.sh || fail "Missing simai-meta-version marker in metadata renderer"

# 3) Metadata docs mention required keys
grep -q "simai-domain" docs/architecture/site-metadata.md || fail "site-metadata doc missing simai-domain"
grep -q "simai-slug" docs/architecture/site-metadata.md || fail "site-metadata doc missing simai-slug"
grep -q "simai-profile" docs/architecture/site-metadata.md || fail "site-metadata doc missing simai-profile"
# 4) Nginx templates include DOC_ROOT placeholder
for tmpl in templates/nginx-*.conf; do
  [[ -f "$tmpl" ]] || continue
  grep -q "{{DOC_ROOT}}" "$tmpl" || fail "{{DOC_ROOT}} placeholder missing in ${tmpl}"
done
# 5) public_dir must not be defaulted via ':-public' or empty-normalized
bad_pd=$(grep -RIn -F "[public_dir]:-public" admin/commands admin/lib || true)
[[ -n "$bad_pd" ]] && fail "public_dir defaulting via ':-public' found:\n${bad_pd}"
bad_norm=$(grep -RIn -F '[[ -z "${SITE_META[public_dir]}" ]]' admin/lib/site_utils.sh || true)
[[ -n "$bad_norm" ]] && fail "public_dir empty normalization found:\n${bad_norm}"
# 6) OS adapter files and init present
[[ -f lib/os_adapter.sh ]] || fail "Missing lib/os_adapter.sh"
[[ -f lib/os/ubuntu.sh ]] || fail "Missing lib/os/ubuntu.sh"
grep -q "os_adapter_init" lib/os_adapter.sh || fail "os_adapter_init missing in lib/os_adapter.sh"
# 7) No direct systemctl list-unit-files in admin/lib|admin/commands (must go via adapter)
bad_list_units=$(grep -RIn "systemctl list-unit-files" admin/lib admin/commands 2>/dev/null | grep -v "lib/os_adapter.sh" || true)
[[ -n "$bad_list_units" ]] && fail "direct systemctl list-unit-files usage found:\n${bad_list_units}"
# 8) Backup command/docs present
[[ -f admin/commands/backup.sh ]] || fail "Missing admin/commands/backup.sh"
[[ -f docs/commands/backup.md ]] || fail "Missing docs/commands/backup.md"
grep -q 'register_cmd "backup"' admin/commands/backup.sh || fail "Backup commands not registered"
# 9) Backup manifest is valid JSON (selftest)
tmp_backup_dir=$(mktemp -d)
echo "x" >"${tmp_backup_dir}/a"
# shellcheck source=admin/lib/backup_utils.sh
source admin/lib/backup_utils.sh
backup_write_manifest "$tmp_backup_dir" "example.com" "example-com" "generic" "8.2" "" "/home/simai/www/example.com" "true"
python3 -c 'import json,sys; json.load(open(sys.argv[1],encoding="utf-8"))' "${tmp_backup_dir}/manifest.json" || fail "manifest.json not valid JSON"
rm -rf "$tmp_backup_dir"
# 10) install.sh guards (stdin-safe, no platform source)
[[ -f install.sh ]] || fail "Missing install.sh"
grep -q "BASH_SOURCE" install.sh && fail "install.sh must not use BASH_SOURCE (stdin regression)"
grep -qE 'source[[:space:]]+.*platform\.sh' install.sh && fail "install.sh must not source platform.sh before download"
grep -q "platform_" install.sh && fail "install.sh must not call platform_* (stdin regression)"

# 2) Catch-all default_server deny present
grep -q "listen 80 default_server" simai-env.sh || fail "simai-env.sh missing listen 80 default_server"
grep -q "return 444" simai-env.sh || fail "simai-env.sh missing return 444"
grep -q "listen 80 default_server" admin/lib/site_utils.sh || fail "site_utils missing listen 80 default_server"
grep -q "return 444" admin/lib/site_utils.sh || fail "site_utils missing return 444"

# 3) No mysql password via argv (-p<pass>)
bad_mysql=$(find . -type f \( -name '*.sh' -o -name '*.profile.sh' \) -not -path './.git/*' -not -path './scripts/ci/smoke.sh' -print0 | xargs -0 grep -nE 'mysql[^\\n]*-p[^[:space:]]' || true)
if [[ -n "$bad_mysql" ]]; then
  fail "mysql password via argv found:\n${bad_mysql}"
fi

echo "Smoke checks passed"
