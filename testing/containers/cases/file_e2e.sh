#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# File manager: list, read, write with a change check, mkdir, rename, remove
# inside the site directory as the site user; links and ".." never lead
# outside; downloads through the panel gateway; owners only on their sites.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }
f() { cli file "$1" --domain files.test "${@:2}" --output json 2>/dev/null | python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps(r.get("data", {"status": r.get("status")})))'; }
native=$(bash -c 'source lib/platform.sh; platform_detect_os; platform_native_php_version')

cli site add --domain files.test --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain files.test --output json 2>/dev/null | js 'd["data"]["root"]')
user=$(stat -c %U "$root")
[[ "$(f list | js 'd["schema"]')" == simai-files/1 ]] && ok "file list answers simai-files/1" || bad "list: $(f list)"

cli file mkdir --domain files.test --path docs --confirm yes >/dev/null 2>&1 && [[ -d "$root/docs" && "$(stat -c %U "$root/docs")" == "$user" ]] \
  && ok "mkdir creates the directory as the site user ($user)" || bad "mkdir: $(stat -c %U "$root/docs" 2>&1)"
printf 'line one\nline two\n' >/tmp/c1
cli file write --domain files.test --path docs/a.txt --content-file /tmp/c1 --expect-sha256 new --confirm yes >/dev/null 2>&1 \
  && cmp -s /tmp/c1 "$root/docs/a.txt" && ok "write creates a file" || bad "write new"
r=$(f read --path docs/a.txt); sha=$(js 'd["sha256"]' <<<"$r")
[[ "$(js 'd["content"] == "line one\nline two\n"' <<<"$r")" == True ]] && ok "read returns the content" || bad "read: $r"
cli file write --domain files.test --path docs/a.txt --content-file /tmp/c1 --expect-sha256 new --confirm yes >/tmp/o 2>&1 \
  && bad "new overwrote a file" || ok "expect new refuses an existing file"
printf 'changed\n' >/tmp/c2
cli file write --domain files.test --path docs/a.txt --content-file /tmp/c2 --expect-sha256 "$(printf '0%.0s' {1..64})" --confirm yes >/tmp/o 2>&1 \
  && bad "wrote over a changed file" || { grep -q changed /tmp/o && ok "a stale sha256 is refused as changed" || bad "stale: $(tail -2 /tmp/o)"; }
cli file write --domain files.test --path docs/a.txt --content-file /tmp/c2 --expect-sha256 "$sha" --confirm yes >/dev/null 2>&1 \
  && cmp -s /tmp/c2 "$root/docs/a.txt" && ok "the current sha256 writes" || bad "write with sha"
cli file write --domain files.test --path docs/a.txt --content-file /tmp/c1 >/dev/null 2>&1; cmp -s /tmp/c2 "$root/docs/a.txt" && ok "without confirm nothing is written" || bad "write without confirm"

# Nothing outside the site directory: links, "..", files the site user cannot read.
ln -sfn /etc "$root/esc"; ln -sfn /etc/hostname "$root/host-link"
[[ "$(f stat --path esc | js 'd["type"]')" == link ]] && ok "a link is shown as a link" || bad "stat link"
cli file read --domain files.test --path esc/hostname >/dev/null 2>&1 && bad "read through a directory link" || ok "a directory link is not followed"
cli file read --domain files.test --path host-link >/dev/null 2>&1 && bad "read through a file link" || ok "a file link is not followed"
cli file list --domain files.test --path ../ >/dev/null 2>&1 && bad "listed outside" || ok '".." is refused'
echo secret >"$root/root-only"; chmod 600 "$root/root-only"; chown root:root "$root/root-only"
cli file read --domain files.test --path root-only >/tmp/o 2>&1 && bad "read a root-only file" || { grep -q permission_denied /tmp/o && ok "runs as the site user, not root" || bad "root-only: $(tail -1 /tmp/o)"; }
rm -f "$root/root-only"
head -c 3000 /dev/urandom >"$root/bin.dat"; chown "$user" "$root/bin.dat"
cli file read --domain files.test --path bin.dat >/tmp/o 2>&1 && bad "read a binary file as text" || ok "a binary file is not shown as text"

