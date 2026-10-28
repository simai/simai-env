#!/usr/bin/env bash
# Runs container end-to-end tests against the working tree.
#
#   testing/containers/run.sh                      # default cases on 24.04
#   testing/containers/run.sh --ubuntu 22.04 all   # every case on 22.04
#   testing/containers/run.sh adopt deploy         # named cases, in order
#
# Needs Docker (privileged containers, systemd inside). Each case prints
# PASS/FAIL lines and ends with failures=<n>; the runner exits non-zero if any
# case failed. Cases that create sites do so inside the container only.
set -uo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UBUNTU=24.04
PHP=8.3
NAME="simai-env-e2e-$(date +%s)-$$"
DEFAULT_CASES=(p0_tests p1_tests upgrade_e2e dispatch_e2e config_e2e menu_e2e nginx_tests backup_tests migrate_e2e iso_e2e lara_e2e sftp_e2e owner_e2e moveq_e2e sot_e2e pg_e2e adopt_e2e deploy_e2e node_e2e host_e2e static_e2e app_e2e panel_e2e)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ubuntu) UBUNTU="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ "$UBUNTU" == 22.04 ]] && PHP=8.1
[[ "$UBUNTU" == 26.04 ]] && PHP=8.5
cases=("$@")
[[ ${#cases[@]} -eq 0 ]] && cases=("${DEFAULT_CASES[@]}")
[[ "${cases[0]}" == all ]] && cases=("${DEFAULT_CASES[@]}")

command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
echo "[e2e] building image for ubuntu ${UBUNTU} (php ${PHP})"
docker build -q --build-arg "UBUNTU=${UBUNTU}" --build-arg "PHP=${PHP}" \
  -t "simai-e2e:${UBUNTU}" "${ROOT_DIR}/testing/containers" >/dev/null || exit 1

if docker container inspect "$NAME" >/dev/null 2>&1; then
  echo "Refusing to replace an existing container: ${NAME}" >&2
  exit 2
fi
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  "simai-e2e:${UBUNTU}" >/dev/null || exit 1
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
deadline=$((SECONDS + 120))
until docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do
  if (( SECONDS >= deadline )); then
    echo 'systemd did not start within 120 seconds' >&2
    docker logs "$NAME" | tail -30
    exit 1
  fi
  sleep 2
done

# Freeze the code snapshot. Exclude Git history, operator secrets and local
# continuity/output so tests cannot read them or observe edits midway through.
snapshot=$(mktemp -d) || exit 1
tar -C "$ROOT_DIR" --exclude=.git --exclude=source --exclude=work --exclude=mirai \
  --exclude=graph.json --exclude=testing/test-config.env --exclude='.env*' \
  --exclude=node_modules --exclude=.simai --exclude=.playwright-cli --exclude=output --exclude=build --exclude=dist \
  -cf "${snapshot}.tar" . || exit 1
# Through a file: in a pipe the reader may stop at the end-of-archive marker
# while the writer still flushes padding, and pipefail turns that into a failure.
tar -xf "${snapshot}.tar" -C "$snapshot" && rm -f "${snapshot}.tar" || exit 1
docker exec "$NAME" mkdir /src
docker cp "${snapshot}/." "${NAME}:/src" >/dev/null || exit 1
candidate=$(python3 "${ROOT_DIR}/testing/containers/receipt.py" digest "$snapshot")
# Previous release for upgrade tests (upgrade_e2e); history stays out of /src.
BASELINE_REF="${SIMAI_E2E_BASELINE_REF:-v1.14.0}"
if git -C "$ROOT_DIR" rev-parse -q --verify "${BASELINE_REF}^{commit}" >/dev/null; then
  docker exec "$NAME" mkdir -p /opt/simai-baseline
  git -C "$ROOT_DIR" archive "$BASELINE_REF" | docker exec -i "$NAME" tar -x -C /opt/simai-baseline
fi
rm -rf "$snapshot"
artifact_dir="${ROOT_DIR}/source/output/${NAME}"
mkdir -p "$artifact_dir"
echo "[e2e] receipts: ${artifact_dir}"

failed=()
for case_name in "${cases[@]}"; do
  script="/src/testing/containers/cases/${case_name}.sh"
  if ! docker exec "$NAME" test -f "$script"; then
    echo "[e2e] unknown case: ${case_name}"
    failed+=("$case_name")
    continue
  fi
  # Cases are written for PHP 8.3; 22.04 ships 8.1 as its default version.
  # 26.04 has only its own PHP 8.5 until ondrej/php covers it, so the
  # "newer PHP" cases (8.4) use 8.5 there.
  newer=8.4; [[ "$UBUNTU" == 26.04 ]] && newer=8.5
  docker exec "$NAME" bash -c 'sed -e "$1" -e "$2" "$3" > /case.sh' _ "s/8\\.3/${PHP}/g" "s/8\\.4/${newer}/g" "$script"
  echo "[e2e] ${case_name}"
  out="${artifact_dir}/${case_name}.log"
  docker exec "$NAME" rm -f /tmp/simai-test-executions.jsonl
  docker exec -e SIMAI_EXECUTION_RECEIPT=/tmp/simai-test-executions.jsonl "$NAME" bash /case.sh >"$out" 2>&1
  rc=$?
  executions="${artifact_dir}/${case_name}.executions.jsonl"
  docker cp "${NAME}:/tmp/simai-test-executions.jsonl" "$executions" >/dev/null 2>&1 || true
  python3 "${ROOT_DIR}/testing/containers/receipt.py" case "${artifact_dir}/${case_name}.json" "$candidate" "$UBUNTU" "$case_name" "$rc" "$out" "$executions"
  grep -E '^(FAIL|SKIP|INFO)' "$out" | sed 's/^/    /'
  printf '    %s (%s passed, rc=%s)\n' "$(grep -E '^failures=' "$out" | tail -n1)" "$(grep -c '^PASS' "$out")" "$rc"
  (( rc == 0 )) || failed+=("$case_name")
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "[e2e] failed cases: ${failed[*]}"
  exit 1
fi
echo "[e2e] all requested cases passed"
