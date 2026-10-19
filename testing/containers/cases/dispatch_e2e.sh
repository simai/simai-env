#!/usr/bin/env bash
# Real dispatcher, including conditional caller, lock contention and JSON output.
set -uo pipefail
cp -r /src /root/simai-env-dispatch
cd /root/simai-env-dispatch || exit 1
fails=0
ok() { echo "PASS $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
cli() { bash ./simai-admin.sh "$@"; }
# Callers without a terminal wait for a held lock by default; contention
# checks need an immediate answer.
export SIMAI_LOCK_WAIT=0
# Fixtures are created only in this disposable runtime copy.
cat >admin/commands/zz_fixture.sh <<'EOF'
fixture_fail() { false; touch /tmp/dispatch-continued; }
fixture_write() { touch /tmp/dispatch-mutated; }
fixture_hold() { touch /tmp/dispatch-holding; sleep 8; }
fixture_secret() { echo 'fixture-secret-must-not-escape'; }
fixture_nested() { run_command fixture write --domain lock.test; sleep 4; }
register_cmd fixture fail 'failure injection' fixture_fail '' '' 'effects:read'
register_cmd fixture write 'mutation injection' fixture_write '' 'domain='
register_cmd fixture hold 'lock injection' fixture_hold '' 'domain='
register_cmd fixture nested 'nested lock injection' fixture_nested '' 'domain='
register_cmd fixture secret 'secret output injection' fixture_secret '' '' 'effects:read'
fixture_cli() { rm -f /tmp/dispatch-cli; SIMAI_ADMIN_MENU=0 bash ./simai-admin.sh fixture mark --confirm yes; }
fixture_mark() { touch /tmp/dispatch-cli; }
register_cmd fixture cli 'nested CLI invocation' fixture_cli '' ''
register_cmd fixture mark 'nested CLI target' fixture_mark '' ''
EOF
if cli fixture fail >/tmp/fail.out 2>&1; then bad 'failed step returned success'; else ok 'failure survives conditional caller'; fi
[[ ! -e /tmp/dispatch-continued ]] && ok 'later step never ran' || bad 'handler continued'
cli fixture write >/tmp/preview.out 2>&1
[[ ! -e /tmp/dispatch-mutated ]] && grep -q 'No handler was executed' /tmp/preview.out && ok 'preview does not execute' || bad 'preview mutated'
cli fixture write --confirm yes --dry-run yes >/tmp/dry.out 2>&1
[[ ! -e /tmp/dispatch-mutated ]] && ok 'dry-run overrides confirmation' || bad 'dry-run mutated'
cli fixture hold --domain lock.test --confirm yes >/tmp/hold.out 2>&1 & holder=$!
for _ in {1..50}; do [[ -e /tmp/dispatch-holding ]] && break; sleep 0.1; done
rc=0; cli fixture write --domain lock.test --confirm yes --output json >/tmp/busy.json 2>/tmp/busy.err || rc=$?
[[ $rc -eq 75 ]] && python3 -c 'import json; d=json.load(open("/tmp/busy.json")); assert d["status"]=="busy" and not d["applied"]' && ok 'same-site conflict refused before mutation' || bad 'same-site lock'
rc=0; cli fixture write --confirm yes >/tmp/host.out 2>&1 || rc=$?
[[ $rc -eq 75 ]] && ok 'host mutation waits for site mutations' || bad 'host lock'
cli fixture write --domain other.test --confirm yes >/tmp/other.out 2>&1 && ok 'another site can proceed' || bad 'unrelated site blocked'
wait "$holder" || bad 'holding operation failed'
rm -f /tmp/dispatch-holding
# Automation (no terminal) waits for the lock instead of failing as busy.
cli fixture hold --domain lock.test --confirm yes >/tmp/hold.out 2>&1 & holder=$!
for _ in {1..50}; do [[ -e /tmp/dispatch-holding ]] && break; sleep 0.1; done
start=$SECONDS; rc=0
SIMAI_LOCK_WAIT=30 cli fixture write --domain lock.test --confirm yes </dev/null >/tmp/waited.out 2>&1 || rc=$?
(( SECONDS - start >= 5 )) && [[ $rc -eq 0 ]] && ok 'waiting caller runs after the lock is released' || bad "lock wait rc=${rc}"
wait "$holder" || bad 'holding operation failed'
rm -f /tmp/dispatch-holding
cli fixture nested --domain lock.test --confirm yes >/tmp/nested.out 2>&1 & holder=$!
sleep 1
rc=0; cli fixture write --domain lock.test --confirm yes >/tmp/nested-busy.out 2>&1 || rc=$?
[[ $rc -eq 75 ]] && ok 'nested operation preserves external lock' || bad 'nested lock'
wait "$holder" && ok 'nested operation completed without deadlock' || { bad 'nested failed'; tail /tmp/nested.out; }
cli fixture cli --confirm yes >/tmp/cli.out 2>&1
[[ -e /tmp/dispatch-cli ]] && ok 'handler can run simai-admin.sh again (self update -> self migrate)' || { bad 'nested CLI did not dispatch'; tail -5 /tmp/cli.out; }
cli fixture secret --output json >/tmp/secret.json 2>/tmp/secret.err
! grep -q 'fixture-secret' /tmp/secret.json /tmp/secret.err && ok 'handler text is absent from JSON and stderr' || bad 'JSON leaked handler output'
cli self commands >/tmp/commands.json 2>/tmp/commands.err
python3 -c 'import json; d=json.load(open("/tmp/commands.json")); assert d["count"]==len(d["commands"]); assert all(all(k in c for k in ("effects","authorization","confirmation","lock","verification")) for c in d["commands"])' && ok 'registry exports safety contracts' || bad 'registry contract'
PYTHONDONTWRITEBYTECODE=1 python3 testing/contracts/check.py /tmp/commands.json || bad 'contract validation'
cli self ai-catalog >/tmp/ai.json 2>/tmp/ai.err
python3 -c 'import json; d=json.load(open("/tmp/ai.json")); assert d["formatVersion"]=="1.0"; assert d["items"] and all(x["capability"]["effects"]=="read" for x in d["items"])' && ok 'AI First read-only pilot' || { bad 'AI catalog'; cat /tmp/ai.err; }
cli site deploy --domain plan.test --git https://account:fixture-url-secret@github.com/example/repo --ref main >/tmp/url-preview.out 2>&1
! grep -q 'fixture-url-secret' /tmp/url-preview.out && ok 'preview masks embedded URL credentials' || bad 'URL credential leak'
cli profile validate --all yes >/tmp/profile-read.out 2>&1 && grep -q 'PASS' /tmp/profile-read.out && ok 'profile diagnostic counters survive strict mode' || { bad 'profile validation'; tail /tmp/profile-read.out; }
echo "failures=$fails"
exit "$fails"
