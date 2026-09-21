# Runtime observer

`observer` creates a private shadow Git repository for a registered project. It
records deployable files and structural Bitrix database metadata without
turning the live web root into a Git checkout.

The observer is intended for short, declared maintenance sessions when a
developer works directly on a server. It does not replace canonical module
repositories or deployment from a reviewed commit.

## Scope and privacy

Tracked files are copied from the registered project root. The following are
excluded:

- `.env`, Bitrix database configuration and private keys;
- `public/bitrix` and `public/upload`;
- caches, logs, backups and archives.

Symlink paths, targets and canonical Git commits are recorded separately. The
database snapshot contains iblock/HL definitions, camp iblock structure,
section/element metadata and hashes of SIMAI option values. Option values and
database credentials are not stored.

The repository is created under `/var/lib/simai-env/runtime-observer/<project>/`
with root-only permissions. It must not be exposed through nginx or pushed to a
public remote.

The scheduled snapshot runs as root, so the observer refuses to work when any
directory of its storage path is not owned by root or is writable by other
users. Storage inside `/home/simai` is rejected because site PHP processes run
as `simai`. The session state file is parsed as data and never executed.

### Migrating from `/home/simai/runtime-observer`

Earlier builds used `/home/simai/runtime-observer`. `observer doctor` reports
such storage as `FAIL`. Move it once as root:

```bash
sudo install -d -m 0700 -o root -g root /var/lib/simai-env/runtime-observer
sudo mv /home/simai/runtime-observer/<project> /var/lib/simai-env/runtime-observer/
sudo chown -R root:root /var/lib/simai-env/runtime-observer
sudo chmod -R go-rwx /var/lib/simai-env/runtime-observer
```

Check the moved `state/active.env` before the next scheduled snapshot.

## Initial setup

```bash
sudo /root/simai-env/simai-admin.sh observer init --domain rim1.ru --schedule yes
sudo /root/simai-env/simai-admin.sh observer doctor --domain rim1.ru
```

`--schedule yes` installs a five-minute snapshot task. A snapshot outside a
declared session is committed as `unattributed`.

## Developer session

Before access is handed to the developer:

```bash
sudo /root/simai-env/simai-admin.sh observer start \
  --domain rim1.ru --actor yura --note 'ticket or short purpose'
```

During the work:

```bash
sudo /root/simai-env/simai-admin.sh observer status --domain rim1.ru
```

After smoke testing:

```bash
sudo /root/simai-env/simai-admin.sh observer finish \
  --domain rim1.ru --note 'accepted or rejected with reason'
```

The resulting commits show the file and structural database delta. Accepted
changes must then be reproduced in their canonical repositories or installer
manifests. Do not copy the shadow repository back over source code.

## Attribution boundary

The SFTP account and active observer session establish a practical attribution
window, not a kernel-level per-operation audit trail. Changes by root, Bitrix
admin users or background tasks in the same window can appear in the same
delta. Bitrix administrative changes therefore also require the Bitrix user
and ticket to be recorded in the session note.

## Stop and rollback

Disable developer access immediately:

```bash
sudo /root/simai-env/simai-admin.sh access disable --login yura
```

Remove only the observer schedule to stop automatic snapshots:

```bash
sudo rm -f /etc/cron.d/simai-runtime-observer-rim1-ru
```

The observer is evidence, not a live rollback engine. Runtime rollback uses the
project backup and canonical deployment procedure. Database rollback requires
a database backup; a structural snapshot is not sufficient for restoration.
