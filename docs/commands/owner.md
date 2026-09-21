# owner commands

Owners are accounts that run several sites, like users in hosting panels
(FastPanel, ISPmanager). All sites of one owner run as the owner's Unix user
and can read each other's files; sites of different owners, and sites with
their own `site-<slug>` user, cannot. Developers log in over SSH as the owner
to deploy.

Run with `sudo /root/simai-env/simai-admin.sh owner <command> [options]`.

## create
```bash
sudo /root/simai-env/simai-admin.sh owner create --name acme --pubkey-file /root/acme.pub
```
Creates user and group `acme` (member of `simai-owners`), home `/home/acme`
(`0750`) with links to the owner's sites in `~/sites/`. Password login is
disabled. `www-data` joins group `acme` so nginx can serve the files.

SSH keys are read only from `/etc/ssh/simai-owner-keys/<owner>` (root-owned,
see `/etc/ssh/sshd_config.d/91-simai-owners.conf`). PHP runs as the owner, so
a key written by a compromised site into `~/.ssh/authorized_keys` is ignored.

## add-key
```bash
sudo /root/simai-env/simai-admin.sh owner add-key --name acme --pubkey-file /root/dev2.pub
```

## list
Shows owners, key counts and their projects.

## remove
```bash
sudo /root/simai-env/simai-admin.sh owner remove --name acme --confirm yes
```
Refuses while the owner still runs sites.

## Assigning sites
```bash
sudo /root/simai-env/simai-admin.sh site add --domain shop.example.com --owner acme
sudo /root/simai-env/simai-admin.sh site isolate --domain old.example.com --owner acme --confirm yes
```
`site isolate --owner` moves a site from `simai`, from its own `site-*` user
(which is then deleted) or from another owner. `site remove` keeps the owner.

## Shared module checkouts and deploy scripts

Sites often symlink modules from checkouts such as `/home/simai/git/<repo>`.
Give each checkout to the owner whose sites use it, keeping the paths, so the
owner can deploy over SSH without sudo:

```bash
chown -R acme:acme /home/simai/git/<repo> /home/simai/backups/<repo>
chmod 0751 /home/simai/backups        # enter known subdirectories, no listing
git config --system --add safe.directory /home/simai/git/<repo>   # root/automation keep working
```

Checkouts must stay readable by others (`755`) if sites of other owners link
to them. Note that the owner's sites can then modify that checkout too.

Security note: the owner's shell and the owner's PHP share one account, so a
compromised site can change files the owner's developers use (for example
`~/.bashrc`). Give each client or project its own owner, and keep sites that
must not affect each other under different owners.
