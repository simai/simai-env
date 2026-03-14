#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "[gate] shell syntax checks"
scripts=()
while IFS= read -r script_path; do
  scripts+=("${script_path}")
done < <(find "${ROOT_DIR}" -type f -name "*.sh" \
  -not -path "${ROOT_DIR}/.git/*" \
  -not -path "${ROOT_DIR}/testing/test-config.env")
if [[ ${#scripts[@]} -eq 0 ]]; then
  echo "[fail] no shell scripts found"
  exit 1
fi
bash -n "${scripts[@]}"

echo "[gate] regression full"
bash "${ROOT_DIR}/testing/run-regression.sh" full

echo "[ok] release gate passed"
