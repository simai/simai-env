#!/usr/bin/env bash
set -euo pipefail

echo "[ci] bash syntax check"
bash scripts/ci/bash_syntax.sh

echo "[ci] shellcheck"
bash scripts/ci/shellcheck.sh

echo "[ci] smoke invariants"
bash scripts/ci/smoke.sh

echo "[ci] correction regressions"
bash scripts/ci/correction_regression.sh

echo "[ci] command coverage"
/usr/bin/python3 scripts/ci/command_coverage.py --check >/dev/null

if (( BASH_VERSINFO[0] >= 4 )); then
  echo "[ci] registry dispatch harness"
  bash scripts/ci/registry_dispatch_harness.sh
else
  echo "[ci] registry dispatch harness skipped locally (requires Bash 4+); required on Linux runtime"
fi
