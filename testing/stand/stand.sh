#!/usr/bin/env bash
# Local development stand: a long-lived Ubuntu container with simai-env and a
# few demo sites, for developing the control panel on a laptop without
# installing simai-env there.
#
#   testing/stand/stand.sh up       # build, start, install the working tree, seed demo sites
#   testing/stand/stand.sh sync     # copy the working tree in again (code changes)
#   testing/stand/stand.sh record   # write gateway answers to testing/fixtures/panel/
#   testing/stand/stand.sh gate < request.json   # one gateway request over SSH
#   testing/stand/stand.sh shell    # root shell inside the stand
#   testing/stand/stand.sh cli ...  # run simai-admin.sh inside the stand
#   testing/stand/stand.sh status | down
#
# Sites answer on http://127.0.0.1:${SIMAI_STAND_HTTP:-18080} with a Host
# header (curl -H 'Host: demo-static.test' ...). Nothing here touches a real
# server; the container uses the same image as the end-to-end tests.
# The panel gateway answers over SSH on 127.0.0.1:${SIMAI_STAND_SSH:-12222}
# as simai-panel with the key ~/.simai-stand/panel_ed25519 (created by up).
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
NAME="${SIMAI_STAND_NAME:-simai-env-stand}"
UBUNTU="${SIMAI_STAND_UBUNTU:-24.04}"
PHP=8.3
[[ "$UBUNTU" == 22.04 ]] && PHP=8.1
[[ "$UBUNTU" == 26.04 ]] && PHP=8.5
HTTP_PORT="${SIMAI_STAND_HTTP:-18080}"
HTTPS_PORT="${SIMAI_STAND_HTTPS:-18443}"
SSH_PORT="${SIMAI_STAND_SSH:-12222}"
FIXTURES="${ROOT_DIR}/testing/fixtures/panel"
KEY_DIR="${HOME}/.simai-stand"
# Bump when the shape of a recorded answer changes (docs/architecture/panel-gate.md).
FIXTURE_SET=11

in_stand() { docker exec "$NAME" "$@"; }
running() { [[ "$(docker container inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" == true ]]; }
need_running() { running || { echo "The stand is not running: $0 up" >&2; exit 1; }; }

sync_code() {
  local snapshot
  snapshot=$(mktemp -d)
  # Same exclusions as the e2e runner: no history, secrets or local state.
  tar -C "$ROOT_DIR" --exclude=.git --exclude=source --exclude=work --exclude=mirai \
    --exclude=graph.json --exclude=testing/test-config.env --exclude='.env*' \
    --exclude=node_modules --exclude=.simai --exclude=.claude --exclude=docara \
    --exclude=output --exclude=build --exclude=dist -cf "${snapshot}.tar" .
  tar -xf "${snapshot}.tar" -C "$snapshot" && rm -f "${snapshot}.tar"
  in_stand rm -rf /root/simai-env.new
  docker cp "${snapshot}/." "${NAME}:/root/simai-env.new" >/dev/null
  rm -rf "$snapshot"
  # Host state lives in /etc/simai-env; replacing the code keeps it.
  in_stand bash -c 'rm -rf /root/simai-env && mv /root/simai-env.new /root/simai-env && chmod +x /root/simai-env/*.sh'
  echo "[stand] code synced ($(cat "${ROOT_DIR}/VERSION"))"
}

