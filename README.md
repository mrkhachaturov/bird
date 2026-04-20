# bird

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![BIRD](https://img.shields.io/badge/BIRD-3.0.1-blue)](https://bird.network.cz/)

Containerised [BIRD](https://bird.network.cz/) with a **config-driven list
fetcher** that keeps your `bird.conf` `include`s fresh from URLs, ASN queries,
and MaxMind GeoLite2 Country CSVs.

One image, any topology. You write `bird.conf` (it's bind-mounted). The
container just keeps the CIDR files under it fresh, validates the config, and
hot-reloads BIRD when lists change.

---

## Why

Most "BIRD + lists" setups hardcode the list sources into shell scripts tied to
a specific use case. This image separates concerns:

- **The container** fetches and transforms lists. Nothing more.
- **You** own the routing logic — BGP templates, filters, communities, peers.

That means the same image works for:

- **Geo-based policy routing** — route `country=RU` via Russian ISP, rest via VPN.
- **Service-based policy routing** — Google / Meta / Discord via specific egress.
- **Ad-hoc blackholing** — your own GitHub-maintained CIDR lists fed in.
- **Any combination** — mix sources freely in one `sources.yaml`.

---

## Features

- Declarative `sources.yaml` with three source types: `url`, `asn`, `maxmind_country`
- Independent refresh cadence for MaxMind (weekly) vs the rest (daily, configurable)
- MD5 change-guard — no reload when nothing changed
- **Webhook** (HMAC-SHA256, GitHub-compatible) for instant refresh on `git push`
- **Cache sharing** — bind-mount the MaxMind CSV dir across sites, one downloader
- Docker secrets support via the `_FILE` convention
- Graceful shutdown (`birdc down` on SIGTERM)
- Built-in healthcheck via `birdc show status`
- Multi-arch (amd64 / arm64) when built through CI

---

## Quick start

```bash
git clone https://github.com/mrkhachaturov/bird.git
cd bird/examples
cp .env.example .env
# Fill MAXMIND_ACCOUNT_ID / MAXMIND_LICENSE_KEY if you want MaxMind sources.
docker compose up -d --build
docker compose exec bird status
```

Output should show BIRD's protocols up and your source lists loaded.

---

## Source types

`examples/sources.yaml`:

```yaml
sources:
  # 1) URL — any CIDR-per-line text file (RIR exports, curated repos, etc.)
  - name: RU
    type: url
    url: https://github.com/ipverse/rir-ip/raw/master/country/ru/ipv4-aggregated.txt
    strip_comments: true        # drop '#' comment lines before transforming

  # 2) MaxMind — extracts all CIDRs for an ISO country code from the Country-CSV.
  #    Needs MAXMIND_ACCOUNT_ID + MAXMIND_LICENSE_KEY (GeoLite2 works, free).
  - name: RU_Max
    type: maxmind_country
    iso: RU

  # 3) ASN — one or more autonomous systems. Resolved via bgpq4 → whois → RIPE RIS.
  - name: Roblox
    type: asn
    asns:
      - AS22697
      - AS11281
```

Each entry produces `/etc/bird/<name>.txt` with `route X.X.X.X/Y reject;`
lines. Reference them from `bird.conf`:

```bird
template static static_template { ipv4; }

protocol static static_RU     from static_template { include "RU.txt"; }
protocol static static_RU_Max from static_template { include "RU_Max.txt"; }
protocol static static_Roblox from static_template { include "Roblox.txt"; }
```

Mix all three types freely in one `sources.yaml` — the container fetches each,
writes its file, and reloads BIRD when anything changes.

---

## Installation

### Option A — pre-built image (recommended for production)

```bash
docker pull ghcr.io/astrateam-net/bird-maxmind:latest
```

(Published from [AstraTeam/containers](https://github.com/AstraTeam/containers)
via CI on version tags.)

### Option B — build from source

```bash
docker build -t mrkhachaturov/bird:local .
```

Optional build-arg to pin BIRD:

```bash
docker build --build-arg BIRD_VERSION=2.17.1 -t mrkhachaturov/bird:2.17.1 .
```

### Option C — docker compose (the example)

See `examples/docker-compose.yml`.

---

## Configuration reference

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `MAXMIND_ACCOUNT_ID` | — | MaxMind account numeric ID |
| `MAXMIND_LICENSE_KEY` | — | MaxMind license key (GeoLite2 OK) |
| `MAXMIND_ACCOUNT_ID_FILE` / `MAXMIND_LICENSE_KEY_FILE` | — | Read corresponding var from a file (docker-secrets-friendly) |
| `MAXMIND_UPDATE` | `auto` | `auto` / `true` / `false`. `auto` = `true` if creds present |
| `MAXMIND_CSV_DIR` | `/var/cache/maxmind` | Cache directory for the Country-CSV bundle |
| `MAXMIND_REFRESH_INTERVAL` | `7d` | Minimum CSV age before re-download |
| `MAXMIND_DOWNLOAD_URL` | built-in permalink | Override if MaxMind changes the URL |
| `REFRESH_INTERVAL` | `24h` | Main fetch loop cadence (url + asn sources) |
| `RUN_ONCE` | `false` | Fetch + validate + exit. For CI |
| `WEBHOOK_SECRET` | — | Enables the webhook server when set |
| `WEBHOOK_SECRET_FILE` | — | Read `WEBHOOK_SECRET` from a file |
| `WEBHOOK_PORT` | `9090` | Port the webhook server listens on |
| `BIRD_CONF` | `/etc/bird/bird.conf` | Override path to your bird.conf |
| `SOURCES_FILE` | `/etc/blacklist/sources.yaml` | Override path to sources.yaml |

### Volumes

| Container path | Required | Purpose |
|---|---|---|
| `/etc/bird/` | Yes | Your `bird.conf` lives here; generated `*.txt` files land alongside |
| `/etc/blacklist/sources.yaml` | Yes | Your source declarations (read-only fine) |
| `/var/cache/maxmind` | No | MaxMind CSV cache; bind-mount to share across sites |
| `/var/cache/blacklist` | No | `.lst` working files + md5 tracker; persists to avoid re-fetching on restart |

### Capabilities & networking

BIRD needs `NET_ADMIN` + `NET_RAW`. For real BGP sessions, `network_mode: host`
is strongly recommended so BIRD's source IP is the host's real interface — no
NAT between BIRD and its peers.

---

## Usage scenarios

### Scenario 1: Country-based policy routing

You want Russian traffic via local ISP, everything else via VPN. MikroTik
handles the routing; bird feeds it the CIDR set tagged by BGP community.

```yaml
# sources.yaml
sources:
  - name: RU
    type: url
    url: https://github.com/ipverse/rir-ip/raw/master/country/ru/ipv4-aggregated.txt
    strip_comments: true
  - name: RU_Max
    type: maxmind_country
    iso: RU
```

```bird
# bird.conf — stamp "any RU source" with community 200
function tag_ru(int source_code) {
    bgp_community.add((64500, 200));
    bgp_community.add((64500, source_code));
    accept;
}

filter bgp_out {
    if proto = "static_RU"     then tag_ru(201);
    if proto = "static_RU_Max" then tag_ru(202);
    reject;
}
```

On MikroTik, match community `64500:200` → push matched routes to the Russian
ISP routing table.

### Scenario 2: Per-service egress

Route Google/Meta/Discord through a dedicated egress. Keep your own hand-maintained
list for edge cases the external sources miss.

```yaml
sources:
  - name: Google
    type: url
    url: https://raw.githubusercontent.com/mrkhachaturov/ipranges/main/google/ipv4.txt
  - name: Meta
    type: url
    url: https://raw.githubusercontent.com/SecOps-Institute/FacebookIPLists/master/facebook_ip_list.lst
  - name: Discord
    type: asn
    asns: [AS49544, AS62240]

  # Your own curated overrides — no fetch, just a URL you control.
  - name: MyOverrides
    type: url
    url: https://raw.githubusercontent.com/mrkhachaturov/my-ips/main/overrides.txt
    strip_comments: true
```

Then use a GitHub webhook (below) so edits to `my-ips` propagate in seconds.

### Scenario 3: Multi-site with shared MaxMind cache

Site A downloads; external rsync syncs the dir; Site B just reads.

**Site A (updater):**
```bash
# .env
MAXMIND_ACCOUNT_ID=123
MAXMIND_LICENSE_KEY=…
MAXMIND_UPDATE=true
MAXMIND_CSV_DIR=/var/cache/maxmind
```

**Site B (consumer):**
```bash
# .env
MAXMIND_UPDATE=false
MAXMIND_CSV_DIR=/var/cache/maxmind
```

Configure rsync on Site A to push `/var/cache/maxmind/GeoLite2-Country-CSV_*`
to Site B. Site B uses whatever it finds, never downloads, doesn't need creds.

---

## Operations

### Shell commands (inside the container)

```bash
docker compose exec bird refresh           # fetch url/asn sources; reuse MaxMind cache
docker compose exec bird refresh-maxmind   # same, but force MaxMind re-download
docker compose exec bird status            # BGP sessions + route counts + md5
docker compose exec bird birdc             # BIRD CLI
```

### Webhook

Enabled only when `WEBHOOK_SECRET` is set.

| Method | Path | Auth | Effect |
|---|---|---|---|
| `POST` | `/refresh` | HMAC-SHA256 via `X-Hub-Signature-256` | Runs `refresh` |
| `POST` | `/refresh-maxmind` | HMAC-SHA256 | Runs `refresh-maxmind` |
| `GET` | `/healthz` | none | `200 ok` |

**Connecting a GitHub webhook to this endpoint:**

1. Source repo → `Settings → Webhooks → Add webhook`
2. **Payload URL:** `http://<host-running-bird>:9090/refresh`
3. **Content type:** `application/json`
4. **Secret:** same value as `WEBHOOK_SECRET`
5. **Events:** push
6. Save.

Now `git push` to that repo → webhook fires → container refetches and reloads
BIRD in seconds. Useful for your own curated CIDR repos.

Test locally:
```bash
secret='your-secret'
sig=$(printf '' | openssl dgst -sha256 -hmac "$secret" | awk '{print $2}')
curl -X POST -H "X-Hub-Signature-256: sha256=$sig" http://localhost:9090/refresh
```

---

## Security notes

- **Webhook** is closed by default (no secret → no server). When enabled, every
  request must carry a valid HMAC-SHA256 over the body using the shared secret.
  Bind the port to a private interface or front with a reverse proxy + TLS if
  exposing publicly.
- **MaxMind creds** should go through `*_FILE` → docker secrets in production.
  The plain env-var form is for local development.
- **Running as root** inside the container: the current image runs the
  entrypoint as root so the fetcher can write to `/etc/bird/`. BIRD is built
  with file capabilities (`cap_net_raw`, `cap_net_admin`) so it doesn't need
  more than those. If you care deeply, run under a user namespace on the host.

---

## Troubleshooting

**"Operation not permitted" on `bird -p`**
Missing capabilities. Add `cap_add: [NET_ADMIN, NET_RAW]` in compose, or the
equivalent `--cap-add` flags on `docker run`.

**"Unable to open included file /etc/bird/X.txt"**
A source listed in `bird.conf` isn't in `sources.yaml`. The fetcher only
creates `.txt` files for declared sources. Either add it to `sources.yaml` or
remove the `include` from `bird.conf`.

**MaxMind returns HTTP 401 "Invalid license key"**
Usually means the key isn't activated for GeoLite2 downloads. Log into
`account.maxmind.com` → Manage License Keys. Also note: the legacy
`/app/geoip_download?edition_id=X` endpoint rejects modern 40-char keys — use
the default download URL this image uses (or override via
`MAXMIND_DOWNLOAD_URL`).

**"Bad BGP identifier"**
Both peers are using the same `router id`. BGP identifiers must be unique per
AS-pair. Pick different values on each end (the value is just a label; it
doesn't have to be an assigned IP).

**BGP stays in `Active` state forever**
TCP isn't reaching the peer. Common causes: peer not listening, firewall
between the two, NAT without port-forward (WSL, etc.), or your `local` address
doesn't exist on the host. Verify with `ip route get <peer-ip>` and
`curl telnet://<peer-ip>:179`.

---

## Repository layout

```
bird/
├── Dockerfile              # Multi-stage build (BIRD from source + runtime tools)
├── scripts/                # Everything copied into /usr/local/bin/ inside the image
│   ├── entrypoint.sh       # supervisor: initial fetch → bird -f + refresh loop
│   ├── fetch-lists.sh      # core fetch + transform + reload logic
│   ├── sources-lib.sh      # per-source-type fetchers (url / asn / maxmind_country)
│   ├── maxmind-country.py  # CSV → CIDR extractor
│   ├── webhook.py          # tiny HMAC-authenticated HTTP webhook server
│   ├── refresh             # shortcut: force a fetch cycle
│   ├── refresh-maxmind     # shortcut: force including a MaxMind re-download
│   └── status              # operational snapshot
├── examples/               # copy-paste starting point
│   ├── docker-compose.yml
│   ├── sources.yaml
│   ├── .env.example
│   └── bird/bird.conf
├── CHANGELOG.md
├── LICENSE
└── README.md
```

---

## Contributing

Bug reports and PRs welcome. Please describe the scenario you're solving so the
generic fetcher stays generic.

## License

MIT — see [`LICENSE`](LICENSE).
