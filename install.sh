#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/simai/simai-env}
VERSION=${VERSION:-main}           # branch name
REF=${REF:-refs/heads/${VERSION}}  # override to pin a tag: REF=refs/tags/vX.Y.Z (see GitHub releases/tags)
INSTALL_DIR=${INSTALL_DIR:-/root/simai-env}

if [[ $EUID -ne 0 && "$INSTALL_DIR" == /root/* ]]; then
  echo "Please run as root or set INSTALL_DIR to a writable path" >&2
  exit 1
fi

check_supported_os() {
  local GREEN="" RED="" RESET=""
  if [[ -t 1 && -r /dev/tty && -w /dev/tty ]]; then
    GREEN=$'\e[32m'; RED=$'\e[31m'; RESET=$'\e[0m'
  fi
  if [[ ! -f /etc/os-release ]]; then
    printf "%s[ERROR] Cannot detect OS%s\n" "$RED" "$RESET" >&2
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  local matrix="Ubuntu 20.04/22.04/24.04"
  if [[ ${ID} == "ubuntu" ]]; then
    case ${VERSION_ID} in
      "20.04"|"22.04"|"24.04")
        printf "%s[OK] OS: %s (%s %s %s) — supported%s\n" "$GREEN" "${PRETTY_NAME:-Ubuntu}" "${ID}" "${VERSION_ID}" "${VERSION_CODENAME:-}" "$RESET" >&2
        return
        ;;
    esac
  fi
  printf "%s[ERROR] OS: %s (%s %s %s) — unsupported. Supported: %s%s\n" "$RED" "${PRETTY_NAME:-Unknown}" "${ID:-unknown}" "${VERSION_ID:-unknown}" "${VERSION_CODENAME:-}" "${matrix}" "$RESET" >&2
  exit 1
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
SRC_DIR=$(find "$TMP_DIR" -maxdepth 1 -type d -name "simai-env-*" | head -n 1)

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

MODE="${SIMAI_INSTALL_MODE:-full}"
NO_BOOT="${SIMAI_INSTALL_NO_BOOTSTRAP:-0}"
MENU_LAUNCHED=0

if [[ "$NO_BOOT" != "1" && "$MODE" != "scripts" ]]; then
  echo "[1/3] Running bootstrap (packages and services)..."
  export DEBIAN_FRONTEND=noninteractive
  if ! "${INSTALL_DIR}/simai-env.sh" bootstrap --php 8.2 --mysql percona --node-version 20 --silent; then
    echo "Bootstrap failed. Check /var/log/simai-env.log for details." >&2
    exit 1
  fi
  echo "[2/3] Bootstrap steps complete."
  echo "[3/3] Bootstrap finished."
else
  echo "Bootstrap skipped (SIMAI_INSTALL_MODE=${MODE}, SIMAI_INSTALL_NO_BOOTSTRAP=${NO_BOOT})."
  echo "You can run it later: sudo ${INSTALL_DIR}/simai-env.sh bootstrap --php 8.2 --mysql percona --node-version 20"
fi

if [[ "${SIMAI_INSTALL_NO_MENU:-0}" != "1" && -t 1 && -r /dev/tty && -w /dev/tty ]]; then
  echo "Launching admin menu..."
  MENU_LAUNCHED=1
  exec "${INSTALL_DIR}/simai-admin.sh" menu </dev/tty >/dev/tty 2>/dev/tty
fi

if [[ $MENU_LAUNCHED -eq 0 ]]; then
  echo "Next: open the admin menu: sudo ${INSTALL_DIR}/simai-admin.sh menu"
fi
