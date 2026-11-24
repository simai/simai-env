#!/usr/bin/env bash
# Forced command of CI deploy keys (see admin/commands/site_deploy_key.sh).
# Runs as root through one sudo rule: simai-deploy-gate <key-id> "<command>".
# The key id fixes the site; the command is one of:
#   deploy-artifact <sha256>   tar.gz of the site on stdin
#   deploy-git <commit>        node/git sites, repository fixed on the server
#   status | rollback
#   artisan <name> [args]      only names the key allows (site deploy-key-allow),
#                              as the site user; stdin reaches the command
#   env-set <NAME>             value on stdin into the site's shared .env, only
#                              names with the key's allowed prefix
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
# artisan alone takes up to 20 plain words (no quotes, no shell characters).
if [[ "$request" =~ ^artisan\ [a-z0-9:_-]+(\ [A-Za-z0-9._:=@/+,-]{1,200}){0,20}$ ]]; then
  verb=artisan
  read -r -a words <<<"${request#artisan }"
  arg="${words[0]}"
else
  [[ "$request" =~ ^[a-z-]+( [A-Za-z0-9_]+)?$ ]] || deny "unsupported command"
  verb="${request%% *}"
  arg=""
  [[ "$request" == *" "* ]] && arg="${request#* }"
fi

admin() { "${ROOT}/simai-admin.sh" "$@"; }

# runs_as, php and root of the key's site (site describe).
site_facts() {
  SIMAI_ADMIN_MENU=0 admin site describe --domain "$domain" --output json </dev/null 2>/dev/null | python3 -I -c '
import json, re, sys
d = json.load(sys.stdin); d = d.get("data", d)
u, p, r = str(d.get("runs_as") or "").split()[0] if d.get("runs_as") else "", str(d.get("php") or ""), str(d.get("root") or "")
ok = re.fullmatch(r"[a-z_][a-z0-9_-]{0,31}", u) and re.fullmatch(r"\d\.\d", p) and r.startswith("/home/")
print(f"{u} {p} {r}" if ok else "")'
}

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
  artisan)
    allow=$(get ARTISAN)
    [[ -n "$allow" && ",${allow}," == *",${arg},"* ]] || deny "artisan ${arg} is not allowed for this key"
    for w in "${words[@]:1}"; do
      [[ "$w" != --env* ]] || deny "artisan --env is not allowed"
    done
    read -r user php root <<<"$(site_facts)"
    [[ -n "$user" && -f "${root}/current/artisan" ]] || deny "the site has no deployed application"
    log "artisan ${domain} ${arg} ($(( ${#words[@]} - 1 )) argument(s))"
    rc=0
    cd "${root}/current"
    sudo -u "$user" -H "php${php}" "${root}/current/artisan" "${words[@]}" || rc=$?
    log "artisan ${domain} ${arg} rc=${rc}"
    exit "$rc"
    ;;
  env-set)
    prefix=$(get ENV_PREFIX)
    [[ -n "$prefix" && "$arg" =~ ^[A-Z][A-Z0-9_]{0,63}$ && "$arg" == "$prefix"* ]] || deny "env-set ${arg} is not allowed for this key"
    read -r user php root <<<"$(site_facts)"
    [[ -n "$user" && -f "${root}/.env" && ! -L "${root}/.env" ]] || deny "the site has no shared .env"
    log "env-set ${domain} ${arg}"
    # The value never reaches a command line or the log.
    head -c 8193 | python3 -I -c '
import os, re, sys
name, path = sys.argv[1], sys.argv[2]
raw = sys.stdin.buffer.read()
if len(raw) > 8192: sys.exit("simai-deploy: value longer than 8192 bytes")
value = raw.decode("utf-8").rstrip("\n")
if any(c in value for c in "\n\r\0"): sys.exit("simai-deploy: one line only")
if not re.fullmatch(r"[A-Za-z0-9._:/+=@-]*", value):
    value = "\"" + value.replace("\\", "\\\\").replace("\"", "\\\"").replace("$", "\\$") + "\""
st = os.stat(path)
lines = open(path, encoding="utf-8").read().splitlines()
out, done = [], False
for line in lines:
    if line.startswith(name + "="):
        if not done: out.append(f"{name}={value}"); done = True
        continue
    out.append(line)
if not done: out.append(f"{name}={value}")
tmp = path + ".simai-tmp"
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, st.st_mode & 0o777)
with os.fdopen(fd, "w", encoding="utf-8") as f: f.write("\n".join(out) + "\n")
os.chown(tmp, st.st_uid, st.st_gid); os.chmod(tmp, st.st_mode & 0o777); os.replace(tmp, path)
print(f"{name} set")' "$arg" "${root}/.env" || deny "env-set ${arg} failed"
    if [[ -f "${root}/current/artisan" ]]; then
      (cd "${root}/current" && sudo -u "$user" -H "php${php}" artisan config:clear </dev/null >/dev/null 2>&1) || true
    fi
    ;;
  *)
    deny "unsupported command"
    ;;
esac
