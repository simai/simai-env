#!/usr/bin/env bash
set -euo pipefail

REPO_URL=${REPO_URL:-https://github.com/simai/simai-env}
REPO_BRANCH=${REPO_BRANCH:-${VERSION:-main}}           # branch name (VERSION kept for backward compatibility override)
REF=${REF:-refs/heads/${REPO_BRANCH}}  # override to pin a tag: REF=refs/tags/vX.Y.Z (see GitHub releases/tags)
INSTALL_DIR=${INSTALL_DIR:-/root/simai-env}
MODE="${SIMAI_INSTALL_MODE:-full}"
NO_BOOT="${SIMAI_INSTALL_NO_BOOTSTRAP:-0}"

install_mode_validate() {
  case "$MODE" in
    full|scripts) ;;
    *)
      echo "Invalid SIMAI_INSTALL_MODE: ${MODE} (expected: full or scripts)" >&2
      return 1
      ;;
  esac
  case "$NO_BOOT" in
    0|1) ;;
    *)
      echo "Invalid SIMAI_INSTALL_NO_BOOTSTRAP: ${NO_BOOT} (expected: 0 or 1)" >&2
      return 1
      ;;
  esac
}

install_bootstrap_enabled() {
  [[ "$MODE" == "full" && "$NO_BOOT" == "0" ]]
}

install_profile_init_enabled() {
  [[ "$MODE" == "full" ]]
}

# Test-only source seam: expose pure mode decisions without downloading or
# changing the host. Normal execution never sets this variable.
if [[ "${SIMAI_INSTALL_SOURCE_ONLY:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

install_mode_validate

# Minimal Ubuntu images come without curl (wget | bash still starts this).
if ! command -v curl >/dev/null 2>&1 && [[ $EUID -eq 0 ]] && command -v apt-get >/dev/null 2>&1; then
  echo "Installing curl..."
  DEBIAN_FRONTEND=noninteractive apt-get -qq update >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive apt-get -qq install -y curl ca-certificates >/dev/null 2>&1 || { echo "curl is needed: apt-get install -y curl" >&2; exit 1; }
fi

# bash install.sh --with-panel [--panel-port 8500] [--panel-domain panel.example.com --panel-email ops@example.com]
# is the same as the SIMAI_INSTALL_PANEL_* variables below. Without a domain
# the panel answers on https://<server address>:8500; a domain can be
# attached later in the panel.
WITH_PANEL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --with-panel) WITH_PANEL=1; shift ;;
    --panel-domain) SIMAI_INSTALL_PANEL_DOMAIN="${2:-}"; shift 2 || shift ;;
    --panel-email) SIMAI_INSTALL_PANEL_EMAIL="${2:-}"; shift 2 || shift ;;
    --panel-port) SIMAI_INSTALL_PANEL_PORT="${2:-}"; shift 2 || shift ;;
    --no-firewall) SIMAI_INSTALL_FIREWALL=no; shift ;;
    *) shift ;;
  esac
done
[[ "$WITH_PANEL" == 1 || -n "${SIMAI_INSTALL_PANEL_DOMAIN:-}" || -n "${SIMAI_INSTALL_PANEL_PORT:-}" ]] && SIMAI_INSTALL_PANEL=yes

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
  echo "Ubuntu 22.04 LTS, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS"
}

is_supported_os() {
  [[ "$OS_ID" == "ubuntu" && ( "$OS_VERSION_ID" == "22.04" || "$OS_VERSION_ID" == "24.04" || "$OS_VERSION_ID" == "26.04" ) ]]
}

install_ref_is_valid() {
  local ref="${1:-}"
  [[ "$ref" =~ ^refs/(heads|tags)/[A-Za-z0-9._/-]+$ ]]
}

install_repo_http_url() {
  local url="${1:-https://github.com/simai/simai-env}"
  url="${url%.git}"
  url="${url%/}"
  case "$url" in
    git@github.com:*) url="https://github.com/${url#git@github.com:}" ;;
    ssh://git@github.com/*) url="https://github.com/${url#ssh://git@github.com/}" ;;
  esac
  printf '%s\n' "$url"
}

