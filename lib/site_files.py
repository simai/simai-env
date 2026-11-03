#!/usr/bin/env python3
"""File operations inside one site directory for `file *` commands.

Runs as the site's user, never as root. Every path is walked from the site
root one component at a time with O_NOFOLLOW, so a symbolic link (or a
directory swapped for one meanwhile) never leads outside the root; links are
listed, not followed.

Usage: site_files.py OP ROOT PATH [ARG]
  list PATH            directory entries (simai-files/1)
  stat PATH            one entry (simai-file-stat/1)
  read PATH            text content up to 1 MiB (simai-file/1)
  cat PATH             raw bytes of a regular file to stdout
  write PATH EXPECT    content from stdin; EXPECT is a sha256, "new" or "any"
  mkdir PATH
  rename PATH NEWPATH
  remove PATH          a file, a link, or a directory with everything in it
Errors go to stderr as "error: <code>: <message>", exit code 2.
"""
import hashlib
import json
import os
import stat
import sys

MAX_ENTRIES = 5000
MAX_TEXT = 1 << 20
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class Fail(Exception):
    pass


def code(e, other):
    return {2: "not_found", 13: "permission_denied"}.get(e.errno, other)


def parts(rel):
    out = []
    for p in rel.split("/"):
        if p in ("", "."):
            continue
        if p == ".." or "\x00" in p or len(p) > 255:
            raise Fail("bad_path", "the path must stay inside the site directory")
        out.append(p)
    return out


def open_root(root):
    try:
        return os.open(root, DIR_FLAGS)
    except OSError as e:
        raise Fail("no_root", f"the site directory cannot be opened: {e.strerror}")


def walk(root_fd, names):
    """A descriptor of the directory holding names[-1] (all parents are real directories)."""
    fd = os.dup(root_fd)
    for name in names[:-1]:
        try:
            nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
        except OSError as e:
            os.close(fd)
            raise Fail(code(e, "not_a_directory"), f"{name}: {e.strerror}")
        os.close(fd)
        fd = nxt
    return fd


def kind(mode):
    if stat.S_ISDIR(mode):
        return "dir"
    if stat.S_ISREG(mode):
        return "file"
    if stat.S_ISLNK(mode):
        return "link"
    return "other"


def entry(name, st, dir_fd):
    e = {"name": name, "type": kind(st.st_mode), "size": st.st_size, "mtime": int(st.st_mtime),
         "mode": oct(stat.S_IMODE(st.st_mode))[2:]}
    if e["type"] == "link":
        try:
            e["target"] = os.readlink(name, dir_fd=dir_fd)
        except OSError:
            e["target"] = None
    return e


def lstat(parent, name):
    try:
        return os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        raise Fail("not_found", f"{name} does not exist")


def op_list(root_fd, names):
    fd = os.dup(root_fd) if not names else None
    if fd is None:
        parent = walk(root_fd, names)
        try:
            fd = os.open(names[-1], DIR_FLAGS, dir_fd=parent)
        except OSError as e:
            raise Fail(code(e, "not_a_directory"), f"{names[-1]}: {e.strerror}")
        finally:
            os.close(parent)
    rows, truncated = [], False
    with os.scandir(fd) as it:
        for de in it:
            if len(rows) >= MAX_ENTRIES:
                truncated = True
                break
            try:
                rows.append(entry(de.name, de.stat(follow_symlinks=False), fd))
            except OSError:
                continue
    os.close(fd)
    rows.sort(key=lambda r: (r["type"] != "dir", r["name"].lower()))
    return {"schema": "simai-files/1", "path": "/".join(names), "entries": rows, "truncated": truncated}


