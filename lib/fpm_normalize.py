#!/usr/bin/env python3
"""Collapse pool keys while retaining explicit site > perf > profile > base.

Input is one managed FPM pool. Unknown comments and keys are preserved. Site
overrides supersede profile defaults even when PHP-FPM uses the first key.
"""
import re
import sys


def normalize(text):
    lines = text.splitlines()
    chosen = {}
    block = 0
    keys = {}
    for i, line in enumerate(lines):
        if line == "; simai-site-ini-begin":
            block = 3
        elif line == "; simai-site-perf-begin":
            block = 2
        elif line == "; simai-profile-ini-begin":
            block = 1
        elif re.match(r"; simai-(site-ini|site-perf|profile-ini)-end$", line):
            block = 0
        match = re.match(r"\s*([A-Za-z0-9_.]+(?:\[[^\]]+\])?)\s*=", line)
        if not match:
            continue
        key = match[1]
        # php_admin_flag/value address the same underlying PHP ini directive.
        key = re.sub(r"^php_admin_(flag|value)\[", "php_admin[", key)
        keys[i] = key
        if key not in chosen or (block, i) > chosen[key]:
            chosen[key] = (block, i)
    return "\n".join(line for i, line in enumerate(lines)
                     if i not in keys or chosen[keys[i]][1] == i) + "\n"


if __name__ == "__main__":
    text = sys.stdin.read()
    if sys.argv[1:] == ["--nginx-bitrix"]:
        text = re.sub(r"(?m)^\s*fastcgi_read_timeout\s+[^;]+;\s*$", "", text)
        text = re.sub(r"(?m)^(\s*server\s*\{)\s*$", r"\1\n    fastcgi_read_timeout 300s;", text)
        sys.stdout.write(text)
    else:
        sys.stdout.write(normalize(text))
