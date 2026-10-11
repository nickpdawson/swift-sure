# dzsec build tooling

ShiftHuman LLC build of swift-sure for the self-hosted server `sure.dzsec.net`. Branch `dzsec` carries three patch commits on top of upstream `main` (identifiers, `SURE_SELF_HOSTED` flag, FinanceKit compiled out) plus this directory.

- `build-testflight.sh` — archive, export, verify, upload. Runs on chamonix. Procedure and context in `~/Development/Sure/CLAUDE.md`.
- `asc_api.py` — stdlib App Store Connect API client (ES256 JWT via openssl). Example: `asc_api.py GET '/v1/builds?limit=3'`.

The ASC key is never committed; both tools read it from `~/.appstoreconnect/private_keys/AuthKey_3LGR8HYV5P.p8` (Ridge fallback `~/private/asc_key.p8`).
