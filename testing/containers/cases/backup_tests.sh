#!/usr/bin/env bash
# shellcheck disable=SC2164  # container test script: loose quoting/cd checks are fine here
# End-to-end test of backup data/verify/schedule/restore through the real CLI.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq mysql-server age rsync nginx-core python3 >/dev/null 2>&1
service mysql start >/dev/null 2>&1 || { echo "mysql did not start"; exit 1; }
cp -r /src /root/simai-env; cd /root/simai-env
id simai >/dev/null 2>&1 || useradd -m simai
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { bash ./simai-admin.sh "$@"; }

D=shop.example.com
root=/home/simai/www/$D
mkdir -p "$root/public" "$root/storage/logs" "$root/node_modules/x"
echo '<?php echo 1;' >"$root/public/index.php"; echo big >"$root/storage/logs/app.log"; echo dep >"$root/node_modules/x/i.js"
chown -R simai "$root"
mkdir -p /etc/nginx/sites-available
source lib/site_metadata.sh; set +e
{ site_nginx_metadata_render "$D" shop-example-com generic "$root" shop-example-com 8.2 none "" "" shop-example-com nginx-generic public; echo 'server { listen 80; }'; } \
  >/etc/nginx/sites-available/$D.conf
mysql -uroot -e "CREATE DATABASE shop; CREATE TABLE shop.orders (id INT PRIMARY KEY, total INT); INSERT INTO shop.orders VALUES (1,100),(2,250);"
install -d -m 0700 /etc/simai-env/sites/$D
printf 'DB_NAME=shop\nDB_USER=shop\nDB_PASS=x\n' >/etc/simai-env/sites/$D/db.env

# 1. Backup
out=$(cli backup data --domain $D --keep 2 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "backup data succeeds" || { bad "backup data rc=$rc"; echo "$out" | tail -20; }
dir=$(ls -1d /var/backups/simai/$D/2* | tail -1)
for f in db.sql.gz files.tar.gz manifest.txt SHA256SUMS; do [[ -s "$dir/$f" ]] && ok "has $f" || bad "missing $f"; done
[[ -s "$dir/config.tar.gz" ]] && ok "has config.tar.gz" || echo "INFO config export skipped: $(ls "$dir")"
[[ "$(stat -c %a /var/backups/simai/$D)" == 700 && "$(stat -c %a "$dir/db.sql.gz")" == 600 ]] && ok "backup is root-only" || bad "perms $(stat -c %a "$dir/db.sql.gz")"
zcat "$dir/db.sql.gz" | grep -q "INSERT INTO \`orders\`" && ok "dump contains data" || bad "dump has no data"
tar -tzf "$dir/files.tar.gz" | grep -q 'public/index.php' && ok "files include project" || bad "project files missing"
tar -tzf "$dir/files.tar.gz" | grep -q 'node_modules\|storage/logs/app.log' && bad "caches/logs not excluded" || ok "node_modules and logs excluded"

# 2. Verify + restore test
cli backup data-verify --path "$dir" --restore-test yes >/tmp/v 2>&1 && grep -q "restore test (1 tables" /tmp/v && ok "verify + restore test" || { bad "verify"; cat /tmp/v; }
[[ -z "$(mysql -uroot -N -e "SHOW DATABASES LIKE 'simai_restore_check%'")" ]] && ok "scratch DB dropped" || bad "scratch DB left"
printf 'x' >>"$dir/files.tar.gz"
cli backup data-verify --path "$dir" >/dev/null 2>&1 && bad "tampered backup verified" || ok "tampering detected"

# 3. Retention (keep 2)
for _ in 1 2; do sleep 1; cli backup data --domain $D --keep 2 >/dev/null 2>&1; done
n=$(find /var/backups/simai/$D -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ "$n" == 2 ]] && ok "retention keeps 2" || bad "retention left $n"

# 4. Restore
good=$(ls -1d /var/backups/simai/$D/2* | tail -1)
mysql -uroot -e "DELETE FROM shop.orders; INSERT INTO shop.orders VALUES (9,9);"
cli backup data-restore --domain $D --path "$good" >/tmp/plan 2>&1; grep -q "Rerun with --confirm yes" /tmp/plan && ok "restore without confirm is a plan" || bad "restore plan"
[[ "$(mysql -uroot -N -e 'SELECT COUNT(*) FROM shop.orders')" == 1 ]] && ok "plan changed nothing" || bad "plan modified DB"
cli backup data-restore --domain $D --path "$good" --confirm yes >/tmp/r 2>&1 || { bad "restore rc"; cat /tmp/r; }
[[ "$(mysql -uroot -N -e 'SELECT SUM(total) FROM shop.orders')" == 350 ]] && ok "database restored" || bad "restored data wrong"
ls /var/backups/simai/$D/pre-restore-*.sql.gz >/dev/null 2>&1 && ok "safety dump taken before restore" || bad "no safety dump"
ls -d "$root".restore-* >/dev/null 2>&1 && ok "files staged for review" || bad "files not staged"

# 5. Encryption
age-keygen -o /root/key.txt 2>/dev/null; pub=$(age-keygen -y /root/key.txt)
cli backup data --domain $D --keep 5 --encrypt-to "$pub" >/dev/null 2>&1 || bad "encrypted backup failed"
enc=$(ls -1d /var/backups/simai/$D/2* | tail -1)
[[ -f "$enc/db.sql.gz.age" && ! -f "$enc/db.sql.gz" ]] && ok "encrypted artifacts only" || bad "encryption layout: $(ls "$enc")"
age -d -i /root/key.txt "$enc/db.sql.gz.age" | zcat | grep -q orders && ok "encrypted dump decrypts" || bad "decrypt failed"
cli backup data-verify --path "$enc" >/dev/null 2>&1 && ok "encrypted backup checksums verify" || bad "encrypted verify"

# 6. Validation and failure handling
cli backup data --domain $D --dest /home/simai/www/b >/dev/null 2>&1 && bad "allowed dest in web root" || ok "refuses dest inside web root"
cli backup data --domain $D --keep 0 >/dev/null 2>&1 && bad "accepted keep 0" || ok "refuses keep 0"
cli backup data --domain $D --offsite 'x;rm -rf /' >/dev/null 2>&1 && bad "accepted bad offsite" || ok "refuses malformed offsite"
before=$(find /var/backups/simai/$D -mindepth 1 -maxdepth 1 -type d | wc -l)
printf 'DB_NAME=missingdb\n' >/etc/simai-env/sites/$D/db.env
cli backup data --domain $D --keep 5 >/dev/null 2>&1 && bad "backup of missing DB succeeded" || ok "failed dump makes the command fail"
after=$(find /var/backups/simai/$D -mindepth 1 -maxdepth 1 -type d | wc -l)
[[ "$before" == "$after" ]] && ok "partial backup removed" || bad "partial backup left behind"

# 7. Schedule
cli backup data-schedule --domain $D --time 02:05 --keep 3 >/dev/null 2>&1
c=/etc/cron.d/simai-backup-shop-example-com
grep -q '^5 2 \* \* \* root .*backup data --domain shop.example.com --keep 3' "$c" && ok "cron scheduled 02:05" || { bad "cron line"; cat "$c"; }
cli backup data-schedule --domain $D --time 25:00 >/dev/null 2>&1 && bad "accepted 25:00" || ok "refuses invalid time"
cli backup data-schedule --domain $D --enabled no >/dev/null 2>&1; [[ ! -e "$c" ]] && ok "schedule disabled" || bad "cron left"

echo "failures=${fails}"
exit "$fails"
