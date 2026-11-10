#!/usr/bin/env bash
# bitrix restore-ready from an archive already on the server (1.56.0):
# --source moves the volumes of a path in the site directory into the
# docroot (as the site user), path escapes and links are refused, the JSON
# answer names what was found (volumes, size, SQL dump, encrypted), plans
# carry "resources" (free disk against three times the archive, memory
# against the profile) with the refusals not_enough_disk / not_enough_ram,
# and the panel gateway refuses with the same codes before a job.
set -uo pipefail
rm -rf /root/simai-env-rrsrc
cp -r /src /root/simai-env-rrsrc
cd /root/simai-env-rrsrc || exit 1
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
D=bxsrc.test
D2=bxsmall.test
root=/home/simai/www/$D
doc=$root/public
root2=/home/simai/www/$D2
doc2=$root2/public
prof=/root/simai-env-rrsrc/profiles/bitrix.profile.sh
name=site_20261110_full_abc.tar.gz

cli profile init --mode all --confirm yes >/tmp/rs-profile.out 2>&1 \
  || cli profile enable --id bitrix --confirm yes >>/tmp/rs-profile.out 2>&1 || bad 'enable profiles'
cli site add --domain "$D" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/rs-add.out 2>&1 \
  || { bad 'add Bitrix site'; tail -15 /tmp/rs-add.out; }
owner=$(stat -c %U:%G "$doc")
rm -f "$doc/bitrixsetup.php"
echo '<?php // restore wizard' >"$doc/restore.php"; chown "$owner" "$doc/restore.php"

# A two-volume Bitrix archive: the base volume names the last part in its
# gzip header ("LN"), the dump comes first.
mkvolumes() {
  python3 - "$1" "$2" <<'PY'
import io, os, struct, sys, tarfile, zlib
out, name = sys.argv[1], sys.argv[2]
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w") as t:
    for path, data in (("bitrix/backup/site_20261110.sql", b"CREATE TABLE b_user (ID int);\n" * 50),
                       ("bitrix/x.txt", os.urandom(40000))):
        info = tarfile.TarInfo(path); info.size = len(data); t.addfile(info, io.BytesIO(data))
tar = buf.getvalue(); half = len(tar) // 2
def gz(data, extra=b""):
    head = b"\x1f\x8b\x08" + (b"\x04" if extra else b"\x00") + b"\0\0\0\0\0\x03"
    if extra:
        head += struct.pack("<H", len(extra)) + extra
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    return head + c.compress(data) + c.flush() + struct.pack("<II", zlib.crc32(data) & 0xffffffff, len(data) & 0xffffffff)
open(os.path.join(out, name), "wb").write(gz(tar[:half], b"LN" + struct.pack("<H", 1) + b"\x00"))
open(os.path.join(out, name + ".1"), "wb").write(gz(tar[half:]))
PY
}
up=$root/upload/bx
mkdir -p "$up" && mkvolumes "$up" "$name" && chown -R "$owner" "$root/upload"
gzip -t "$up/$name" && gzip -t "$up/$name.1" && ok 'test volumes are valid gzip' || bad 'test volumes'
total=$(( $(stat -c %s "$up/$name") + $(stat -c %s "$up/$name.1") ))

# 1. Plan: what --source found, resources, nothing moved yet.
p=$(cli bitrix restore-ready --domain "$D" --source upload/bx --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['archive']['base']+'|'+str(d['data']['archive']['count'])+'|'+str(d['data']['archive']['total_bytes'])+'|'+str(d['data']['archive']['encrypted'])" <<<"$p")" == "planned|$name|2|$total|False" ]] \
  && ok 'plan names the volumes found at --source' || bad "plan found: ${p:0:800}"
[[ "$(j "str(d['data']['resources']['ok'])+'|'+str(d['data']['resources']['needed_bytes'])+'|'+str(type(d['data']['resources']['disk_free_bytes']).__name__)+'|'+str(d['data']['resources']['ram_recommended_mb'])" <<<"$p")" == "True|$((total * 3))|int|4096" ]] \
  && ok 'plan resources: needed is three times the archive' || bad "plan resources: ${p:0:800}"
[[ -f "$up/$name" && ! -e "$doc/$name" ]] && ok 'a plan moves nothing' || bad 'plan moved files'
cli bitrix restore-ready --domain "$D" --source upload/bx >/tmp/rs-plan.out 2>&1
grep -q "Archive: $name (2 volume(s)" /tmp/rs-plan.out && ok 'human plan names the archive' || { bad 'human plan'; cat /tmp/rs-plan.out; }

