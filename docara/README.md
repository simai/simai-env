# Docara Site

This repository publishes its documentation through a contained Docara project in `docara/`.

## What Lives Here

- `source/docs/en/`: published documentation source
- `source/_core/`: Docara UI and generated support files
- `build_production/`: generated static site output, not committed
- `.github/workflows/docara-pages.yml`: GitHub Pages build and deploy workflow

## Local Build

Use PHP 8.2 and Node 20.

On this machine, the Homebrew `php` binary is broken because of an ICU mismatch, so local Docara commands should use ServBay PHP:

```bash
cd docara
/Applications/ServBay/bin/php /Applications/ServBay/bin/composer install
DOCARA_SKIP_FRONTEND_INSTALL=true /Applications/ServBay/bin/php vendor/bin/docara init --update
YARN_IGNORE_PATH=1 npx --yes yarn@1.22.22 --no-default-rc install --frozen-lockfile --production=false --non-interactive
YARN_IGNORE_PATH=1 npx --yes yarn@1.22.22 --no-default-rc prod
/Applications/ServBay/bin/php vendor/bin/docara build production
```

Output is written to `docara/build_production/`.

## Publishing

The repository publishes the Docara site through GitHub Pages Actions.

- Workflow: `.github/workflows/docara-pages.yml`
- Artifact path: `docara/build_production`
- Required repository setting: GitHub Settings -> Pages -> Source -> GitHub Actions

## Notes

- `config.php` uses `DOCARA_BASE_URL` from the environment, so the same site can build locally and on GitHub Pages.
- The workflow uses Node 20, Yarn 1.22.22 and Vite from the committed lockfile.
- Laravel Mix, webpack and `docara-mix` are not part of this site.
