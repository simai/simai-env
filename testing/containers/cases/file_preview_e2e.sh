#!/usr/bin/env bash
# Files for the panel (1.61.0): file preview (an image whole, the start of a
# text file, binaries refused, the 5 MiB cap), the trash keeps 7 days and an
# expired entry goes with the hourly status refresh, without anyone opening
# the trash; a database browser plan names its refusal (no_https).
set -uo pipefail
rm -rf /root/simai-env-fp
cp -r /src /root/simai-env-fp
cd /root/simai-env-fp || exit 1
chmod 700 /root
chmod +x ./*.sh
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
id simai >/dev/null 2>&1 || useradd -m simai
j() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {}, {"d": d}))' "$1"; }
cli profile enable --id generic --confirm yes >/dev/null 2>&1
D=fp.test
cli site add --domain $D --profile generic --php 8.3 --create-db yes --confirm yes >/tmp/fp-add 2>&1 || { bad 'site add'; tail -5 /tmp/fp-add; }
root=/home/simai/www/$D; own=$(stat -c %U:%G $root)
python3 -c 'import base64,sys; open(sys.argv[1],"wb").write(base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="))' $root/dot.png
python3 -c 'import sys; open(sys.argv[1],"w").write("строка текста\n" * 20000)' $root/big.txt
head -c 3000 /dev/urandom >$root/blob.bin
chown $own $root/dot.png $root/big.txt $root/blob.bin
cli panel gate-enable --confirm yes >/dev/null 2>&1 || bad 'gate-enable'
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":null},"command":"%s","args":%s%s}' "$1" "$2" "${3:-}"; }

# Preview.
p=$(gate "$(req file:preview "{\"domain\":\"$D\",\"path\":\"dot.png\"}")")
[[ "$(j "(d['data']['kind'], d['data']['mime'], d['data']['encoding'])" <<<"$p")" == "('image', 'image/png', 'base64')" \
  && "$(j "d['data']['sha256']" <<<"$p")" == "$(sha256sum $root/dot.png | cut -d' ' -f1)" ]] && ok 'image preview with sha256' || bad "image: $(head -c 300 <<<"$p")"
t=$(gate "$(req file:preview "{\"domain\":\"$D\",\"path\":\"big.txt\",\"max-bytes\":\"1000\"}")")
[[ "$(j "(d['data']['kind'], d['data']['truncated'], d['data']['bytes'] <= 1000, d['data']['size'] > 100000)" <<<"$t")" == "('text', True, True, True)" \
  && "$(j "d['data']['content'][:6]" <<<"$t")" == строка ]] && ok 'text preview: the start, cut on a character' || bad "text: $(head -c 300 <<<"$t")"
[[ "$(gate "$(req file:preview "{\"domain\":\"$D\",\"path\":\"blob.bin\"}")" | j "d['status']")" != ok ]] && ok 'a binary is not previewed' || bad 'binary previewed'
[[ "$(gate "$(req file:preview "{\"domain\":\"$D\",\"path\":\"big.txt\",\"max-bytes\":\"9999999\"}")" | j "d['status']")" != ok ]] && ok 'over 5 MiB refused' || bad 'cap'
[[ "$(gate "$(req file:preview "{\"domain\":\"$D\",\"path\":\"../../etc/passwd\"}")" | j "d['status']")" == refused ]] && ok 'no path out of the site' || bad 'path escape'
cli file preview --domain $D --path big.txt --max-bytes 200 >/tmp/fp-cli 2>&1 && grep -q '(truncated)' /tmp/fp-cli && ok 'CLI preview summary' || bad "cli: $(tail -3 /tmp/fp-cli)"

# Trash: 7 days, pruned by the status refresh.
cli file remove --domain $D --path blob.bin --confirm yes >/dev/null 2>&1 || bad 'remove'
l=$(cli file trash-list --domain $D --output json 2>/dev/null)
[[ "$(j "(d['data'] if 'data' in d else d)['retention_days']" <<<"$l")" == 7 ]] && ok 'the trash keeps 7 days' || bad "retention: $l"
tid=$(j "(d['data'] if 'data' in d else d)['entries'][0]['id']" <<<"$l")
old="20200101T000000Z-${tid##*-}"
mv "$root/.simai-trash/$tid" "$root/.simai-trash/$old"
rm -f /var/lib/simai-env/trash-prune.stamp
SIMAI_ADMIN_MENU=0 timeout 300 bash ./simai-admin.sh self status-refresh --confirm yes >/dev/null 2>&1
[[ ! -e "$root/.simai-trash/$old" ]] && ok 'status refresh removes an expired entry' || bad 'expired entry left'
[[ -f /var/lib/simai-env/trash-prune.stamp ]] && ok 'prune stamp written (hourly)' || bad 'stamp'

# A database browser plan names its refusal.
r=$(gate "$(req site:db-browser "{\"domain\":\"$D\"}")")
[[ "$(j "d['status']+'/'+d['reason']" <<<"$r")" == refused/no_https && "$(j "len(d['data']['checks']['blockers'])" <<<"$r")" -ge 1 ]] \
  && ok 'db browser refusal: no_https' || bad "reason: $(head -c 300 <<<"$r")"
r=$(gate "$(req site:db-browser "{\"domain\":\"$D\"}" ',"confirm":true')")
[[ "$(j "d['status']+'/'+d['reason']" <<<"$r")" == refused/no_https ]] && ok 'confirmed: refused before a job starts' || bad "confirm: $(head -c 300 <<<"$r")"

cli site remove --domain $D --remove-files yes --drop-db yes --drop-db-user yes --confirm yes >/dev/null 2>&1
echo "failures=$fails"; exit "$fails"
