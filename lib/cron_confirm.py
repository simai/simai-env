#!/usr/bin/env python3
"""Preserve existing managed cron mutation intent across confirmation upgrade."""
import os
import re
import shutil
import stat
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

path = Path(sys.argv[1])
info = path.lstat()
if os.geteuid() != 0 or not stat.S_ISREG(info.st_mode) or info.st_uid != 0 or info.st_mode & 0o022:
    raise SystemExit("unsafe managed cron file")
text = path.read_text()
changed = []
for line in text.splitlines(keepends=True):
    managed = re.match(r"^(?:\S+\s+){5}root\s+.*simai-admin\.sh\s+(?:observer\s+snapshot|backup\s+data|self\s+scheduler)(?=\s|$)", line)
    if managed and "--confirm" not in line:
        ending = "\n" if line.endswith("\n") else ""
        body = line.rstrip("\n")
        redirection = re.search(r"\s+(?=[<>|])", body)
        at = redirection.start() if redirection else len(body)
        line = body[:at] + " --confirm yes" + body[at:] + ending
    changed.append(line)
new = "".join(changed)
if new == text:
    raise SystemExit(0)
base = Path("/var/backups/simai-system/cron-confirm")
base.mkdir(parents=True, exist_ok=True, mode=0o700)
base_info = base.lstat()
if not stat.S_ISDIR(base_info.st_mode) or base_info.st_uid != 0 or base_info.st_mode & 0o077:
    raise SystemExit("unsafe cron recovery directory")
backup = base / (path.name + "." + datetime.now(timezone.utc).strftime("%Y%m%d%H%M%S") + f".{os.getpid()}")
shutil.copy2(path, backup)
os.chmod(backup, 0o600)
assert backup.read_bytes() == path.read_bytes()
fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
try:
    with os.fdopen(fd, "w") as stream:
        stream.write(new)
        stream.flush()
        os.fsync(stream.fileno())
    os.chmod(temporary, stat.S_IMODE(info.st_mode))
    os.chown(temporary, 0, info.st_gid)
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print(path.name)
