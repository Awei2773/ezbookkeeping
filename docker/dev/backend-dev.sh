#!/bin/sh
# Dev-mode backend runner with hot reload.
#
# Builds the backend inside the container and restarts it whenever a .go file
# changes. Uses a polling loop (find -newer) on purpose: on NAS filesystems the
# inotify events of a bind-mounted directory are not always delivered, so a
# poll-based watcher is the reliable fallback. Rebuilds are incremental thanks
# to the persistent Go build cache, so a change usually restarts in a few
# seconds.
set -u

APP_DIR="${EBK_APP_DIR:-/app}"
BIN="/tmp/ezbookkeeping-dev"
MARKER="/tmp/.ebk-build-marker"
POLL_SECONDS="${EBK_DEV_POLL_SECONDS:-2}"
PID=""

cd "$APP_DIR" || { echo "[dev-backend] cannot cd to $APP_DIR" >&2; exit 1; }

log() { echo "[dev-backend] $*"; }

build() {
    log "building backend..."
    CGO_ENABLED=1 go build -o "$BIN" ezbookkeeping.go
    rc=$?
    if [ "$rc" -ne 0 ]; then
        log "build FAILED (exit $rc)"
        return "$rc"
    fi
    touch "$MARKER"
    log "build ok -> $BIN"
    return 0
}

stop_server() {
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        log "stopping server pid $PID"
        kill "$PID" 2>/dev/null || true
        wait "$PID" 2>/dev/null || true
    fi
    PID=""
}

start_server() {
    log "starting server..."
    if [ -n "${EBK_CONF_PATH:-}" ]; then
        "$BIN" server run --conf-path="$EBK_CONF_PATH" &
    else
        "$BIN" server run &
    fi
    PID=$!
    log "started pid $PID"
}

# Initial build only if there is no binary or marker yet.
if [ ! -x "$BIN" ] || [ ! -f "$MARKER" ]; then
    if ! build; then
        log "initial build failed; will retry on next source change"
        : > "$MARKER" 2>/dev/null || true
    fi
fi

start_server

while true; do
    sleep "$POLL_SECONDS"

    if find . -name '*.go' -newer "$MARKER" -print -quit 2>/dev/null | grep -q .; then
        log ".go change detected, rebuilding + restarting..."
        stop_server
        if build; then
            start_server
        else
            log "build failed; server stays stopped until a successful rebuild"
        fi
    fi
done
