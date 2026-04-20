# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/mrkhachaturov/bird/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mrkhachaturov/bird/releases/tag/v0.1.0
