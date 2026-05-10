#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p "$tmpdir/fakebin" "$tmpdir/list"

cat > "$tmpdir/fakebin/wget" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$WGET_LOG"

case "$*" in
    *"-4"*) ;;
    *) exit 11 ;;
esac
case "$*" in
    *"--connect-timeout=10"*) ;;
    *) exit 12 ;;
esac
case "$*" in
    *"--read-timeout=60"*) ;;
    *) exit 13 ;;
esac
case "$*" in
    *"--tries=1"*) ;;
    *) exit 14 ;;
esac

count=0
[ -f "$WGET_COUNT_FILE" ] && count=$(cat "$WGET_COUNT_FILE")
count=$((count + 1))
printf '%s\n' "$count" > "$WGET_COUNT_FILE"

if [ "$count" -lt 3 ]; then
    exit 4
fi

out=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -O)
            shift
            out="$1"
            ;;
    esac
    shift
done

[ -n "$out" ] || exit 15
printf '203.0.113.0/24\n' > "$out"
SH

cat > "$tmpdir/fakebin/curl" <<'SH'
#!/bin/sh
printf 'curl should not be used\n' >> "$CURL_LOG"
exit 64
SH

cat > "$tmpdir/fakebin/sleep" <<'SH'
#!/bin/sh
exit 0
SH

chmod +x "$tmpdir/fakebin/wget" "$tmpdir/fakebin/curl" "$tmpdir/fakebin/sleep"

export PATH="$tmpdir/fakebin:$PATH"
export LIST_DIR="$tmpdir/list"
export WGET_LOG="$tmpdir/wget.log"
export WGET_COUNT_FILE="$tmpdir/wget.count"
export CURL_LOG="$tmpdir/curl.log"

# shellcheck source=../scripts/sources-lib.sh
source "$repo_root/scripts/sources-lib.sh"

fetch_url "github" "https://raw.githubusercontent.com/example/repo/main/ipv4.txt" false

grep -qx '203.0.113.0/24' "$LIST_DIR/github.lst"
grep -qx '3' "$WGET_COUNT_FILE"
grep -Eq '(^|[[:space:]])-4([[:space:]]|$)' "$WGET_LOG"

if [ -s "$CURL_LOG" ]; then
    echo "expected fetch_url to use wget, but curl was called" >&2
    exit 1
fi
