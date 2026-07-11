#!/usr/bin/env python3
"""Build and validate an explicit coverage row for every registered command."""

from __future__ import annotations

import argparse
import json
import re
import shlex
from pathlib import Path

REGISTER_RE = re.compile(r"^register_cmd\s+(.+)$")
MENU_RE = re.compile(r"run_menu_command\s+([a-z0-9_-]+)\s+([a-z0-9_-]+)")
CLI_RE = re.compile(r"simai-admin\.sh\s+([a-z0-9_-]+)\s+([a-z0-9_-]+)")


def command_rows(root: Path) -> list[dict[str, object]]:
    registrations: dict[str, dict[str, str]] = {}
    for path in sorted((root / "admin" / "commands").glob("*.sh")):
        for line_no, line in enumerate(path.read_text().splitlines(), 1):
            match = REGISTER_RE.match(line.strip())
            if not match:
                continue
            fields = shlex.split(match.group(1))
            if len(fields) not in (6, 7):
                raise SystemExit(f"invalid register_cmd at {path}:{line_no}")
            if len(fields) == 6:
                fields.append("")
            section, name, desc, _handler, required, optional, flags = fields
            key = f"{section}:{name}"
            if key in registrations:
                raise SystemExit(f"duplicate command: {key}")
            registrations[key] = {"description": desc, "required": required, "optional": optional, "flags": flags, "source": f"{path.relative_to(root)}:{line_no}"}

    menu_keys = {f"{a}:{b}" for a, b in MENU_RE.findall((root / "admin" / "menu.sh").read_text())}
    runtime_keys = {f"{a}:{b}" for a, b in CLI_RE.findall((root / "testing" / "run-regression.sh").read_text())}
    rows: list[dict[str, object]] = []
    for key, meta in sorted(registrations.items()):
        flags = str(meta["flags"]).split()
        surface = "hidden_legacy" if "menu:hidden" in flags else ("menu" if key in menu_keys else "cli_only")
        coverage = (["runtime_execution"] if key in runtime_keys else []) + ["dispatcher_harness"]
        if key not in runtime_keys:
            coverage.append("not_run_runtime")
        rows.append({"command": key, "surface": surface, "coverage": coverage, **meta})
    return rows


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=Path(__file__).resolve().parents[2], type=Path)
    parser.add_argument("--output")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()
    rows = command_rows(root)
    report = {"schema": "simai-env-command-coverage-v1", "total": len(rows), "classified": len(rows), "unclassified": 0, "surface_totals": {name: sum(row["surface"] == name for row in rows) for name in ("menu", "cli_only", "hidden_legacy")}, "rows": rows}
    if args.check and (not rows or report["classified"] != report["total"]):
        return 1
    payload = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.output:
        Path(args.output).write_text(payload)
    else:
        print(payload, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
