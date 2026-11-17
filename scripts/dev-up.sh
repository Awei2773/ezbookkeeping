#!/bin/sh
# Start the ezBookkeeping development environment.
#
#   ./scripts/dev-up.sh
#
# - backend  : Go backend on :8080 (hot reload)
# - frontend : Vite dev server on :8081 (HMR, proxies /api -> :8080)
#
# Requires Docker + Compose. All builds run inside containers; nothing is
# installed on the host.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.dev.yml"

cd "$PROJECT_DIR"

echo "[dev-up] project dir: $PROJECT_DIR"

# 0. Check docker is usable
if ! docker info >/dev/null 2>&1; then
    echo "[dev-up] ERROR: cannot talk to Docker daemon (is docker running? is this user in the docker group?)" >&2
    exit 1
fi

# 1. Check target ports are free
port_in_use() {
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

if port_in_use 8080; then
    echo "[dev-up] ERROR: port 8080 is already in use. Free it or change the mapping in docker-compose.dev.yml." >&2
    exit 1
fi

if port_in_use 8081; then
    echo "[dev-up] ERROR: port 8081 is already in use. Free it or change the mapping in docker-compose.dev.yml." >&2
    exit 1
fi

# 2. Ensure .env exists (optional; empty secret key is only for local first run)
if [ ! -f "$PROJECT_DIR/.env" ]; then
    echo "[dev-up] WARNING: no .env found. Copying .env.example; set EBK_SECURITY_SECRET_KEY before exposing the app."
    cp "$PROJECT_DIR/.env.example" "$PROJECT_DIR/.env"
fi

# 3. Build + start
echo "[dev-up] building images and starting services..."
docker compose -f "$COMPOSE_FILE" up -d --build

echo ""
echo "[dev-up] done."
echo "  frontend (Vite, HMR) : http://localhost:8081/"
echo "  backend  (API)       : http://localhost:8080/healthz.json"
echo ""
echo "  Logs:   docker compose -f $COMPOSE_FILE logs -f backend frontend"
echo "  Stop:   ./scripts/dev-down.sh"