install_repo_is_allowed() {
  local repo_url="$1"
  [[ "$repo_url" == "https://github.com/simai/simai-env" ]] && return 0
  [[ "${SIMAI_INSTALL_ALLOW_CUSTOM_REPO:-no}" == "yes" ]] && [[ "$repo_url" == https://github.com/*/* ]] && return 0
  return 1
}

install_resolve_ref_sha() {
  local ref="$1" repo_url="$2" sha=""
  if ! command -v git >/dev/null 2>&1; then
    # Minimal images have no git before bootstrap; ask the GitHub API instead.
    local slug="${repo_url#https://github.com/}" short="${ref#refs/heads/}"
    short="${short#refs/tags/}"
    [[ "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    sha=$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${slug}/commits/${short}" 2>/dev/null || true)
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
    printf '%s\n' "$sha"
    return 0
  fi
  sha=$(git ls-remote "$repo_url" "$ref" 2>/dev/null | awk 'NR==1{print $1}')
  if [[ -z "$sha" && "$ref" == refs/tags/* ]]; then
    sha=$(git ls-remote "$repo_url" "${ref}^{}" 2>/dev/null | awk 'NR==1{print $1}')
  fi
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s\n' "$sha"
}

install_archive_entries_safe() {
  local archive="$1"
  local entry_type entry
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    if [[ "$entry" == /* || "$entry" == ".." || "$entry" == ../* || "$entry" == */../* || "$entry" == */.. ]]; then
      echo "Unsafe archive path: ${entry}" >&2
      return 1
    fi
  done < <(tar -tzf "$archive")
  while IFS= read -r entry_type; do
    case "$entry_type" in
      d|-) ;;
      *)
        echo "Unsafe archive entry type: ${entry_type}" >&2
        return 1
        ;;
    esac
  done < <(tar -tvzf "$archive" | awk 'NF {print substr($0,1,1)}')
}

install_find_extracted_source_dir() {
  local dest="$1"
  local found=()
  mapfile -t found < <(find "$dest" -mindepth 1 -maxdepth 1 -type d -name "simai-env-*" | sort)
  if [[ ${#found[@]} -ne 1 ]]; then
    return 1
  fi
  printf '%s\n' "${found[0]}"
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

if ! install_ref_is_valid "$REF"; then
  echo "Invalid install ref: ${REF} (expected refs/heads/<branch> or refs/tags/<tag>)" >&2
  exit 1
fi
REPO_HTTP_URL=$(install_repo_http_url "$REPO_URL")
if ! install_repo_is_allowed "$REPO_HTTP_URL"; then
  echo "Refusing install repo: ${REPO_HTTP_URL}" >&2
  echo "Use the official repo or set SIMAI_INSTALL_ALLOW_CUSTOM_REPO=yes for a GitHub fork you trust." >&2
  exit 1
fi
TARGET_SHA="$(install_resolve_ref_sha "$REF" "$REPO_HTTP_URL" 2>/dev/null || true)"
if [[ -z "$TARGET_SHA" && "${SIMAI_INSTALL_ALLOW_UNRESOLVED_REF:-no}" != "yes" ]]; then
  echo "Could not resolve ${REF} to a commit SHA for ${REPO_HTTP_URL}" >&2
  echo "Check network access to github.com or set SIMAI_INSTALL_ALLOW_UNRESOLVED_REF=yes to allow a ref tarball fallback." >&2
  exit 1
fi
if [[ -n "$TARGET_SHA" ]]; then
  TARBALL_URL="${REPO_HTTP_URL}/archive/${TARGET_SHA}.tar.gz"
else
  TARBALL_URL="${REPO_HTTP_URL}/archive/${REF}.tar.gz"
fi

echo "Downloading simai-env (ref: ${REF})..."
if [[ -n "$TARGET_SHA" ]]; then
  echo "Resolved target commit: ${TARGET_SHA}"
else
  echo "Target commit could not be resolved before bootstrap; using ref tarball."
fi
curl -fsSL "$TARBALL_URL" -o "$TMP_DIR/simai-env.tar.gz"

echo "Unpacking..."
install_archive_entries_safe "$TMP_DIR/simai-env.tar.gz"
tar --no-same-owner --no-same-permissions -xzf "$TMP_DIR/simai-env.tar.gz" -C "$TMP_DIR"
SRC_DIR=$(install_find_extracted_source_dir "$TMP_DIR" || true)

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

MENU_LAUNCHED=0

if install_bootstrap_enabled; then
  echo "[1/3] Running bootstrap (packages and services)..."
  export DEBIAN_FRONTEND=noninteractive
  # SIMAI_INSTALL_PHP / SIMAI_INSTALL_DB: a version or "none" for hosts that
  # run no PHP or MySQL (for example a Node-only service host).
  install_db="${SIMAI_INSTALL_DB:-}"
  # Percona publishes no server packages for Ubuntu 26.04 yet.
  if [[ -z "$install_db" ]]; then
    [[ "$OS_VERSION_ID" == 26.04 ]] && install_db=mysql || install_db=percona
  fi
  bootstrap_args=(--mysql "$install_db" --node-version "${SIMAI_INSTALL_NODE:-22}" --silent)
  [[ -n "${SIMAI_INSTALL_PHP:-}" ]] && bootstrap_args+=(--php "$SIMAI_INSTALL_PHP")
  if ! "${INSTALL_DIR}/simai-env.sh" bootstrap "${bootstrap_args[@]}"; then
    echo "Bootstrap failed. Check /var/log/simai-env.log for details." >&2
    exit 1
  fi
  echo "[2/3] Bootstrap steps complete."
  echo "[3/3] Bootstrap finished."
else
  echo "Bootstrap skipped (SIMAI_INSTALL_MODE=${MODE}, SIMAI_INSTALL_NO_BOOTSTRAP=${NO_BOOT})."
  echo "You can run it later: sudo ${INSTALL_DIR}/simai-env.sh bootstrap --mysql percona --node-version 22"
fi

if install_profile_init_enabled; then
  if [[ $EUID -eq 0 ]]; then
    if [[ ! -f /etc/simai-env/profiles.enabled ]]; then
      has_simai=0
      if find /etc/nginx/sites-available -maxdepth 1 -type f -name "*.conf" -print -quit 2>/dev/null | grep . >/dev/null; then
        if grep -qE '^[[:space:]]*# simai-domain:' /etc/nginx/sites-available/*.conf 2>/dev/null; then
          has_simai=1
        fi
      fi
      if [[ $has_simai -eq 0 ]]; then
        echo "Initializing profile activation (core profiles enabled by default)..."
        if ! "${INSTALL_DIR}/simai-admin.sh" profile init --mode core --confirm yes; then
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

# SIMAI_INSTALL_PANEL=yes installs Larena Panel as its own site right away:
# on the server's address and SIMAI_INSTALL_PANEL_PORT (8500), or at
# SIMAI_INSTALL_PANEL_DOMAIN (SIMAI_INSTALL_PANEL_EMAIL also requests a
# certificate). The end of its output has the first sign-in link.
if [[ "${SIMAI_INSTALL_PANEL:-no}" == yes || -n "${SIMAI_INSTALL_PANEL_DOMAIN:-}" ]]; then
  panel_args=(panel install --confirm yes)
  [[ -n "${SIMAI_INSTALL_PANEL_DOMAIN:-}" ]] && panel_args+=(--domain "$SIMAI_INSTALL_PANEL_DOMAIN")
  [[ -n "${SIMAI_INSTALL_PANEL_EMAIL:-}" ]] && panel_args+=(--ssl-email "$SIMAI_INSTALL_PANEL_EMAIL")
  [[ -n "${SIMAI_INSTALL_PANEL_PORT:-}" ]] && panel_args+=(--port "$SIMAI_INSTALL_PANEL_PORT")
  # A server set up with the panel is a new server: close every port but
  # SSH, the web and the panel's (--no-firewall keeps the firewall as it is).
  if [[ "${SIMAI_INSTALL_FIREWALL:-yes}" != no ]] && ! { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep '^Status: active' >/dev/null; }; then
    echo "Turning on the firewall: SSH, HTTP, HTTPS and the panel port stay open..."
    SIMAI_ADMIN_MENU=0 "${INSTALL_DIR}/simai-admin.sh" self firewall-ensure --confirm yes >/dev/null \
      || echo "WARNING: the firewall was not turned on; later: sudo ${INSTALL_DIR}/simai-admin.sh self firewall-ensure --confirm yes"
  fi
  echo "Installing Larena Panel${SIMAI_INSTALL_PANEL_DOMAIN:+ at ${SIMAI_INSTALL_PANEL_DOMAIN}}..."
  if "${INSTALL_DIR}/simai-admin.sh" "${panel_args[@]}"; then
    # The sign-in link is the last thing the person needs: no menu over it.
    SIMAI_INSTALL_NO_MENU=1
  else
    echo "WARNING: Panel installation failed. Run later:"
    echo "  sudo ${INSTALL_DIR}/simai-admin.sh ${panel_args[*]}"
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
