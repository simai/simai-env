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
`too_large`, `not_text`, `bad_archive`, and for the trash `bad_id`,
`no_trash`, `cross_device`, `secret`.

Files with passwords (1.62.2): `.env` and `.env.*` (not `.env.example`,
`.env.sample`, `.env.dist`, `.env.template`), `wp-config.php`,
`.settings.php`, `.settings_extra.php`, `dbconn.php`, `auth.json`,
`.htpasswd`, `.my.cnf`, `.pgpass`, `.netrc`, `id_rsa`, `id_ecdsa`,
`id_ed25519` and `*.pem`, `*.key`, `*.p12`, `*.pfx`. Listings, `stat` and
the trash mark them `secret: true`; the panel shows and changes them only
to people with that right. `archive` and `extract` take `--without-secrets
yes` for the others.

## list
`--path P` (default: the site directory). `--output json` answers
`simai-files/1`: `path, entries [{name, type: dir|file|link|other, size,
mtime, mode, target (links), secret (1.62.2)}], truncated` (at most 5000 entries; directories
first).

## stat
One entry, `simai-file-stat/1`: `path, name, type, size, mtime, mode,
target`.

## preview
Show an image or the start of a text file without downloading it (1.61.0).

Usage: `simai-admin.sh file preview --domain <domain> --path <path> [--max-bytes 1048576] [--output json]`

`simai-file-preview/1`: `path`, `size`, `mtime`, `kind` (`image` or
`text`), `mime`, `encoding` (`base64` for an image, `utf-8` for text),
`truncated`, `bytes` and `sha256` of what is returned, and `content`.
An image (PNG, JPEG, GIF, WebP, BMP, ICO) comes whole or is refused
`too_large` past `--max-bytes`; a text file comes cut at that size on a
whole character. Other binaries are refused `not_previewable`.
`--max-bytes` is 1–5242880 (5 MiB), 1 MiB by default.

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
`--path P --source F --sha256 S [--expect-sha256 new|any|<sha256>] --confirm yes`. Puts any file up to 1 GiB at `P`, written the same atomic way as
`write`. `--sha256` must match `F` before anything is written. By default
(`new`) an existing file is not replaced; `any` replaces it.

## archive
`--path P --to Q --confirm yes`. Packs the file or directory `P` into the new
archive `Q`: `.zip`, `.tar.gz`, `.tgz` or `.tar` by its name. Links are
stored as links and never followed; sockets and devices are left out. `Q`
cannot be inside `P`. With `--without-secrets yes` files with passwords and
the trash are left out and listed in `secret_skipped`; packing such a file
itself is refused (`secret`).

## extract
`--path P --to D [--overwrite yes|no] --confirm yes`. Unpacks `P` (`.zip`,
`.tar.gz`, `.tgz`, `.tar`) into the directory `D`, created if missing. Only
files and directories are unpacked; links, hard links and devices are
skipped and counted. An entry with an absolute name or `..` refuses the whole
archive (`bad_archive`), as does one with more than 100000 entries or 8 GiB.
Without `--overwrite yes` nothing is written if any file already exists.
The answer counts `files`, `dirs` and `skipped`. With `--without-secrets
yes` entries that are files with passwords are neither created nor
overwritten (an existing `.env` stays as it was) and are listed in
`secret_skipped`; they do not count as a clash for `--overwrite no`.

## mkdir
`--path P --confirm yes`. The parent must exist.

## rename
`--path P --to Q --confirm yes`. Renames or moves within the site
directory; fails `exists` if `Q` exists, and a directory cannot move into
itself.

## copy
`--path P --to Q --confirm yes` (1.57.0). Copies the file or directory `P`
to `Q` inside the site directory, keeping modes and file times. Links are
copied as links and never followed; sockets and devices are left out. Fails
`exists` if `Q` exists; a directory cannot be copied into itself. The copy is
written under a hidden name next to `Q` first, so a failed copy leaves
nothing at `Q`. Without `--confirm yes` the plan already reports a missing
`P`, an existing `Q` or a bad path.

## remove
`--path P [--permanent yes] --confirm yes`. Since 1.57.0 a file, a link (its
target stays) or a directory with everything in it is moved into the site's
trash, not deleted; `--permanent yes` deletes it for good (the panel gateway
never passes it). The site directory itself cannot be removed, nor the trash
itself. The answer carries `trash_id`.

## Overwrites keep the previous version (1.64.0)
`write`, `upload` and `extract --overwrite yes` never lose the file they
replace: before the new content takes its name, the old file goes into the
trash as an entry with `reason: overwritten` (a hard link, or a copy where a
link is not allowed), under the same 7-day retention, and comes back with
`trash-restore` (use `--to` while the new file is in place). `write` and
`upload` answer `previous_trash_id` (null for a new file); `extract` answers
`trashed` (count) and `trash_ids` (up to 1000; a panel job result keeps 30).
If the old version cannot be kept, nothing is replaced and the command fails
`trash_failed`.

## Trash (1.57.0)
The trash is `<site directory>/.simai-trash/` (for example
`/home/simai/www/example.com/.simai-trash/`), created on the first `remove`,
owned by the site user with mode 700. It is outside the served `public/`
directory (and nginx refuses every dot path anyway), outside `releases/`, so
a release rollback never touches it, and it counts toward the site: its disk
use, backups and `site remove --remove-files`. Each entry is
`.simai-trash/<id>/` holding `item` (the removed file or directory, moved
without copying) and `meta.json` (`path`, `type`, `size`, `deleted_at`). The
id is the UTC deletion time plus six hex characters, e.g.
`20261116T120000Z-1a2b3c`. A path on another filesystem (a mount inside the
site) cannot be moved and is refused `cross_device`; remove it with
`--permanent yes`.

Retention: entries are kept 7 days (30 before 1.61.0). Every trash command
(`remove`, `trash-list`, `trash-restore`, `trash-empty`) first deletes the
entries older than that, and `self status-refresh` prunes every site's trash
at most once an hour, so an untouched trash empties itself too. The age
comes from the id.

### trash-list
`--domain D`. `--output json` answers `simai-file-trash/1`: `dir,
retention_days, entries [{id, path, name, type, size, deleted_at,
expires_at, secret, reason}] (newest first), count, total_bytes`. Times are
Unix seconds; `reason` is `removed` or `overwritten` (1.64.0).

### trash-restore
`--domain D --id ID [--to P] --confirm yes`. Moves the entry back to where it
was, or to `P`; missing parent directories are created. Fails `exists` if the
target exists (the plan already says so), `not_found` for an unknown id,
`bad_id` for a malformed one.

### trash-empty
`--domain D [--id ID] [--dry-run yes] --confirm yes`. Deletes one entry, or
the whole trash, for good, and answers `removed, count, items, bytes`. With
`--dry-run yes` (1.64.0) nothing is deleted: the answer is `{dry_run: true,
items, bytes, ids}`. The panel plan of `file:trash-empty` carries the same as
`trash: {items, bytes, ids}`.

```bash
sudo /root/simai-env/simai-admin.sh file list --domain example.com --path public
sudo /root/simai-env/simai-admin.sh file read --domain example.com --path public/robots.txt
```
