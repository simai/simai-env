# file commands

Run with `sudo /root/simai-env/simai-admin.sh file <command> --domain D [options]`.

The site's files for the panel's file manager. Every command works inside the
site directory (`/home/simai/www/<domain>/`) and runs as the site's user,
never as root: what the site user cannot read or change, the command cannot
either. Paths are relative to the site directory. Each one is walked a
component at a time without following symbolic links, so `..`, a link to
`/etc` or a directory swapped for a link while the command runs never lead
outside. Links are listed and can be removed, but are never followed.

Errors read `error: <code>: <message>`: `bad_path`, `not_found`,
`not_a_directory`, `not_a_file`, `permission_denied`, `exists`, `changed`,
`too_large`, `not_text`, `bad_archive`.

## list
`--path P` (default: the site directory). `--output json` answers
`simai-files/1`: `path, entries [{name, type: dir|file|link|other, size,
mtime, mode, target (links)}], truncated` (at most 5000 entries; directories
first).

## stat
One entry, `simai-file-stat/1`: `path, name, type, size, mtime, mode,
target`.

## read
A UTF-8 text file up to 1 MiB, `simai-file/1`: `path, size, mtime, sha256,
content`. A larger or binary file is refused (`too_large`, `not_text`);
download it instead.

## cat
The raw bytes of one regular file to stdout. The panel gateway streams it as
`file:download`.

## write
`--path P --content-file F [--expect-sha256 S|new|any] --confirm yes`.
Replaces or creates the file atomically (a temporary file in the same
directory, then a rename), keeping its mode. `--expect-sha256` with the
sha256 from `read` fails `changed` if someone changed the file meanwhile;
`new` fails `exists` if it is already there. Up to 1 MiB.

## upload
`--path P --source F --sha256 S [--expect-sha256 new|any|<sha256>] --confirm
yes`. Puts any file up to 1 GiB at `P`, written the same atomic way as
`write`. `--sha256` must match `F` before anything is written. By default
(`new`) an existing file is not replaced; `any` replaces it.

## archive
`--path P --to Q --confirm yes`. Packs the file or directory `P` into the new
archive `Q`: `.zip`, `.tar.gz`, `.tgz` or `.tar` by its name. Links are
stored as links and never followed; sockets and devices are left out. `Q`
cannot be inside `P`.

## extract
`--path P --to D [--overwrite yes|no] --confirm yes`. Unpacks `P` (`.zip`,
`.tar.gz`, `.tgz`, `.tar`) into the directory `D`, created if missing. Only
files and directories are unpacked; links, hard links and devices are
skipped and counted. An entry with an absolute name or `..` refuses the whole
archive (`bad_archive`), as does one with more than 100000 entries or 8 GiB.
Without `--overwrite yes` nothing is written if any file already exists.
The answer counts `files`, `dirs` and `skipped`.

## mkdir
`--path P --confirm yes`. The parent must exist.

## rename
`--path P --to Q --confirm yes`. Renames or moves within the site
directory; fails `exists` if `Q` exists, and a directory cannot move into
itself.

## remove
`--path P --confirm yes`. A file, a link (its target stays) or a directory
with everything in it. The site directory itself cannot be removed. Take
`backup data` first when in doubt: there is no trash.

```bash
sudo /root/simai-env/simai-admin.sh file list --domain example.com --path public
sudo /root/simai-env/simai-admin.sh file read --domain example.com --path public/robots.txt
```
