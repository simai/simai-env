#!/usr/bin/env bash
set -euo pipefail

SHELLCHECK_BIN="${SHELLCHECK_BIN:-$(command -v shellcheck || true)}"

if [[ -z "$SHELLCHECK_BIN" ]]; then
  echo "shellcheck not found"
  exit 1
fi

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(
  find . \
    \( -path './.git' -o -path '*/node_modules' -o -path '*/vendor' \) -prune -o \
    -type f \( -name '*.sh' -o -name '*.profile.sh' \) -print0
)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No shell files found"
  exit 0
fi

echo "ShellCheck (warnings as errors)"
"$SHELLCHECK_BIN" -S warning -f gcc "${files[@]}"
