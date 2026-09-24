#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2164  # container test script: loose quoting/cd checks are fine here
# Behavioural checks for the P0 fixes. Runs as root inside a disposable container.
set -uo pipefail
cd /src
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }

error() { echo "error: $*" >&2; }
info() { :; }
SIMAI_USER=simai
id -u simai >/dev/null 2>&1 || useradd -m simai

extract() { awk -v n="$1" '$0 ~ "^"n"\\(\\) \\{" {p=1} p {print} p && /^\}/ {exit}' "$2"; }
eval "$(extract generate_password admin/lib/site_utils.sh)"
eval "$(extract env_set_kv admin/lib/site_utils.sh)"
eval "$(extract laravel_prepare_env_file admin/lib/site_utils.sh)"
for f in access_mount_is_active access_path_has_mounts access_safe_remove_dir; do
  eval "$(extract "$f" admin/lib/access_utils.sh)"
done
for f in observer_base observer_path_is_trusted observer_assert_trusted_root observer_read_session; do
  eval "$(extract "$f" admin/commands/runtime_observer.sh)"
done

# 1. Password length
for _ in $(seq 200); do
  p=$(generate_password)
  [[ ${#p} -eq 32 && "$p" =~ ^[A-Za-z0-9]+$ ]] || { bad "password length ${#p}"; break; }
done
[[ ${#p} -eq 32 ]] && ok "200 passwords are 32 alnum chars"

# 2. env_set_kv refuses symlinks, keeps values
work=$(mktemp -d); chown simai "$work"
echo 'secret-target' >/root/target; chmod 600 /root/target
ln -s /root/target "$work/.env"
if env_set_kv "$work/.env" DB_PASSWORD x 2>/dev/null; then bad "env_set_kv followed symlink"; else ok "env_set_kv refuses symlink"; fi
[[ "$(stat -c '%U %a' /root/target)" == "root 600" ]] && ok "symlink target untouched" || bad "target perms changed"
rm "$work/.env"
env_set_kv "$work/.env" DB_PASSWORD 'p w"d' && env_set_kv "$work/.env" DB_HOST h && env_set_kv "$work/.env" DB_HOST h2
[[ "$(grep -c DB_HOST "$work/.env")" == 1 && "$(grep DB_HOST "$work/.env")" == DB_HOST=h2 ]] && ok "env_set_kv upserts" || bad "env_set_kv content: $(cat "$work/.env")"
[[ "$(stat -c '%U %a' "$work/.env")" == "simai 640" ]] && ok "env file owned simai 0640" || bad "env perms $(stat -c '%U %a' "$work/.env")"
site_primary_url() { echo "https://$1"; }
read_site_db_env() { :; }
laravel_env_file_path() { echo "$1/.env"; }
laravel_env_example_file_path() { echo "$1/.env.example"; }
lw=$(mktemp -d); ln -s /root/target "$lw/.env.example"
if laravel_prepare_env_file example.com "$lw" 2>/dev/null; then bad "laravel env copied symlinked example"; else ok "laravel env refuses symlinked example"; fi
[[ ! -e "$lw/.env" ]] && ok "no .env created from symlink" || bad ".env created"

# 3. access_safe_remove_dir never crosses a live bind mount
base=/tmp/jails; site=/tmp/site-www
mkdir -p "$base/u1/site" "$site"; echo keep >"$site/index.php"
if mount --bind "$site" "$base/u1/site" 2>/dev/null; then
  if access_safe_remove_dir "$base" "$base/u1" 2>/dev/null; then bad "removed jail with active mount"; else ok "refuses jail with active mount"; fi
  [[ -f "$site/index.php" ]] && ok "site files survive" || bad "site files deleted"
  umount "$base/u1/site"
  access_safe_remove_dir "$base" "$base/u1" && [[ ! -e "$base/u1" ]] && ok "removes jail after unmount" || bad "jail not removed"
else
  echo "SKIP bind mount (container not privileged)"
fi
access_safe_remove_dir "$base" "$base" 2>/dev/null && bad "removed base" || ok "refuses base itself"
access_safe_remove_dir "$base" /etc 2>/dev/null && bad "removed outside base" || ok "refuses path outside base"

# 4. Observer storage trust and session parsing
SIMAI_OBSERVER_ROOT=/home/simai/runtime-observer
mkdir -p /home/simai/runtime-observer/x; chown -R simai /home/simai/runtime-observer
observer_assert_trusted_root /home/simai/runtime-observer/x 2>/dev/null && bad "trusted simai-owned storage" || ok "rejects simai-owned storage"
install -d -m 0700 /var/lib/simai-env/runtime-observer/x
observer_assert_trusted_root /var/lib/simai-env/runtime-observer/x && ok "accepts root-owned storage" || bad "rejected root storage"
chmod 0777 /var/lib/simai-env/runtime-observer/x
observer_assert_trusted_root /var/lib/simai-env/runtime-observer/x 2>/dev/null && bad "trusted world-writable dir" || ok "rejects world-writable dir"
sf=$(mktemp)
printf 'SESSION_ACTOR=dev1\nSESSION_STARTED_AT=2026-09-21T10:00:00Z\nSESSION_BASE_COMMIT=%s\n' "$(printf 'a%.0s' {1..40})" >"$sf"
observer_read_session "$sf" && [[ "$SESSION_ACTOR" == dev1 ]] && ok "reads valid session" || bad "valid session rejected"
printf 'SESSION_ACTOR=$(touch /tmp/pwned)\nSESSION_BASE_COMMIT=abc; touch /tmp/pwned\n' >"$sf"
observer_read_session "$sf" && bad "accepted malicious session" || ok "rejects malicious session"
[[ ! -e /tmp/pwned ]] && ok "session file not executed" || bad "session file executed"

# 5. Strict dispatcher really aborts on failure
cat >/tmp/strict.sh <<'EOS'
set -euo pipefail
h() { false; echo reached; }
run() {
  local rc=0
  if [[ "${SIMAI_STRICT_HANDLERS:-0}" == "1" ]]; then
    local had_errexit=0; [[ $- == *e* ]] && had_errexit=1
    set +e; ( set -e; "$@" ); rc=$?; (( had_errexit )) && set -e
  elif ( "$@" ); then rc=0; else rc=$?; fi
  echo "rc=$rc"
}
run h
EOS
out=$(SIMAI_STRICT_HANDLERS=1 bash /tmp/strict.sh)
[[ "$out" == "rc=1" ]] && ok "strict mode aborts handler" || bad "strict output: $out"
out=$(bash /tmp/strict.sh | tr '\n' ' ')
[[ "$out" == "reached rc=0 " ]] && ok "default mode unchanged" || bad "default output: $out"
grep -q 'if \[\[ "\${SIMAI_STRICT_HANDLERS:-0}" == "1" \]\]' admin/core.sh && ok "core.sh uses the tested strict pattern" || bad "core.sh pattern differs"

echo "failures=${fails}"
exit "$fails"
