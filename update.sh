#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/simai/simai-env}
INSTALL_DIR=${INSTALL_DIR:-/root/simai-env}
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "${SCRIPT_DIR}/lib/platform.sh"
source "${SCRIPT_DIR}/lib/update_channel.sh"
if [[ -f /etc/simai-env.conf ]]; then
  # shellcheck disable=SC1091
  source /etc/simai-env.conf
fi

REPO_BRANCH=${SIMAI_UPDATE_BRANCH:-${REPO_BRANCH:-main}}
REF=${SIMAI_UPDATE_REF:-${REF:-$(update_ref_default)}}
UPDATE_BACKUP_ROOT=${SIMAI_UPDATE_BACKUP_DIR:-/root/simai-backups}
REPO_HTTP_URL=$(update_repo_http_url "${REPO_URL:-https://github.com/simai/simai-env}")

if [[ ! "$REF" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]]; then
  echo "Invalid update ref: ${REF} (expected refs/heads/<branch> or refs/tags/<tag>)" >&2
  exit 1
fi

if [[ $EUID -ne 0 && "$INSTALL_DIR" == /root/* ]]; then
  echo "Please run as root or set INSTALL_DIR to a writable path" >&2
  exit 1
fi

check_supported_os() {
  platform_detect_os
  local matrix
  matrix=$(platform_supported_matrix_string)
  if platform_is_supported_os; then
    echo "OS: ${PLATFORM_OS_PRETTY} — supported"
    return
  fi
  echo "OS: ${PLATFORM_OS_PRETTY} — NOT supported"
  echo "Supported OS: ${matrix}"
  exit 1
}

check_supported_os

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TARGET_SHA="$(update_resolve_ref_sha "$REF" "$REPO_HTTP_URL" 2>/dev/null || true)"
TARBALL_URL="$(update_tarball_url "$REF" "$REPO_HTTP_URL")"

PREV_VERSION="(unknown)"
if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
  PREV_VERSION=$(cat "${INSTALL_DIR}/VERSION")
fi
BACKUP_ARCHIVE=""
if [[ -d "$INSTALL_DIR" ]]; then
  if mkdir -p "${UPDATE_BACKUP_ROOT:-/root/simai-backups}" 2>/dev/null; then
    ts=$(date +%Y%m%d-%H%M%S)
    BACKUP_ARCHIVE="${UPDATE_BACKUP_ROOT:-/root/simai-backups}/simai-env-preupdate-${ts}.tar.gz"
    if tar -czf "$BACKUP_ARCHIVE" -C "$INSTALL_DIR" .; then
      echo "Pre-update backup created: ${BACKUP_ARCHIVE}"
    else
      echo "Warning: failed to create pre-update backup at ${BACKUP_ARCHIVE}" >&2
      BACKUP_ARCHIVE=""
    fi
  else
    echo "Warning: cannot create backup directory ${UPDATE_BACKUP_ROOT:-/root/simai-backups}; continuing without backup" >&2
  fi
fi

echo "Updating simai-env (ref: ${REF}) into ${INSTALL_DIR}..."
if [[ -n "$TARGET_SHA" ]]; then
  echo "Resolved target commit: ${TARGET_SHA}"
fi
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/simai-env.tar.gz"
tar --no-same-owner --no-same-permissions -xzf "$TMP_DIR/simai-env.tar.gz" -C "$TMP_DIR"
SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "simai-env-*" | head -n 1)

if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
  echo "Could not locate extracted sources" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp -R "${SRC_DIR}/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/simai-env.sh"
chmod +x "$INSTALL_DIR/simai-admin.sh"
# Clean up deprecated files
rm -f "$INSTALL_DIR/admin/commands/alias.sh"

NEW_VERSION="(unknown)"
if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
  NEW_VERSION=$(cat "${INSTALL_DIR}/VERSION")
fi

if [[ -n "$TARGET_SHA" ]]; then
  echo "Updated to ${REF} (${TARGET_SHA}) at ${INSTALL_DIR}"
else
  echo "Updated to ${REF} at ${INSTALL_DIR}"
fi
echo "Version: ${PREV_VERSION} -> ${NEW_VERSION}"
if [[ -n "$BACKUP_ARCHIVE" ]]; then
  echo "Rollback (manual): rm -rf ${INSTALL_DIR}/* && tar -xzf ${BACKUP_ARCHIVE} -C ${INSTALL_DIR}"
fi
echo "Run scripts from ${INSTALL_DIR} as usual."
