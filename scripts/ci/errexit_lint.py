#!/usr/bin/env python3
"""Catch shell patterns that abort handlers under `set -euo pipefail`.

Handlers run fail-fast (admin/worker.sh). These patterns return non-zero in
normal situations and silently end a command:
  * a function whose last statement is `[[ cond ]] && VAR=...` (returns 1
    whenever cond is false);
  * `(( x += n ))` / `(( x -= n ))` / `(( x++ ))` as a statement (returns 1 when
    the result is 0);
  * `var=$(grep ...)` without a fallback (grep finds nothing -> status 1).
Predicates that intentionally return their condition are not flagged.
"""
import pathlib
import re
import sys

ROOTS = ["admin", "lib", "simai-admin.sh", "simai-env.sh", "update.sh", "install.sh"]
ASSIGN_TAIL = re.compile(r"&&\s*(local\s+)?[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?=")
ARITH_STMT = re.compile(r"^\s*\(\(\s*[A-Za-z_][A-Za-z0-9_]*\s*(\+\+|--|[-+*/]=)")
GREP_SUBST = re.compile(r"^\s*(local\s+)?[A-Za-z_][A-Za-z0-9_]*=\$\((.*\|)?\s*grep\b(?!.*-c\b)")


def files():
    for root in ROOTS:
        path = pathlib.Path(root)
        if path.is_file():
            yield path
        elif path.is_dir():
            yield from sorted(path.rglob("*.sh"))


def main() -> int:
    problems = []
    for path in files():
        lines = path.read_text(errors="replace").split("\n")
        for number, line in enumerate(lines, 1):
            stripped = line.strip()
            if stripped.startswith("#"):
                continue
            if ARITH_STMT.match(line) and "|| true" not in line:
                problems.append(f"{path}:{number}: arithmetic statement can return 1; use x=$((x + n))")
            if GREP_SUBST.match(line) and "||" not in line:
                problems.append(f"{path}:{number}: grep in command substitution needs '|| true'")
            if re.match(r"^[A-Za-z_][A-Za-z0-9_]*\(\)\s*\{\s*$", line):
                end = number
                while end < len(lines) and lines[end] != "}":
                    end += 1
                body = [l for l in lines[number:end] if l.strip() and not l.strip().startswith("#")]
                if body and ASSIGN_TAIL.search(body[-1]) and "||" not in body[-1]:
                    problems.append(f"{path}:{end + 1}: function ends with 'cond && assignment'; add 'return 0'")
    for problem in problems:
        print(problem)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
