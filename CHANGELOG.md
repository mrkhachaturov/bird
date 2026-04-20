# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.1] - 2026-04-21

### Added
- `GET /ready` endpoint on the webhook server. Executes
  `birdc show status`; returns `200 ready` only if BIRD is actually responsive
  on its control socket, `503 not ready: <reason>` otherwise. Suitable as a
  load-balancer health-check target (HAProxy/Traefik/Kubernetes) to steer
  traffic away from nodes where BIRD is down. `/healthz` remains unchanged
  as a lightweight liveness probe for the webhook process itself.
- `BIRD_CTL` environment variable — override the path to the BIRD control
  socket (default `/var/run/bird/bird.ctl`) for both `/ready` and any future
  `birdc`-driven tooling.
- `BGP_PASSWORD` and `BGP_PASSWORD_FILE` — BGP MD5 password delivered via the
  same `*_FILE` convention as MaxMind credentials (docker-secrets-friendly).
- Config-file templating: when `BIRD_CONF_TEMPLATE` is set and points at a
  file, the entrypoint renders it into `BIRD_CONF` via `envsubst` at startup.
  Supported placeholders:
  - `${BGP_PASSWORD}` — the raw secret
  - `${BGP_PASSWORD_LINE}` — the whole `password "xxx";` statement, or an
    empty string if no password was provided. Use this form to keep BGP auth
    **optional** — a template referencing `${BGP_PASSWORD_LINE}` renders to
    a valid config both with and without a password supplied.
- `gettext-base` (ships `envsubst`) in the runtime image.

### Notes
- All new features are additive; existing `v0.1.0` configurations continue to
  work unchanged. `BIRD_CONF_TEMPLATE` is opt-in — if unset, the entrypoint
  reads `BIRD_CONF` verbatim as before.

## [0.1.0] - 2026-04-20

### Added
- Multi-stage Docker image: BIRD 3.0.1 compiled from source on `debian:trixie-slim`.
- Config-driven list fetcher (`fetch-lists.sh`) consuming a declarative
  `sources.yaml`.
- Three source types:
  - `url` — any CIDR-per-line text file, with optional `strip_comments`.
  - `asn` — one or more AS numbers, resolved via `bgpq4` → `whois` →
    RIPE RIS API fallback chain.
  - `maxmind_country` — extracts every CIDR for a given ISO country from
    MaxMind GeoLite2 Country-CSV.
- Independent refresh cadence:
  - `REFRESH_INTERVAL` (default `24h`) for `url` + `asn` sources.
  - `MAXMIND_REFRESH_INTERVAL` (default `7d`) for MaxMind CSV re-download.
- `MAXMIND_UPDATE={auto,true,false}` for explicit updater / consumer roles.
- `MAXMIND_CSV_DIR` bind-mount for sharing the CSV between sites.
- `MAXMIND_DOWNLOAD_URL` override (defaults to the current permalink that
  supports modern 40-char license keys; the legacy `/app/geoip_download`
  endpoint was removed).
- `*_FILE` convention for MaxMind and webhook secrets (docker-secrets-friendly).
- MD5 change-guard: `birdc configure` fires only when the combined `.lst`
  content hash changes.
- Pre-creation of empty `.txt` for every declared source so a single failed
  fetch never breaks BIRD config validation.
- Webhook server (`webhook.py`):
  - HMAC-SHA256 authentication, GitHub-compatible
    (`X-Hub-Signature-256` header).
  - Endpoints `POST /refresh`, `POST /refresh-maxmind`, `GET /healthz`.
  - Enabled only when `WEBHOOK_SECRET` is set (no secret → server off).
- Shell shortcuts inside the container: `refresh`, `refresh-maxmind`, `status`.
- Graceful shutdown via `birdc down` on SIGTERM/SIGINT/SIGQUIT.
- Built-in Docker `HEALTHCHECK` using `birdc show status`.
- Example `docker-compose.yml`, `sources.yaml`, `bird/bird.conf`, `.env.example`.

### Notes
- BIRD is started with file capabilities `cap_net_raw` + `cap_net_admin`; the
  container process runs as root so the fetcher can write `/etc/bird/*.txt`
  and avoid the `capset` edge case in host-network mode.
- Use `network_mode: host` with `cap_add: [NET_ADMIN, NET_RAW]` for real BGP
  sessions so BIRD's source IP is a host interface, not a NATed container IP.

[Unreleased]: https://github.com/mrkhachaturov/bird/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/mrkhachaturov/bird/releases/tag/v0.1.1
[0.1.0]: https://github.com/mrkhachaturov/bird/releases/tag/v0.1.0
