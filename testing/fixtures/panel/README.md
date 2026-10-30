# Recorded panel answers

Gateway answers (`simai-panel-answer/1`) recorded from the local stand with
`testing/stand/stand.sh record`. Larena Panel (`larena/env`) replays
them in its fixture driver; see `docs/architecture/panel-gate.md`. The file
name is the request; the request id inside is `fixture-<name>`. Re-record
instead of editing by hand.

`manifest.json` pins the set: `set_version` (bumped when the shape of an
answer changes), the simai-env version it was recorded with and the sha256 of
every file. `larena/env` keeps a copy of the set and checks it against the
manifest, so a format change fails on both sides until both are updated.
