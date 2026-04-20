#!/bin/bash
set -euo pipefail

BIRD_VERSION="${BIRD_VERSION:-unknown}"
BIRD_CTL="/var/run/bird/bird.ctl"

: "${REFRESH_INTERVAL:=24h}"
: "${RUN_ONCE:=false}"
: "${SOURCES_FILE:=/etc/blacklist/sources.yaml}"
: "${BIRD_DIR:=/etc/bird}"
: "${BIRD_CONF:=${BIRD_DIR}/bird.conf}"
export SOURCES_FILE BIRD_DIR

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] [BIRD-${BIRD_VERSION}] $1"
}

# Expand *_FILE secret envs (Docker secret convention)
for var in MAXMIND_ACCOUNT_ID MAXMIND_LICENSE_KEY WEBHOOK_SECRET; do
    file_var="${var}_FILE"
    if [ -n "${!file_var:-}" ] && [ -f "${!file_var}" ]; then
        export "$var"="$(cat "${!file_var}")"
        log "loaded $var from $file_var"
    fi
done

BIRD_PID=""
LOOP_PID=""

WEBHOOK_PID=""

shutdown() {
    log "shutdown signal received"
    for pid in "$LOOP_PID" "$WEBHOOK_PID"; do
        [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null || true
    done
    if [ -n "$BIRD_PID" ] && kill -0 "$BIRD_PID" 2>/dev/null; then
        if birdc -s "$BIRD_CTL" show status >/dev/null 2>&1; then
            log "asking bird to shut down cleanly"
            birdc -s "$BIRD_CTL" down 2>/dev/null || kill -TERM "$BIRD_PID" 2>/dev/null
        else
            kill -TERM "$BIRD_PID" 2>/dev/null || true
        fi
    fi
    wait || true
    exit 0
}
trap shutdown TERM INT QUIT

if [ ! -f "$BIRD_CONF" ]; then
    log "FATAL: $BIRD_CONF not found. Mount your bird.conf into ${BIRD_DIR}."
    exit 1
fi

log "=== initial fetch ==="
if ! /usr/local/bin/fetch-lists.sh; then
    log "WARN: initial fetch had errors; continuing if any lists exist"
fi

log "=== validating bird config ==="
if ! bird -p -c "$BIRD_CONF"; then
    log "FATAL: bird config validation failed"
    exit 1
fi

if [ "$RUN_ONCE" = "true" ]; then
    log "RUN_ONCE=true; exiting."
    exit 0
fi

log "=== starting bird ==="
# Run bird as root inside the container. The container is dedicated to bird;
# the bird user exists but privilege-dropping via -u/-g triggers capset errors
# in host network mode without CAP_SETPCAP. Simpler + fine for a lab.
bird -f -c "$BIRD_CONF" -s "$BIRD_CTL" &
BIRD_PID=$!

if [ -n "${WEBHOOK_SECRET:-}" ]; then
    log "=== starting webhook server on :${WEBHOOK_PORT:-9090} ==="
    python3 /usr/local/bin/webhook.py &
    WEBHOOK_PID=$!
fi

(
    while :; do
        sleep "$REFRESH_INTERVAL"
        log "=== periodic refresh ==="
        /usr/local/bin/fetch-lists.sh || log "WARN: refresh failed; retry next interval"
    done
) &
LOOP_PID=$!

# Exit when either child dies (then shutdown handler cleans the other)
wait -n
log "a supervised process exited"
shutdown
