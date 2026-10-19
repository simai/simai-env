#!/usr/bin/env python3
"""Write an execution receipt for a frozen container snapshot and one case."""
import hashlib
import json
import sys
from pathlib import Path
from datetime import datetime, timezone


def digest(root):
    values = []
    for path in sorted(Path(root).rglob("*")):
        if path.is_file() and not path.is_symlink():
            values.append(f"{path.relative_to(root)}:{hashlib.sha256(path.read_bytes()).hexdigest()}")
    return hashlib.sha256("\n".join(values).encode()).hexdigest()


if sys.argv[1] == "digest":
    print(digest(sys.argv[2]))
else:
    output, candidate, ubuntu, case, rc, log, executions = sys.argv[2:]
    events = []
    try:
        events = [json.loads(line) for line in Path(executions).read_text().splitlines()]
    except FileNotFoundError:
        pass
    text = Path(log).read_text(errors="replace")
    receipt = {
        "schema": "simai-env-test-receipt/1", "candidate_sha256": candidate,
        "ubuntu": ubuntu, "case": case, "exit_code": int(rc),
        "status": "passed" if int(rc) == 0 else "failed",
        "assertions": {kind.lower(): [line[len(kind) + 1:] for line in text.splitlines() if line.startswith(kind + " ")]
                       for kind in ("PASS", "FAIL", "SKIP")},
        "command_executions": events,
        "log_sha256": hashlib.sha256(Path(log).read_bytes()).hexdigest(),
        "observed_at": datetime.now(timezone.utc).isoformat(),
    }
    Path(output).write_text(json.dumps(receipt, indent=2) + "\n")
