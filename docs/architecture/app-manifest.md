# Application manifest (`.simai/app.json`)

An application tells simai-env what it needs to run. `site adopt` and
`site deploy` read the manifest from the application directory (or the
release being deployed); `site describe` reports its validated fields.

Requirements that composer already knows are not repeated: the PHP lower
bound comes from `require.php` and PHP extensions from `ext-*` entries in
`composer.json`.

## Schema `simai-app/1`

| Field | Type | Meaning |
| --- | --- | --- |
| `schema` | string | `simai-app/1` |
| `profile` | string | simai profile id (default: `laravel` when `artisan` exists, else `generic`) |
| `php` | `"8.4"` or `"8.4.1"` | minimum PHP; overrides `composer.json` |
| `db.engine` | `mysql` \| `pgsql` | database engine (profile must allow it) |
| `db.version` | `"17"` | PostgreSQL major to install when missing (non-Ubuntu versions need `--pgdg yes`) |
| `php_extensions` | list | PHP extensions not declared as `ext-*` in `composer.json` (`redis`, `pgsql`) |
| `packages` | list | apt packages the application calls (`age`, `util-linux`, ...) |
| `executables` | list | absolute paths that must exist after packages are installed |
| `env` | object | non-secret production values: they override `.env.example` when adopt creates `.env`; later runs only fill keys that are still unset |
| `scheduler` | bool | run `artisan schedule:run` every minute (default: profile) |
| `migrate` | bool | run `artisan migrate --force` on adopt and before each release switch |
| `workers` | list | one systemd unit per worker instance (see below) |
| `frame_ancestors` | list | origins allowed to embed the site (`https://*.bitrix24.ru`) |
| `node.version` | `"22"` | minimum Node.js major (service sites, profile `node`) |
| `node.start` | string | command of the service, such as `node src/server.js` (a program on `PATH` plus plain arguments, no shell syntax) |
| `node.install` | `auto` \| `yarn` \| `npm` \| `none` | dependency install; `auto` picks yarn when `yarn.lock` exists, else npm |
| `node.build` | string | optional build command; dev dependencies are installed when it is set |
| `python.requirements` | path | Python requirements installed into `.venv` of the release; `.venv/bin` is on the service `PATH` |
| `shared` | list | paths kept in `<root>/shared` across releases (`cache`, `uploads`); the first release seeds them |
| `health.path` | `/health` | URL path that must answer 2xx/3xx after a deploy (default `/`) |
| `health.timeout` | seconds | how long deploy waits for it (5–3600, default 120) |

Worker entry: `name` (default `default`), `command` — artisan arguments such
as `queue:work database --queue=default --tries=5 --timeout=172800` —,
`stop_timeout` in seconds (keep it above the longest job timeout), and
`count` (1–16). The `default` worker keeps the unit name
`laravel-queue-<project>.service`; others are
`laravel-queue-<project>-<name>[-<n>].service`.

## Service sites (profile `node`)

`site add --profile node` allocates a local port (3100–3999, or
`--app-port`), records it in `/etc/simai-env/sites/<domain>/service.env` and
writes an nginx proxy to `127.0.0.1:<port>`; `public/` stays outside releases
for ACME challenges. `site deploy` then:

1. fetches the release as the site user and links `.env` and `shared` paths;
2. creates the shared `.env` once from `.env.example` and the manifest `env`;
   `PORT` and `HOST=127.0.0.1` are always written by simai-env;
3. installs dependencies (yarn/npm), the Python venv and runs `node.build`;
4. switches `current`, writes `simai-app-<project>.service`
   (`WorkingDirectory=<root>/current`, `EnvironmentFile=<root>/.env`,
   `Restart=always`, enabled for boot, logs in journald,
   `SIMAI_STATE_DIR=<root>/shared/state` for persistent data) and restarts it;
5. waits for `health.path`; when it fails, `current` returns to the previous
   release and the new one is kept as `releases/<id>-failed`.

`site service-restart` restarts the unit and waits for the health check;
`site deploy-rollback` switches releases the same way. Example:

```json
{
  "schema": "simai-app/1",
  "profile": "node",
  "node": {"version": "22", "start": "node src/server.js", "install": "yarn"},
  "python": {"requirements": "requirements.txt"},
  "shared": ["cache"],
  "health": {"path": "/health", "timeout": 1800}
}
```

## Validation

`lib/app_manifest.py` validates every field before the shell sees it:
package and executable names, env keys and values, worker commands (artisan
arguments only, no shell syntax), origins. Keys that look like secrets
(`*PASS`, `*SECRET`, `*TOKEN`, `*KEY`) and `APP_KEY` are rejected: secrets
belong in the site `.env` on the server.

The manifest lives in a directory the site user can write. simai-env only
acts on it through explicit operator commands (`adopt`, `deploy`), and
`describe` publishes validated fields only.

## Queue timeouts

Laravel requires `--timeout` < `retry_after` of the queue connection, and
the worker's `stop_timeout` should exceed the longest job so a stop during
deploy does not kill it. Deploys use `artisan queue:restart`: workers finish
their current job, exit and systemd starts them on the new release.

## Monorepos and prebuilt artifacts

When `composer.json` uses path repositories (`../../packages/...`) or the
frontend must be built with Node, build a release artifact where the whole
repository is available: `composer install --no-dev` and the asset build,
then archive the application directory including `vendor/` and
`public/build/`. `site adopt` and `site deploy` skip `composer install` when
`vendor/autoload.php` is already present (`--build auto`, the default).
