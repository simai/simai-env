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
grep -q "install_repo_is_allowed" install.sh || fail "install.sh must restrict install repo by default"
grep -q "install_archive_entries_safe" install.sh || fail "install.sh must validate archive entries before extraction"
grep -q "install_find_extracted_source_dir" install.sh || fail "install.sh must require exactly one extracted source dir"
# 12) install/platform must not source /etc/os-release directly
grep -qE '^[[:space:]]*(source|\.)[[:space:]]+/etc/os-release' install.sh && fail "install.sh must not source /etc/os-release directly (env pollution regression)"
grep -qE '^[[:space:]]*(source|\.)[[:space:]]+/etc/os-release' lib/platform.sh && fail "platform_detect_os must not source /etc/os-release directly (env pollution regression)"
grep -q "REPO_BRANCH" install.sh || fail "install.sh must define REPO_BRANCH (VERSION collision regression)"
# 11) register_cmd must not use raw $6
grep -q 'optional="$6"' admin/core.sh && fail "register_cmd uses raw \$6 (set -u regression)"
grep -q 'optional="\${6-' admin/core.sh || fail "register_cmd should default optional via \${6-}"

# 2) Catch-all default_server deny present
grep -q "listen 80 default_server" simai-env.sh || fail "simai-env.sh missing listen 80 default_server"
grep -q "return 444" simai-env.sh || fail "simai-env.sh missing return 444"
grep -q "listen 80 default_server" admin/lib/site_utils.sh || fail "site_utils missing listen 80 default_server"
grep -q "return 444" admin/lib/site_utils.sh || fail "site_utils missing return 444"

# 3) No mysql password via argv (-p<pass>)
bad_mysql=$(
  find . \
    \( -path './.git' -o -path '*/node_modules' -o -path '*/vendor' \) -prune -o \
    -type f \( -name '*.sh' -o -name '*.profile.sh' \) \
    -not -path './scripts/ci/smoke.sh' -print0 |
    xargs -0 grep -nE 'mysql[^\\n]*-p[^[:space:]]' || true
)
if [[ -n "$bad_mysql" ]]; then
  fail "mysql password via argv found:\n${bad_mysql}"
fi

# 4) site doctor must keep security baseline checks visible
grep -q "doctor_world_writable_count" admin/commands/doctor.sh || fail "site doctor missing world-writable filesystem check helper"
grep -q "World-writable files" admin/commands/doctor.sh || fail "site doctor missing world-writable filesystem result"
grep -q "doctor_mysql_public_listeners" admin/commands/doctor.sh || fail "site doctor missing MySQL public listener check helper"
grep -q "MySQL network exposure" admin/commands/doctor.sh || fail "site doctor missing MySQL network exposure result"

# 5) backup import must reject unsafe archive entries
grep -q "backup_archive_path_safe" admin/lib/backup_utils.sh || fail "backup import missing archive path safety helper"
grep -q "backup_archive_types_safe" admin/lib/backup_utils.sh || fail "backup import missing archive type safety helper"
grep -q "Unsafe archive entry type" admin/lib/backup_utils.sh || fail "backup import must reject symlink/hardlink/device entries"
grep -q "unexpected unit name" admin/lib/backup_utils.sh || fail "backup import must reject unexpected systemd unit names"

# 6) access subsystem must expose a read-only security doctor
grep -q 'register_cmd "access" "doctor"' admin/commands/access.sh || fail "access doctor command not registered"
grep -q "ForceCommand internal-sftp" admin/commands/access.sh || fail "access doctor must check internal-sftp restriction"
grep -q "ChrootDirectory" admin/commands/access.sh || fail "access doctor must check chroot rule"
grep -q "expected root:root 755" admin/commands/access.sh || fail "access doctor must check project chroot ownership/mode"

# 7) destructive site removal must stay constrained to the managed web root
grep -q 'Refusing to remove path outside managed web root' admin/lib/site_utils.sh || fail "site remove missing managed web-root removal guard"
grep -q 'Refusing to remove symlink project path' admin/lib/site_utils.sh || fail "site remove must reject symlink project roots"
grep -q 'rm -rf --one-file-system' admin/lib/site_utils.sh || fail "site remove must avoid crossing filesystem boundaries"

