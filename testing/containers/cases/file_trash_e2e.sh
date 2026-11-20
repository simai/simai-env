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
p=$(gate "$(req null file:trash-empty '{"domain":"trash.test"}')")
[[ "$(js 'set(d["data"]["trash"]) == {"items", "bytes", "ids"}' <<<"$p")" == True ]] && ok "the file:trash-empty plan names items and bytes" || bad "gate empty plan data: $p"
echo gated-old >"$root/public/g.txt"; chown "$user:" "$root/public/g.txt"; echo gated-new >/tmp/g-new
a=$(gate "$(req null file:write '{"domain":"trash.test","path":"public/g.txt","content":"gated-new\n","expect-sha256":"any"}' 1)")
j=$(js 'd["job_id"]' <<<"$a"); s=$(wait_job "$j")
r=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")" | js 'd["data"].get("result") or {}')
[[ "$s" == succeeded && "$r" == *previous_trash_id* ]] && ok "a file:write job hands on the previous version's trash id" || bad "gate write job: $s $r $a"

# Overwrites keep the previous version in the trash (1.64.0).
echo old-text >"$root/public/w.txt"; chown "$user:" "$root/public/w.txt"; echo new-text >/tmp/w-new
w=$(fj write --path public/w.txt --content-file /tmp/w-new --expect-sha256 any --confirm yes)
wid=$(js 'd["previous_trash_id"]' <<<"$w")
[[ "$(cat "$root/public/w.txt")" == new-text && "$(cat "$root/.simai-trash/$wid/item" 2>/dev/null)" == old-text ]] \
  && ok "write over a file keeps the previous version in the trash" || bad "write trash: $w"
[[ "$(fj trash-list | js "[e['reason'] for e in d['entries'] if e['id'] == '$wid'][0]")" == overwritten ]] && ok "the entry is marked overwritten" || bad "overwritten reason"
cli file trash-restore --domain trash.test --id "$wid" --to public/w-old.txt --confirm yes >/dev/null 2>&1
[[ "$(cat "$root/public/w-old.txt" 2>/dev/null)" == old-text && "$(cat "$root/public/w.txt")" == new-text ]] && ok "the previous version restores like a removed file" || bad "restore previous"
[[ "$(fj write --path public/fresh.txt --content-file /tmp/w-new --expect-sha256 new --confirm yes | js 'd["previous_trash_id"]')" == None ]] \
  && ok "a new file puts nothing in the trash" || bad "new write trashed"
sum=$(sha256sum /tmp/w-new | cut -d' ' -f1)
u=$(fj upload --path public/w.txt --source /tmp/w-new --sha256 "$sum" --expect-sha256 any --confirm yes)
[[ "$(js 'd["previous_trash_id"] is not None' <<<"$u")" == True ]] && ok "upload over a file keeps the previous version" || bad "upload trash: $u"
mkdir -p /tmp/xa/public && echo from-archive >/tmp/xa/public/w.txt && echo extra >/tmp/xa/public/new.txt
tar -C /tmp/xa -czf "$root/x.tgz" public && chown "$user:" "$root/x.tgz"
before=$(cat "$root/public/w.txt")
e=$(fj extract --path x.tgz --to . --overwrite yes --confirm yes)
eid=$(js 'd["trash_ids"][0]' <<<"$e")
[[ "$(js 'd["trashed"]' <<<"$e")" == 1 && "$(cat "$root/public/w.txt")" == from-archive && "$(cat "$root/.simai-trash/$eid/item")" == "$before" ]] \
  && ok "extract with overwrite keeps each replaced file in the trash" || bad "extract trash: $e"

# Emptying: a dry run counts and deletes nothing.
n=$(fj trash-list | js 'd["count"]'); b=$(fj trash-list | js 'd["total_bytes"]')
d=$(fj trash-empty --dry-run yes --confirm yes)
[[ "$(js 'd["items"]' <<<"$d")" == "$n" && "$(js 'd["bytes"]' <<<"$d")" == "$b" && "$(js 'd["dry_run"]' <<<"$d")" == True && "$(fj trash-list | js 'd["count"]')" == "$n" ]] \
  && ok "trash-empty --dry-run yes gives items and bytes and deletes nothing" || bad "dry run: $d (n=$n b=$b)"
[[ "$(fj trash-empty --id "$eid" --dry-run yes --confirm yes | js 'd["items"]')" == 1 ]] && ok "a dry run of one entry counts one" || bad "dry run one"
e2=$(fj trash-empty --confirm yes)
[[ "$(js 'd["items"]' <<<"$e2")" == "$n" && "$(js 'd["bytes"]' <<<"$e2")" == "$b" && "$(fj trash-list | js 'd["count"]')" == 0 ]] && ok "emptying reports what went" || bad "empty: $e2"

