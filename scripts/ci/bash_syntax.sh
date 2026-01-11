#!/usr/bin/env bash
set -euo pipefail

files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < <(find . -type f \( -name '*.sh' -o -name '*.profile.sh' \) -not -path './.git/*' -print0)

if [[ ${#files[@]} -eq 0 ]]; then
  echo "No shell files found"
  exit 0
fi

printf "%s\0" "${files[@]}" | xargs -0 -n1 -P4 bash -n
echo "bash -n passed for ${#files[@]} file(s)"
