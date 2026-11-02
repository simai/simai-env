#!/bin/bash
# Runs one user cron job of a site as the site user (cron calls it from
# /etc/cron.d/simai-jobs-<slug>) and records the run: start, end, exit code
# and the last 50 output lines, keeping the last 50 runs. Installed by
# simai-admin.sh cron job-add as /usr/local/lib/simai-env/cron-job-run.
set -u
domain="${1:-}" id="${2:-}"
[[ "$domain" =~ ^[a-z0-9.-]+$ && "$id" =~ ^[a-f0-9]{8}$ ]] || exit 2
runs="/var/lib/simai-env/cron-runs/${domain}"
{ IFS= read -r workdir && IFS= read -r command; } <"/etc/simai-env/cron-jobs/${domain}/${id}.cmd" || exit 2
exec 9>"${runs}/${id}.lock" || exit 1
flock -n 9 || exit 0  # the previous run is still going
out=$(mktemp) || exit 1
trap 'rm -f "$out"' EXIT
started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
( cd "$workdir" || exit 1; exec bash -c "$command" ) </dev/null >"$out" 2>&1
rc=$?
finished=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tail -n 50 "$out" | python3 -I -c '
import json, os, sys
started, finished, rc, path = sys.argv[1:5]
record = json.dumps({"started_at": started, "finished_at": finished, "exit_code": int(rc),
                     "output": [l.rstrip("\n")[:2000] for l in sys.stdin]}, ensure_ascii=False)
try:
    old = open(path, errors="replace").read().splitlines()[-49:]
except OSError:
    old = []
with open(path + ".tmp", "w") as f:
    f.write("\n".join(old + [record]) + "\n")
os.replace(path + ".tmp", path)' "$started" "$finished" "$rc" "${runs}/${id}.jsonl"
