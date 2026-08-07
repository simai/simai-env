#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "$TEST_DIR"' EXIT

export SIMAI_ENV_ROOT="$ROOT_DIR"
export ADMIN_DIR="$ROOT_DIR/admin"
export SCRIPT_DIR="$ROOT_DIR"
export LOG_FILE="$TEST_DIR/test.log"

source "$ROOT_DIR/admin/core.sh"
source "$ROOT_DIR/admin/lib/site_utils.sh"

cp "$ROOT_DIR/templates/nginx-laravel.conf" "$TEST_DIR/input.conf"

site_frame_policy_render_file "$TEST_DIR/input.conf" "$TEST_DIR/any.conf" any
grep -Fq 'Content-Security-Policy "frame-ancestors *" always;' "$TEST_DIR/any.conf"
! grep -Fq 'X-Frame-Options' "$TEST_DIR/any.conf"

site_frame_policy_render_file "$TEST_DIR/any.conf" "$TEST_DIR/same-origin.conf" same-origin
grep -Fq 'X-Frame-Options "SAMEORIGIN" always;' "$TEST_DIR/same-origin.conf"
! grep -Fq 'frame-ancestors *' "$TEST_DIR/same-origin.conf"
[[ $(grep -c 'simai-frame-policy-start' "$TEST_DIR/same-origin.conf") -eq 1 ]]

site_frame_policy_render_file "$TEST_DIR/same-origin.conf" "$TEST_DIR/any-again.conf" any
[[ $(grep -c 'simai-frame-policy-start' "$TEST_DIR/any-again.conf") -eq 1 ]]

echo "Frame policy checks passed"