cli panel gate-disable --confirm yes >/dev/null 2>&1

# The last backup before a removal (1.64.0): held 7 days, listed after the
# site is gone, swept once its hold ends.
echo keep-me >"$root/public/last.txt"; chown "$user:" "$root/public/last.txt"
cli site remove --domain trash.test --remove-files yes --confirm yes >/tmp/o 2>&1
lb=$(ls -d /var/backups/simai/trash.test/*/ 2>/dev/null | tail -1); lb="${lb%/}"
[[ -n "$lb" && ! -e "$root" ]] && grep -q '^reason=site-remove$' "$lb/manifest.txt" && grep -q '^keep_until=' "$lb/manifest.txt" \
  && tar -xzOf "$lb/files.tar.gz" 2>/dev/null | grep -q keep-me && ok "site remove with files takes a held last backup first" || bad "last backup: $(tail -3 /tmp/o) $lb"
grep -q 'Last backup' /tmp/o && ok "the remove output names the last backup" || bad "remove output"
l=$(cli backup data-list --domain trash.test --output json 2>/dev/null | js 'd["data"]')
[[ "$(python3 -c 'import ast,sys; d=ast.literal_eval(sys.argv[1]); i=d["items"][0]; print(i["site_exists"] is False and i["reason"]=="site-remove" and bool(i["keep_until"]) and i["backup"] and "files" in i["parts"])' "$l")" == True ]] \
  && ok "backup data-list shows it after the site is gone" || bad "data-list: $l"
# «Вернуть сайт»: the same domain again, then its files live (1.65.0).
cli site add --domain trash.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
echo mine >"$root/public/mine.txt"
cli backup data-restore --domain trash.test --backup "$(basename "$lb")" --files-live yes --confirm yes >/tmp/o 2>&1 && bad "files went live over a site with files" \
  || { grep -q root_not_empty /tmp/o && ok "files-live refuses a site with files (root_not_empty)" || bad "not empty: $(tail -2 /tmp/o)"; }
rm -f "$root/public/mine.txt"
cli backup data-restore --domain trash.test --backup "$(basename "$lb")" --files-live yes >/tmp/o 2>&1 && [[ ! -e "$root/public/last.txt" ]] \
  && ok "the files-live plan passes on an empty site and changes nothing" || bad "live plan: $(tail -3 /tmp/o)"
cli backup data-restore --domain trash.test --backup "$(basename "$lb")" --files-live yes --confirm yes >/tmp/o 2>&1
[[ "$(cat "$root/public/last.txt" 2>/dev/null)" == keep-me && "$(stat -c %U "$root/public/last.txt")" == "$(stat -c %U "$root")" ]] \
  && ok "the removed site's files come back live, owned by the site user" || bad "live restore: $(tail -3 /tmp/o)"
cli site remove --domain trash.test --remove-files yes --last-backup no --confirm yes >/dev/null 2>&1
rm -f /var/lib/simai-env/backup-hold.stamp; cli self status-refresh --confirm yes >/dev/null 2>&1
[[ -d "$lb" ]] && ok "a held backup stays before its hold ends" || bad "swept too early"
sed -i 's/^keep_until=.*/keep_until=2020-01-01T00:00:00Z/' "$lb/manifest.txt"
rm -f /var/lib/simai-env/backup-hold.stamp; cli self status-refresh --confirm yes >/dev/null 2>&1
[[ ! -d "$lb" ]] && ok "a removed site's held backup goes after its hold" || bad "not swept"
cli site add --domain gone.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
groot=$(cli site describe --domain gone.test --output json 2>/dev/null | js 'd["data"]["root"]')
chmod 000 /var/backups/simai 2>/dev/null; chattr +i /var/backups/simai 2>/dev/null
if lsattr -d /var/backups/simai 2>/dev/null | grep -q -- '-i-'; then
  cli site remove --domain gone.test --remove-files yes --confirm yes >/tmp/o 2>&1
  [[ -d "$groot" && -f /etc/nginx/sites-available/gone.test.conf ]] && grep -q backup_failed /tmp/o && ok "a failed last backup stops the removal (backup_failed)" || bad "failed backup removed: $(tail -2 /tmp/o)"
  chattr -i /var/backups/simai
else
  ok "skip: immutable flag unavailable in this container"
fi
chmod 700 /var/backups/simai
cli site remove --domain gone.test --remove-files yes --last-backup no --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))
