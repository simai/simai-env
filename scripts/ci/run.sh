#!/usr/bin/env bash
set -euo pipefail

echo "[ci] bash syntax check"
bash scripts/ci/bash_syntax.sh

echo "[ci] shellcheck"
bash scripts/ci/shellcheck.sh

echo "[ci] smoke invariants"
bash scripts/ci/smoke.sh
