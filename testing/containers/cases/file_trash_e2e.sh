#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Site trash and copy (1.57.0): file remove moves into <root>/.simai-trash as
# the site user, trash-list/restore/empty, 7-day retention, --permanent yes;
# file copy inside the site (links copied, never followed); the panel gateway
# (plans, a confirmed job, refusals).
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
fj() { cli file "$1" --domain trash.test "${@:2}" --output json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r.get("data", {"status": r.get("status")})))'; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain trash.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain trash.test --output json 2>/dev/null | js 'd["data"]["root"]')
user=$(stat -c %U "$root")
mkdir -p "$root/public/docs/sub"; echo one >"$root/public/docs/a.txt"; echo two >"$root/public/docs/sub/b.txt"
ln -sfn /etc "$root/public/docs/esc"; chown -R "$user:" "$root/public/docs"

# Trash.
[[ "$(fj trash-list | js 'd["count"]')" == 0 ]] && ok "an empty trash lists no entries" || bad "trash-list empty: $(fj trash-list)"
cli file remove --domain trash.test --path public/docs/a.txt >/dev/null 2>&1; [[ -f "$root/public/docs/a.txt" ]] && ok "without confirm nothing is removed" || bad "remove without confirm"
r=$(cli file remove --domain trash.test --path public/docs --confirm yes 2>&1)
tid=$(fj trash-list | js 'd["entries"][0]["id"]' 2>/dev/null)
[[ ! -e "$root/public/docs" && -f "$root/.simai-trash/$tid/item/sub/b.txt" ]] && ok "remove moves a directory into the trash" || bad "remove to trash: $r"
[[ "$(stat -c '%U %a' "$root/.simai-trash")" == "$user 700" ]] && ok "the trash belongs to the site user, mode 700" || bad "trash owner: $(stat -c '%U %a' "$root/.simai-trash")"
[[ "$(stat -c %U "$root/.simai-trash/$tid/item")" == "$user" && -L "$root/.simai-trash/$tid/item/esc" && -d /etc ]] && ok "links go to the trash as links" || bad "trash link"
l=$(fj trash-list)
[[ "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); e=d["entries"]; print(len(e)==1 and e[0]["id"]==sys.argv[2] and e[0]["path"]=="public/docs" and e[0]["type"]=="dir" and e[0]["expires_at"]-e[0]["deleted_at"]==7*86400 and d["schema"]=="simai-file-trash/1")' "$l" "$tid")" == True ]] \
  && ok "trash-list shows the original path, type and 7-day expiry" || bad "trash-list: $l"
cli file remove --domain trash.test --path .simai-trash --confirm yes >/tmp/o 2>&1 && bad "trashed the trash" || ok "the trash cannot be moved into itself"

# Restore: where it was, refused over an existing path, elsewhere with parents.
mkdir -p "$root/public/docs"; chown "$user:" "$root/public/docs"
cli file trash-restore --domain trash.test --id "$tid" --confirm yes >/tmp/o 2>&1 && bad "restored over an existing path" \
  || { grep -q exists /tmp/o && ok "restore refuses an existing target" || bad "restore exists: $(tail -1 /tmp/o)"; }
cli file trash-restore --domain trash.test --id "$tid" >/tmp/o 2>&1 && bad "the plan missed an existing target" || ok "the restore plan already refuses an existing target"
rmdir "$root/public/docs"
cli file trash-restore --domain trash.test --id "$tid" --confirm yes >/dev/null 2>&1 && [[ -f "$root/public/docs/sub/b.txt" && ! -e "$root/.simai-trash/$tid" ]] \
  && ok "restore puts a directory back where it was" || bad "restore"
cli file remove --domain trash.test --path public/docs/a.txt --confirm yes >/dev/null 2>&1
tid2=$(fj trash-list | js 'd["entries"][0]["id"]')
cli file trash-restore --domain trash.test --id "$tid2" --to restored/deep/a.txt --confirm yes >/dev/null 2>&1 \
  && [[ "$(cat "$root/restored/deep/a.txt")" == one && "$(stat -c %U "$root/restored/deep")" == "$user" ]] && ok "restore --to creates missing parents as the site user" || bad "restore --to"
