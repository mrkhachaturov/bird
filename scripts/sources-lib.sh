# Per-source-type fetchers. Each writes ${LIST_DIR}/${name}.lst (CIDR-per-line).
# Sourced by fetch-lists.sh.

fetch_url() {
    local name="$1" url="$2" strip_comments="${3:-false}"
    local out="${LIST_DIR}/${name}.lst"
    local tmp="${out}.tmp"
    local max_retries=3 retry_delay=10 attempt=1

    while [ $attempt -le $max_retries ]; do
        if curl -fsSL --max-time 60 -o "$tmp" "$url" && [ -s "$tmp" ]; then
            if [ "$strip_comments" = "true" ]; then
                sed -i '/^#/d; /^[[:space:]]*$/d' "$tmp"
            fi
            mv "$tmp" "$out"
            return 0
        fi
        rm -f "$tmp"
        if [ $attempt -lt $max_retries ]; then
            echo "WARN: url fetch for $name failed, retry $attempt/$max_retries in ${retry_delay}s"
            sleep $retry_delay
        fi
        attempt=$((attempt + 1))
    done

    echo "ERROR: url fetch failed for $name ($url)" >&2
    return 1
}

fetch_asn() {
    local name="$1"
    shift
    local asns=("$@")
    local out="${LIST_DIR}/${name}.lst"
    local tempdir
    tempdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$tempdir'" RETURN

    for asn in "${asns[@]}"; do
        local asn_num="${asn#AS}"
        local asn_file="${tempdir}/${asn}.lst"

        # Preferred: bgpq4
        if timeout 30 bgpq4 -4 -b -l temp "AS${asn_num}" 2>/dev/null \
            | grep -E '^[[:space:]]*[0-9]' \
            | sed 's/^[[:space:]]*//; s/,$//; s/;$//' \
            | grep -v ':' \
            | sort -u > "$asn_file" && [ -s "$asn_file" ]; then
            continue
        fi

        # Fallback: whois RADB
        if timeout 30 whois -h whois.radb.net -- "-i origin $asn" 2>/dev/null \
            | awk '/^route:/ {print $2}' \
            | grep -v ':' \
            | sort -u > "$asn_file" && [ -s "$asn_file" ]; then
            continue
        fi

        # Fallback: RIPE RIS API
        if curl -fsSL --max-time 30 \
            "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS${asn_num}" 2>/dev/null \
            | grep -oE '"prefix":"[^"]+"' \
            | sed 's/"prefix":"//; s/"//' \
            | grep -v ':' \
            | sort -u > "$asn_file" && [ -s "$asn_file" ]; then
            continue
        fi

        echo "WARN: failed to fetch $asn for $name" >&2
    done

    # Merge + dedup across all ASNs for this source
    cat "${tempdir}"/*.lst 2>/dev/null | sort -u > "$out"
    [ -s "$out" ]
}

# Convert a sleep-style duration (e.g. 7d, 24h, 60m, 3600s, or bare seconds) to seconds.
_interval_to_seconds() {
    local i="$1"
    case "$i" in
        *s) echo "${i%s}" ;;
        *m) echo $((${i%m} * 60)) ;;
        *h) echo $((${i%h} * 3600)) ;;
        *d) echo $((${i%d} * 86400)) ;;
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$i" ;;
    esac
}

# Resolve effective MAXMIND_UPDATE mode: "true" or "false".
# MAXMIND_UPDATE=auto (default) => true if creds set, else false.
_maxmind_update_mode() {
    case "${MAXMIND_UPDATE:-auto}" in
        true|false) echo "${MAXMIND_UPDATE}" ;;
        auto)
            if [ -n "${MAXMIND_ACCOUNT_ID:-}" ] && [ -n "${MAXMIND_LICENSE_KEY:-}" ]; then
                echo true
            else
                echo false
            fi
            ;;
        *)
            echo "ERROR: MAXMIND_UPDATE must be true|false|auto (got '${MAXMIND_UPDATE}')" >&2
            echo false
            return 1
            ;;
    esac
}

# Find the CSV dir inside MAXMIND_CSV_DIR. Prefers the latest
# GeoLite2-Country-CSV_YYYYMMDD/ subdir, falls back to flat layout.
_maxmind_find_csv_dir() {
    local root="$1"
    [ -z "$root" ] || [ ! -d "$root" ] && return 1

    local dated
    dated=$(find "$root" -maxdepth 2 -type d -name 'GeoLite2-Country-CSV_*' 2>/dev/null | sort | tail -1)
    if [ -n "$dated" ]; then
        echo "$dated"
        return 0
    fi
    if [ -f "$root/GeoLite2-Country-Locations-en.csv" ] \
       && [ -f "$root/GeoLite2-Country-Blocks-IPv4.csv" ]; then
        echo "$root"
        return 0
    fi
    return 1
}

# Download + extract MaxMind Country CSV. $1 = destination dir (persisted or tmp).
# Echoes the resulting CSV directory path on stdout.
_maxmind_download() {
    local dest="$1"
    if [ -z "${MAXMIND_ACCOUNT_ID:-}" ] || [ -z "${MAXMIND_LICENSE_KEY:-}" ]; then
        echo "ERROR: MAXMIND_UPDATE=true requires MAXMIND_ACCOUNT_ID and MAXMIND_LICENSE_KEY" >&2
        return 1
    fi
    local zip="${dest}/country.zip"
    # New-style permalink. The legacy /app/geoip_download endpoint rejects
    # modern 40-char license keys. Overridable via MAXMIND_DOWNLOAD_URL.
    local url="${MAXMIND_DOWNLOAD_URL:-https://download.maxmind.com/geoip/databases/GeoLite2-Country-CSV/download?suffix=zip}"
    if ! curl -fsSL --max-time 300 -u "${MAXMIND_ACCOUNT_ID}:${MAXMIND_LICENSE_KEY}" \
         -o "$zip" "$url"; then
        echo "ERROR: MaxMind download failed" >&2
        return 1
    fi
    if ! unzip -q -o "$zip" -d "$dest"; then
        echo "ERROR: unzip failed for MaxMind CSV" >&2
        return 1
    fi
    rm -f "$zip"
    local csv_dir
    csv_dir=$(find "$dest" -maxdepth 1 -type d -name 'GeoLite2-Country-CSV_*' | sort | tail -1)
    if [ -z "$csv_dir" ]; then
        echo "ERROR: extracted CSV directory not found" >&2
        return 1
    fi
    echo "$csv_dir"
}

fetch_maxmind_country() {
    local name="$1" iso="$2"
    local out="${LIST_DIR}/${name}.lst"
    local mode csv_dir=""

    mode=$(_maxmind_update_mode) || return 1

    if [ "$mode" = "true" ]; then
        # Updater role: download only if cached CSV is older than MAXMIND_REFRESH_INTERVAL.
        local max_age
        max_age=$(_interval_to_seconds "${MAXMIND_REFRESH_INTERVAL:-7d}")
        local existing=""
        if [ -n "${MAXMIND_CSV_DIR:-}" ] && [ -d "${MAXMIND_CSV_DIR}" ]; then
            existing=$(_maxmind_find_csv_dir "${MAXMIND_CSV_DIR}") || existing=""
        fi

        if [ -n "$existing" ] && [ "$max_age" -gt 0 ]; then
            local now mtime age
            now=$(date +%s)
            mtime=$(stat -c %Y "$existing" 2>/dev/null || echo 0)
            age=$((now - mtime))
            if [ "$age" -lt "$max_age" ]; then
                echo "reusing MaxMind CSV at $existing (age ${age}s < ${max_age}s)"
                csv_dir="$existing"
            fi
        fi

        if [ -z "$csv_dir" ]; then
            local dest
            if [ -n "${MAXMIND_CSV_DIR:-}" ] && [ -d "${MAXMIND_CSV_DIR}" ]; then
                dest="${MAXMIND_CSV_DIR}"
            else
                dest=$(mktemp -d)
                # shellcheck disable=SC2064
                trap "rm -rf '$dest'" RETURN
            fi
            csv_dir=$(_maxmind_download "$dest") || return 1
            echo "downloaded MaxMind CSV to $csv_dir"
        fi
    else
        # Consumer role: never download. Require populated MAXMIND_CSV_DIR.
        if [ -z "${MAXMIND_CSV_DIR:-}" ] || [ ! -d "${MAXMIND_CSV_DIR}" ]; then
            echo "ERROR: MAXMIND_UPDATE=false but MAXMIND_CSV_DIR not set or missing" >&2
            return 1
        fi
        csv_dir=$(_maxmind_find_csv_dir "${MAXMIND_CSV_DIR}") || {
            echo "ERROR: no MaxMind CSVs found under ${MAXMIND_CSV_DIR} (consumer mode expects external sync)" >&2
            return 1
        }
        echo "using MaxMind CSV at $csv_dir (consumer mode)"
    fi

    python3 /usr/local/bin/maxmind-country.py \
        "$iso" \
        "${csv_dir}/GeoLite2-Country-Locations-en.csv" \
        "${csv_dir}/GeoLite2-Country-Blocks-IPv4.csv" \
        | sort -u > "$out"

    [ -s "$out" ]
}
