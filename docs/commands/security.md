# security commands

Run with `sudo /root/simai-env/simai-admin.sh security <command> [options]`.

The security center checks the server and its sites by itself, gives a score
from 0 to 100, lists the problems with the most serious first, and fixes many
of them in one step. Nothing has to be configured: the status refresh (every
five minutes) keeps the report current, and the vulnerability databases are
asked once a day.

## status
```bash
sudo /root/simai-env/simai-admin.sh security status
sudo /root/simai-env/simai-admin.sh security status --output json
```

`simai-security/1`: `score`, `grade` (`good` 90+, `attention` 70+, `risk`),
`summary {risk, warn, ok, unknown}`, `recommendations` (check ids, risks first,
then by severity), `online {enabled, checked_at, error}`, `checks [{id, check,
area, title, status: ok|warn|risk|unknown, severity: low|medium|high|critical,
detail, domain, fix: {command, args} | null, how}]` and `vulnerabilities
{domain: [{ecosystem, package, version, id, aliases, severity, summary,
fixed}]}`. `fix` is a panel gateway command that resolves the problem (its
CLI form is `simai-admin.sh <section> <command> --<arg> <value> --confirm
yes`); `how` says what to do when there is none.

Checks:

| Check | Area | What it looks at | Fix |
| --- | --- | --- | --- |
| `security_updates` | updates | packages with fixes in the `-security` pocket | `software:update {security-only: yes}` |
| `auto_updates` | updates | unattended upgrades on | `security:fix {check: auto_updates}` |
| `reboot_required` | updates | a restart is needed after updates | how |
| `ssh_password` | access | SSH accepts passwords | `security:fix {check: ssh_password}` (only when an SSH key is set) |
| `ssh_root` | access | root may log in with a password | same |
| `firewall` | network | ufw active | `self:firewall-ensure` |
| `fail2ban` | network | Fail2ban running | `security:fix {check: fail2ban}` |
| `exposed_services` | network | MySQL, PostgreSQL, Redis, Memcached, PHP-FPM and others listening on all addresses | how |
| `panel_access` | access | the panel limited to addresses | how (`panel access`) |
| `php_eol:<domain>` | sites | the site's PHP past upstream support (the Ubuntu release's own PHP is patched by Ubuntu and is fine) | how |
| `https:<domain>` | sites | the site has no certificate | `ssl:letsencrypt {domain}` |
| `certificate:<domain>` | sites | the certificate expires within 14 days | `ssl:renew {domain}` |
| `backup_schedule:<domain>` | backups | no daily backup | `backup:data-schedule {domain, enabled: yes}` |
| `backup_verify:<domain>` | backups | no successful check of a backup in a month | `backup:data-schedule {..., verify: yes}` |
| `backup_offsite:<domain>` | backups | the last upload to the storage failed | `backup:storage-test {name}` |
| `backup_storage` | backups | no S3 storage for copies | how |
| `site_components:<domain>` | sites | known vulnerabilities in `composer.lock` and `package-lock.json` packages (OSV) | how |
| `wordpress_core:<domain>` | sites | WordPress older than the current release | how |
| `vulnerability_scan` | sites | the databases could not be asked yet | `security:scan` |
| `antivirus` | sites | ClamAV installed | `security:fix {check: antivirus}` |
| `file_scan` | sites | site files not checked yet | `security:files-scan` |
| `malware:<domain>` | sites | suspicious files found (critical) | how (`security:quarantine`) |

The score loses points for every kind of open problem: a risk loses 30, 15, 7
or 2 points by severity, a warning about half of that; the same problem on
further sites costs one more point each (up to 5).

Serious problems (a risk of high or critical severity) also open
`security_risk` alerts (`self alerts`), which go to the alert channel.

## scan
```bash
sudo /root/simai-env/simai-admin.sh security scan --confirm yes
```
Asks the vulnerability databases now. The scan sends only package names and
versions from each site's lock files to OSV (`api.osv.dev`, which collects
GitHub, PHP, npm and other advisories) and asks `api.wordpress.org` for the
current WordPress version. Set `SIMAI_SECURITY_ONLINE=no` in
`/etc/simai-env.conf` to keep the server offline; the local checks still run.
Lock files are read as data (up to 20 MB, valid package names only).

## files-scan, files
```bash
sudo /root/simai-env/simai-admin.sh security files-scan --domain example.com --confirm yes
sudo /root/simai-env/simai-admin.sh security files --output json
```
Checks site files (the current release of a site with releases) for web
shells and malware: simai-env's own signatures of PHP backdoors always (code
evaluated from encoded strings, commands run from request input, known shell
kits, PHP code in upload folders), and ClamAV when it is installed (`security
fix --check antivirus`; `clamdscan` when its daemon runs, else `clamscan` at
the lowest priority). `.git`, `node_modules` and caches are skipped; symlinks
are not followed. Every night between 02:00 and 06:00 the status refresh scans
all sites by itself.

`security files` (`simai-file-scan/1`): `checked_at`, `engines`, `sites
{domain: {scanned, found [{path, signature, engine, size, sha256, modified}],
error, seconds, first_seen}}`. Nothing is changed by a scan.

## quarantine, quarantine-list, quarantine-restore
```bash
sudo /root/simai-env/simai-admin.sh security quarantine --domain example.com --path public/shell.php --confirm yes
sudo /root/simai-env/simai-admin.sh security quarantine-list
sudo /root/simai-env/simai-admin.sh security quarantine-restore --id 3f2a9c1d4e5b --confirm yes
```
Quarantine moves a file of a site into `/var/lib/simai-env/quarantine` (root
only), so the site stops serving it; paths outside the site and symlinks are
refused. `quarantine-list` (`simai-quarantine/1`): `files [{id, domain, path,
size, mode, uid, gid, sha256, quarantined_at, state: quarantined|restored,
restored_at}]`. Restore puts a file back with its owner and mode, unless
another file took its place.

ClamAV's daemon socket (`/run/clamav/clamd.ctl`, servers with 4 GB of memory
or more) can be used by site modules such as SIMAI Guard for Bitrix.

## fix
```bash
sudo /root/simai-env/simai-admin.sh security fix --check fail2ban --confirm yes
```
- `antivirus`: installs ClamAV and its daily signature updates (`freshclam`);
  the daemon only with 4 GB of memory or more.
- `auto_updates`: installs `unattended-upgrades` and lets it install security
  updates every day (`/etc/apt/apt.conf.d/20auto-upgrades`).
- `fail2ban`: installs Fail2ban and bans an address for an hour after 5
  failed SSH logins in 10 minutes (`/etc/fail2ban/jail.d/simai.conf`).
- `ssh_password`: SSH with keys only, root by key only (`self
  ssh-hardening-ensure`). Refused while no SSH key is set for root or any
  user, so nobody is locked out. SFTP accesses with passwords keep working.

The report is kept in `/var/lib/simai-env/security/report.json` (root only).
