#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2164  # container test script: loose quoting/cd checks are fine here
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq curl ca-certificates logrotate >/dev/null 2>&1
cd /src
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

# 1. SHA resolution without git (fresh minimal image).
command -v git >/dev/null && bad "git unexpectedly present" || true
source lib/update_channel.sh
sha=$(update_resolve_ref_sha refs/heads/main https://github.com/simai/simai-env)
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] && ok "resolves main via API without git ($sha)" || bad "no SHA without git: '$sha'"
eval "$(awk '/^install_resolve_ref_sha\(\) \{/,/^\}/' install.sh)"
sha2=$(install_resolve_ref_sha refs/heads/main https://github.com/simai/simai-env)
[[ "$sha2" == "$sha" ]] && ok "install.sh resolver agrees" || bad "install resolver: '$sha2'"
install_resolve_ref_sha refs/heads/main 'https://github.com/x/y;id' >/dev/null && bad "accepted bad slug" || ok "rejects malformed repo slug"

# 2. Node via pinned NodeSource repo (no remote script).
export SCRIPT_DIR=/src SIMAI_ENV_ROOT=/src
LOG_FILE=/tmp/env.log
set +u
eval "$(sed -n '/^NODESOURCE_KEY_FPR=/p' simai-env.sh)"
source lib/os_adapter.sh 2>/dev/null
source lib/platform.sh 2>/dev/null
eval "$(awk '/^apt_update_once\(\) \{/,/^\}/' simai-env.sh)"
eval "$(awk '/^add_nodesource_repo\(\) \{/,/^\}/' simai-env.sh)"
set -u
APT_UPDATED=0
info() { :; }; error() { echo "error: $*"; }
run_long() { shift; env "$@" >/dev/null 2>&1; }
os_adapter_init >/dev/null 2>&1 || true
NODE_VERSION=22
if add_nodesource_repo && apt-get install -y -qq nodejs >/dev/null 2>&1; then
  v=$(node -v); [[ "$v" == v22.* ]] && ok "Node $v installed from NodeSource" || bad "node version $v"
else
  bad "add_nodesource_repo/apt install failed"
fi
grep -q 'signed-by=/etc/apt/keyrings/nodesource.gpg' /etc/apt/sources.list.d/nodesource.list && ok "repo uses signed-by keyring" || bad "repo line"
NODESOURCE_KEY_FPR=0000000000000000000000000000000000000000
add_nodesource_repo >/dev/null 2>&1 && bad "accepted wrong key fingerprint" || ok "rejects mismatched key fingerprint"

# 3. site add guards.
set +u; SIMAI_USER=root; source admin/lib/site_utils.sh; set +e; set -u
error() { :; }
site_validate_wildcard_domain '*.example.com' && ok "accepts *.example.com" || bad "rejected valid wildcard"
for w in 'example.com' '*.ex#ample.com' '*.a.com;evil' '*.a.com}' '**.a.com'; do
  site_validate_wildcard_domain "$w" && bad "accepted wildcard '$w'" || ok "rejects wildcard '$w'"
done
WWW_ROOT=/home/simai/www
for p in /home/simai/www/a.com /var/www/site /srv/app; do site_path_is_allowed_root "$p" && ok "allows $p" || bad "blocks $p"; done
for p in /var /etc/nginx /home/simai/www /home/simai/www/../../etc /root/x /usr/local; do site_path_is_allowed_root "$p" && bad "allows $p" || ok "blocks $p"; done
SIMAI_ALLOW_EXTERNAL_SITE_PATH=1 site_path_is_allowed_root /opt/app && ok "override allows /opt/app" || bad "override ignored"
mkdir -p /etc/php/8.2/fpm/pool.d; touch /etc/php/8.2/fpm/pool.d/a-b-com.conf
site_project_slug_in_use a-b-com >/dev/null && ok "detects slug collision (pool)" || bad "missed pool collision"
touch /etc/cron.d/x-y-com
site_project_slug_in_use x-y-com >/dev/null && ok "detects slug collision (cron)" || bad "missed cron collision"
site_project_slug_in_use fresh-com >/dev/null && bad "false collision" || ok "free slug accepted"

# 4. Atomic managed block write.
source admin/lib/scheduler_utils.sh 2>/dev/null
f=/etc/simai-env.conf; printf 'KEEP=1\n' >"$f"
scheduler_replace_managed_block "$f" '# b' '# e' 'A=1' && scheduler_replace_managed_block "$f" '# b' '# e' 'A=2'
[[ "$(cat "$f")" == $'KEEP=1\n\n# b\nA=2\n# e' ]] && ok "managed block replaced in place" || bad "conf content: $(cat -A "$f")"
[[ "$(stat -c %a "$f")" == 644 ]] && ok "conf mode 0644" || bad "conf mode $(stat -c %a "$f")"
ls /etc/simai-env.conf.* >/dev/null 2>&1 && bad "temp files left" || ok "no temp files left"

# 5. logrotate config is valid.
AUDIT_LOG_FILE=/var/log/simai-audit.log LOG_FILE=/var/log/simai-admin.log
eval "$(awk '/^ensure_audit_log\(\) \{/,/^\}/' admin/core.sh)"
eval "$(awk '/^ensure_simai_logrotate\(\) \{/,/^EOF$/' admin/core.sh; echo '  chmod 0644 "$conf"'; echo '}')"
touch /var/log/simai-admin.log; ensure_audit_log
logrotate -d /etc/logrotate.d/simai-env >/tmp/lr 2>&1 && ok "logrotate config parses" || { bad "logrotate config"; cat /tmp/lr; }
[[ "$(stat -c %a /var/log/simai-admin.log)" == 640 ]] && ok "admin log 0640" || bad "admin log mode"

echo "failures=${fails}"
exit "$fails"