# 2. Paths that leave the site directory or follow links are refused.
mkdir -p "$root/upload/linked" && ln -sf /etc/passwd "$root/upload/linked/$name"
ln -sfn /etc "$root/upload/etc-link"
chown -h "$owner" "$root/upload/linked/$name" "$root/upload/etc-link"
for s in ../bxsmall.test upload/../../x /etc /home/simai/www upload/etc-link upload/linked "upload/linked/$name" upload/missing; do
  r=$(cli bitrix restore-ready --domain "$D" --source "$s" --output json 2>/dev/null)
  [[ "$(j "d['status']+'|'+str(d.get('data',{}).get('refusal'))" <<<"$r")" == 'failed|source_invalid' ]] \
    && ok "source $s refused" || bad "source $s: ${r:0:400}"
done
r=$(cli bitrix restore-ready --domain "$D" --source "upload/etc-link" --confirm yes --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+str(d['data']['refusal'])" <<<"$r")" == 'failed|source_invalid' ]] \
  && ok 'a confirmed run refuses a link too' || bad "confirmed link: ${r:0:400}"

# 3. Confirmed: volumes moved into the docroot, the answer names them.
r=$(cli bitrix restore-ready --domain "$D" --source upload/bx --confirm yes --output json 2>/tmp/rs-run.err)
[[ "$(j "d['status']+'|'+d['data']['status']+'|'+','.join(d['data']['moved'])" <<<"$r")" == "success|ready|$name,$name.1" ]] \
  && ok 'confirmed: both volumes moved, ready' || { bad "confirmed: ${r:0:900}"; tail -20 /tmp/rs-run.err; }
[[ "$(j "str(d['data']['archive']['count'])+'|'+str(d['data']['archive']['total_bytes'])+'|'+str(d['data']['archive']['sql_dump'])+'|'+str(d['data']['archive']['encrypted'])+'|'+d['data']['restore_url']" <<<"$r")" == "2|$total|True|False|http://$D/restore.php" ]] \
  && ok 'answer: volumes, size, SQL dump present, not encrypted' || bad "answer archive: ${r:0:900}"
[[ -f "$doc/$name" && -f "$doc/$name.1" && ! -e "$up/$name" && ! -e "$up/$name.1" ]] \
  && ok 'volumes are in the docroot, not in the upload folder' || bad 'volumes not moved'
[[ "$(stat -c %h "$doc/$name")" == 1 ]] && ok 'moved, not left as a second link' || bad 'hard link left'
[[ "$(cli bitrix status --domain "$D" --output json 2>/dev/null | j "d['data']['step']")" == run_restore ]] \
  && ok 'bitrix status: run_restore' || bad 'status after move'
[[ -f /etc/passwd && "$(stat -c %U /etc/passwd)" == root ]] && ok '/etc/passwd untouched' || bad '/etc/passwd moved'
cli bitrix restore-ready --domain "$D" --confirm yes >/tmp/rs-human.out 2>&1
grep -q "Volumes.*$name, $name.1" /tmp/rs-human.out && grep -q 'SQL dump.*yes' /tmp/rs-human.out \
  && ok 'human answer lists volumes and the SQL dump' || { bad 'human answer'; cat /tmp/rs-human.out; }
# Moving again onto existing names is refused, nothing is replaced.
mkdir -p "$root/upload/again" && mkvolumes "$root/upload/again" "$name" && chown -R "$owner" "$root/upload/again"
r=$(cli bitrix restore-ready --domain "$D" --source upload/again --confirm yes --output json 2>/dev/null)
[[ "$(j "d['status']" <<<"$r")" == failed && -f "$root/upload/again/$name" ]] \
  && ok 'existing volumes in the docroot are not replaced' || bad "again: ${r:0:500}"
rm -rf "$root/upload/again"
mkdir -p "$root/upload/enc"
python3 -c 'import gzip,os,sys; open(sys.argv[1],"wb").write(gzip.compress(os.urandom(4096)))' "$root/upload/enc/site_20261110_full_enc.enc.gz"
chown -R "$owner" "$root/upload/enc"
p=$(cli bitrix restore-ready --domain "$D" --source upload/enc/site_20261110_full_enc.enc.gz --output json 2>/dev/null)
[[ "$(j "d['data']['archive']['base']+'|'+str(d['data']['archive']['encrypted'])" <<<"$p")" == 'site_20261110_full_enc.enc.gz|True' ]] \
  && ok 'an .enc.gz volume is found and named encrypted' || bad "enc: ${p:0:500}"
rm -rf "$root/upload/enc"

# 4. Memory against the profile: below the recommendation warns, below the minimum refuses.
cp "$prof" /tmp/rs-profile.bak
sed -i 's/^PROFILE_RECOMMENDED_RAM_MB=.*/PROFILE_RECOMMENDED_RAM_MB="9999999"/' "$prof"
p=$(cli bitrix restore-ready --domain "$D" --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+','.join(w['code'] for w in d['data']['resources']['warnings'])" <<<"$p")" == 'planned|ram_below_recommended' ]] \
  && ok 'RAM below the recommendation: a warning in the plan' || bad "ram warning: ${p:0:600}"