def open_file(root_fd, names):
    if not names:
        raise Fail("not_a_file", "the site directory is not a file")
    parent = walk(root_fd, names)
    try:
        fd = os.open(names[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK, dir_fd=parent)
    except OSError as e:
        raise Fail(code(e, "not_a_file"), f"{names[-1]}: {e.strerror}")
    finally:
        os.close(parent)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise Fail("not_a_file", f"{names[-1]} is not a regular file")
    return fd


def op_read(root_fd, names):
    fd = open_file(root_fd, names)
    st = os.fstat(fd)
    if st.st_size > MAX_TEXT:
        os.close(fd)
        raise Fail("too_large", f"the file is larger than {MAX_TEXT} bytes; download it instead")
    with os.fdopen(fd, "rb") as f:
        data = f.read(MAX_TEXT + 1)
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        raise Fail("not_text", "the file is not UTF-8 text; download it instead")
    if "\x00" in text:
        raise Fail("not_text", "the file is binary; download it instead")
    return {"schema": "simai-file/1", "path": "/".join(names), "size": len(data), "mtime": int(st.st_mtime),
            "sha256": hashlib.sha256(data).hexdigest(), "content": text}


def op_cat(root_fd, names):
    fd = open_file(root_fd, names)
    out = sys.stdout.buffer
    with os.fdopen(fd, "rb") as f:
        while True:
            chunk = f.read(1 << 20)
            if not chunk:
                break
            out.write(chunk)
    out.flush()


def op_write(root_fd, names, expect):
    if not names:
        raise Fail("not_a_file", "the site directory is not a file")
    data = sys.stdin.buffer.read(MAX_TEXT + 1)
    if len(data) > MAX_TEXT:
        raise Fail("too_large", f"content larger than {MAX_TEXT} bytes")
    parent = walk(root_fd, names)
    name, mode = names[-1], 0o644
    try:
        try:
            st = os.stat(name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            st = None
        if st is not None:
            if not stat.S_ISREG(st.st_mode):
                raise Fail("not_a_file", f"{name} is not a regular file")
            mode = stat.S_IMODE(st.st_mode)
            if expect == "new":
                raise Fail("exists", f"{name} already exists")
            if expect not in ("new", "any"):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
                with os.fdopen(fd, "rb") as f:
                    if hashlib.sha256(f.read()).hexdigest() != expect:
                        raise Fail("changed", f"{name} changed since it was read")
        elif expect not in ("new", "any"):
            raise Fail("changed", f"{name} no longer exists")
        tmp = f".{name[:200]}.simai-{os.getpid()}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=parent)
        try:
            with os.fdopen(fd, "wb") as f:
                os.fchmod(f.fileno(), mode)  # the umask must not narrow it
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.rename(tmp, name, src_dir_fd=parent, dst_dir_fd=parent)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=parent)
            except OSError:
                pass
            raise
    finally:
        os.close(parent)
    return {"schema": "simai-file-stat/1", "path": "/".join(names), "type": "file", "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest()}


def op_stat(root_fd, names):
    if not names:
        st = os.fstat(root_fd)
        return {"schema": "simai-file-stat/1", "path": "", **entry("", st, root_fd)}
    parent = walk(root_fd, names)
    try:
        return {"schema": "simai-file-stat/1", "path": "/".join(names), **entry(names[-1], lstat(parent, names[-1]), parent)}
    finally:
        os.close(parent)


def op_mkdir(root_fd, names):
    if not names:
        raise Fail("exists", "the site directory exists")
    parent = walk(root_fd, names)
    try:
        os.mkdir(names[-1], 0o755, dir_fd=parent)
    except FileExistsError:
        raise Fail("exists", f"{names[-1]} already exists")
    finally:
        os.close(parent)
    return {"schema": "simai-file-stat/1", "path": "/".join(names), "type": "dir"}


def op_rename(root_fd, names, new):
    if not names or not new:
        raise Fail("bad_path", "the site directory itself cannot be renamed")
    if new[:len(names)] == names:
        raise Fail("bad_path", "a directory cannot move into itself")
    src, dst = walk(root_fd, names), walk(root_fd, new)
    try:
        lstat(src, names[-1])
        try:
            os.stat(new[-1], dir_fd=dst, follow_symlinks=False)
            raise Fail("exists", f"{new[-1]} already exists")
        except FileNotFoundError:
            pass
        os.rename(names[-1], new[-1], src_dir_fd=src, dst_dir_fd=dst)
    finally:
        os.close(src)
        os.close(dst)
    return {"schema": "simai-file-stat/1", "path": "/".join(new), "from": "/".join(names)}


def remove_tree(parent, name):
    fd = os.open(name, DIR_FLAGS, dir_fd=parent)
    try:
        with os.scandir(fd) as it:
            children = [(de.name, de.is_dir(follow_symlinks=False)) for de in it]
        for child, is_dir in children:
            if is_dir:
                remove_tree(fd, child)
            else:
                os.unlink(child, dir_fd=fd)
    finally:
        os.close(fd)
    os.rmdir(name, dir_fd=parent)


def op_remove(root_fd, names):
    if not names:
        raise Fail("bad_path", "the site directory itself cannot be removed")
    parent = walk(root_fd, names)
    try:
        st = lstat(parent, names[-1])
        if stat.S_ISDIR(st.st_mode):
            remove_tree(parent, names[-1])
        else:
            os.unlink(names[-1], dir_fd=parent)
    finally:
        os.close(parent)
    return {"schema": "simai-file-stat/1", "path": "/".join(names), "removed": kind(st.st_mode)}


def main(argv):
    op, root, rel = argv[0], argv[1], argv[2]
    names = parts(rel)
    root_fd = open_root(root)
    if op == "cat":
        op_cat(root_fd, names)
        return
    if op == "write":
        result = op_write(root_fd, names, argv[3])
    elif op == "rename":
        result = op_rename(root_fd, names, parts(argv[3]))
    else:
        result = {"list": op_list, "stat": op_stat, "read": op_read, "mkdir": op_mkdir,
                  "remove": op_remove}[op](root_fd, names)
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Fail as f:
        print(f"error: {f.args[0]}: {f.args[1]}", file=sys.stderr)
        sys.exit(2)
    except PermissionError as e:
        print(f"error: permission_denied: {e.strerror}", file=sys.stderr)
        sys.exit(2)
    except OSError as e:
        print(f"error: os_error: {e.strerror}", file=sys.stderr)
        sys.exit(2)
