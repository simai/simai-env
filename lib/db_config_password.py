#!/usr/bin/env python3
"""Replace a site's database password in its PHP configuration (site db-rotate).

Usage: db_config_password.py check|apply KIND FILE
The old and the new password come on stdin, one per line, never in argv.

KIND:
  wp              define('DB_PASSWORD', '...') in wp-config.php
  bitrix-settings 'password' => '...' in bitrix/.settings.php
  bitrix-dbconn   $DBPassword = '...' in bitrix/php_interface/dbconn.php

Only a quoted literal equal to the old password is replaced. Exit codes:
0 replaced (or would be: check) at least once; 3 the setting is absent;
4 the setting holds another password; 2 bad input or an unreadable file.
Runs as the file's owner (sudo -u), so the file keeps its owner and inode;
a symbolic link is refused.
"""
import os
import re
import sys

PATTERNS = {
    "wp": r"""(define\(\s*['"]DB_PASSWORD['"]\s*,\s*)(['"])(.*?)\2""",
    "bitrix-settings": r"""(['"]password['"]\s*=>\s*)(['"])(.*?)\2""",
    "bitrix-dbconn": r"""(\$DBPassword\s*=\s*)(['"])(.*?)\2""",
}


def main():
    if len(sys.argv) != 4 or sys.argv[1] not in ("check", "apply") or sys.argv[2] not in PATTERNS:
        print(__doc__, file=sys.stderr)
        return 2
    mode, kind, path = sys.argv[1:]
    lines = sys.stdin.read().split("\n")
    if len(lines) < 2 or not lines[0] or not lines[1]:
        return 2
    old, new = lines[0], lines[1]
    if not re.fullmatch(r"[A-Za-z0-9]{8,128}", new):
        return 2
    try:
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
    except OSError:
        return 2
    with os.fdopen(fd, "r+", encoding="utf-8", errors="surrogateescape", newline="") as fh:
        text = fh.read()
        rx = re.compile(PATTERNS[kind], re.S)
        found = rx.findall(text)
        if not found:
            return 3
        # Generated passwords are alphanumeric, so the literal equals the
        # password. Other 'password' keys (a cache or mail server in
        # .settings.php) hold other values and are left alone.
        if not any(value == old for _, _, value in found):
            return 4
        if mode == "check":
            return 0
        text = rx.sub(lambda m: m.group(1) + m.group(2) + new + m.group(2) if m.group(3) == old else m.group(0), text)
        fh.seek(0)
        fh.write(text)
        fh.truncate()
    return 0


if __name__ == "__main__":
    sys.exit(main())
