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
CASES_DIR="${ROOT_DIR}/testing/containers/cases"
UBUNTU=24.04
PHP=8.3
NAME=simai-e2e
DEFAULT_CASES=(p0_tests p1_tests nginx_tests backup_tests migrate_e2e iso_e2e lara_e2e sftp_e2e owner_e2e moveq_e2e sot_e2e pg_e2e adopt_e2e deploy_e2e)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ubuntu) UBUNTU="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
[[ "$UBUNTU" == 22.04 ]] && PHP=8.1
cases=("$@")
[[ ${#cases[@]} -eq 0 ]] && cases=("${DEFAULT_CASES[@]}")
[[ "${cases[0]}" == all ]] && cases=("${DEFAULT_CASES[@]}")

command -v docker >/dev/null || { echo "docker is required" >&2; exit 2; }
echo "[e2e] building image for ubuntu ${UBUNTU} (php ${PHP})"
docker build -q --build-arg "UBUNTU=${UBUNTU}" --build-arg "PHP=${PHP}" \
  -t "simai-e2e:${UBUNTU}" "${ROOT_DIR}/testing/containers" >/dev/null || exit 1

docker rm -f "$NAME" >/dev/null 2>&1
docker run -d --name "$NAME" --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "${ROOT_DIR}":/src:ro "simai-e2e:${UBUNTU}" >/dev/null || exit 1
trap 'docker rm -f "$NAME" >/dev/null 2>&1' EXIT
until docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; do sleep 2; done

failed=()
for case_name in "${cases[@]}"; do
  script="${CASES_DIR}/${case_name}.sh"
  if [[ ! -f "$script" ]]; then
    echo "[e2e] unknown case: ${case_name}"
    failed+=("$case_name")
    continue
  fi
  # Cases are written for PHP 8.3; 22.04 ships 8.1 as its default version.
  tmp=$(mktemp) || exit 1
  sed "s/8\\.3/${PHP}/g" "$script" >"$tmp"
  docker cp "$tmp" "${NAME}:/case.sh" >/dev/null
  rm -f "$tmp"
  echo "[e2e] ${case_name}"
  out=$(mktemp) || exit 1
  docker exec "$NAME" bash /case.sh >"$out" 2>&1
  rc=$?
  grep -E '^(FAIL|SKIP|INFO)' "$out" | sed 's/^/    /'
  printf '    %s (%s passed, rc=%s)\n' "$(grep -E '^failures=' "$out" | tail -n1)" "$(grep -c '^PASS' "$out")" "$rc"
  (( rc == 0 )) || failed+=("$case_name")
  rm -f "$out"
done

if [[ ${#failed[@]} -gt 0 ]]; then
  echo "[e2e] failed cases: ${failed[*]}"
  exit 1
fi
echo "[e2e] all requested cases passed"
