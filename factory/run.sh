#!/usr/bin/env bash
# factory/run.sh — Dark Factory task runner
#
# Accepts task input as environment variables and walks the pipeline stages
# in order. Each stage is an independent shell function that can be replaced
# without touching the others.
#
# See factory/README.md for the full task input and run-directory conventions.

set -euo pipefail

FACTORY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$FACTORY_DIR/.." && pwd)"

TASK="${TASK:-}"
REPO="${REPO:-}"

if [ -z "$TASK" ]; then
    echo "error: TASK is required" >&2
    echo "usage: TASK=\"<prompt>\" [REPO=\"<url>\"] make run" >&2
    exit 1
fi

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')"
RUN_DIR="runs/$RUN_ID"

MAX_ATTEMPTS=3
RETRY_DELAY=5

mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/run.log") 2>&1

echo "==> run  $RUN_ID"
echo "    task: $TASK"
[ -n "$REPO" ] && echo "    repo: $REPO"
echo "    dir:  $RUN_DIR"
echo ""

# ---------------------------------------------------------------------------
# Lifecycle stages — each function receives RUN_DIR, TASK, and REPO as
# environment variables.
# ---------------------------------------------------------------------------

provision() {
    local workspace_dir

    if [ -n "$REPO" ]; then
        workspace_dir="$RUN_DIR/workspace"
        rm -rf "$workspace_dir"
        echo "[provision] cloning $REPO"
        if ! git clone --depth 1 "$REPO" "$workspace_dir"; then
            echo "[provision] failed to clone $REPO" >&2
            return 1
        fi
    else
        workspace_dir="$REPO_ROOT"
        echo "[provision] using current repository"
    fi

    echo "[provision] starting devcontainer (workspace: $workspace_dir)"

    local up_log="$RUN_DIR/provision.log"
    if ! devcontainer up \
            --workspace-folder "$workspace_dir" \
            --config "$REPO_ROOT/.devcontainer/devcontainer.json" \
            2>&1 | tee "$up_log"; then
        echo "[provision] devcontainer up failed (see $up_log)" >&2
        return 1
    fi

    local container_id
    container_id=$(jq -Rr 'try (fromjson | select(.containerId != null) | .containerId)' "$up_log" 2>/dev/null | tail -1)

    if [ -z "$container_id" ]; then
        echo "[provision] could not determine container ID (see $up_log)" >&2
        return 1
    fi

    printf '%s\n' "$workspace_dir" > "$RUN_DIR/workspace-path"
    printf '%s\n' "$container_id" > "$RUN_DIR/container-id"

    echo "[provision] container ready: $container_id"
}

# invoke_agent — isolated agent call; replace this function to swap providers.
invoke_agent() {
    local workspace_dir="$1"
    local task="$2"
    local log_file="$3"
    devcontainer exec \
        --workspace-folder "$workspace_dir" \
        -- claude -p "$task" \
        2>&1 | tee "$log_file"
}

execute() {
    local workspace_dir container_id agent_log
    workspace_dir=$(cat "$RUN_DIR/workspace-path")
    container_id=$(cat "$RUN_DIR/container-id")
    agent_log="$RUN_DIR/agent.log"

    echo "[execute]   running agent in container $container_id"

    if ! invoke_agent "$workspace_dir" "$TASK" "$agent_log"; then
        echo "[execute]   agent failed (see $agent_log)" >&2
        return 1
    fi

    echo "[execute]   agent output written to $agent_log"
}

collect() {
    local run_status="${1:-ok}"

    if [ -f "$RUN_DIR/workspace-path" ]; then
        local workspace_dir diff_file
        workspace_dir=$(cat "$RUN_DIR/workspace-path")
        diff_file="$RUN_DIR/changes.patch"
        git -C "$workspace_dir" diff HEAD > "$diff_file" 2>/dev/null || true
        echo "[collect]   changes.patch: $diff_file"
    fi

    local end_time
    end_time=$(date -u '+%Y%m%dT%H%M%SZ')
    {
        echo "task:   $TASK"
        [ -n "$REPO" ] && echo "repo:   $REPO"
        echo "start:  $RUN_ID"
        echo "end:    $end_time"
        echo "status: $run_status"
    } > "$RUN_DIR/summary.txt"

    echo "[collect]   run.log:       $RUN_DIR/run.log"
    [ -f "$RUN_DIR/agent.log" ] && echo "[collect]   agent.log:     $RUN_DIR/agent.log"
    echo "[collect]   summary.txt:   $RUN_DIR/summary.txt"
}

teardown() {
    if [ ! -f "$RUN_DIR/container-id" ]; then
        echo "[teardown]  no container-id found, nothing to remove"
        return 0
    fi

    local container_id failed=0
    container_id=$(cat "$RUN_DIR/container-id")

    echo "[teardown]  stopping container $container_id"
    if ! docker stop "$container_id" 2>&1; then
        echo "[teardown]  ERROR: failed to stop $container_id" >&2
        failed=1
    fi

    echo "[teardown]  removing container $container_id"
    if ! docker rm "$container_id" 2>&1; then
        echo "[teardown]  ERROR: failed to remove $container_id" >&2
        failed=1
    fi

    return "$failed"
}

# ---------------------------------------------------------------------------
# Main — retry loop around provision+execute; collect and teardown always run.
# ---------------------------------------------------------------------------

pipeline_status=1
attempt=0

while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    echo "==> attempt $attempt of $MAX_ATTEMPTS"

    if provision && execute; then
        pipeline_status=0
        break
    fi

    teardown || true

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        echo "    attempt $attempt failed, retrying in ${RETRY_DELAY}s ..."
        sleep "$RETRY_DELAY"
    else
        echo "    all $MAX_ATTEMPTS attempts failed" >&2
    fi
done

run_result="ok"
[ "$pipeline_status" -ne 0 ] && run_result="failed"
collect "$run_result"

if ! teardown; then
    echo "" >&2
    echo "!!! teardown encountered errors — manual cleanup may be required" >&2
    echo "" >&2
fi

echo ""
[ "$pipeline_status" -eq 0 ] && echo "==> done $RUN_ID" || echo "==> failed $RUN_ID"
exit "$pipeline_status"