# 8) DNS provider credentials must stay private and non-symlinked
grep -q 'DNS credentials file must not be a symlink' admin/commands/ssl.sh || fail "ssl DNS credentials must reject symlinks"
grep -q 'chown root:root "$file"' admin/commands/ssl.sh || fail "ssl DNS credentials must enforce root ownership"
grep -q 'chmod 0600 "$file"' admin/commands/ssl.sh || fail "ssl DNS credentials must enforce 0600 permissions"

# 9) New PHP-FPM pools must include baseline hardening directives
for src in admin/lib/site_utils.sh simai-env.sh; do
  grep -q 'listen.mode = 0660' "$src" || fail "${src} missing PHP-FPM socket mode hardening"
  grep -q 'clear_env = yes' "$src" || fail "${src} missing PHP-FPM clear_env hardening"
  grep -q 'security.limit_extensions = .php' "$src" || fail "${src} missing PHP-FPM extension hardening"
done
grep -q 'fail2ban' simai-env.sh || fail "bootstrap must install/configure fail2ban"
grep -q 'simai-sshd.local' simai-env.sh || fail "bootstrap must create managed fail2ban sshd jail"
grep -q 'fail2ban sshd jail' admin/commands/self.sh || fail "self status must report fail2ban jail state"
grep -q 'php${PHP_VERSION}-redis' simai-env.sh || fail "bootstrap PHP stack must include php-redis"
grep -q 'php${ver}-redis' admin/lib/php_utils.sh || fail "php install helper must include php-redis"

# 10) Nginx templates must deny dotfiles except ACME challenges
for tmpl in templates/nginx-*.conf; do
  [[ -f "$tmpl" ]] || continue
  grep -q 'location ~ \^/\\\.(?!well-known/)' "$tmpl" || fail "${tmpl} missing dotfile deny rule"
done

# 11) self-update supply-chain guardrails must stay wired
grep -q "update_repo_is_allowed" lib/update_channel.sh || fail "update channel missing repo allowlist helper"
grep -q "update_archive_entries_safe" lib/update_channel.sh || fail "update channel missing archive validation helper"
grep -q "SIMAI_UPDATE_ALLOW_UNRESOLVED_REF" update.sh || fail "update.sh missing explicit unresolved-ref escape hatch"
grep -q 'register_cmd "self" "supply-chain-doctor"' admin/commands/self.sh || fail "self supply-chain-doctor command not registered"
grep -q 'updater_tmp=$(mktemp -d)' admin/commands/self.sh || fail "self update must run updater from a temporary snapshot"
grep -q 'INSTALL_DIR="${SCRIPT_DIR}" "${updater_tmp}/update.sh"' admin/commands/self.sh || fail "self update must target current install dir from temporary updater"

# 12) non-root sudo admin workflow must be managed and diagnosable
grep -q 'register_cmd "self" "sudo-admin-ensure"' admin/commands/self.sh || fail "sudo-admin-ensure command not registered"
grep -q 'register_cmd "self" "sudo-admin-doctor"' admin/commands/self.sh || fail "sudo-admin-doctor command not registered"
grep -q 'register_cmd "self" "admin-mode-status"' admin/commands/self.sh || fail "admin-mode-status command not registered"
grep -q 'self_admin_mode_detect' admin/commands/self.sh || fail "admin access mode detection missing"
grep -q 'admin access mode' admin/commands/self.sh || fail "self status must report admin access mode"
grep -q 'useradd -m -s /bin/bash "$login"' admin/commands/self.sh || fail "sudo-admin-ensure must create a normal shell user"
grep -q 'usermod -aG sudo "$login"' admin/commands/self.sh || fail "sudo-admin-ensure must add user to sudo group"
grep -q 'visudo -cf "$sudoers"' admin/commands/self.sh || fail "sudo-admin-ensure must validate sudoers file"
grep -q 'register_cmd "self" "ssh-hardening-ensure"' admin/commands/self.sh || fail "ssh-hardening-ensure command not registered"
grep -q 'register_cmd "self" "ssh-hardening-doctor"' admin/commands/self.sh || fail "ssh-hardening-doctor command not registered"
grep -q 'PermitRootLogin prohibit-password' admin/commands/self.sh || fail "SSH hardening must keep root key-only"
grep -q 'PasswordAuthentication no' admin/commands/self.sh || fail "SSH hardening must disable password auth"

echo "Smoke checks passed"