seed() {
  docker exec -i "$NAME" bash -s "$PHP" <<'SEED'
set -uo pipefail
php="$1"; cd /root/simai-env
cli() { ./simai-admin.sh "$@" >/tmp/stand-seed.log 2>&1 || { echo "[stand] failed: $*"; tail -5 /tmp/stand-seed.log; }; }
id simai >/dev/null 2>&1 || useradd -m simai
command -v sshd >/dev/null || { apt-get update -qq >/dev/null; apt-get install -y -qq openssh-server >/dev/null 2>&1; }
systemctl enable --now ssh >/dev/null 2>&1 || true
[[ -f /root/stand-owner ]] || ssh-keygen -q -t ed25519 -N '' -C stand-owner -f /root/stand-owner
cli profile enable --id redirect --confirm yes
./simai-admin.sh owner list 2>/dev/null | grep -q demo || cli owner create --name demo --pubkey-file /root/stand-owner.pub --confirm yes
site() { [[ -f "/etc/nginx/sites-available/$1.conf" ]] || cli site add --domain "$@" --confirm yes; }
site demo-static.test --profile static
site demo-php.test --profile generic --php "$php" --create-db yes
site demo-owned.test --profile generic --php "$php" --create-db no --owner demo
site demo-redirect.test --profile redirect --redirect-to https://demo-static.test --redirect-path drop
if [[ ! -e /home/simai/www/demo-static.test/current ]]; then
  mkdir -p /root/stand-art && echo '<h1>demo-static</h1>' >/root/stand-art/index.html
  tar -C /root/stand-art -czf /root/stand-art.tgz .
  cli site deploy --domain demo-static.test --archive /root/stand-art.tgz --sha256 "$(sha256sum /root/stand-art.tgz | cut -d' ' -f1)" --confirm yes
fi
./simai-admin.sh access list 2>/dev/null | grep -q demo-staff ||
  cli access create-project --domain demo-owned.test --login demo-staff --pubkey-file /root/stand-owner.pub --confirm yes
echo "[stand] demo sites: demo-static.test demo-php.test demo-owned.test (owner demo) demo-redirect.test"
SEED
  # The laptop reaches the gateway like a panel on another machine would.
  install -d -m 0700 "$KEY_DIR"
  [[ -f "${KEY_DIR}/panel_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C simai-stand-panel -f "${KEY_DIR}/panel_ed25519"
  docker cp "${KEY_DIR}/panel_ed25519.pub" "${NAME}:/root/stand-panel.pub" >/dev/null
  in_stand /root/simai-env/simai-admin.sh panel gate-enable --pubkey-file /root/stand-panel.pub --confirm yes >/dev/null
  echo "[stand] panel gateway: ssh -i ${KEY_DIR}/panel_ed25519 -p ${SSH_PORT} simai-panel@127.0.0.1 < request.json"
}

gate() {
  ssh -i "${KEY_DIR}/panel_ed25519" -p "$SSH_PORT" -o BatchMode=yes -o LogLevel=ERROR \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null simai-panel@127.0.0.1
}

record() {
  need_running
  mkdir -p "$FIXTURES"
  # Keep the recorded set when the gateway does not answer.
  printf '{"schema":"simai-panel-request/1","request_id":"probe","actor":{"user":"admin@stand.test","owner":null},"command":"self:commands","args":{}}' \
    | gate | grep -q '"status": "ok"' || { echo "[stand] the gateway does not answer; run: $0 up" >&2; exit 1; }
  rm -f "${FIXTURES}"/*.json
  # One known alert (a failed backup of the owner's site) for the alert answers;
  # two runs, so the load history has points.
  in_stand bash -c 'mkdir -p /var/lib/simai-env/backup-runs && echo "{\"at\":\"2026-01-01T00:00:00Z\",\"ok\":false}" >/var/lib/simai-env/backup-runs/demo-owned.test.json'
  in_stand /root/simai-env/simai-admin.sh self status-refresh --confirm yes >/dev/null 2>&1
  in_stand /root/simai-env/simai-admin.sh self status-refresh --confirm yes >/dev/null 2>&1
  # One cron job of the owner's site with a fixed id and one recorded run.
  docker exec -i "$NAME" bash -s <<'CRON'
f=/etc/simai-env/cron-jobs/demo-owned.test/jobs.json
mkdir -p "$(dirname "$f")" && chmod 0711 "$(dirname "$f")"
printf '{"jobs":[{"id":"a1b2c3d4","schedule":"*/10 * * * *","command":"php artisan app:sync --quiet","enabled":true,"created_at":"2026-01-01T00:00:00Z"}]}' >"$f"; chmod 0600 "$f"
/root/simai-env/simai-admin.sh cron job-enable --id a1b2c3d4 --confirm yes >/dev/null 2>&1
u=$(awk '/a1b2c3d4/ {print $6}' /etc/cron.d/simai-jobs-demo-owned-test)
mkdir -p /var/lib/simai-env/cron-runs/demo-owned.test
printf '{"started_at":"2026-01-01T00:00:00Z","finished_at":"2026-01-01T00:00:02Z","exit_code":0,"output":["Synced 12 records."]}\n' >/var/lib/simai-env/cron-runs/demo-owned.test/a1b2c3d4.jsonl
chown -R "$u" /var/lib/simai-env/cron-runs/demo-owned.test
CRON
  # The firewall on, one rule from an address and one blocked address, each a
  # confirmed timed change; the last change answers change-status.
  docker exec -i "$NAME" bash -s <<'FW'
cd /root/simai-env
a() { ./simai-admin.sh "$@" --confirm yes 2>/dev/null | sed -nE 's/^\| Change +\| ([a-f0-9]{12}) .*/\1/p'; }
./simai-admin.sh self firewall-ensure --confirm yes >/dev/null 2>&1
ufw show added | grep -q 'port 3306' || { id=$(a firewall rule-add --port 3306 --proto tcp --from 192.0.2.10); ./simai-admin.sh change confirm --id "$id" --confirm yes >/dev/null 2>&1; }
ufw show added | grep -q 'deny from 203.0.113.7' || { id=$(a firewall block --address 203.0.113.7); ./simai-admin.sh change confirm --id "$id" --confirm yes >/dev/null 2>&1; }
ls -t /var/lib/simai-env/changes | head -n1 >/root/stand-change-id
FW
  local change_id
  change_id=$(in_stand cat /root/stand-change-id)
  # The site answers show one backup, also on a freshly created stand.
  in_stand bash -c 'ls -d /var/backups/simai/demo-php.test/*/ >/dev/null 2>&1 || /root/simai-env/simai-admin.sh backup data --domain demo-php.test --confirm yes >/dev/null 2>&1'
  local bk
  bk=$(in_stand bash -c 'ls -1 /var/backups/simai/demo-php.test | grep -E "^[0-9]{8}-[0-9]{6}$" | tail -n1')
  # The site answers show a checked copy (last_verify).
  in_stand /root/simai-env/simai-admin.sh backup data-verify --domain demo-php.test --backup latest --restore-test auto --confirm yes >/dev/null 2>&1
  local key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixtureKeyFixtureKeyFixtureKeyFixtureKeyFixt staff@example'
  # name, owner (JSON), command, args (JSON)
  local -a requests=(
    "self-describe|null|self:describe|{}"
    "self-describe.owner-demo|\"demo\"|self:describe|{}"
    "self-commands|null|self:commands|{}"
    "refused.owner-scope|\"demo\"|site:describe|{\"domain\":\"demo-php.test\"}"
    "refused.not-allowed|null|self:bootstrap|{}"
    "plan.backup-data|null|backup:data|{\"domain\":\"demo-owned.test\",\"db\":\"no\"}"
    "plan.site-add|null|site:add|{\"domain\":\"new.test\",\"profile\":\"static\"}"
    "plan.site-deploy-git|null|site:deploy|{\"domain\":\"demo-static.test\",\"git\":\"https://github.com/example/site\",\"ref\":\"v1.0.0\"}"
    "refused.owner-admin-only|\"demo\"|owner:create|{\"name\":\"other\"}"
    "plan.site-set-php|null|site:set-php|{\"domain\":\"demo-php.test\",\"php\":\"${PHP}\"}"
    "plan.owner-create|null|owner:create|{\"name\":\"staff\"}"
    "plan.owner-block|null|owner:block|{\"name\":\"demo\"}"
    "plan.site-add-laravel|null|site:add|{\"domain\":\"app.test\",\"profile\":\"laravel\"}"
    "logs-nginx.demo-static.test|null|logs:nginx|{\"domain\":\"demo-static.test\",\"lines\":\"5\"}"
    "logs-nginx.match|null|logs:nginx|{\"domain\":\"demo-static.test\",\"lines\":\"5\",\"match\":\"GET\"}"
    "self-metrics|null|self:metrics|{}"
    "refused.owner-admin-only.metrics|\"demo\"|self:metrics|{}"
    "php-extensions|null|php:extensions|{\"php\":\"${PHP}\"}"
    "site-php-ini-list.demo-owned.test|\"demo\"|site:php-ini-list|{\"domain\":\"demo-owned.test\"}"
    "plan.site-php-ini-set|\"demo\"|site:php-ini-set|{\"domain\":\"demo-owned.test\",\"name\":\"memory_limit\",\"value\":\"256M\"}"
    "plan.site-php-ini-unset|\"demo\"|site:php-ini-unset|{\"domain\":\"demo-owned.test\",\"name\":\"memory_limit\"}"
    "refused.invalid-argument.php-ini-key|\"demo\"|site:php-ini-set|{\"domain\":\"demo-owned.test\",\"name\":\"open_basedir\",\"value\":\"/\"}"
    "db-list|null|db:list|{}"
    "db-list.owner-demo|\"demo\"|db:list|{}"
    "plan.site-db-rotate|null|site:db-rotate|{\"domain\":\"demo-php.test\"}"
    "plan.backup-data-restore|null|backup:data-restore|{\"domain\":\"demo-php.test\",\"backup\":\"${bk}\",\"files\":\"no\"}"
    "plan.backup-data-verify|null|backup:data-verify|{\"domain\":\"demo-php.test\",\"backup\":\"${bk}\"}"
    "plan.backup-data-schedule|null|backup:data-schedule|{\"domain\":\"demo-php.test\",\"time\":\"03:30\",\"keep\":\"14\",\"verify\":\"yes\"}"
    "plan.site-add-no-backup|null|site:add|{\"domain\":\"new.test\",\"profile\":\"static\",\"backup\":\"no\"}"
    "access-list|null|access:list|{}"
    "access-list.owner-demo|\"demo\"|access:list|{}"
    "plan.access-create-project|\"demo\"|access:create-project|{\"domain\":\"demo-owned.test\",\"login\":\"demo-staff2\",\"pubkey\":\"${key}\"}"
    "plan.access-add-key|\"demo\"|access:add-key|{\"login\":\"demo-staff\",\"pubkey\":\"${key}\"}"
    "plan.access-disable|\"demo\"|access:disable|{\"login\":\"demo-staff\"}"
    "plan.access-enable|\"demo\"|access:enable|{\"login\":\"demo-staff\"}"
    "plan.access-remove|\"demo\"|access:remove|{\"login\":\"demo-staff\"}"
    "refused.unknown-access|null|access:disable|{\"login\":\"nobody1\"}"
    "refused.invalid-argument.access-password|\"demo\"|access:create-project|{\"domain\":\"demo-owned.test\",\"login\":\"pwstaff\",\"password\":\"secret123\"}"
    "self-alerts|null|self:alerts|{}"
    "self-alerts.owner-demo|\"demo\"|self:alerts|{}"
    "plan.self-alerts-ack|\"demo\"|self:alerts-ack|{\"id\":\"9147a2749fff\"}"
    "plan.self-alerts-channel|null|self:alerts-channel|{\"kind\":\"webhook\",\"target\":\"https://hooks.example.com/simai\"}"
    "plan.self-alerts-test|null|self:alerts-test|{}"
    "refused.owner-admin-only.alerts-channel|\"demo\"|self:alerts-channel|{\"kind\":\"off\"}"
    "self-metrics-history|null|self:metrics-history|{\"period\":\"day\"}"
    "refused.owner-admin-only.metrics-history|\"demo\"|self:metrics-history|{\"period\":\"week\"}"
    "self-update-plan.env|null|self:update-plan|{\"target\":\"env\"}"
    "self-update-plan.panel|null|self:update-plan|{\"target\":\"panel\"}"
    "plan.self-update|null|self:update|{\"target\":\"env\"}"
    "refused.owner-admin-only.update|\"demo\"|self:update|{\"target\":\"env\"}"
    "service-list|null|service:list|{}"
    "cron-list.demo-owned.test|\"demo\"|cron:list|{\"domain\":\"demo-owned.test\"}"
    "cron-job-runs|\"demo\"|cron:job-runs|{\"id\":\"a1b2c3d4\"}"
    "plan.cron-job-add|\"demo\"|cron:job-add|{\"domain\":\"demo-owned.test\",\"schedule\":\"0 3 * * *\",\"command\":\"php artisan backup:clean\"}"
    "plan.cron-job-disable|\"demo\"|cron:job-disable|{\"id\":\"a1b2c3d4\"}"
    "plan.cron-job-remove|\"demo\"|cron:job-remove|{\"id\":\"a1b2c3d4\"}"
    "refused.owner-scope.cron-job-add|\"demo\"|cron:job-add|{\"domain\":\"demo-php.test\",\"schedule\":\"0 3 * * *\",\"command\":\"true\"}"
    "refused.unknown-cron-job|null|cron:job-runs|{\"id\":\"00000000\"}"
    "firewall-status|null|firewall:status|{}"
    "plan.firewall-rule-add|null|firewall:rule-add|{\"port\":\"8080\",\"proto\":\"tcp\",\"from\":\"any\",\"action\":\"allow\"}"
    "plan.firewall-rule-remove|null|firewall:rule-remove|{\"id\":\"0123abcd\"}"
    "plan.firewall-block|null|firewall:block|{\"address\":\"198.51.100.20\",\"ttl\":\"3600\"}"
    "plan.firewall-unblock|null|firewall:unblock|{\"address\":\"203.0.113.7\"}"
    "plan.panel-access|null|panel:access|{\"allow\":[\"192.0.2.10\",\"198.51.100.0/24\"]}"
    "plan.change-confirm|null|change:confirm|{\"change_id\":\"${change_id}\"}"
    "change-status|null|change:status|{\"change_id\":\"${change_id}\"}"
    "refused.owner-admin-only.firewall-status|\"demo\"|firewall:status|{}"
    "refused.invalid-argument.panel-access|null|panel:access|{\"allow\":\"192.0.2.10; deny all\"}"
    "service-log.nginx|null|service:log|{\"name\":\"nginx\",\"lines\":\"20\"}"
    "plan.service-restart|null|service:restart|{\"name\":\"nginx\"}"
    "plan.service-reload|null|service:reload|{\"name\":\"nginx\"}"
    "refused.owner-admin-only.service-restart|\"demo\"|service:restart|{\"name\":\"nginx\"}"
    "refused.invalid-argument.service-name|null|service:restart|{\"name\":\"ssh\"}"
    "self-profiles|null|self:profiles|{}"
    "self-profiles.owner-demo|\"demo\"|self:profiles|{}"
    "plan.site-add-proxy|null|site:add|{\"domain\":\"demo-proxy.test\",\"profile\":\"proxy\",\"upstream-port\":\"3000\",\"websockets\":\"yes\"}"
    "plan.site-add-bitrix|null|site:add|{\"domain\":\"demo-bitrix.test\",\"profile\":\"bitrix\",\"bitrix-files\":\"setup\"}"
    "refused.owner-scope.access-create-project|\"demo\"|access:create-project|{\"domain\":\"demo-php.test\",\"login\":\"x-staff\",\"pubkey\":\"${key}\"}"
  )
  # An owner is refused on another owner's site, for every site command.
  local c extra
  for c in site:php-ini-list site:php-ini-set site:php-ini-unset site:db-rotate backup:data-restore backup:data-verify backup:data-schedule; do
    extra=""
    [[ "$c" == site:php-ini-set ]] && extra=',"name":"memory_limit","value":"256M"'
    [[ "$c" == site:php-ini-unset ]] && extra=',"name":"memory_limit"'
    [[ "$c" == backup:data-restore || "$c" == backup:data-verify ]] && extra=",\"backup\":\"${bk}\""
    requests+=("refused.owner-scope.${c/:/-}|\"demo\"|${c}|{\"domain\":\"demo-php.test\"${extra}}")
  done
  local d
  for d in demo-static.test demo-php.test demo-owned.test demo-redirect.test; do
    requests+=("site-describe.${d}|null|site:describe|{\"domain\":\"${d}\"}")
    requests+=("site-doctor.${d}|null|site:doctor|{\"domain\":\"${d}\"}")
  done
  local row name owner command args
  for row in "${requests[@]}"; do
    IFS='|' read -r name owner command args <<<"$row"
    printf '{"schema":"simai-panel-request/1","request_id":"fixture-%s","actor":{"user":"admin@stand.test","owner":%s},"command":"%s","args":%s}' \
      "$name" "$owner" "$command" "$args" | gate >"${FIXTURES}/${name}.json"
  done
  # A job: start, follow to the end, then remove the backup it made so the
  # site answers above stay the same on the next recording.
  local job req='{"schema":"simai-panel-request/1","request_id":"fixture-%s","actor":{"user":"admin@stand.test","owner":null},"command":"%s","args":%s%s}'
  # shellcheck disable=SC2059 # the format is the request template above
  printf "$req" job-start backup:data '{"domain":"demo-owned.test","db":"no"}' ',"confirm":true' | gate >"${FIXTURES}/job-start.json"
  job=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["job_id"])' "${FIXTURES}/job-start.json")
  for _ in $(seq 60); do
    # shellcheck disable=SC2059
    printf "$req" job-status job:status "{\"job_id\":\"${job}\"}" '' | gate >"${FIXTURES}/job-status.json"
    grep -q '"state": "running"' "${FIXTURES}/job-status.json" || break
    sleep 1
  done
  # shellcheck disable=SC2059
  printf "$req" job-log job:log "{\"job_id\":\"${job}\"}" '' | gate >"${FIXTURES}/job-log.json"
  in_stand bash -c 'ls -1d /var/backups/simai/demo-owned.test/*/ | tail -n1 | xargs -r rm -rf'
  # Every answer must be valid JSON; a recording with stray output is useless.
  # manifest.json pins the set: larena/env checks its copy against it.
  python3 - "$FIXTURES" "$(cat "${ROOT_DIR}/VERSION")" "$FIXTURE_SET" <<'PY'
import hashlib, json, pathlib, re, sys
root, env_version, set_version = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
files = {}
for f in sorted(root.glob("*.json")):
    if f.name == "manifest.json":
        continue
    d = json.loads(f.read_text())
    # Volatile values are pinned so that only a real change alters the set.
    if "operation_id" in d:
        d["operation_id"] = "fixture"
    data = d.get("data") if isinstance(d.get("data"), dict) else {}
    if "generated_at" in data:
        data["generated_at"] = "2026-01-01T00:00:00Z"
    sites = list(data.get("sites", [])) if isinstance(data.get("sites"), list) else []
    if "domain" in data and "answers" in data:
        sites.append(data)
    for site in sites:
        if site.get("answers"):
            site["answers"]["checked_at"] = "2026-01-01T00:00:00Z"
        if site.get("disk"):
            site["disk"] = {"bytes": 1048576, "checked_at": "2026-01-01T00:00:00Z"}
        if site.get("last_backup"):
            site["last_backup"] = "2026-01-01T00:00:00"
        if site.get("last_verify"):
            site["last_verify"].update(at="2026-01-01T00:00:00Z", backup="20260101-000000")
        backups = site.get("backups") if isinstance(site.get("backups"), dict) else {}
        if backups.get("last_verify"):
            backups["last_verify"].update(at="2026-01-01T00:00:00Z", backup="20260101-000000")
        if (site.get("certificate") or {}).get("last_renew"):
            site["certificate"]["last_renew"]["at"] = "2026-01-01T00:00:00Z"
    for owner in (data.get("isolation") or {}).get("owners", []):
        if owner.get("sites_disk_bytes") is not None:
            owner["sites_disk_bytes"] = 1048576 * len([s for s in sites if s.get("owner") == owner["name"]])
    if data.get("schema") == "simai-host-metrics/1":
        data.update(cpu={"cores": 2, "load1": 0.1, "load5": 0.1, "load15": 0.1},
                    memory={"total_bytes": 4294967296, "used_bytes": 1073741824},
                    swap={"total_bytes": 0, "used_bytes": 0}, checked_at="2026-01-01T00:00:00Z",
                    disk=[{"mount": "/", "total_bytes": 42949672960, "used_bytes": 10737418240}])
    for access in data.get("accesses", []) if isinstance(data.get("accesses"), list) else []:
        access["created_at"] = "2026-01-01T00:00:00"
    for db in data.get("databases", []) if isinstance(data.get("databases"), list) else []:
        if db.get("size_bytes") is not None:
            db["size_bytes"] = 16384
    if isinstance(data.get("args"), dict) and re.fullmatch(r"\d{8}-\d{6}", str(data["args"].get("backup", ""))):
        data["args"]["backup"] = "20260101-000000"
    if data.get("schema") == "simai-alerts/1":
        # Only the planted alert: disk use and the like differ between machines.
        data["checked_at"] = "2026-01-01T00:00:00Z"
        data["alerts"] = [dict(a, first_seen="2026-01-01T00:00:00Z", last_seen="2026-01-01T00:00:00Z")
                          for a in data["alerts"] if a.get("kind") == "backup_failed"]
    if data.get("schema") == "simai-metrics-history/1":
        data["points"] = [{"at": "2026-01-01T00:00:00Z", "load1": 0.1, "cpu_cores": 2, "memory_used_bytes": 1073741824,
                           "memory_total_bytes": 4294967296, "swap_used_bytes": 0,
                           "disk": [{"mount": "/", "used_bytes": 10737418240, "total_bytes": 42949672960}]}]
    if data.get("schema") == "simai-services/1":
        for svc in data["services"]:
            svc["since"] = "Thu 2026-01-01 00:00:00 UTC"
    if data.get("schema") == "simai-service-log/1":
        data["lines"] = ["2026-01-01T00:00:00+0000 simai-stand systemd[1]: Started nginx.service - A high performance web server."]
    for plan in (data, data.get("update") if isinstance(data.get("update"), dict) else {}):
        if plan.get("schema") == "simai-update-plan/1" and plan.get("target") == "env":
            # The update channel answers whatever is published today.
            plan.update(available="9.9.0", update_available=True, blocked=None,
                        notes=[{"version": "9.9.0", "text": "- An example release note."}])
    if "job_id" in d:
        d["job_id"] = "0" * 24
    if "job_id" in data:
        data["job_id"] = "0" * 24
        if "created_at" in data:
            data["created_at"] = "2026-01-01T00:00:00Z"
    if "lines" in data:
        # Dates, times and backup ids change on every run.
        data["lines"] = [re.sub(r"\d{8}-\d{6}", "20260101-000000", re.sub(r"corr_id=[0-9A-Za-z-]+", "corr_id=fixture",
                         re.sub(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}", "2026-01-01T00:00:00",
                         re.sub(r"\d{2}/[A-Z][a-z]{2}/\d{4}:\d{2}:\d{2}:\d{2} [+-]\d{4}", "01/Jan/2026:00:00:00 +0000", l))))
                         for l in data["lines"]]
    f.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
    files[f.name] = {"sha256": hashlib.sha256(f.read_bytes()).hexdigest(), "status": d["status"]}
    print(f"[stand] recorded {f.name}: {d['status']}")
manifest = {"schema": "simai-panel-fixtures/1", "set_version": set_version,
            "request_schema": "simai-panel-request/1", "answer_schema": "simai-panel-answer/1",
            "simai_env": env_version, "files": files}
(root / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"[stand] manifest: set {set_version}, {len(files)} files")
PY
}

