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

if ! update_ref_is_valid "$REF"; then
  echo "Invalid update ref: ${REF} (expected refs/heads/<branch> or refs/tags/<tag>)" >&2
  exit 1
fi
if ! update_repo_is_allowed "$REPO_HTTP_URL"; then
  echo "Refusing update repo: ${REPO_HTTP_URL}" >&2
  echo "Use the official repo or set SIMAI_UPDATE_ALLOW_CUSTOM_REPO=yes for a GitHub fork you trust." >&2
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

update_safe_remove_transaction_dir() {
  local path="$1" parent="$2" base="$3" name
  [[ -n "$path" && "$path" != "/" && "$path" != "$parent" ]] || return 1
  [[ "$(dirname "$path")" == "$parent" ]] || return 1
  name=$(basename "$path")
  case "$name" in
    ".${base}.stage."*|".${base}.rollback."*|".${base}.failed."*) ;;
    *) return 1 ;;
  esac
  [[ ! -L "$path" ]] || return 1
  rm -rf -- "$path"
}

update_post_apply_smoke() {
  local root="$1" required
  for required in simai-env.sh simai-admin.sh update.sh; do
    if [[ ! -x "${root}/${required}" ]]; then
      echo "Post-update smoke failed: ${required} is missing or not executable" >&2
      return 1
    fi
    if ! bash -n "${root}/${required}"; then
      echo "Post-update smoke failed: bash -n ${required}" >&2
      return 1
    fi
  done
  if [[ ! -f "${root}/scripts/ci/smoke.sh" ]]; then
    echo "Post-update smoke failed: scripts/ci/smoke.sh is missing" >&2
    return 1
  fi
  (cd "$root" && bash scripts/ci/smoke.sh)
}

check_supported_os

TMP_DIR=$(mktemp -d)
INSTALL_PARENT=$(cd "$(dirname "$INSTALL_DIR")" && pwd)
INSTALL_BASE=$(basename "$INSTALL_DIR")
TRANSACTION_ID="$(date +%Y%m%d-%H%M%S)-$$"
STAGE_DIR="${INSTALL_PARENT}/.${INSTALL_BASE}.stage.${TRANSACTION_ID}"
ROLLBACK_DIR="${INSTALL_PARENT}/.${INSTALL_BASE}.rollback.${TRANSACTION_ID}"
FAILED_DIR="${INSTALL_PARENT}/.${INSTALL_BASE}.failed.${TRANSACTION_ID}"
cleanup() {
  local rc=$?
  if [[ -e "$STAGE_DIR" ]]; then
    update_safe_remove_transaction_dir "$STAGE_DIR" "$INSTALL_PARENT" "$INSTALL_BASE" || true
  fi
  rm -rf -- "$TMP_DIR"
  return "$rc"
}
trap cleanup EXIT

TARGET_SHA="$(update_resolve_ref_sha "$REF" "$REPO_HTTP_URL" 2>/dev/null || true)"
if [[ -z "$TARGET_SHA" && "${SIMAI_UPDATE_ALLOW_UNRESOLVED_REF:-no}" != "yes" ]]; then
  echo "Could not resolve ${REF} to a commit SHA for ${REPO_HTTP_URL}" >&2
  echo "Install git/network access or set SIMAI_UPDATE_ALLOW_UNRESOLVED_REF=yes to allow a ref tarball fallback." >&2
  exit 1
fi
TARBALL_URL="$(update_tarball_url "$REF" "$REPO_HTTP_URL")"

PREV_VERSION="(unknown)"
if [[ -f "${INSTALL_DIR}/VERSION" ]]; then
  PREV_VERSION=$(cat "${INSTALL_DIR}/VERSION")
fi
BACKUP_ARCHIVE=""
if [[ -d "$INSTALL_DIR" ]]; then
  if ! mkdir -p "$UPDATE_BACKUP_ROOT"; then
    echo "Cannot create backup directory ${UPDATE_BACKUP_ROOT}; update aborted" >&2
    exit 1
  fi
  BACKUP_ARCHIVE="${UPDATE_BACKUP_ROOT}/simai-env-preupdate-${TRANSACTION_ID}.tar.gz"
  if ! tar -czf "$BACKUP_ARCHIVE" -C "$INSTALL_DIR" .; then
    rm -f -- "$BACKUP_ARCHIVE"
    echo "Failed to create pre-update backup at ${BACKUP_ARCHIVE}; update aborted" >&2
    exit 1
  fi
  echo "Pre-update backup created: ${BACKUP_ARCHIVE}"
fi

echo "Staging simai-env update (ref: ${REF}) for ${INSTALL_DIR}..."
if [[ -n "$TARGET_SHA" ]]; then
  echo "Resolved target commit: ${TARGET_SHA}"
fi
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/simai-env.tar.gz"
update_extract_archive "$TMP_DIR/simai-env.tar.gz" "$TMP_DIR"
SRC_DIR=$(update_find_extracted_source_dir "$TMP_DIR" || true)
if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
  echo "Could not locate extracted sources" >&2
  exit 1
fi

mkdir "$STAGE_DIR"
cp -R "${SRC_DIR}/." "$STAGE_DIR/"
chmod +x "$STAGE_DIR/simai-env.sh" "$STAGE_DIR/simai-admin.sh" "$STAGE_DIR/update.sh"
update_post_apply_smoke "$STAGE_DIR"

if [[ -e "$INSTALL_DIR" ]]; then
  if ! mv -- "$INSTALL_DIR" "$ROLLBACK_DIR"; then
    echo "Failed to move the current installation into rollback position" >&2
    exit 1
  fi
fi
if ! mv -- "$STAGE_DIR" "$INSTALL_DIR"; then
  echo "Failed to activate staged update; restoring previous installation" >&2
  if [[ -e "$ROLLBACK_DIR" ]]; then
    mv -- "$ROLLBACK_DIR" "$INSTALL_DIR" || {
      echo "CRITICAL: automatic rollback failed; previous tree remains at ${ROLLBACK_DIR}" >&2
      exit 1
    }
  fi
  exit 1
fi

if ! update_post_apply_smoke "$INSTALL_DIR"; then
  echo "Post-update smoke failed; restoring previous installation" >&2
  mv -- "$INSTALL_DIR" "$FAILED_DIR" || {
    echo "CRITICAL: cannot move failed installation aside" >&2
    exit 1
  }
  if [[ -e "$ROLLBACK_DIR" ]]; then
    mv -- "$ROLLBACK_DIR" "$INSTALL_DIR" || {
      echo "CRITICAL: automatic rollback failed; previous tree remains at ${ROLLBACK_DIR}" >&2
      exit 1
    }
    update_post_apply_smoke "$INSTALL_DIR" || {
      echo "CRITICAL: restored installation failed smoke; inspect ${INSTALL_DIR}" >&2
      exit 1
    }
  fi
  update_safe_remove_transaction_dir "$FAILED_DIR" "$INSTALL_PARENT" "$INSTALL_BASE" || true
  exit 1
fi

if [[ -e "$ROLLBACK_DIR" ]]; then
  update_safe_remove_transaction_dir "$ROLLBACK_DIR" "$INSTALL_PARENT" "$INSTALL_BASE"
fi

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
  echo "Recovery archive: ${BACKUP_ARCHIVE}"
fi
echo "Run scripts from ${INSTALL_DIR} as usual."