cli file trash-restore --domain trash.test --id "$tid2" --to ../x --confirm yes >/dev/null 2>&1 && bad "restored outside the site" || ok "restore --to cannot leave the site"
cli file trash-restore --domain trash.test --id nope --confirm yes >/dev/null 2>&1 && bad "a bad id was accepted" || ok "a bad trash id is refused"

# Empty, retention, --permanent.
cli file remove --domain trash.test --path restored --confirm yes >/dev/null 2>&1
cli file remove --domain trash.test --path public/docs/sub --confirm yes >/dev/null 2>&1
ids=$(fj trash-list | js '" ".join(e["id"] for e in d["entries"])')
first=${ids%% *}
cli file trash-empty --domain trash.test --id "$first" --confirm yes >/dev/null 2>&1 && [[ ! -e "$root/.simai-trash/$first" && "$(fj trash-list | js 'd["count"]')" == 1 ]] \
  && ok "trash-empty --id deletes one entry" || bad "empty one: $(fj trash-list)"
old=20200101T000000Z-abcdef
runuser -u "$user" -- mkdir -p "$root/.simai-trash/$old/item"
[[ "$(fj trash-list | js 'd["count"]')" == 1 && ! -e "$root/.simai-trash/$old" ]] && ok "entries older than 7 days are dropped" || bad "retention: $(ls "$root/.simai-trash")"
cli file trash-empty --domain trash.test --confirm yes >/dev/null 2>&1 && [[ "$(fj trash-list | js 'd["count"]')" == 0 ]] && ok "trash-empty deletes the whole trash" || bad "empty all"
echo x >"$root/public/gone.txt"; chown "$user:" "$root/public/gone.txt"
cli file remove --domain trash.test --path public/gone.txt --permanent yes --confirm yes >/dev/null 2>&1 \
  && [[ ! -e "$root/public/gone.txt" && "$(fj trash-list | js 'd["count"]')" == 0 ]] && ok "--permanent yes deletes without the trash" || bad "permanent"
mkdir -p "$root/locked"; echo s >"$root/locked/s"; chmod 700 "$root/locked"; chown root:root "$root/locked"
cli file remove --domain trash.test --path locked/s --confirm yes >/tmp/o 2>&1 && bad "trashed a root-only file" \
  || { grep -q permission_denied /tmp/o && [[ -f "$root/locked/s" ]] && ok "the trash runs as the site user, not root" || bad "root-only: $(tail -1 /tmp/o)"; }

# Copy.
cli file copy --domain trash.test --path public/docs --to public/docs-copy --confirm yes >/dev/null 2>&1 \
  && [[ -L "$root/public/docs-copy/esc" &&"$(stat -c %U "$root/public/docs-copy")" == "$user" ]] \
  && ok "copy copies a directory as the site user, links as links" || bad "copy dir: $(ls -la "$root/public/docs-copy" 2>&1)"
echo hello >"$root/public/one.txt"; chown "$user:" "$root/public/one.txt"
cli file copy --domain trash.test --path public/one.txt --to public/two.txt --confirm yes >/dev/null 2>&1 && cmp -s "$root/public/one.txt" "$root/public/two.txt" \
  && ok "copy copies a file" || bad "copy file"
cli file copy --domain trash.test --path public/one.txt --to public/two.txt --confirm yes >/tmp/o 2>&1 && bad "copy overwrote" \
  || { grep -q exists /tmp/o && ok "copy refuses an existing target" || bad "copy exists: $(tail -1 /tmp/o)"; }
cli file copy --domain trash.test --path public/one.txt --to public/two.txt >/dev/null 2>&1 && bad "the copy plan missed an existing target" || ok "the copy plan already refuses an existing target"
cli file copy --domain trash.test --path public/docs --to public/docs/inner --confirm yes >/dev/null 2>&1 && bad "copied a directory into itself" || ok "a directory cannot be copied into itself"
cli file copy --domain trash.test --path public/docs/esc/hostname --to public/h --confirm yes >/dev/null 2>&1 && bad "copied through a link" || ok "copy does not follow a link"
cli file copy --domain trash.test --path ../../../etc/hostname --to public/h --confirm yes >/dev/null 2>&1 && bad "copied from outside" || ok '".." is refused by copy'
if cli file copy --domain trash.test --path public/one.txt --to public/docs/esc/x --confirm yes >/dev/null 2>&1 || [[ -e /etc/x ]]; then
  bad "copied through a link"; rm -f /etc/x
