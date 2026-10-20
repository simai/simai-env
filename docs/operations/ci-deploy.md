# Deploying sites from CI

Builds run in the repository's CI (GitHub Actions); the server only switches
releases. Each site has its own deploy key that can deploy that one site and
nothing else.

## On the server (once per site)

```bash
# static site: the release is the document root (index.html at its top)
sudo /root/simai-env/simai-admin.sh site add --domain docs.example.com --profile static --confirm yes

# key generated for the repository (keep the private half as a CI secret)
ssh-keygen -t ed25519 -N '' -C ci-docs.example.com -f ci-docs
sudo /root/simai-env/simai-admin.sh site deploy-key-add --domain docs.example.com --pubkey-file ci-docs.pub --confirm yes
```

`deploy-key-add` prints the key id, its fingerprint and the
`SIMAI_DEPLOY_KNOWN_HOSTS` lines (the server's host keys). Add a
`--host <name-or-ip>` matching how CI connects; the default is the server's
primary IP. Node sites that deploy from git get the repository fixed with
`--git <url>`.

`site deploy-key-list` shows the keys; `site deploy-key-remove --key-id ID
--confirm yes` revokes one.

## What a key can do

The key logs in as the system account `simai-deploy`. Its forced command is
the deploy gate, which accepts exactly:

| Command | Meaning |
| --- | --- |
| `deploy-artifact <sha256>` | tar.gz of the site on stdin; checked against the sha256 and the size limit (`SIMAI_DEPLOY_MAX_ARCHIVE_MB`, default 1024) |
| `deploy-git <40-hex commit>` | keys added with `--git`: deploy that commit of the fixed repository |
| `status` | `site deploy-status` |
| `rollback` | `site deploy-rollback` |

Everything else is refused with exit code 126 and logged in
`/var/log/simai-deploy-gate.log`. The key has no shell, no TTY and no
forwarding.

## The release

- tar.gz of the directory to publish: `tar -C dist -czf site.tgz .`
- absolute paths, `..`, hard links, special files and symbolic links that
  leave the release are refused;
- `.simai/app.json` inside the artifact is read and never served; for static
  sites the useful field is `"health": {"path": "/ru/"}` (default `/`);
- `CNAME` and `.nojekyll` from GitHub Pages builds are harmless and ignored.

Static sites behave like GitHub Pages: `/dir/` serves `dir/index.html`,
`/dir` redirects to `/dir/`, `/name` serves `name.html`, `404.html` is the
error page, and a single-page app ships `200.html` to answer unknown paths.
HTML is revalidated on every visit, other files are cached for an hour, text
is compressed.

After the switch the server requests the health path through nginx; when it
does not answer 2xx, the previous release is restored and the new one is kept
as `releases/<id>-failed`. The command's exit code is the deploy result.

## Workflow step

Run the deploy only on `push` to the main branch and on `workflow_dispatch`,
never on `pull_request`, in a GitHub environment (for example
`simai-server`) that holds the two secrets.

```yaml
deploy:
  needs: build
  if: github.event_name == 'push' || github.event_name == 'workflow_dispatch'
  runs-on: ubuntu-latest
  environment: simai-server
  concurrency: deploy-${{ github.repository }}
  steps:
    - uses: actions/download-artifact@v4
      with: { name: site, path: dist }
    - name: Deploy to the simai server
      env:
        DEPLOY_KEY: ${{ secrets.SIMAI_DEPLOY_KEY }}
        DEPLOY_KNOWN_HOSTS: ${{ secrets.SIMAI_DEPLOY_KNOWN_HOSTS }}
      run: |
        install -m 600 /dev/null key && printf '%s\n' "$DEPLOY_KEY" > key
        printf '%s\n' "$DEPLOY_KNOWN_HOSTS" > known_hosts
        tar -C dist -czf site.tgz .
        sum=$(sha256sum site.tgz | cut -d' ' -f1)
        ssh -i key -o UserKnownHostsFile=known_hosts -o StrictHostKeyChecking=yes \
          simai-deploy@SERVER "deploy-artifact $sum" < site.tgz
```

`SERVER` is the name or IP given to `deploy-key-add --host`. For an on-demand
deploy, run the workflow manually, or on the server:
`simai-admin.sh site deploy --domain D --archive F --sha256 S --confirm yes`.

## Redirects

```bash
# one exact path (kept across certificate changes and other re-renders)
sudo /root/simai-env/simai-admin.sh site redirect-add --domain example.com --from / --to /ru/ --code 302 --confirm yes
sudo /root/simai-env/simai-admin.sh site redirect-list --domain example.com

# a whole domain (path and query are kept; ACME still answers for renewals)
sudo /root/simai-env/simai-admin.sh profile enable --id redirect --confirm yes
sudo /root/simai-env/simai-admin.sh site add --domain old.example.com --profile redirect --redirect-to https://new.example.com --redirect-code 301 --confirm yes
```
