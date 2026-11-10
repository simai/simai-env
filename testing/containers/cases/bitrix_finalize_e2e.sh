#!/usr/bin/env bash
# bitrix finalize after a simulated restore: session modes in
# after_connect_d7.php, PHP date.timezone, database default charset, restore
# leftovers moved out of the docroot, and a second run that changes nothing.
set -uo pipefail
rm -rf /root/simai-env-bxfin
cp -r /src /root/simai-env-bxfin
cd /root/simai-env-bxfin || exit 1
fails=0; ok() { echo "PASS $*"; }; bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { COLUMNS=220 bash ./simai-admin.sh "$@"; }
D=bxrestore.test
root=/home/simai/www/$D
doc=$root/public
php_if=$doc/bitrix/php_interface
ac=$php_if/after_connect_d7.php
pool=/etc/php/8.3/fpm/pool.d/bxrestore-test.conf
ini=/etc/simai-env/sites/$D/php.ini

# Host time zone: use Europe/Moscow when tzdata is there (MySQL follows it).
tz_expected=""
if [[ -f /usr/share/zoneinfo/Europe/Moscow ]]; then
  ln -sf /usr/share/zoneinfo/Europe/Moscow /etc/localtime
  echo Europe/Moscow >/etc/timezone
  tz_expected=Europe/Moscow
fi

# Profiles may already be initialized by an earlier case in this container.
cli profile init --mode all --confirm yes >/tmp/bxf-profile.out 2>&1 \
  || cli profile enable --id bitrix --confirm yes >>/tmp/bxf-profile.out 2>&1 || bad 'enable profiles'
cli site add --domain "$D" --profile bitrix --php 8.3 --create-db yes --confirm yes >/tmp/bxf-add.out 2>&1 \
  || { bad 'add Bitrix site'; tail -15 /tmp/bxf-add.out; }
owner=$(stat -c %U:%G "$doc")
db=$(sed -n 's/^DB_NAME=//p' "/etc/simai-env/sites/$D/db.env")

# Preseed writes after_connect_d7.php and leaves no temp files behind.
tmp_before=$(find /tmp -maxdepth 1 -name 'tmp.*' -type f | wc -l)
cli bitrix db-preseed --domain "$D" --overwrite yes --confirm yes >/tmp/bxf-preseed.out 2>&1 || { bad 'db-preseed'; tail /tmp/bxf-preseed.out; }
grep -q "innodb_strict_mode=0" "$ac" 2>/dev/null && ok 'preseed writes after_connect_d7.php' || bad 'preseed did not write after_connect_d7.php'
[[ $(find /tmp -maxdepth 1 -name 'tmp.*' -type f | wc -l) -le $tmp_before ]] && ok 'preseed leaves no temp files' || bad 'preseed leaked temp files'

