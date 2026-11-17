#!/bin/sh
# Stop the ezBookkeeping development environment.
#
#   ./scripts/dev-down.sh          # stop containers, keep named volumes
#   ./scripts/dev-down.sh --clean  # stop and remove named volumes (go module cache)

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.dev.yml"

cd "$PROJECT_DIR"

echo "[dev-down] stopping services..."
docker compose -f "$COMPOSE_FILE" down

if [ "${1:-}" = "--clean" ]; then
    echo "[dev-down] removing named volumes (go module cache)..."
    docker compose -f "$COMPOSE_FILE" down -v
fi

echo "[dev-down] done."
