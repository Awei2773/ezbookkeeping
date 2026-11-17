#!/bin/sh
# Semi-automatic upstream sync for the ezBookkeeping 2nd-development repo.
#
# Phase 1 (automatic) — run this first:
#   ./scripts/sync-upstream.sh
#   1. fetch upstream
#   2. report how far main lags behind upstream/main
#   3. back up data/ (Sync2 silently alters tables on the next start)
#   4. fast-forward main to upstream/main (main is an upstream mirror)
#   5. STOP and print the manual merge + conflict instructions.
#
# Phase 2 (manual merge) — you run this by hand:
#   git checkout feat/local-dev
#   git merge --no-ff main -m "sync: upstream vX.Y.Z"
#   # resolve conflicts per docs/dev/DEV_WORKFLOW.md, then commit
#
# Phase 3 (verify) — run this after the merge is committed:
#   ./scripts/sync-upstream.sh --continue
#   - runs the full test gate (go test / npm run test / npm run lint)
#   - only if everything is green, prompts for the tag name.
#
# Any failure in Phase 1 aborts and restores main to its pre-sync commit.

set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PROJECT_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
COMPOSE_FILE="$PROJECT_DIR/docker-compose.dev.yml"
MODE="${1:-phase1}"

cd "$PROJECT_DIR"

log() { echo "[sync] $*"; }
die() { echo "[sync] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

require_clean_tree() {
    if [ -n "$(git status --porcelain)" ]; then
        echo "[sync] working tree is NOT clean. Commit or stash first:" >&2
        git status --short >&2
        die "refusing to sync with a dirty working tree"
    fi
}

run_test_gate() {
    log "running backend unit tests (go test ./...)..."
    docker compose -f "$COMPOSE_FILE" run --rm --no-deps --entrypoint sh backend \
        -c "go test ./..." || return 1

    log "running frontend unit tests (npm run test) + lint (npm run lint)..."
    docker compose -f "$COMPOSE_FILE" run --rm --no-deps --entrypoint sh frontend \
        -c "npm install && npm run test && npm run lint" || return 1

    return 0
}

upstream_version() {
    git show upstream/main:package.json 2>/dev/null \
        | grep '"version"' \
        | sed -E 's/.*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

# ---------------------------------------------------------------------------
# Phase 1
# ---------------------------------------------------------------------------

if [ "$MODE" = "phase1" ]; then
    require_clean_tree

    PRE_BRANCH=$(git branch --show-current)
    PRE_MAIN=$(git rev-parse main)

    log "current branch: $PRE_BRANCH"

    log "fetching upstream..."
    git fetch upstream || die "git fetch upstream failed"

    LAG=$(git rev-list --count main..upstream/main || true)
    log "main lags upstream/main by $LAG commit(s)."

    if [ "$LAG" = "0" ]; then
        log "already up to date; nothing to sync."
        exit 0
    fi

    # Back up data/ before any schema-changing start.
    if [ -d "$PROJECT_DIR/data" ] && [ -n "$(ls -A "$PROJECT_DIR/data" 2>/dev/null)" ]; then
        BACKUP="data.bak.$(date +%Y%m%d%H%M%S)"
        log "backing up data/ -> $BACKUP"
        cp -r "$PROJECT_DIR/data" "$PROJECT_DIR/$BACKUP" || die "data/ backup failed"
    else
        log "data/ is empty or missing; nothing to back up."
    fi

    # Move main forward (fast-forward only — main must stay a clean mirror).
    log "fast-forwarding main to upstream/main..."
    git checkout main
    if ! git merge --ff-only upstream/main; then
        log "ff-only merge failed; restoring main to $PRE_MAIN"
        git merge --abort 2>/dev/null || true
        git branch -f main "$PRE_MAIN"
        git checkout "$PRE_BRANCH"
        die "main is not a fast-forward of upstream/main; inspect manually"
    fi

    VER=$(upstream_version)
    echo ""
    log "main updated. Now perform the manual merge (not done automatically):"
    echo ""
    echo "    git checkout feat/local-dev"
    echo "    git merge --no-ff main -m \"sync: upstream v${VER}\""
    echo ""
    echo "  Resolve conflicts per docs/dev/DEV_WORKFLOW.md (conflict priority table)."
    echo "  When done and committed, run:  ./scripts/sync-upstream.sh --continue"
    exit 0
fi

# ---------------------------------------------------------------------------
# Phase 3 (--continue)
# ---------------------------------------------------------------------------

if [ "$MODE" = "--continue" ]; then
    CUR=$(git branch --show-current)
    log "current branch: $CUR"

    if [ "$CUR" != "feat/local-dev" ]; then
        die "expected to be on feat/local-dev (run the manual merge first)"
    fi

    if ! run_test_gate; then
        die "test gate FAILED — fix and re-run --continue; no tag was created"
    fi

    log "test gate is GREEN."

    VER=$(upstream_version)
    printf "[sync] enter tag name (empty to skip), e.g. my/v%s-1: " "$VER"
    read -r TAG

    if [ -n "$TAG" ]; then
        git tag "$TAG" || die "failed to create tag $TAG"
        log "tag $TAG created. Push with:"
        echo "    git push origin feat/local-dev $TAG"
    else
        log "no tag created."
    fi

    exit 0
fi

die "unknown mode: $MODE (use: (phase1) | --continue)"