cli file rename --domain files.test --path docs --to docs2 --confirm yes >/dev/null 2>&1 && [[ -f "$root/docs2/a.txt" ]] && ok "rename moves a directory" || bad "rename"
cli file rename --domain files.test --path docs2 --to docs2/inner --confirm yes >/dev/null 2>&1 && bad "moved a directory into itself" || ok "a directory cannot move into itself"
cli file remove --domain files.test --path docs2 --confirm yes >/dev/null 2>&1 && [[ ! -e "$root/docs2" ]] && ok "remove deletes a directory with its files" || bad "remove dir"
cli file remove --domain files.test --path esc --confirm yes >/dev/null 2>&1 && [[ ! -e "$root/esc" && -d /etc ]] && ok "removing a link keeps its target" || bad "remove link"
cli file remove --domain files.test --path "" --confirm yes >/dev/null 2>&1 && bad "removed the site directory" || ok "the site directory cannot be removed"

# Through the panel gateway: owners on their own sites only, downloads as bytes.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
cli site add --domain acme-files.test --owner acme --profile generic --php "$native" --create-db no --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
[[ "$(gate "$(req null file:list '{"domain":"files.test"}')" | js 'd["data"]["schema"]')" == simai-files/1 ]] && ok "file:list through the gateway" || bad "gate list"
[[ "$(gate "$(req '"acme"' file:list '{"domain":"files.test"}')" | js 'd["reason"]')" == owner_scope ]] && ok "an owner cannot open another site's files" || bad "owner scope"
[[ "$(gate "$(req '"acme"' file:list '{"domain":"acme-files.test"}')" | js 'd["status"]')" == ok ]] && ok "an owner lists their own site" || bad "owner own list"
[[ "$(gate "$(req null file:read '{"domain":"files.test","path":"../etc/passwd"}')" | js 'd["reason"]')" == invalid_argument ]] && ok '".." is refused by the gateway' || bad "gate dotdot"
gate "$(req null file:download '{"domain":"files.test","path":"bin.dat"}')" >/tmp/dl
python3 - "$root/bin.dat" <<'PY' && ok "file:download sends the answer line and the exact bytes" || bad "download"
import json, sys
raw = open("/tmp/dl", "rb").read()
head, _, body = raw.partition(b"\n")
h = json.loads(head)
sys.exit(0 if h["kind"] == "download" and h["data"]["size"] == len(body) and body == open(sys.argv[1], "rb").read() else 1)
PY
[[ "$(gate "$(req null file:download '{"domain":"files.test","path":"host-link"}')" | head -1 | js 'd["reason"]')" == not_a_file ]] && ok "a link is not downloaded" || bad "download link"
[[ "$(gate "$(req null file:download '{"domain":"files.test","path":"nope"}')" | head -1 | js 'd["reason"]')" == not_found ]] && ok "a missing file is not_found" || bad "download missing"
[[ "$(gate "$(req null file:remove '{"domain":"files.test","path":"bin.dat"}')" | js 'd["kind"]')" == plan ]] && ok "file:remove answers a plan" || bad "remove plan"
a=$(gate "$(req '"acme"' file:write '{"domain":"acme-files.test","path":"note.txt","content":"hello\nworld","expect-sha256":"new"}' 1)"); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..60}; do s=$(gate "$(req '"acme"' job:status "{\"job_id\":\"$j\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done
aroot=$(cli site describe --domain acme-files.test --output json 2>/dev/null | js 'd["data"]["root"]')
[[ "$s" == succeeded && "$(cat "$aroot/note.txt")" == $'hello\nworld' && "$(stat -c %U "$aroot/note.txt")" == acme ]] && ok "file:write job writes exactly the content as the owner" || bad "write job: $s"
jd=/var/lib/simai-env/panel-jobs/$j
grep -q '"content": "(11 bytes)"' "$jd/job.json" && [[ ! -e "$jd/content.txt" ]] && ok "the job keeps the content size only" || bad "job record: $(cat "$jd/job.json" 2>/dev/null | head -c 300)"

# Uploads, archives and extraction.
head -c 2500000 /dev/urandom >/tmp/up.bin; usum=$(sha256sum /tmp/up.bin | cut -d' ' -f1)
python3 - "$usum" <<'PY' >/tmp/upreq
import json, sys
req = {"schema": "simai-panel-request/1", "request_id": "r1", "actor": {"user": "admin@x", "owner": None},
       "command": "file:upload", "args": {"domain": "files.test", "path": "up.bin"}, "confirm": True,
       "attachment": {"sha256": sys.argv[1], "size": 2500000}}
sys.stdout.write(json.dumps(req) + "\n")
PY
cat /tmp/up.bin >>/tmp/upreq
a=$(sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate </tmp/upreq); j=$(js 'd["job_id"]' <<<"$a")
for _ in {1..60}; do s=$(gate "$(req null job:status "{\"job_id\":\"$j\"}")" | js 'd["data"]["state"]'); [[ "$s" != running ]] && break; sleep 1; done
[[ "$s" == succeeded ]] && cmp -s /tmp/up.bin "$root/up.bin" && [[ "$(stat -c %U "$root/up.bin")" == "$user" ]] && ok "file:upload puts the exact bytes as the site user" || bad "upload job: $s $a"
[[ ! -e "/var/lib/simai-env/panel-jobs/$j/upload.bin" ]] && ok "the uploaded copy leaves the job directory" || bad "upload copy kept"
cli file upload --domain files.test --path up.bin --source /tmp/up.bin --sha256 "$usum" --confirm yes >/dev/null 2>&1 && bad "an upload replaced a file by default" || ok "an upload does not replace a file unless asked"
cli file upload --domain files.test --path up2.bin --source /tmp/up.bin --sha256 "$(printf '0%.0s' {1..64})" --confirm yes >/dev/null 2>&1 && bad "a wrong sha256 uploaded" || ok "an upload with a wrong sha256 is refused"
mkdir -p "$root/pack/sub"; echo a >"$root/pack/a.txt"; echo b >"$root/pack/sub/b.txt"; ln -sfn /etc "$root/pack/esc"; chown -R "$user" "$root/pack"
for ext in zip tar.gz; do
  cli file archive --domain files.test --path pack --to "pack.${ext}" --confirm yes >/dev/null 2>&1 && [[ -s "$root/pack.${ext}" ]] && ok "archive packs into .${ext}" || bad "archive ${ext}"
  cli file extract --domain files.test --path "pack.${ext}" --to "out-${ext}" --confirm yes >/tmp/o 2>&1 && cmp -s "$root/pack/sub/b.txt" "$root/out-${ext}/pack/sub/b.txt" \
    && [[ ! -e "$root/out-${ext}/pack/esc" ]] && ok "extract unpacks .${ext} without its links" || { bad "extract ${ext}"; tail -2 /tmp/o; }
  cli file extract --domain files.test --path "pack.${ext}" --to "out-${ext}" --confirm yes >/dev/null 2>&1 && bad "extract overwrote by default" || ok "extract does not overwrite unless asked"
done
cli file archive --domain files.test --path pack --to pack/inner.zip --confirm yes >/dev/null 2>&1 && bad "packed an archive into itself" || ok "an archive cannot go inside what it packs"
python3 - "$root/evil.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    i = tarfile.TarInfo("../escaped.txt"); i.size = 1; t.addfile(i, io.BytesIO(b"x"))
PY
chown "$user" "$root/evil.tgz"
cli file extract --domain files.test --path evil.tgz --to out-evil --confirm yes >/tmp/o 2>&1 && bad "extracted an entry with .." \
  || { grep -q bad_archive /tmp/o && [[ ! -e "$(dirname "$root")/escaped.txt" ]] && ok "an entry leading outside is refused" || bad "evil: $(tail -1 /tmp/o)"; }
[[ "$(gate "$(req null file:extract '{"domain":"files.test","path":"pack.zip","to":"out-g"}')" | js 'd["kind"]')" == plan ]] && ok "file:extract answers a plan" || bad "extract plan"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli site remove --domain acme-files.test --remove-files yes --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain files.test --remove-files yes --confirm yes >/dev/null 2>&1
echo "failures=${fails}"
exit $(( fails > 0 ))