else
  ok "copy cannot write through a link"
fi

# Through the panel gateway.
cli panel gate-enable --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
wait_job() { local s; for _ in {1..60}; do s=$(gate "$(req null job:status "{\"job_id\":\"$1\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done; echo "$s"; }
[[ "$(gate "$(req null file:trash-list '{"domain":"trash.test"}')" | js 'd["data"]["schema"]')" == simai-file-trash/1 ]] && ok "file:trash-list through the gateway" || bad "gate trash-list"
[[ "$(gate "$(req null file:remove '{"domain":"trash.test","path":"public/one.txt"}')" | js 'd["kind"]')" == plan ]] && ok "file:remove answers a plan" || bad "gate remove plan"
[[ "$(gate "$(req null file:remove '{"domain":"trash.test","path":"public/one.txt","permanent":"yes"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "the gateway never removes for good" || bad "gate permanent"
a=$(gate "$(req null file:remove '{"domain":"trash.test","path":"public/one.txt"}' 1)"); s=$(wait_job "$(js 'd["job_id"]' <<<"$a")")
gid=$(gate "$(req null file:trash-list '{"domain":"trash.test"}')" | js '[e["id"] for e in d["data"]["entries"] if e["path"] == "public/one.txt"][0]')
[[ "$s" == succeeded && ! -e "$root/public/one.txt" && -f "$root/.simai-trash/$gid/item" ]] && ok "the file:remove job moves into the trash" || bad "gate remove job: $s $a"
[[ "$(gate "$(req null file:trash-restore "{\"domain\":\"trash.test\",\"id\":\"$gid\"}")" | js 'd["kind"]')" == plan ]] && ok "file:trash-restore answers a plan" || bad "gate restore plan"
a=$(gate "$(req null file:trash-restore "{\"domain\":\"trash.test\",\"id\":\"$gid\"}" 1)"); s=$(wait_job "$(js 'd["job_id"]' <<<"$a")")
[[ "$s" == succeeded && -f "$root/public/one.txt" ]] && ok "the file:trash-restore job restores" || bad "gate restore job: $s"
[[ "$(gate "$(req null file:trash-restore '{"domain":"trash.test","id":"../x"}')" | js 'd["reason"]')" == invalid_argument ]] && ok "a bad trash id is refused by the gateway" || bad "gate bad id"
[[ "$(gate "$(req null file:copy '{"domain":"trash.test","path":"public/one.txt","to":"public/three.txt"}')" | js 'd["kind"]')" == plan ]] && ok "file:copy answers a plan" || bad "gate copy plan"
[[ "$(gate "$(req null file:copy '{"domain":"trash.test","path":"public/one.txt","to":"public/two.txt"}')" | js 'd["status"]')" == failed ]] && ok "a file:copy plan over an existing target fails" || bad "gate copy exists"
[[ "$(gate "$(req null file:copy '{"domain":"trash.test","path":"../etc/passwd","to":"public/p"}')" | js 'd["reason"]')" == invalid_argument ]] && ok '".." is refused by file:copy' || bad "gate copy dotdot"
a=$(gate "$(req null file:copy '{"domain":"trash.test","path":"public/one.txt","to":"public/three.txt"}' 1)"); s=$(wait_job "$(js 'd["job_id"]' <<<"$a")")
[[ "$s" == succeeded ]] && cmp -s "$root/public/one.txt" "$root/public/three.txt" && ok "the file:copy job copies" || bad "gate copy job: $s"
[[ "$(gate "$(req null file:trash-empty '{"domain":"trash.test"}')" | js 'd["kind"]')" == plan ]] && ok "file:trash-empty answers a plan" || bad "gate empty plan"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli site remove --domain trash.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))
