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
  rm -f "${FIXTURES}"/*.json
  # name, owner (JSON), command, args (JSON)
  local -a requests=(
    "self-describe|null|self:describe|{}"
    "self-describe.owner-demo|\"demo\"|self:describe|{}"
    "self-commands|null|self:commands|{}"
    "refused.owner-scope|\"demo\"|site:describe|{\"domain\":\"demo-php.test\"}"
    "refused.not-allowed|null|site:add|{\"domain\":\"x.test\"}"
  )
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
  # Every answer must be valid JSON; a recording with stray output is useless.
  python3 - "$FIXTURES" <<'PY'
import json, pathlib, sys
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.json")):
    d = json.loads(f.read_text())
    print(f"[stand] recorded {f.name}: {d['status']}")
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
