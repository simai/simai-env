# Docara Site

This repository publishes its documentation through a contained Docara 3 project in `docara/`.

## What Lives Here

- `docara.json`: site settings (title, locale, branding, layout, search, header menu)
- `source/docs/en/`: published documentation source (the content root)
  - `section.json`: section title for a folder
  - `<page>.page.json` / `index.page.json`: menu order of a page or section
  - `lang.json`: interface strings
- `assets/`: logo and favicon
- `contracts/`, `simai-framework.lock.json`, `.docara/engine/`: Docara-managed files; do not edit
- `build_production/`: generated static site output, not committed
- `.github/workflows/docara-pages.yml`: GitHub Pages build and deploy workflow

## Local Build

Requires PHP 8.2+ (`ctype`, `dom`, `intl`, `json`, `libxml`, `mbstring`), Composer and Node.js 20+.

```bash
cd docara
composer install
php vendor/bin/docara build production
php vendor/bin/docara verify-static build_production
php vendor/bin/docara serve production --no-build
```

Output is written to `docara/build_production/`. Locally pages are served from the site root
(`/architecture/command-execution/`).

## Publishing

The repository publishes the Docara site through GitHub Pages Actions.

- Workflow: `.github/workflows/docara-pages.yml`
- Public paths keep the `/docs/en/` prefix: the workflow builds with
  `base_url=<pages base>/docs/en/`, publishes the build under `docs/en/` of the Pages artifact
  and adds a root redirect to it.
- Required repository setting: GitHub Settings -> Pages -> Source -> GitHub Actions

## Notes

- Markdown is strict: raw HTML is rejected, so write placeholders such as `php<version>` in backticks.
- Link to other pages by their site route (`../ssl/`), not by `.md` file name; `verify-static` fails on broken links.
- Update Docara with `php vendor/bin/docara upgrade` (same major version).
