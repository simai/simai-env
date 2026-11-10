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
  write PATH EXPECT    text from stdin (up to 1 MiB); EXPECT is a sha256, "new" or "any"
  put PATH EXPECT      any bytes from stdin (an upload, up to 1 GiB), the same EXPECT
  mkdir PATH
  rename PATH NEWPATH
  remove PATH          a file, a link, or a directory with everything in it
  archive PATH DEST    pack a file or directory into DEST (.tar.gz, .tgz or .zip, new);
                       links are stored as links, never followed
  extract PATH DEST OVERWRITE  unpack a .tar.gz/.tgz/.tar/.zip into the directory
                       DEST (created if missing); only files and directories, names
                       that stay inside DEST; OVERWRITE yes|no
  volumes PATH         the volumes of one backup archive (simai-file-volumes/1): PATH
                       is the base volume (<name>.tar.gz, .tgz, .tar or .enc.gz, or
                       one of its parts .N) or a directory holding exactly one
  gather PATH DEST     move those volumes into the directory DEST (same answer, with
                       "moved"); a name that already exists in DEST is refused
Errors go to stderr as "error: <code>: <message>", exit code 2.
"""
import hashlib
import json
import os
import re
import stat
import sys
import tarfile
import time
import zipfile

MAX_ENTRIES = 5000
MAX_TEXT = 1 << 20
MAX_UPLOAD = 1 << 30
MAX_MEMBERS = 100000  # an archive with more entries is refused
MAX_UNPACKED = 8 << 30  # nor one that unpacks to more bytes
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


def check_expect(parent, name, expect):
    """The mode to keep; fails when the file is not what the caller saw."""
    try:
        st = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        if expect not in ("new", "any"):
            raise Fail("changed", f"{name} no longer exists")
        return 0o644
    if not stat.S_ISREG(st.st_mode):
        raise Fail("not_a_file", f"{name} is not a regular file")
    if expect == "new":
        raise Fail("exists", f"{name} already exists")
    if expect != "any":
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=parent)
        digest = hashlib.sha256()
        with os.fdopen(fd, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                digest.update(chunk)
        if digest.hexdigest() != expect:
            raise Fail("changed", f"{name} changed since it was read")
    return stat.S_IMODE(st.st_mode)


def save(parent, name, mode, src, limit):
    """Write src to name atomically (a temporary file, then a rename); size and sha256."""
    tmp = f".{name[:200]}.simai-{os.getpid()}"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, mode, dir_fd=parent)
    digest, size = hashlib.sha256(), 0
    try:
        with os.fdopen(fd, "wb") as f:
            os.fchmod(f.fileno(), mode)  # the umask must not narrow it
            while True:
                chunk = src.read(1 << 20)
                if not chunk:
                    break
                size += len(chunk)
                if size > limit:
                    raise Fail("too_large", f"content larger than {limit} bytes")
                digest.update(chunk)
                f.write(chunk)
            f.flush()
            os.fsync(f.fileno())
        os.rename(tmp, name, src_dir_fd=parent, dst_dir_fd=parent)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=parent)
        except OSError:
            pass
        raise
    return size, digest.hexdigest()


def op_write(root_fd, names, expect, limit=MAX_TEXT):
    if not names:
        raise Fail("not_a_file", "the site directory is not a file")
    parent = walk(root_fd, names)
    try:
        mode = check_expect(parent, names[-1], expect)
        size, sha = save(parent, names[-1], mode, sys.stdin.buffer, limit)
    finally:
        os.close(parent)
    return {"schema": "simai-file-stat/1", "path": "/".join(names), "type": "file", "size": size, "sha256": sha}


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


def archive_format(name):
    low = name.lower()
    if low.endswith((".tar.gz", ".tgz")):
        return "tar.gz"
    if low.endswith(".tar"):
        return "tar"
    if low.endswith(".zip"):
        return "zip"
    raise Fail("bad_archive", "the archive name must end with .tar.gz, .tgz, .tar or .zip")


def walk_tree(dir_fd, prefix):
    """(relative name, stat, parent fd) for everything under dir_fd, links not followed."""
    with os.scandir(dir_fd) as it:
        names = sorted(de.name for de in it)
    for name in names:
        st = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
        rel = f"{prefix}/{name}" if prefix else name
        yield rel, st, dir_fd, name
        if stat.S_ISDIR(st.st_mode):
            sub = os.open(name, DIR_FLAGS, dir_fd=dir_fd)
            try:
                yield from walk_tree(sub, rel)
            finally:
                os.close(sub)


def op_archive(root_fd, names, dest):
    if not names or not dest:
        raise Fail("bad_path", "name what to pack and the archive to create")
    fmt = archive_format(dest[-1])
    if dest[:len(names)] == names:
        raise Fail("bad_path", "the archive cannot be inside what it packs")
    src_parent, dst_parent = walk(root_fd, names), walk(root_fd, dest)
    count = 0
    try:
        top = lstat(src_parent, names[-1])
        try:
            os.stat(dest[-1], dir_fd=dst_parent, follow_symlinks=False)
            raise Fail("exists", f"{dest[-1]} already exists")
        except FileNotFoundError:
            pass
        top_fd = os.open(names[-1], DIR_FLAGS, dir_fd=src_parent) if stat.S_ISDIR(top.st_mode) else None

        def items():
            # Each directory descriptor is open only while its entries are packed.
            yield names[-1], top, src_parent, names[-1]
            if top_fd is not None:
                for rel, st, fd, n in walk_tree(top_fd, names[-1]):
                    yield rel, st, fd, n
        tmp = f".{dest[-1][:200]}.simai-{os.getpid()}"
        out_fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644,
                         dir_fd=dst_parent)
        try:
            with os.fdopen(out_fd, "wb") as out:
                if fmt == "zip":
                    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
                        for rel, st, fd, n in items():
                            count += zip_add(z, rel, st, fd, n)
                else:
                    with tarfile.open(fileobj=out, mode="w:gz" if fmt == "tar.gz" else "w") as t:
                        for rel, st, fd, n in items():
                            count += tar_add(t, rel, st, fd, n)
                out.flush()
                os.fsync(out.fileno())
            os.rename(tmp, dest[-1], src_dir_fd=dst_parent, dst_dir_fd=dst_parent)
        except BaseException:
            try:
                os.unlink(tmp, dir_fd=dst_parent)
            except OSError:
                pass
            raise
        finally:
            if top_fd is not None:
                os.close(top_fd)
    finally:
        os.close(src_parent)
        os.close(dst_parent)
    return {"schema": "simai-file-stat/1", "path": "/".join(dest), "type": "file", "packed": count}


def open_member(fd, name):
    return os.fdopen(os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=fd), "rb")


def tar_add(t, rel, st, fd, name):
    info = tarfile.TarInfo(rel)
    info.mtime, info.mode = int(st.st_mtime), stat.S_IMODE(st.st_mode)
    if stat.S_ISDIR(st.st_mode):
        info.type = tarfile.DIRTYPE
        t.addfile(info)
    elif stat.S_ISLNK(st.st_mode):
        info.type, info.linkname = tarfile.SYMTYPE, os.readlink(name, dir_fd=fd)
        t.addfile(info)
    elif stat.S_ISREG(st.st_mode):
        with open_member(fd, name) as f:
            info.size = os.fstat(f.fileno()).st_size
            t.addfile(info, f)
    else:
        return 0  # sockets, devices, pipes are not packed
    return 1


def zip_add(z, rel, st, fd, name):
    info = zipfile.ZipInfo(rel + ("/" if stat.S_ISDIR(st.st_mode) else ""),
                           time.localtime(max(st.st_mtime, 315532800))[:6])
    if stat.S_ISDIR(st.st_mode):
        info.external_attr = (0o40000 | stat.S_IMODE(st.st_mode)) << 16
        z.writestr(info, b"")
    elif stat.S_ISLNK(st.st_mode):
        info.external_attr = (0o120000 | 0o777) << 16
        z.writestr(info, os.readlink(name, dir_fd=fd))
    elif stat.S_ISREG(st.st_mode):
        info.external_attr = (0o100000 | stat.S_IMODE(st.st_mode)) << 16
        info.compress_type = zipfile.ZIP_DEFLATED
        with open_member(fd, name) as f, z.open(info, "w", force_zip64=True) as w:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                w.write(chunk)
    else:
        return 0
    return 1


def members(src, fmt):
    """(names, kind dir|file|skip, mode, open()) for each entry, names checked."""
    if fmt == "zip":
        z = zipfile.ZipFile(src)
        infos = z.infolist()
        if len(infos) > MAX_MEMBERS or sum(i.file_size for i in infos) > MAX_UNPACKED:
            raise Fail("too_large", "the archive holds too many entries or bytes")
        for i in infos:
            mode = i.external_attr >> 16
            kind = "dir" if i.is_dir() else "skip" if stat.S_ISLNK(mode) else "file"
            yield parts_member(i.filename), kind, (stat.S_IMODE(mode) & 0o777) or (0o755 if kind == "dir" else 0o644), \
                (lambda i=i: z.open(i))
        return
    t = tarfile.open(fileobj=src, mode="r:*")
    total = count = 0
    for m in t:
        count += 1
        total += m.size if m.isfile() else 0
        if count > MAX_MEMBERS or total > MAX_UNPACKED:
            raise Fail("too_large", "the archive holds too many entries or bytes")
        kind = "dir" if m.isdir() else "file" if m.isfile() else "skip"
        yield parts_member(m.name), kind, stat.S_IMODE(m.mode) & 0o777, (lambda m=m: t.extractfile(m))


def parts_member(name):
    if name.startswith("/") or "\\" in name:
        raise Fail("bad_archive", f"an entry outside the destination: {name[:200]}")
    try:
        return parts(name)
    except Fail:
        raise Fail("bad_archive", f"an entry outside the destination: {name[:200]}")


def ensure_dirs(root_fd, names):
    """Create the directories names (as needed); a descriptor of the last one."""
    fd = os.dup(root_fd)
    for name in names:
        try:
            os.mkdir(name, 0o755, dir_fd=fd)
        except FileExistsError:
            pass
        try:
            nxt = os.open(name, DIR_FLAGS, dir_fd=fd)
        except OSError as e:
            os.close(fd)
            raise Fail("not_a_directory", f"{name}: {e.strerror}")
        os.close(fd)
        fd = nxt
    return fd


def op_extract(root_fd, names, dest, overwrite):
    fmt = archive_format(names[-1] if names else "")
    src = os.fdopen(open_file(root_fd, names), "rb")
    dest_fd = ensure_dirs(root_fd, dest)
    files = dirs = skipped = 0
    try:
        entries = list(members(src, fmt))
        if overwrite != "yes":
            clash = []
            for mnames, kind, _, _ in entries:
                if kind == "file" and mnames:
                    try:
                        parent = walk(dest_fd, mnames)
                    except Fail:
                        continue
                    try:
                        os.stat(mnames[-1], dir_fd=parent, follow_symlinks=False)
                        clash.append("/".join(mnames))
                    except FileNotFoundError:
                        pass
                    finally:
                        os.close(parent)
            if clash:
                raise Fail("exists", f"{len(clash)} file(s) already exist, e.g. {clash[0][:200]}; use overwrite")
        for mnames, kind, mode, opener in entries:
            if not mnames or kind == "skip":
                skipped += kind == "skip"
                continue
            if kind == "dir":
                os.close(ensure_dirs(dest_fd, mnames))
                dirs += 1
                continue
            parent = ensure_dirs(dest_fd, mnames[:-1])
            try:
                try:
                    st = os.stat(mnames[-1], dir_fd=parent, follow_symlinks=False)
                    if not stat.S_ISREG(st.st_mode):
                        raise Fail("exists", f"{'/'.join(mnames)[:200]} exists and is not a file")
                except FileNotFoundError:
                    pass
                with opener() as f:
                    save(parent, mnames[-1], mode or 0o644, f, MAX_UNPACKED)
                files += 1
            finally:
                os.close(parent)
    except (tarfile.TarError, zipfile.BadZipFile, EOFError) as e:
        raise Fail("bad_archive", f"the archive cannot be read: {e}")
    finally:
        os.close(dest_fd)
        src.close()
    return {"schema": "simai-file-stat/1", "path": "/".join(dest), "type": "dir", "files": files, "dirs": dirs,
            "skipped": skipped}


# A backup archive: base volume and its parts <base>.1 .. <base>.N (Bitrix
# multi-volume backups). Distribution archives (*_encode.tar.gz) are not backups.
ARCHIVE_BASE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}\.(?:tar\.gz|tgz|tar|enc\.gz)$")
MAX_VOLUMES = 10000


def is_base(name):
    return bool(ARCHIVE_BASE.match(name)) and not name.endswith("_encode.tar.gz")


def volumes_at(root_fd, names):
    """(directory fd, directory names, base name, [(name, size)]) of one archive."""
    if names:
        parent = walk(root_fd, names)
        try:
            st = lstat(parent, names[-1])
            if stat.S_ISLNK(st.st_mode):
                raise Fail("link", f"{names[-1]} is a symbolic link")
            if stat.S_ISDIR(st.st_mode):
                fd, dir_names, base = os.open(names[-1], DIR_FLAGS, dir_fd=parent), names, None
            elif stat.S_ISREG(st.st_mode):
                fd, dir_names, base = os.dup(parent), names[:-1], re.sub(r"\.[0-9]+$", "", names[-1])
                if not is_base(base):
                    raise Fail("not_an_archive", f"{names[-1]} is not a backup archive volume")
            else:
                raise Fail("not_a_file", f"{names[-1]} is not a file or a directory")
        finally:
            os.close(parent)
    else:
        fd, dir_names, base = os.dup(root_fd), [], None
    try:
        present = set(os.listdir(fd))
        if base is None:
            found = sorted(n for n in present if is_base(n))
            if not found:
                raise Fail("no_archive", "no backup archive (.tar.gz, .tgz, .tar, .enc.gz) in the directory")
            if len(found) > 1:
                raise Fail("ambiguous", "more than one backup archive: " + ", ".join(found[:5]))
            base = found[0]
        vols, index = [], 0
        while index <= MAX_VOLUMES:
            name = base if index == 0 else f"{base}.{index}"
            if name not in present:
                if index == 0:
                    raise Fail("not_found", f"{base} does not exist")
                break
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISLNK(st.st_mode):
                raise Fail("link", f"{name} is a symbolic link")
            if not stat.S_ISREG(st.st_mode):
                raise Fail("not_a_file", f"{name} is not a regular file")
            if st.st_nlink != 1:
                raise Fail("hardlinked", f"{name} has other hard links")
            vols.append((name, st.st_size))
            index += 1
    except BaseException:
        os.close(fd)
        raise
    return fd, dir_names, base, vols


def volumes_answer(dir_names, base, vols):
    return {"schema": "simai-file-volumes/1", "dir": "/".join(dir_names), "base": base,
            "encrypted": base.endswith(".enc.gz"),
            "volumes": [{"name": n, "size": s} for n, s in vols], "count": len(vols),
            "total_bytes": sum(s for _, s in vols)}


def op_volumes(root_fd, names):
    fd, dir_names, base, vols = volumes_at(root_fd, names)
    os.close(fd)
    return volumes_answer(dir_names, base, vols)


def move_one(src_fd, dst_fd, name):
    """Link then unlink: never replaces a file; a copy across filesystems."""
    try:
        os.link(name, name, src_dir_fd=src_fd, dst_dir_fd=dst_fd, follow_symlinks=False)
    except FileExistsError:
        raise Fail("exists", f"{name} already exists in the destination")
    except OSError as e:
        if e.errno != 18:  # EXDEV: another filesystem
            raise
        sfd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=src_fd)
        try:
            dfd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o644,
                          dir_fd=dst_fd)
        except FileExistsError:
            os.close(sfd)
            raise Fail("exists", f"{name} already exists in the destination")
        try:
            with os.fdopen(sfd, "rb") as src, os.fdopen(dfd, "wb") as out:
                while True:
                    chunk = src.read(1 << 20)
                    if not chunk:
                        break
                    out.write(chunk)
                out.flush()
                os.fsync(out.fileno())
        except BaseException:
            os.unlink(name, dir_fd=dst_fd)
            raise
    os.unlink(name, dir_fd=src_fd)


def op_gather(root_fd, names, dest):
    fd, dir_names, base, vols = volumes_at(root_fd, names)
    try:
        if dest:
            parent = walk(root_fd, dest)
            try:
                dst_fd = os.open(dest[-1], DIR_FLAGS, dir_fd=parent)
            except OSError as e:
                raise Fail(code(e, "not_a_directory"), f"{dest[-1]}: {e.strerror}")
            finally:
                os.close(parent)
        else:
            dst_fd = os.dup(root_fd)
        moved = []
        try:
            a, b = os.fstat(fd), os.fstat(dst_fd)
            if (a.st_dev, a.st_ino) != (b.st_dev, b.st_ino):
                for name, _ in vols:
                    try:
                        os.stat(name, dir_fd=dst_fd, follow_symlinks=False)
                        raise Fail("exists", f"{name} already exists in the destination")
                    except FileNotFoundError:
                        pass
                for name, _ in vols:
                    move_one(fd, dst_fd, name)
                    moved.append(name)
        finally:
            os.close(dst_fd)
    finally:
        os.close(fd)
    answer = volumes_answer(dest, base, vols)
    answer.update({"from": "/".join(dir_names), "moved": moved})
    return answer


def main(argv):
    op, root, rel = argv[0], argv[1], argv[2]
    names = parts(rel)
    root_fd = open_root(root)
    if op == "cat":
        op_cat(root_fd, names)
        return
    if op == "write":
        result = op_write(root_fd, names, argv[3])
    elif op == "put":
        result = op_write(root_fd, names, argv[3], MAX_UPLOAD)
    elif op == "archive":
        result = op_archive(root_fd, names, parts(argv[3]))
    elif op == "extract":
        result = op_extract(root_fd, names, parts(argv[3]), argv[4])
    elif op == "rename":
        result = op_rename(root_fd, names, parts(argv[3]))
    elif op == "gather":
        result = op_gather(root_fd, names, parts(argv[3]))
    else:
        result = {"list": op_list, "stat": op_stat, "read": op_read, "mkdir": op_mkdir,
                  "remove": op_remove, "volumes": op_volumes}[op](root_fd, names)
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
