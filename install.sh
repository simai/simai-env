#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/simai/simai-env}
REPO_BRANCH=${REPO_BRANCH:-${VERSION:-main}}           # branch name (VERSION kept for backward compatibility override)
REF=${REF:-refs/heads/${REPO_BRANCH}}  # override to pin a tag: REF=refs/tags/vX.Y.Z (see GitHub releases/tags)
INSTALL_DIR=${INSTALL_DIR:-/root/simai-env}

if [[ $EUID -ne 0 && "$INSTALL_DIR" == /root/* ]]; then
  echo "Please run as root or set INSTALL_DIR to a writable path" >&2
  exit 1
fi

read_os_release() {
  if [[ -r /etc/os-release ]]; then
    mapfile -t _os < <(
      ( . /etc/os-release
        printf '%s\n' "${ID:-unknown}" "${VERSION_ID:-unknown}" "${PRETTY_NAME:-}" )
      )
    OS_ID="${_os[0]:-unknown}"
    OS_VERSION_ID="${_os[1]:-unknown}"
    OS_PRETTY="${_os[2]:-}"
  else
    OS_ID="unknown"
    OS_VERSION_ID="unknown"
    OS_PRETTY=""
  fi
  if [[ -z "$OS_PRETTY" ]]; then
    OS_PRETTY="${OS_ID} ${OS_VERSION_ID}"
  fi
}

supported_matrix_string() {
  echo "Ubuntu 22.04 LTS, Ubuntu 24.04 LTS"
}

is_supported_os() {
  [[ "$OS_ID" == "ubuntu" && ( "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" ) ]]
}

check_supported_os() {
  read_os_release
  if is_supported_os; then
    echo "OS: ${OS_PRETTY} — supported"
    return
  fi
  echo "OS: ${OS_PRETTY} — NOT supported"
  echo "Supported OS: $(supported_matrix_string)"
  exit 1
}

print_banner() {
  if [[ "${SIMAI_INSTALL_NO_BANNER:-0}" == "1" ]]; then
    return
  fi
  if [[ ! -t 1 || ! -r /dev/tty || ! -w /dev/tty ]]; then
    return
  fi
  local cols
  cols=$(tput cols 2>/dev/null || echo 80)
  if [[ "$cols" -lt 70 ]]; then
    echo "SIMAI ENV"
    echo
    return
  fi
  local charset
  charset=$(locale charmap 2>/dev/null || echo "UTF-8")
  if [[ "$charset" != "UTF-8" ]]; then
    echo "SIMAI ENV"
    echo
    return
  fi
  cat <<'BANNER'
███████╗██╗███╗   ███╗ █████╗ ██╗    ███████╗███╗   ██╗██╗   ██╗
██╔════╝██║████╗ ████║██╔══██╗██║    ██╔════╝████╗  ██║██║   ██║
███████╗██║██╔████╔██║███████║██║    █████╗  ██╔██╗ ██║██║   ██║
╚════██║██║██║╚██╔╝██║██╔══██║██║    ██╔══╝  ██║╚██╗██║╚██╗ ██╔╝
███████║██║██║ ╚═╝ ██║██║  ██║██║    ███████╗██║ ╚████║ ╚████╔╝
╚══════╝╚═╝╚═╝     ╚═╝╚═╝  ╚═╝╚═╝    ╚══════╝╚═╝  ╚═══╝  ╚═══╝

BANNER
}

print_banner
check_supported_os

TMP_DIR=$(mktemp -d)
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

TARBALL_URL="${REPO_URL}/archive/${REF}.tar.gz"

echo "Downloading simai-env (branch: ${REPO_BRANCH})..."
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/simai-env.tar.gz"

echo "Unpacking..."
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

if [[ "$MODE" != "scripts" ]]; then
  if [[ $EUID -eq 0 ]]; then
    if [[ ! -f /etc/simai-env/profiles.enabled ]]; then
      has_simai=0
      if find /etc/nginx/sites-available -maxdepth 1 -type f -name "*.conf" -print -quit 2>/dev/null | grep -q .; then
        if grep -qE '^[[:space:]]*# simai-domain:' /etc/nginx/sites-available/*.conf 2>/dev/null; then
          has_simai=1
        fi
      fi
      if [[ $has_simai -eq 0 ]]; then
        echo "Initializing profile activation (core profiles enabled by default)..."
        if ! "${INSTALL_DIR}/simai-admin.sh" profile init --mode core; then
          echo "WARNING: Profile activation init failed. You can run later:"
          echo "  sudo ${INSTALL_DIR}/simai-admin.sh profile init --mode core"
        fi
      else
        echo "Detected existing simai-managed sites; skipping profile activation init (legacy mode kept)."
      fi
    fi
  else
    echo "Skipping profile activation init (not running as root). Run later as root:"
    echo "  sudo ${INSTALL_DIR}/simai-admin.sh profile init --mode core"
  fi
fi

if [[ "${SIMAI_INSTALL_NO_MENU:-0}" != "1" && -t 1 && -r /dev/tty && -w /dev/tty ]]; then
  echo "Launching admin menu..."
  MENU_LAUNCHED=1
  exec "${INSTALL_DIR}/simai-admin.sh" menu </dev/tty >/dev/tty 2>/dev/tty
fi

if [[ $MENU_LAUNCHED -eq 0 ]]; then
  echo "Next: open the admin menu: sudo ${INSTALL_DIR}/simai-admin.sh menu"
fi
