#!/bin/bash
# Core fetch + transform + reload loop. Mirrors chklist.sh semantics but config-driven.
set -euo pipefail

: "${SOURCES_FILE:=/etc/blacklist/sources.yaml}"
: "${BIRD_DIR:=/etc/bird}"
: "${LIST_DIR:=/var/cache/blacklist/list}"
: "${MD5_FILE:=/var/cache/blacklist/md5.txt}"
export LIST_DIR BIRD_DIR

mkdir -p "$LIST_DIR"

# shellcheck source=/dev/null
source /usr/local/bin/sources-lib.sh

if [ ! -f "$SOURCES_FILE" ]; then
    echo "ERROR: sources file not found: $SOURCES_FILE" >&2
    exit 1
fi

count=$(yq -r '.sources | length' "$SOURCES_FILE" 2>/dev/null || echo "0")
if [ -z "$count" ] || [ "$count" = "null" ] || [ "$count" = "0" ]; then
    echo "WARN: no sources defined in $SOURCES_FILE"
    exit 0
fi

# Pre-create empty .lst for each declared source so a failed fetch
# doesn't leave bird.conf with a missing include. `touch` preserves
# any existing successful data from a prior run.
for i in $(seq 0 $((count - 1))); do
    name=$(yq -r ".sources[$i].name" "$SOURCES_FILE")
    touch "${LIST_DIR}/${name}.lst"
done

for i in $(seq 0 $((count - 1))); do
    name=$(yq -r ".sources[$i].name" "$SOURCES_FILE")
    type=$(yq -r ".sources[$i].type" "$SOURCES_FILE")
    echo "--- [$i] name=$name type=$type ---"

    case "$type" in
        url)
            url=$(yq -r ".sources[$i].url" "$SOURCES_FILE")
            strip=$(yq -r ".sources[$i].strip_comments // false" "$SOURCES_FILE")
            fetch_url "$name" "$url" "$strip" || echo "WARN: $name failed"
            ;;
        asn)
            mapfile -t asns < <(yq -r ".sources[$i].asns[]" "$SOURCES_FILE")
            fetch_asn "$name" "${asns[@]}" || echo "WARN: $name failed"
            ;;
        maxmind_country)
            iso=$(yq -r ".sources[$i].iso" "$SOURCES_FILE")
            fetch_maxmind_country "$name" "$iso" || echo "WARN: $name failed"
            ;;
        *)
            echo "WARN: unknown source type '$type' for $name, skipping"
            ;;
    esac
done

# Transform .lst -> bird <name>.txt route format (same sed as chklist.sh).
# Always run so bird's include never points at a missing file — even when a
# single source fails and its .lst is empty, its .txt still exists (empty).
for i in $(seq 0 $((count - 1))); do
    name=$(yq -r ".sources[$i].name" "$SOURCES_FILE")
    lst="${LIST_DIR}/${name}.lst"
    out="${BIRD_DIR}/${name}.txt"
    if [ -s "$lst" ]; then
        sed 's_.*_route & reject;_' "$lst" > "$out"
    else
        : > "$out"
    fi
done

# MD5 guard controls reload only — the .txt files above are already written.
old_md5=""
[ -f "$MD5_FILE" ] && old_md5=$(cat "$MD5_FILE" 2>/dev/null || echo "")
new_md5=$(cd "$LIST_DIR" && cat ./*.lst 2>/dev/null | md5sum | head -c 32 || echo "")

if [ -z "$new_md5" ]; then
    echo "ERROR: no lists produced"
    exit 1
fi

if [ "$old_md5" = "$new_md5" ]; then
    echo "MD5 unchanged; skipping bird reload"
    exit 0
fi

echo "MD5 changed; reloading bird"

if pgrep -x bird >/dev/null 2>&1; then
    if birdc configure; then
        echo "bird reconfigured"
        echo "$new_md5" > "$MD5_FILE"
    else
        echo "ERROR: birdc configure failed" >&2
        exit 1
    fi
else
    echo "bird not running yet; recording md5 for next refresh"
    echo "$new_md5" > "$MD5_FILE"
fi
