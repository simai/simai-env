#!/usr/bin/env python3
"""Malware scan of site files and the quarantine (security center).

Usage: file_scan.py scan ROOTS_JSON [clamav|none]   ({domain: root}; prints the result, saves it)
       file_scan.py results OUTPUT
       file_scan.py quarantine DOMAIN ROOT RELPATH
       file_scan.py quarantine-list OUTPUT
       file_scan.py restore ID

Two engines: ClamAV (clamdscan when its daemon runs, else clamscan), when it
is installed, and simai-env's own signatures of PHP web shells and backdoors,
which always run. A file in an upload folder that holds PHP code is reported
too: uploads never need PHP.

Site files are attacker-controlled: they are read as bytes with size limits,
never executed, symlinks are not followed, and paths are checked to stay
inside the site root. Quarantine moves a file into
/var/lib/simai-env/quarantine (root only) and can put it back.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

STATE = Path(os.environ.get("SIMAI_SECURITY_STATE", "/var/lib/simai-env/security"))
RESULTS = STATE / "files.json"
QUARANTINE = Path(os.environ.get("SIMAI_QUARANTINE_DIR", "/var/lib/simai-env/quarantine"))
INDEX = QUARANTINE / "index.json"
CODE = {".php", ".phtml", ".php3", ".php4", ".php5", ".php7", ".phar", ".inc", ".pht"}
SKIP_DIRS = {".git", "node_modules", ".svn", "cache", "bitrix/cache", "bitrix/managed_cache", "storage/framework"}
UPLOAD_DIRS = ("wp-content/uploads/", "upload/", "uploads/", "storage/app/public/", "public/uploads/",
               "public/storage/")
MAX_FILE = 4 * 1048576
MAX_FILES = 300000
# Strong signs of web shells and injected backdoors; framework code does not
# look like this.
SIGNATURES = [
    ("simai.php.eval_encoded", re.compile(
        rb"(?:eval|assert)\s*\(\s*(?:@?\s*)?(?:base64_decode|gzinflate|gzuncompress|gzdecode|str_rot13|"
        rb"hex2bin|convert_uudecode)\s*\(", re.I)),
    ("simai.php.exec_input", re.compile(
        rb"(?:system|shell_exec|passthru|popen|proc_open|pcntl_exec|exec|assert|eval|create_function)"
        rb"\s*\(\s*@?\s*(?:stripslashes\s*\(\s*)?\$_(?:GET|POST|REQUEST|COOKIE|SERVER|FILES)\s*\[", re.I)),
    ("simai.php.call_input", re.compile(
        rb"\$_(?:GET|POST|REQUEST|COOKIE)\s*\[\s*['\"]?[A-Za-z0-9_]{0,32}['\"]?\s*\]\s*\(\s*\$_(?:GET|POST|REQUEST|COOKIE)",
        re.I)),
    ("simai.php.known_shell", re.compile(
        rb"(?:FilesMan|WSO\s+[0-9.]+|b374k|c99shell|r57shell|IndoXploit|Mini\s*Shell|AnonymousFox|"
        rb"Leaf\s*PHPMailer|Uname:\s*<|safe_mode\s*:\s*<)", re.I)),
    ("simai.php.preg_e", re.compile(rb"preg_replace\s*\(\s*['\"]/[^'\"]{0,200}/[a-df-z]*e[a-z]*['\"]\s*,\s*\$_", re.I)),
    ("simai.php.long_blob", re.compile(rb"(?:eval|assert)\s*\([^)]{0,64}['\"][A-Za-z0-9+/=]{4000,}", re.I)),
]


def now() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def save(path: Path, data) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(data, ensure_ascii=False))
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def walk(root: Path):
    count = 0
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "" if rel_dir == "." else rel_dir + "/"
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and (rel_dir + d) not in SKIP_DIRS]
        for name in filenames:
            count += 1
            if count > MAX_FILES:
                return
            yield Path(dirpath) / name, rel_dir + name


def base(root: str) -> Path:
    """The code that runs: the current release of a site with releases."""
    r = Path(root)
    return (r / "current").resolve() if (r / "current").is_symlink() else r


def own_scan(root: Path) -> tuple[int, list[dict]]:
    found, scanned = [], 0
    for path, rel in walk(root):
        ext = path.suffix.lower()
        try:
            st = path.lstat()
        except OSError:
            continue
        if not path.is_file() or path.is_symlink() or st.st_size > MAX_FILE:
            continue
        in_upload = any(rel.startswith(u) or f"/{u}" in rel for u in UPLOAD_DIRS)
        if ext not in CODE and not (in_upload and st.st_size < 1048576):
            continue
        scanned += 1
        try:
            data = path.read_bytes()
        except OSError:
            continue
        hit = next((sig for sig, rx in SIGNATURES if rx.search(data)), None)
        if not hit and in_upload and (ext in CODE or b"<?php" in data[:4096]):
            hit = "simai.php.in_uploads"
        if hit:
            found.append({"path": rel, "signature": hit, "engine": "simai", "size": st.st_size,
                          "sha256": hashlib.sha256(data).hexdigest(), "modified": time.strftime(
                              "%Y-%m-%dT%H:%M:%SZ", time.gmtime(st.st_mtime))})
    return scanned, found


def clam_scan(root: Path) -> tuple[str, list[dict], str | None]:
    daemon = subprocess.run(["systemctl", "is-active", "clamav-daemon"], capture_output=True, text=True).stdout.strip()
    if daemon == "active" and shutil.which("clamdscan"):
        cmd, engine = ["clamdscan", "--fdpass", "--multiscan", "--infected", "--no-summary", str(root)], "clamd"
    elif shutil.which("clamscan"):
        cmd = ["nice", "-n", "19", "ionice", "-c3", "clamscan", "-r", "--infected", "--no-summary",
               "--max-filesize=20M", "--max-scansize=50M", "--follow-dir-symlinks=0", "--follow-file-symlinks=0",
               "--exclude-dir=/\\.git$", "--exclude-dir=/node_modules$", str(root)]
        engine = "clamscan"
    else:
        return "none", [], None
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=6 * 3600, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return engine, [], "timeout"
    found = []
    for line in p.stdout.splitlines():
        m = re.match(r"^(.*): (\S+) FOUND$", line)
        if m:
            try:
                rel = str(Path(m.group(1)).resolve().relative_to(root.resolve()))
            except ValueError:
                continue
            found.append({"path": rel, "signature": m.group(2)[:120], "engine": "clamav"})
    return engine, found, None if p.returncode in (0, 1) else (p.stderr.strip().splitlines() or ["error"])[-1][:200]


def scan(roots: dict, clamav: str) -> dict:
    previous = load(RESULTS, {}).get("sites", {})
    result = {"schema": "simai-file-scan/1", "checked_at": now(), "engines": ["simai"], "sites": {}}
    quarantined = {(q["domain"], q["path"]) for q in load(INDEX, []) if q.get("state") == "quarantined"}
    for domain, root in sorted(roots.items()):
        root_path = base(root)
        if not root_path.is_dir():
            continue
        started = time.time()
        scanned, found = own_scan(root_path)
        engine, error = "simai", None
        if clamav == "clamav":
            engine, more, error = clam_scan(root_path)
            seen = {f["path"] for f in found}
            found += [f for f in more if f["path"] not in seen]
            if engine != "none" and "clamav" not in result["engines"]:
                result["engines"].append("clamav")
        found = [f for f in found if (domain, f["path"]) not in quarantined][:500]
        result["sites"][domain] = {"scanned": scanned, "found": found, "error": error,
                                   "seconds": round(time.time() - started, 1),
                                   "first_seen": {f["path"]: (previous.get(domain, {}).get("first_seen") or {})
                                                  .get(f["path"], now()) for f in found}}
    save(RESULTS, result)
    return result


def inside(root: Path, rel: str) -> Path:
    if not rel or rel.startswith("/") or "\x00" in rel or any(p == ".." for p in rel.split("/")):
        raise SystemExit("bad path")
    path = root / rel
    real_parent = path.parent.resolve()
    if real_parent != root.resolve() and root.resolve() not in real_parent.parents:
        raise SystemExit("the path leaves the site root")
    if path.is_symlink() or not path.is_file():
        raise SystemExit("not a regular file")
    return path


def quarantine(domain: str, root: str, rel: str) -> dict:
    root = str(base(root))
    path = inside(Path(root), rel)
    qid = secrets.token_hex(6)
    dest = QUARANTINE / domain / qid
    dest.mkdir(mode=0o700, parents=True)
    st = path.stat()
    data = path.read_bytes()
    target = dest / "file"
    shutil.move(str(path), target)
    os.chmod(target, 0o600)
    entry = {"id": qid, "domain": domain, "path": rel, "root": root, "size": st.st_size,
             "mode": oct(st.st_mode & 0o7777), "uid": st.st_uid, "gid": st.st_gid,
             "sha256": hashlib.sha256(data).hexdigest(), "quarantined_at": now(), "state": "quarantined"}
    index = load(INDEX, [])
    index.append(entry)
    save(INDEX, index)
    results = load(RESULTS, {})
    site = (results.get("sites") or {}).get(domain)
    if site:
        site["found"] = [f for f in site.get("found") or [] if f.get("path") != rel]
        save(RESULTS, results)
    return entry


def restore(qid: str) -> dict:
    index = load(INDEX, [])
    entry = next((q for q in index if q["id"] == qid and q.get("state") == "quarantined"), None)
    if not entry:
        raise SystemExit("no quarantined file with this id")
    root = Path(entry["root"])
    path = root / entry["path"]
    if any(p == ".." for p in entry["path"].split("/")) or path.exists() or path.is_symlink():
        raise SystemExit("a file is already at the original path")
    parent = path.parent.resolve()
    if parent != root.resolve() and root.resolve() not in parent.parents:
        raise SystemExit("the original folder now leaves the site root")
    shutil.move(str(QUARANTINE / entry["domain"] / qid / "file"), path)
    os.chown(path, entry["uid"], entry["gid"])
    os.chmod(path, int(entry["mode"], 8))
    entry["state"], entry["restored_at"] = "restored", now()
    save(INDEX, index)
    return entry


def site_roots(only: str) -> dict:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import host_describe
    roots = {}
    for d in host_describe.site_domains():
        if only and d != only:
            continue
        meta = host_describe.metadata(d)
        if meta.get("profile") not in ("alias", "redirect", "proxy") and meta.get("root"):
            roots[d] = meta["root"]
    return roots


def main(argv: list[str]) -> int:
    mode = argv[0]
    if mode in ("scan", "scan-sites"):
        roots = json.loads(argv[1]) if mode == "scan" else site_roots(argv[1])
        if mode == "scan-sites" and argv[1]:
            # One site: keep the others' last results.
            old = load(RESULTS, {}).get("sites", {})
            r = scan(roots, argv[2] if len(argv) > 2 else "none")
            r["sites"] = {**{k: v for k, v in old.items() if k not in roots}, **r["sites"]}
            save(RESULTS, r)
        else:
            r = scan(roots, argv[2] if len(argv) > 2 else "none")
        r = {**r, "sites": {k: v for k, v in r["sites"].items() if k in roots}}
        total = sum(len(s["found"]) for s in r["sites"].values())
        for d, s in r["sites"].items():
            for f in s["found"]:
                print(f"FOUND {d}: {f['path']} ({f['signature']}, {f['engine']})")
            if s["error"]:
                print(f"ERROR {d}: {s['error']}")
        print(f"{len(r['sites'])} sites, {sum(s['scanned'] for s in r['sites'].values())} code files checked by "
              f"{' + '.join(r['engines'])}, {total} suspicious")
        return 0
    if mode == "results":
        r = load(RESULTS, {"schema": "simai-file-scan/1", "checked_at": None, "engines": [], "sites": {}})
        if argv[1] == "json":
            print(json.dumps(r, ensure_ascii=False))
        else:
            print(f"Last scan: {r.get('checked_at') or 'never'} ({' + '.join(r.get('engines') or []) or '-'})")
            for d, s in (r.get("sites") or {}).items():
                for f in s["found"]:
                    print(f"  {d}: {f['path']} ({f['signature']})")
        return 0
    if mode == "quarantine":
        e = quarantine(argv[1], argv[2], argv[3])
        print(json.dumps(e))
        return 0
    if mode == "quarantine-list":
        rows = [{k: v for k, v in q.items() if k != "root"} for q in load(INDEX, [])]
        if argv[1] == "json":
            print(json.dumps({"schema": "simai-quarantine/1", "files": rows}, ensure_ascii=False))
        else:
            for q in rows:
                print(f"{q['id']}  {q['state']:<12}{q['domain']}: {q['path']} ({q['quarantined_at']})")
            if not rows:
                print("The quarantine is empty")
        return 0
    if mode == "restore":
        print(json.dumps(restore(argv[1])))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