# Simulate the restored archive: installed database, the old site's files.
mysql -e "CREATE TABLE \`${db}\`.b_user (ID INT PRIMARY KEY) DEFAULT CHARSET=utf8mb4; INSERT INTO \`${db}\`.b_user VALUES (1);
  CREATE TABLE \`${db}\`.b_option (ID INT PRIMARY KEY) DEFAULT CHARSET=utf8mb3;
  ALTER DATABASE \`${db}\` COLLATE utf8mb3_general_ci;" || bad 'prepare database'
cat >"$doc/bitrix/.settings.php" <<'EOF'
<?php
return ['connections' => ['value' => ['default' => [
  'className' => '\Bitrix\Main\DB\MysqliConnection', 'host' => 'localhost',
  'database' => 'olddb', 'login' => 'olduser', 'password' => 'RestoredSecret-42',
]], 'readonly' => true]];
EOF
cat >"$php_if/dbconn.php" <<'EOF'
<?php
$DBType = "mysql";
define("BX_UTF", true);
EOF
printf '%s\n' '<?php' "\$this->queryExecute(\"SET NAMES 'utf8mb4'\");" "\$this->queryExecute(\"SET collation_connection = 'utf8mb4_unicode_ci'\");" '?>' >"$ac"
chmod 0644 "$ac"
mkdir -p "$doc/bitrix/backup"
echo a >"$doc/x_full_abc.tar.gz"; echo b >"$doc/x_full_abc.tar.gz.1"; echo c >"$doc/restore.php"
echo d >"$doc/bitrix/backup/x.sql"; echo keep >"$doc/keep.tar.gz"; echo keep >"$doc/bitrix/backup/notes.txt"
chown -R "$owner" "$doc"
settings_sum=$(sha256sum "$doc/bitrix/.settings.php")
ac_mode=$(stat -c '%a %U:%G' "$ac")

cli bitrix finalize --domain "$D" --confirm yes >/tmp/bxf-1.out 2>&1 && ok 'finalize after restore succeeds' || { bad 'finalize failed'; tail -40 /tmp/bxf-1.out; }

# 1. Session modes appended in the file's own style, archive lines kept.
grep -qF "\$this->queryExecute(\"SET SESSION sql_mode=''\");" "$ac" && grep -qF '$this->queryExecute("SET SESSION innodb_strict_mode=0");' "$ac" \
  && grep -qF "SET NAMES 'utf8mb4'" "$ac" && grep -qF "SET collation_connection = 'utf8mb4_unicode_ci'" "$ac" \
  && ok 'after_connect_d7.php gains session modes, keeps charset lines' || { bad 'after_connect_d7.php content'; cat "$ac"; }
! grep -q '?>' "$ac" && php -l "$ac" >/dev/null 2>&1 && ok 'after_connect_d7.php is valid PHP without a closing tag' || bad 'after_connect_d7.php lint'
[[ "$(stat -c '%a %U:%G' "$ac")" == "$ac_mode" ]] && ok 'after_connect_d7.php keeps owner and mode' || bad "owner/mode changed: $(stat -c '%a %U:%G' "$ac") vs $ac_mode"
[[ -z "$(find "$php_if" -name '.after_connect_d7.php.*')" ]] && ok 'no temp file left in php_interface' || bad 'temp file left'
[[ "$settings_sum" == "$(sha256sum "$doc/bitrix/.settings.php")" ]] && ok '.settings.php untouched' || bad '.settings.php changed'
! grep -q 'RestoredSecret-42' /tmp/bxf-1.out && ok 'credentials are not printed' || bad 'password printed'
# 2. PHP time zone follows the host.
if [[ -n "$tz_expected" ]]; then
  grep -qx "date.timezone=${tz_expected}" "$ini" && grep -q "^php_admin_value\[date.timezone\] = ${tz_expected}$" "$pool" \
    && ok "date.timezone=${tz_expected} in overrides and pool" || { bad 'date.timezone'; grep timezone "$ini" "$pool"; }
else
  echo "INFO tzdata missing; checking that some date.timezone is set"
  grep -q '^php_admin_value\[date.timezone\] = ' "$pool" && ok 'date.timezone set in pool' || bad 'date.timezone missing'
fi
grep -q '^memory_limit=512M' "$ini" && ok 'baseline keys stay in overrides' || bad 'baseline lost'
# 3. Database default charset, tables reported, not converted.
[[ "$(mysql -NBe "SELECT CONCAT(DEFAULT_CHARACTER_SET_NAME,'/',DEFAULT_COLLATION_NAME) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}'")" == utf8mb4/utf8mb4_unicode_ci ]] \
  && ok 'database default is utf8mb4/utf8mb4_unicode_ci' || bad 'database default charset'
grep -q 'Tables still utf8mb3.*1 (not converted)' /tmp/bxf-1.out && ok 'utf8mb3 tables reported' || { bad 'utf8mb3 table count'; grep -i utf8mb3 /tmp/bxf-1.out; }
[[ "$(mysql -NBe "SELECT TABLE_COLLATION FROM information_schema.TABLES WHERE TABLE_SCHEMA='${db}' AND TABLE_NAME='b_option'")" == utf8mb3* ]] \
  && ok 'tables are not converted' || bad 'table was converted'
# 4. Leftovers moved out of the docroot, decoys stay.
arch=$root/restore-archive
[[ "$(stat -c %a "$arch" 2>/dev/null)" == 700 ]] && ok 'restore-archive is mode 700' || bad 'restore-archive mode'
[[ -f $arch/x_full_abc.tar.gz && -f $arch/x_full_abc.tar.gz.1 && -f $arch/restore.php && -f $arch/x.sql ]] \
  && [[ ! -e $doc/x_full_abc.tar.gz && ! -e $doc/x_full_abc.tar.gz.1 && ! -e $doc/restore.php && ! -e $doc/bitrix/backup/x.sql ]] \
  && ok 'archive volumes, restore.php and dump moved' || { bad 'leftovers not moved'; ls -la "$doc" "$arch"; }
[[ -f $doc/keep.tar.gz && -f $doc/bitrix/backup/notes.txt ]] && ok 'other files stay in docroot' || bad 'unrelated file moved'
grep -q "moved 4 file(s) to ${arch}" /tmp/bxf-1.out && ok 'finalize prints where leftovers went' || bad 'leftovers destination not printed'
# 5. perf-status sees the session modes.
cli bitrix perf-status --domain "$D" >/tmp/bxf-perf.out 2>&1
grep -Eq 'after_connect_d7\.php +\| ready' /tmp/bxf-perf.out && grep -q 'Settings init_commands *| ready (via after_connect_d7.php)' /tmp/bxf-perf.out \
  && ok 'perf-status reports session modes ready' || { bad 'perf-status'; grep -E 'init_commands|after_connect' /tmp/bxf-perf.out; }

# Second run changes nothing.
sums() { sha256sum "$ac" "$ini" "$pool" "$doc/bitrix/.settings.php"; find "$arch" "$doc" -maxdepth 1 -printf '%p\n' | sort; \
  mysql -NBe "SELECT DEFAULT_COLLATION_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='${db}'"; }
before=$(sums)
cli bitrix finalize --domain "$D" --confirm yes >/tmp/bxf-2.out 2>&1 && ok 'second finalize succeeds' || { bad 'second finalize failed'; tail -30 /tmp/bxf-2.out; }
[[ "$before" == "$(sums)" ]] && ok 'second finalize changes nothing' || { bad 'second finalize changed state'; diff <(echo "$before") <(sums); }
grep -q 'none in docroot' /tmp/bxf-2.out && grep -q 'unchanged (session modes present)' /tmp/bxf-2.out \
  && grep -q 'unchanged (utf8mb4/utf8mb4_unicode_ci)' /tmp/bxf-2.out && grep -q 'kept site override' /tmp/bxf-2.out \
  && ok 'second run reports every step unchanged' || { bad 'second run report'; grep '^|' /tmp/bxf-2.out; }

# Fresh-install shape: no after_connect_d7.php, operator's own time zone.
rm -f "$ac"
cli site php-ini-set --domain "$D" --name date.timezone --value Asia/Tokyo --confirm yes >/dev/null 2>&1 || bad 'set date.timezone'
cli bitrix finalize --domain "$D" --confirm yes >/tmp/bxf-3.out 2>&1 || { bad 'finalize without after_connect'; tail -30 /tmp/bxf-3.out; }
grep -q '\$connection->queryExecute("SET SESSION innodb_strict_mode=0");' "$ac" 2>/dev/null && grep -q 'after_connect_d7.php *| created' /tmp/bxf-3.out \
  && ok 'missing after_connect_d7.php is created' || bad 'after_connect_d7.php not created'
grep -qx 'date.timezone=Asia/Tokyo' "$ini" && grep -q '^php_admin_value\[date.timezone\] = Asia/Tokyo$' "$pool" \
  && ok 'existing date.timezone override is kept' || { bad 'date.timezone override replaced'; grep timezone "$ini" "$pool"; }

cli site remove --domain "$D" --remove-files yes --drop-db yes --confirm yes >/dev/null 2>&1 || true
echo "failures=$fails"; exit "$fails"