cli bitrix restore-ready --domain "$D" >/tmp/rs-warn.out 2>&1
grep -q 'recommends 9999999 MB' /tmp/rs-warn.out && ok 'human plan prints the RAM warning' || bad 'human RAM warning'
p=$(cli site add --domain new.test --profile bitrix --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+','.join(w['code'] for w in d['data']['resources']['warnings'])+'|'+str(d['data']['resources']['ok'])" <<<"$p")" == 'planned|ram_below_recommended|True' ]] \
  && ok 'site add plan: RAM warning, still ok' || bad "site add warning: ${p:0:600}"
sed -i 's/^PROFILE_MIN_RAM_MB=.*/PROFILE_MIN_RAM_MB="9999998"/' "$prof"
p=$(cli site add --domain new.test --profile bitrix --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['refusal']+'|'+str(d['data']['resources']['ok'])" <<<"$p")" == 'failed|not_enough_ram|False' ]] \
  && ok 'site add plan refuses not_enough_ram' || bad "site add ram: ${p:0:600}"
cli site add --domain new.test --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/rs-add-ram.out 2>&1 \
  && bad 'site add ran below the minimum' || { grep -q 'Not enough memory' /tmp/rs-add-ram.out && ok 'site add refuses below the minimum' || bad "site add ram msg: $(tail -3 /tmp/rs-add-ram.out)"; }
[[ ! -e /etc/nginx/sites-available/new.test.conf ]] && ok 'no site created' || bad 'site created below minimum'
p=$(cli bitrix restore-ready --domain "$D" --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['refusal']" <<<"$p")" == 'failed|not_enough_ram' ]] \
  && ok 'restore-ready plan refuses not_enough_ram' || bad "restore ram: ${p:0:600}"
p=$(cli site add --domain new.test --profile static --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+str(d['data']['resources']['ram_min_mb'])" <<<"$p")" == 'planned|0' ]] \
  && ok 'a static site has no memory need' || bad "static: ${p:0:400}"

# 5. Panel gateway.
cli panel gate-enable --confirm yes >/tmp/rs-gate.out 2>&1 || { bad 'gate-enable'; tail -5 /tmp/rs-gate.out; }
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }
a=$(gate "$(req site:add '{"domain":"new.test","profile":"bitrix"}')")
[[ "$(j "d['status']+':'+d['reason']+':'+str(d['data']['resources']['ram_min_mb'])" <<<"$a")" == refused:not_enough_ram:9999998 ]] \
  && ok 'gateway refuses site:add not_enough_ram, with resources' || bad "gateway ram: ${a:0:500}"
a=$(gate "$(req site:add '{"domain":"new.test","profile":"bitrix"}' ',"confirm":true')")
[[ "$(j "d['status']+':'+d['reason']+':'+str(d.get('job_id'))" <<<"$a")" == refused:not_enough_ram:None ]] \
  && ok 'gateway refuses before a job' || bad "gateway ram job: ${a:0:500}"
cp /tmp/rs-profile.bak "$prof"
a=$(gate "$(req site:add '{"domain":"new.test","profile":"bitrix"}')")
[[ "$(j "d['kind']+'|'+str(d['data']['resources']['ok'])+'|'+str(d['data']['resources']['ram_recommended_mb'])" <<<"$a")" == 'plan|True|4096' ]] \
  && ok 'gateway site:add plan carries resources' || bad "gateway site add plan: ${a:0:500}"
mkdir -p "$root/upload/bx2" && mkvolumes "$root/upload/bx2" "other_20261110_full_def.tar.gz" && chown -R "$owner" "$root/upload/bx2"
a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D\",\"source\":\"upload/bx2\"}")")
[[ "$(j "d['kind']+'|'+d['data']['archive']['base']+'|'+str(d['data']['archive']['count'])+'|'+str(d['data']['resources']['ok'])" <<<"$a")" == 'plan|other_20261110_full_def.tar.gz|2|True' ]] \
  && ok 'gateway restore-ready plan: archive found and resources' || bad "gateway plan: ${a:0:600}"
for bad_args in '"source":"../x"' '"source":"/etc"' '"url":"http://example.com/a.tar.gz"' '"url":"https://example.com/a.zip"' \
                '"source":"upload/bx2","url":"https://example.com/a.tar.gz"'; do
  a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D\",$bad_args}")")
  [[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:invalid_argument ]] && ok "gateway refuses {$bad_args}" || bad "gateway $bad_args: ${a:0:300}"
