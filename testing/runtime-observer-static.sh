#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

bash -n "${ROOT_DIR}/admin/commands/runtime_observer.sh"

expected=(init start snapshot status finish doctor)
for command in "${expected[@]}"; do
  grep -Eq "^register_cmd observer ${command} " "${ROOT_DIR}/admin/commands/runtime_observer.sh" || {
    echo "Missing observer command registration: ${command}" >&2
    exit 1
  }
done

grep -Fq -- "--exclude='/public/bitrix/'" "${ROOT_DIR}/admin/commands/runtime_observer.sh"
grep -Fq -- "--exclude='/public/upload/'" "${ROOT_DIR}/admin/commands/runtime_observer.sh"
grep -Fq -- "SHA2(VALUE,256)" "${ROOT_DIR}/admin/commands/runtime_observer.sh"

echo 'runtime-observer static checks: PASS'