case "${1:-}" in
  up)
    command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
    if ! running; then
      docker build -q --build-arg "UBUNTU=${UBUNTU}" --build-arg "PHP=${PHP}" \
        -t "simai-e2e:${UBUNTU}" "${ROOT_DIR}/testing/containers" >/dev/null
      docker rm -f "$NAME" >/dev/null 2>&1 || true
      docker run -d --name "$NAME" --hostname simai-stand --privileged --cgroupns=host \
        -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
        -p "127.0.0.1:${HTTP_PORT}:80" -p "127.0.0.1:${HTTPS_PORT}:443" -p "127.0.0.1:${SSH_PORT}:22" \
        "simai-e2e:${UBUNTU}" >/dev/null
      for _ in $(seq 60); do
        in_stand systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded' && break
        sleep 2
      done
    fi
    sync_code
    seed
    echo "[stand] up: http://127.0.0.1:${HTTP_PORT} (Host header), ssh 127.0.0.1:${SSH_PORT}"
    ;;
  sync) need_running; sync_code ;;
  record) record ;;
  gate) need_running; gate ;;
  shell) need_running; docker exec -it "$NAME" bash -l ;;
  cli) need_running; shift; docker exec "$NAME" /root/simai-env/simai-admin.sh "$@" ;;
  status)
    if running; then echo "[stand] running: ${NAME} (ubuntu ${UBUNTU})"; in_stand cat /root/simai-env/VERSION; else echo "[stand] not running"; fi
    ;;
  down) docker rm -f "$NAME" >/dev/null 2>&1 && echo "[stand] removed" || echo "[stand] not running" ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
