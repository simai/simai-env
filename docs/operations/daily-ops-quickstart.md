# Daily Ops Quickstart

Use this page as the fastest operator checklist for routine work.
For profile-specific command selection, see `docs/operations/profile-ops-matrix.md`.
For menu-driven everyday work, start with `docs/guide/menu-user-guide.md`.

Fresh install defaults:
- only the core profiles are enabled at first: `static`, `generic`, `alias`
- bootstrap installs PHP `8.2` by default
- before creating `WordPress`, `Laravel`, or `Bitrix` sites, enable the profile and install another PHP version if you need one

## 1) Daily read-only check

```bash
NO_COLOR=1 /root/simai-env/simai-admin.sh self status
NO_COLOR=1 /root/simai-env/simai-admin.sh self platform-status
NO_COLOR=1 /root/simai-env/simai-admin.sh self perf-status
NO_COLOR=1 /root/simai-env/simai-admin.sh self perf-plan
NO_COLOR=1 /root/simai-env/simai-admin.sh site list
NO_COLOR=1 /root/simai-env/simai-admin.sh ssl list
NO_COLOR=1 /root/simai-env/simai-admin.sh db status
```

## 2) One-site triage

```bash
/root/simai-env/simai-admin.sh site info --domain <domain>
/root/simai-env/simai-admin.sh site runtime-status --domain <domain>
/root/simai-env/simai-admin.sh site doctor --domain <domain>
/root/simai-env/simai-admin.sh ssl status --domain <domain>
```

## 3) SSL common actions

```bash
/root/simai-env/simai-admin.sh ssl letsencrypt --domain <domain> --email <email>
/root/simai-env/simai-admin.sh ssl install --domain <domain> --cert <fullchain.pem> --key <privkey.pem>
/root/simai-env/simai-admin.sh ssl remove --domain <domain>
```

## 4) Backup / migrate (safe path first)

```bash
/root/simai-env/simai-admin.sh backup export --domain <domain>
/root/simai-env/simai-admin.sh backup inspect --file <archive.tar.gz>
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply no
```

Apply only after plan review:

```bash
/root/simai-env/simai-admin.sh backup import --file <archive.tar.gz> --apply yes
```

## 5) Release gate before production rollout

```bash
bash /root/simai-env/testing/release-gate.sh
```