done
a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D\",\"source\":\"upload/etc-link\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:source_invalid ]] && ok 'gateway refuses a linked source' || bad "gateway link: ${a:0:300}"
a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D\",\"url\":\"https://127.0.0.1/x/site.tar.gz?sig=SECRET\"}")")
[[ "$(j "d['status']+':'+d['reason']" <<<"$a")" == refused:url_invalid ]] && ok 'gateway refuses a URL to this server' || bad "gateway url: ${a:0:300}"
[[ "$a" != *SECRET* ]] && ok 'the signature is not in the answer' || bad 'signature shown'
r=$(cli bitrix restore-ready --domain "$D" --url "https://localhost/a.tar.gz" --output json 2>/dev/null)
[[ "$(j "d['data']['refusal']" <<<"$r")" == url_invalid ]] && ok 'CLI refuses a URL to localhost' || bad "cli url: ${r:0:300}"
r=$(cli bitrix restore-ready --domain "$D" --url "https://localhost/a.tar.gz?sig=SECRET2" --confirm yes --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['refusal']" <<<"$r")" == 'failed|url_invalid' && "$r" != *SECRET2* ]] \
  && ok 'confirmed CLI run refuses the URL, no signature in the answer' || bad "cli url run: ${r:0:400}"
grep -q 'SECRET2' /var/log/simai-audit.log /var/log/simai-admin.log 2>/dev/null && bad 'signature in the logs' || ok 'signature not in the logs'
grep -q 'url=https://localhost/a.tar.gz?\*\*\*\|--url https://localhost/a.tar.gz?\*\*\*' /var/log/simai-audit.log && ok 'audit log keeps the URL without its query' || bad "audit url: $(grep -o 'restore-ready.\{0,200\}' /var/log/simai-audit.log | tail -1)"

# 6. Free disk: a docroot on a small filesystem refuses three times the archive.
cli site add --domain "$D2" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/rs-add2.out 2>&1 \
  || { bad 'add second site'; tail -15 /tmp/rs-add2.out; }
owner2=$(stat -c %U:%G "$doc2")
mount -t tmpfs -o size=6m,mode=0755 tmpfs "$doc2" && chown "$owner2" "$doc2" || bad 'mount tmpfs'
echo '<?php // restore wizard' >"$doc2/restore.php"; chown "$owner2" "$doc2/restore.php"
mkdir -p "$root2/upload"
python3 -c 'import gzip,os,sys; open(sys.argv[1],"wb").write(gzip.compress(os.urandom(3 << 20), 1))' "$root2/upload/big_20261110_full_x.tar.gz"
chown -R "$owner2" "$root2/upload"
p=$(cli bitrix restore-ready --domain "$D2" --source upload --output json 2>/dev/null)
[[ "$(j "d['status']+'|'+d['data']['refusal']+'|'+str(d['data']['resources']['disk_free_bytes'] < d['data']['resources']['needed_bytes'])" <<<"$p")" == 'failed|not_enough_disk|True' ]] \
  && ok 'plan refuses not_enough_disk on a small filesystem' || bad "disk plan: ${p:0:600}"
r=$(cli bitrix restore-ready --domain "$D2" --source upload --confirm yes --output json 2>/tmp/rs-disk.err)
[[ "$(j "d['status']+'|'+d['data']['refusal']" <<<"$r")" == 'failed|not_enough_disk' && -f "$root2/upload/big_20261110_full_x.tar.gz" ]] \
  && ok 'confirmed run refuses before moving anything' || bad "disk run: ${r:0:600}"
[[ "$(j "d['data']['detail']" <<<"$r")" == 'Not enough free disk:'* ]] && ok 'the refusal says why' || bad "disk message: ${r:0:600}"
cli bitrix restore-ready --domain "$D2" --source upload --confirm yes >/tmp/rs-disk.out 2>&1 \
  && bad 'human run passed the disk check' || { grep -q 'Not enough free disk' /tmp/rs-disk.out && ok 'human run prints the disk refusal' || bad "human disk: $(tail -5 /tmp/rs-disk.out)"; }
a=$(gate "$(req bitrix:restore-ready "{\"domain\":\"$D2\",\"source\":\"upload\"}" ',"confirm":true')")
[[ "$(j "d['status']+':'+d['reason']+':'+str(d['data']['resources']['ok'])+':'+str(d.get('job_id'))" <<<"$a")" == refused:not_enough_disk:False:None ]] \
  && ok 'gateway refuses not_enough_disk before a job' || bad "gateway disk: ${a:0:600}"
umount "$doc2" 2>/dev/null || true

cli site remove --domain "$D2" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
cli site remove --domain "$D" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
echo "failures=$fails"; exit "$fails"
