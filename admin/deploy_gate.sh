#!/usr/bin/env bash
# Forced command of CI deploy keys (see admin/commands/site_deploy_key.sh).
# Runs as root through one sudo rule: simai-deploy-gate <key-id> "<command>".
# The key id fixes the site; the command is one of:
#   deploy-artifact <sha256>   tar.gz of the site on stdin
#   deploy-git <commit>        node/git sites, repository fixed on the server
#   status | rollback
set -euo pipefail
umask 077
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="${SIMAI_DEPLOY_REGISTRY:-/etc/simai-env/deploy-keys}"
INCOMING=/var/lib/simai-env/deploy-incoming
LOG=/var/log/simai-deploy-gate.log
MAX_MB="${SIMAI_DEPLOY_MAX_ARCHIVE_MB:-1024}"

id="${1:-}"
request="${2:-}"

log() { printf '%s key=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${id:-?}" "$*" >>"$LOG"; }
deny() { log "denied: $1"; echo "simai-deploy: $1" >&2; exit 126; }

[[ "$id" =~ ^[a-f0-9]{12}$ && -f "${REGISTRY}/${id}" ]] || deny "unknown key"
get() { sed -n "s/^${1}=//p" "${REGISTRY}/${id}" | tail -n1; }
domain=$(get DOMAIN)
mode=$(get MODE)
git_url=$(get GIT_URL)
[[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || deny "broken key registry"

# One verb and at most one argument; nothing else is ever interpreted.
[[ "$request" =~ ^[a-z-]+( [A-Za-z0-9]+)?$ ]] || deny "unsupported command"
verb="${request%% *}"
arg=""
[[ "$request" == *" "* ]] && arg="${request#* }"

admin() { "${ROOT}/simai-admin.sh" "$@"; }

case "$verb" in
  deploy-artifact)
    [[ "$mode" == artifact ]] || deny "this key deploys from git"
    [[ "$arg" =~ ^[a-f0-9]{64}$ ]] || deny "deploy-artifact needs the sha256 of the archive"
    install -d -m 0700 "$INCOMING"
    file=$(mktemp "${INCOMING}/${domain}.XXXXXX.tar.gz")
    trap 'rm -f -- "$file"' EXIT
    head -c $(( MAX_MB * 1048576 + 1 )) >"$file"
    size=$(stat -c %s "$file")
    (( size > 0 )) || deny "no archive on stdin"
    (( size <= MAX_MB * 1048576 )) || deny "archive larger than ${MAX_MB} MB"
    [[ "$(sha256sum "$file" | cut -d' ' -f1)" == "$arg" ]] || deny "sha256 mismatch"
    chmod 0644 "$file"
    log "deploy-artifact ${domain} ${arg} (${size} bytes)"
    rc=0
    SIMAI_ADMIN_MENU=0 admin site deploy --domain "$domain" --archive "$file" --sha256 "$arg" --confirm yes || rc=$?
    log "deploy-artifact ${domain} rc=${rc}"
    exit "$rc"
    ;;
  deploy-git)
    [[ "$mode" == git && -n "$git_url" ]] || deny "this key deploys artifacts"
    [[ "$arg" =~ ^[a-f0-9]{40}$ ]] || deny "deploy-git needs a full commit sha"
    log "deploy-git ${domain} ${arg}"
    rc=0
    SIMAI_ADMIN_MENU=0 admin site deploy --domain "$domain" --git "$git_url" --ref "$arg" --confirm yes </dev/null || rc=$?
    log "deploy-git ${domain} rc=${rc}"
    exit "$rc"
    ;;
  status)
    [[ -z "$arg" ]] || deny "status takes no argument"
    SIMAI_ADMIN_MENU=0 admin site deploy-status --domain "$domain" </dev/null
    ;;
  rollback)
    [[ -z "$arg" ]] || deny "rollback takes no argument"
    log "rollback ${domain}"
    SIMAI_ADMIN_MENU=0 admin site deploy-rollback --domain "$domain" --confirm yes </dev/null
    ;;
  *)
    deny "unsupported command"
    ;;
esac
