#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose cd checks are fine here
# Off-site backup storages (S3) against a real S3 server (rclone serve s3): keys are
# checked before they are saved and never shown; every data backup is uploaded
# to the default storage, which keeps the newest N; a failed upload keeps the
# local backup and opens an alert; a copy is fetched back on a "new server"
# (local backups gone) and restored; through the panel gateway, admin only,
# with the keys never kept in the job record.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
rm -rf /root/simai-env && cp -r /src /root/simai-env && chmod +x /root/simai-env/*.sh
cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails+1)); }
cli() { ./simai-admin.sh "$@"; }
js() { python3 -c 'import json,sys; d=json.load(sys.stdin); print(eval(sys.argv[1], {"d": d}))' "$1"; }

# S3 server: rclone's own S3 server (official build), the client is the
# distribution's rclone that simai-env installs.
arch=$(dpkg --print-architecture)
curl -fsSL --retry 3 -o /tmp/rclone.zip "https://downloads.rclone.org/v1.71.2/rclone-v1.71.2-linux-${arch}.zip" \
  && python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); n=[m for m in z.namelist() if m.endswith("/rclone")][0]; open("/usr/local/bin/s3-server","wb").write(z.read(n))' /tmp/rclone.zip \
  && chmod +x /usr/local/bin/s3-server || { echo "FAIL cannot download the S3 server"; exit 1; }
AK=simaitestaccess; SK=simaitestsecret0123456789
mkdir -p /srv/s3/backups
s3_up() {
  nohup s3-server serve s3 /srv/s3 --addr 127.0.0.1:9000 --auth-key "$AK,$SK" >>/var/log/s3-server.log 2>&1 &
  for _ in {1..40}; do [[ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/)" != 000 ]] && break; sleep 0.5; done
}
s3_up
apt-get install -y -qq rclone >/dev/null 2>&1
s3() { RCLONE_CONFIG=/dev/null RCLONE_CONFIG_M_TYPE=s3 RCLONE_CONFIG_M_PROVIDER=Other RCLONE_CONFIG_M_ACCESS_KEY_ID=$AK \
  RCLONE_CONFIG_M_SECRET_ACCESS_KEY=$SK RCLONE_CONFIG_M_ENDPOINT=http://127.0.0.1:9000 rclone "$@" 2>/dev/null; }
s3 lsf m:backups >/dev/null && ok "S3 server with a bucket" || { bad "s3 server: $(tail -3 /var/log/s3-server.log)"; exit 1; }
printf '%s\n' "$AK" >/root/ak; printf '%s\n' "$SK" >/root/sk; printf 'wrongsecret0123456789\n' >/root/bad
chmod 600 /root/ak /root/sk /root/bad

D=s3.test
cli site add --domain "$D" --profile static --confirm yes >/dev/null 2>&1
root=$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["root"]')
echo "first" >"$root/public/index.html"

add() { cli backup storage-add --name main --bucket backups --endpoint http://127.0.0.1:9000 --region us-east-1 \
  --prefix web1 --keep 2 --access-key-file /root/ak "$@"; }
add --secret-key-file /root/sk >/tmp/o 2>&1
[[ ! -e /etc/simai-env/backup-storages/main.env ]] && grep -q 'Plan:' /tmp/o && ok "without confirm only a plan" || { bad "plan"; cat /tmp/o; }
add --secret-key-file /root/bad --confirm yes >/tmp/o 2>&1 && bad "wrong keys accepted" \
  || { [[ ! -e /etc/simai-env/backup-storages/main.env ]] && grep -q 'nothing saved' /tmp/o && ok "wrong keys are refused and nothing is saved" || { bad "bad keys"; cat /tmp/o; }; }
add --secret-key-file /root/sk --confirm yes >/tmp/o 2>&1 && ok "storage added after a write check" || { bad "add"; cat /tmp/o; }
[[ "$(stat -c '%a %U' /etc/simai-env/backup-storages/main.env)" == "600 root" ]] && ok "storage keys are root-only" || bad "perms $(stat -c '%a %U' /etc/simai-env/backup-storages/main.env)"
l=$(cli backup storage-list --output json 2>/dev/null)
[[ "$(js '[(s["name"], s["default"], s["keep"], s["last_test"]["ok"]) for s in d["data"]["storages"]]' <<<"$l")" == "[('main', True, 2, True)]" ]] \
  && ok "storage-list shows the default storage and its check" || bad "list: $l"
grep -q "$SK" <<<"$l" && bad "storage-list shows the secret" || ok "storage-list never shows the secret"
s3 lsf m:backups/web1/.simai-probe | grep -q . && bad "the check left an object" || ok "the check cleans up after itself"

# Every backup goes to the default storage; it keeps the newest 2.
for n in 1 2 3; do
  echo "v$n" >"$root/public/index.html"
  cli backup data --domain "$D" --keep 5 --confirm yes >/tmp/b 2>&1 || bad "backup $n: $(tail -3 /tmp/b)"
  sleep 1
done
grep -q 'uploaded to main' /tmp/b && ok "backup data reports the upload" || bad "report: $(tail -12 /tmp/b)"
remote=$(s3 lsf --dirs-only "m:backups/web1/$D" | sed 's#/$##')
local_copies() { find "/var/backups/simai/$D" -mindepth 1 -maxdepth 1 -type d -name '2*' -printf '%f\n' | sort; }
newest=$(local_copies | tail -1)
[[ "$(wc -l <<<"$remote")" == 2 && "$(tail -1 <<<"$remote")" == "$newest" ]] && ok "the storage keeps the newest 2 copies" || bad "remote: $remote / $newest"
[[ "$(local_copies | wc -l)" == 3 ]] && ok "local retention is separate" || bad "local count"
s3 lsf "m:backups/web1/$D/$newest" | grep -q SHA256SUMS && ok "the copy has its checksums" || bad "no SHA256SUMS remote"
c=$(cli backup storage-copies --name main --output json 2>/dev/null)
[[ "$(js '[x["backup"] for x in d["data"]["copies"] if x["domain"] == "'"$D"'"][0]' <<<"$c")" == "$newest" ]] && ok "storage-copies lists the copies, newest first" || bad "copies: $c"
o=$(cli site describe --domain "$D" --output json 2>/dev/null | js 'd["data"]["last_offsite"]')
[[ "$o" == *"'ok': True"*"'storage': 'main'"*"'backup': '$newest'"* ]] && ok "site describe has last_offsite" || bad "last_offsite: $o"
cli backup data --domain "$D" --storage none --confirm yes >/tmp/b 2>&1 && grep -q 'not configured' /tmp/b && ok "--storage none skips the upload" || bad "storage none"
sleep 1

# A failed upload keeps the local backup and opens an alert.
pkill -f 's3-server serve'; sleep 1
cli backup data --domain "$D" --confirm yes >/tmp/b 2>&1 && ok "the local backup succeeds while the storage is down" || bad "backup failed: $(tail -3 /tmp/b)"
grep -q 'upload to storage main failed' /tmp/b && ok "the failed upload is reported" || bad "no warning: $(tail -5 /tmp/b)"
cli self status-refresh --confirm yes >/dev/null 2>&1
a=$(cli self alerts --output json 2>/dev/null)
[[ "$(js '[x["kind"] for x in d["data"]["alerts"] if x["domain"] == "'"$D"'" and x["state"] == "open"]' <<<"$a")" == *backup_offsite_failed* ]] \
  && ok "a failed upload opens an alert" || bad "alerts: ${a:0:400}"
cli backup storage-test --name main --confirm yes >/tmp/t 2>&1 && bad "storage-test passed while down" || ok "storage-test fails while the storage is down"
[[ "$(cli backup storage-list --output json 2>/dev/null | js 'd["data"]["storages"][0]["last_test"]["ok"]')" == False ]] && ok "the failed check is remembered" || bad "test state"
s3_up
cli backup storage-test --name main --confirm yes >/dev/null 2>&1 && ok "storage-test passes again" || bad "storage-test"

# A new server: local backups gone, the copy is fetched and restored.
rm -rf "/var/backups/simai/$D"; echo "broken" >"$root/public/index.html"
cli backup storage-fetch --name main --domain "$D" --backup "$newest" >/tmp/f 2>&1
[[ ! -e "/var/backups/simai/$D/$newest" ]] && grep -q 'Plan:' /tmp/f && ok "fetch without confirm only a plan" || bad "fetch plan"
cli backup storage-fetch --name main --domain "$D" --backup "$newest" --confirm yes >/tmp/f 2>&1 && ok "a copy is fetched with checksums" || { bad "fetch"; cat /tmp/f; }
[[ "$(stat -c %a "/var/backups/simai/$D/$newest")" == 700 ]] && ok "the fetched copy is root-only" || bad "fetched perms"
cli backup data-restore --domain "$D" --backup "$newest" --confirm yes >/tmp/r 2>&1 || bad "restore: $(tail -5 /tmp/r)"
find "$root".restore-* -name index.html -exec grep -qx v3 {} \; -print 2>/dev/null | grep -q . && ok "the fetched copy restores (files staged)" || bad "restored: $(tail -8 /tmp/r)"
s3 copyto /dev/null "m:backups/web1/$D/20200101-000000/files.tar.gz"; printf 'x  files.tar.gz\n' | s3 rcat "m:backups/web1/$D/20200101-000000/SHA256SUMS"
cli backup storage-fetch --name main --domain "$D" --backup 20200101-000000 --confirm yes >/tmp/f 2>&1 && bad "a damaged copy was kept" \
  || { [[ ! -e "/var/backups/simai/$D/20200101-000000" ]] && ok "a damaged copy is refused" || bad "damaged kept"; }

# Through the panel gateway: administrator only; keys never kept.
cli panel gate-enable --confirm yes >/dev/null 2>&1
ssh-keygen -q -t ed25519 -N '' -f /root/own <<<y >/dev/null 2>&1
cli owner create --name acme --pubkey-file /root/own.pub --confirm yes >/dev/null 2>&1
gate() { printf '%s' "$1" | sudo -n -u simai-panel sudo -n /usr/local/sbin/simai-panel-gate; }
req() { printf '{"schema":"simai-panel-request/1","request_id":"r1","actor":{"user":"admin@x","owner":%s},"command":"%s","args":%s%s}' "$1" "$2" "$3" "${4:+,\"confirm\":true}"; }
wait_job() { local st s; for _ in {1..90}; do st=$(gate "$(req null job:status "{\"job_id\":\"$1\"}")"); s=$(js 'd["data"]["state"]' <<<"$st"); [[ "$s" != running ]] && break; sleep 1; done; echo "$s"; }
[[ "$(gate "$(req '"acme"' backup:storage-list '{}')" | js 'd["reason"]')" == not_allowed ]] && ok "an owner cannot see storages" || bad "owner list"
a=$(gate "$(req null backup:storage-list '{}')")
[[ "$(js 'd["data"]["storages"][0]["name"]' <<<"$a")" == main ]] && ok "backup:storage-list reads" || bad "gate list: ${a:0:300}"
body="{\"name\":\"second\",\"bucket\":\"backups\",\"endpoint\":\"http://127.0.0.1:9000\",\"prefix\":\"web2\",\"access-key\":\"$AK\",\"secret-key\":\"$SK\"}"
p=$(gate "$(req null backup:storage-add "$body")")
[[ "$(js 'd["kind"]' <<<"$p")" == plan && "$p" != *"$SK"* ]] && ok "backup:storage-add answers a plan without the secret" || bad "gate plan: ${p:0:300}"
a=$(gate "$(req null backup:storage-add "$body" 1)"); j=$(js 'd["job_id"]' <<<"$a")
[[ "$(wait_job "$j")" == succeeded && -f /etc/simai-env/backup-storages/second.env ]] && ok "the job adds the storage" || bad "gate add: ${a:0:300}"
grep -rqs "$SK" "/var/lib/simai-env/panel-jobs/$j" && bad "the secret stayed in the job" || ok "the keys are not kept in the job"
[[ "$(sed -n 's/^DEFAULT=//p' /etc/simai-env/backup-storages/second.env)" == no ]] && ok "a second storage is not the default" || bad "second default"
c=$(gate "$(req null backup:storage-copies "{\"name\":\"main\",\"domain\":\"$D\"}")")
[[ "$(js 'd["data"]["copies"][0]["backup"]' <<<"$c")" == "$newest" ]] && ok "backup:storage-copies reads" || bad "gate copies: ${c:0:300}"
a=$(gate "$(req null backup:storage-remove '{"name":"second"}' 1)"); j=$(js 'd["job_id"]' <<<"$a")
[[ "$(wait_job "$j")" == succeeded && ! -e /etc/simai-env/backup-storages/second.env ]] && ok "backup:storage-remove removes the settings" || bad "gate remove: ${a:0:300}"
s3 lsf "m:backups/web1/$D" | grep -q . && ok "the copies stay in the bucket" || bad "copies gone"

cli panel gate-disable --confirm yes >/dev/null 2>&1
cli owner remove --name acme --confirm yes >/dev/null 2>&1
cli site remove --domain "$D" --remove-files yes --confirm yes >/dev/null 2>&1
pkill -f 's3-server serve'
echo "failures=${fails}"
exit $(( fails > 0 ))
