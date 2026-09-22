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
| `packages` | list | apt packages the application calls (`age`, `util-linux`, ...) |
| `executables` | list | absolute paths that must exist after packages are installed |
| `env` | object | non-secret production values: they override `.env.example` when adopt creates `.env`; later runs only fill keys that are still unset |
| `scheduler` | bool | run `artisan schedule:run` every minute (default: profile) |
| `migrate` | bool | run `artisan migrate --force` on adopt and before each release switch |
| `workers` | list | one systemd unit per worker instance (see below) |
| `frame_ancestors` | list | origins allowed to embed the site (`https://*.bitrix24.ru`) |

Worker entry: `name` (default `default`), `command` — artisan arguments such
as `queue:work database --queue=default --tries=5 --timeout=172800` —,
`stop_timeout` in seconds (keep it above the longest job timeout), and
`count` (1–16). The `default` worker keeps the unit name
`laravel-queue-<project>.service`; others are
`laravel-queue-<project>-<name>[-<n>].service`.

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
