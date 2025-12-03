#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/simai/laravel-env}
VERSION=${VERSION:-main}           # branch name
REF=${REF:-refs/heads/${VERSION}}  # override to pin a tag: REF=refs/tags/v1.0.0
INSTALL_DIR=${INSTALL_DIR:-/root/simai-env}

if [[ $EUID -ne 0 && "$INSTALL_DIR" == /root/* ]]; then
  echo "Please run as root or set INSTALL_DIR to a writable path" >&2
  exit 1
fi

check_supported_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Cannot detect OS" >&2
    exit 1
  fi
  . /etc/os-release
  if [[ ${ID} != "ubuntu" ]]; then
    echo "Supported only on Ubuntu 20.04/22.04/24.04" >&2
    exit 1
  fi
  case ${VERSION_ID} in
    "20.04"|"22.04"|"24.04") ;;
    *) echo "Unsupported Ubuntu version ${VERSION_ID}" >&2; exit 1 ;;
  esac
}

check_supported_os

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TARBALL_URL="${REPO_URL}/archive/${REF}.tar.gz"

echo "Downloading simai-env (${VERSION})..."
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/simai-env.tar.gz"

echo "Unpacking..."
tar -xzf "$TMP_DIR/simai-env.tar.gz" -C "$TMP_DIR"
SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "laravel-env-*" | head -n 1)

if [[ -z "${SRC_DIR}" || ! -d "${SRC_DIR}" ]]; then
  echo "Could not locate extracted sources" >&2
  exit 1
fi

mkdir -p "$INSTALL_DIR"
cp -R "${SRC_DIR}/." "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/simai-env.sh"
chmod +x "$INSTALL_DIR/simai-admin.sh"
chmod +x "$INSTALL_DIR/update.sh"

echo "Installed to $INSTALL_DIR"
echo "Run: sudo $INSTALL_DIR/simai-env.sh --domain example.com --project-name myapp --db-pass secret"
