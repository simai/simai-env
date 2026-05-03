# Bitrix User Documentation Fill Plan

Date: 2026-05-03

This plan defines how to fill `docs/user/bitrix/` with practical user-facing instructions based on real server scenarios.

## Goal

Make the Bitrix user documentation useful for an operator who works mainly through:

```bash
sudo /root/simai-env/simai-admin.sh menu
```

The documentation should explain what to choose in the menu, what the environment does automatically, what still requires browser/application actions, how to verify success, and what to do when common Bitrix-specific problems appear.

## Done When

- Each core Bitrix operator scenario has a dedicated user-facing guide.
- Every guide includes:
  - when to use this scenario
  - menu path
  - CLI equivalent when useful
  - expected successful result
  - verification commands
  - common mistakes or symptoms
  - safe rollback or next action when possible
- `docs/user/bitrix/README.md` acts as a readable map, not a dumping ground.
- `docs/user/profile-workflows.md` stays short and only routes users to profile folders.
- All instructions are checked against actual `simai-env` commands and at least one real or scripted scenario before being marked stable.

## Documentation Shape

Current target tree:

```text
docs/user/bitrix/
  README.md
  create-site.md
  install-vs-restore.md
  agents-cron.md
  ownership.md
  nginx-routing.md
  uploads.md
  ssl.md
  database.md
  diagnostics.md
  troubleshooting.md
```

Future files can be added only when one existing file becomes too broad. Prefer expanding existing files first.

## Fill Batches

### Batch 1: Creation And First Successful Launch

Status: completed in docs structure and first-pass user content on 2026-05-03. Future improvements should be based on new live-server findings, not on restructuring.

Target files:

- `docs/user/bitrix/create-site.md`
- `docs/user/bitrix/install-vs-restore.md`
- `docs/user/bitrix/database.md`
- `docs/user/bitrix/diagnostics.md`

Scenarios to document:

- create single-domain Bitrix site
- create wildcard/subdomain Bitrix site
- choose managed DB vs no DB during site creation
- fresh Bitrix install through browser installer
- restore existing Bitrix backup through `restore.php`
- what to do when site path already contains files
- what to check before handing the site to the developer

Acceptance checks:

- A new operator can answer what each prompt means.
- The docs clearly separate infrastructure creation from Bitrix application installation/restore.
- The docs do not imply that `site add` fully installs Bitrix by itself.

### Batch 2: SSL And DNS For Bitrix Sites

Status: completed in first-pass user content on 2026-05-03. Future improvements should be based on new provider support, screenshots, or renewal behavior changes.

Target file:

- `docs/user/bitrix/ssl.md`

Scenarios to document:

- issue normal Let's Encrypt certificate
- issue wildcard certificate for root domain plus first-level subdomains
- Cloudflare token flow
- manual DNS challenge flow and its renewal limitation
- DNS records required before issuing certificate
- how to verify certificate status from menu and CLI

Acceptance checks:

- A non-OPS user understands whether they need an `A` record, wildcard `A` record, Cloudflare token, or manual TXT entry.
- The docs clearly warn that manual DNS challenge is not suitable for unattended renewal.

### Batch 3: Cron Agents And Runtime Jobs

Status: completed in first-pass user content on 2026-05-03. Future improvements should be based on new live-server findings or menu label changes.

Target file:

- `docs/user/bitrix/agents-cron.md`

Scenarios to document:

- why Bitrix agents should run on cron
- when to run `agents-sync`
- what `BX_CRONTAB`, `BX_CRONTAB_SUPPORT`, and cron entry mean
- why CLI `short_open_tag=1` is required for some old Bitrix cores
- how to verify the minute cron job
- what to do after restoring a site or changing PHP version

Acceptance checks:

- The expected healthy status block is documented and matches command output.
- The docs distinguish created cron file from agents actually switched to cron.

### Batch 4: Nginx, Routing, Hosts, And Upload Limits

Status: completed in first-pass user content on 2026-05-03. Future improvements should be based on new routing/upload incidents or additional automated repair commands.

Target files:

- `docs/user/bitrix/nginx-routing.md`
- `docs/user/bitrix/uploads.md`

Scenarios to document:

- Bitrix SEF/CHPU routing through `/bitrix/urlrewrite.php`
- `SERVER_NAME` vs `HTTP_HOST` on root domain and subdomains
- wildcard host mode behavior
- public editor upload failure with `413 Request Entity Too Large`
- difference between nginx body limit and PHP upload limits
- checks after nginx template regeneration or manual config edits

Acceptance checks:

- The docs explain why fallback to `/index.php` is wrong for many Bitrix routes.
- The upload guide tells the user where the failure is blocked: browser, nginx, PHP, or Bitrix.

### Batch 5: Ownership, Permissions, And Safe File Operations

Status: completed in first-pass user content on 2026-05-03. Future improvements should be based on new module/restore/deploy ownership incidents.

Target file:

- `docs/user/bitrix/ownership.md`

Scenarios to document:

- modules installed through web UI must not become `root:root`
- restored files may need ownership repair
- cache or upload directories can block Bitrix operations
- when to use project access instead of root
- how to run ownership check and repair

Acceptance checks:

- The docs make clear why root-owned files are dangerous for Bitrix.
- The repair command is documented as deliberate and confirmed, not invisible automation.

### Batch 6: Troubleshooting Index

Status: completed in first-pass user content on 2026-05-03. Future improvements should be added as new real symptoms appear.

Target files:

- `docs/user/bitrix/README.md`
- optional new `docs/user/bitrix/troubleshooting.md` if symptoms outgrow README

Scenarios to index:

- site opens slowly on first request
- subdomain opens wrong host or wrong data
- HTTPS issue fails
- restore stops near the end
- FileInput shows `Network error`
- Bitrix modules cannot be deleted
- CHPU pages open wrong content
- agents status is not ready
- `site doctor` has warnings but no failures

Acceptance checks:

- A user with a symptom can find the right detailed guide in one jump.
- Troubleshooting entries link to verification commands, not just explanations.

## Verification Method

For each documentation batch:

1. Compare commands against `simai-admin.sh` and `docs/commands/bitrix.md`.
2. Run syntax checks:

```bash
bash scripts/ci/bash_syntax.sh
git diff --check
```

3. If the batch changes user-facing behavior or uses live examples, verify on a disposable or known test domain.
4. Update `CHANGELOG.md` and `VERSION` when the committed docs materially improve user workflows.

## Priority

Recommended order:

1. Batch 1: creation/install/restore/database/diagnostics
2. Batch 3: cron agents
3. Batch 2: SSL and DNS
4. Batch 4: nginx routing and uploads
5. Batch 5: ownership
6. Batch 6: troubleshooting index

Reason: creation and post-install readiness are the highest-frequency operator path; cron, SSL, routing, uploads, and ownership are the highest-risk Bitrix-specific support topics seen so far.

## Open Questions

- Should restore from `restore.php` become a first-class menu wizard with explicit "fresh install" vs "restore backup" choice during `Sites -> Create site`?
- Should Bitrix docs include screenshots, or stay terminal/menu-first with separate knowledge-base HTML articles for visual providers such as Cloudflare?
- Should `docs/user/bitrix/database.md` cover external DB hosts now, or wait until the menu has explicit support for external DB credentials?
