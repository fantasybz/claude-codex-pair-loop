#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
SELF_PATH="$ROOT_DIR/scripts/local-ci.sh"
LOCAL_ENV_FILE="$ROOT_DIR/.local-ci.env"

if [ -f "$LOCAL_ENV_FILE" ]; then
  # shellcheck disable=SC1090
  . "$LOCAL_ENV_FILE"
fi

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/local-ci.sh <command>

Commands:
  deterministic    Run fast deterministic local checks
  live             Run the live authenticated Claude/Codex E2E in the foreground
  live-background  Start the live E2E in the background unless one is already running
  all              Run deterministic checks, then the live E2E in the foreground
  install-hooks    Set git core.hooksPath to .githooks for this clone
  help             Show this help message

Optional local overrides can be placed in .local-ci.env:
  LOCAL_CI_ENABLE_SHELLCHECK=1
  LOCAL_CI_SKIP_POST_COMMIT_LIVE=0
  LOCAL_CI_LIVE_MODE=standard
  LOCAL_CI_LIVE_FIRST_AGENT=claude
  LOCAL_CI_LIVE_MAX_ITERATIONS=1
  LOCAL_CI_LIVE_ROLE_PRESET=balanced
  LOCAL_CI_REQUIRE_CLAUDE_TURN=0
  LOCAL_CI_REQUIRE_CODEX_TURN=0
  LOCAL_CI_LIVE_TURN_TIMEOUT=300
  LOCAL_CI_LIVE_TASK="..."
  LOCAL_CI_LIVE_VALIDATION_COMMAND="..."
  LOCAL_CI_LIVE_CLEANUP=0
EOF
}

local_ci_log_root() {
  printf '%s\n' "$ROOT_DIR/logs/local-ci"
}

commit_short_sha() {
  git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo "nohead"
}

cleanup_pid_file() {
  local pid_file="${LOCAL_CI_PID_FILE:-}"
  local recorded_pid=""

  [ -n "$pid_file" ] || return 0
  [ -f "$pid_file" ] || return 0

  recorded_pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [ -z "$recorded_pid" ] || [ "$recorded_pid" = "$$" ]; then
    rm -f "$pid_file"
  fi
}

register_pid_cleanup() {
  [ -n "${LOCAL_CI_PID_FILE:-}" ] || return 0
  trap cleanup_pid_file EXIT INT TERM
}

run_bash_syntax() {
  local file
  local files=(
    pair_loop.sh
    pair_loop_mcp.sh
    scripts/local-ci.sh
    .githooks/pre-commit
    .githooks/post-commit
    tests/e2e_live_pair_loop.sh
    tests/fake_pair_loop_test_lib.sh
    tests/positional_args_regression.sh
    tests/pair_loop_integration_regression.sh
    tests/e2e_harness_regression.sh
  )

  cd "$ROOT_DIR"
  for file in "${files[@]}"; do
    bash -n "$file"
  done
}

run_optional_shellcheck() {
  local files=(
    pair_loop.sh
    pair_loop_mcp.sh
    scripts/local-ci.sh
    .githooks/pre-commit
    .githooks/post-commit
    tests/e2e_live_pair_loop.sh
    tests/fake_pair_loop_test_lib.sh
    tests/positional_args_regression.sh
    tests/pair_loop_integration_regression.sh
    tests/e2e_harness_regression.sh
  )

  if [ "${LOCAL_CI_ENABLE_SHELLCHECK:-1}" = "0" ]; then
    echo "[local-ci] shellcheck disabled by LOCAL_CI_ENABLE_SHELLCHECK=0"
    return 0
  fi

  if ! command -v shellcheck >/dev/null 2>&1; then
    echo "[local-ci] shellcheck not installed; skipping"
    return 0
  fi

  cd "$ROOT_DIR"
  shellcheck "${files[@]}"
}

run_deterministic() {
  echo "[local-ci] Running bash syntax checks"
  run_bash_syntax

  echo "[local-ci] Running shellcheck when available"
  run_optional_shellcheck

  cd "$ROOT_DIR"

  echo "[local-ci] Running positional regression"
  bash tests/positional_args_regression.sh

  echo "[local-ci] Running pair-loop integration regression"
  bash tests/pair_loop_integration_regression.sh

  echo "[local-ci] Running E2E harness regression"
  bash tests/e2e_harness_regression.sh
}

run_live() {
  local mode="${LOCAL_CI_LIVE_MODE:-standard}"
  local first_agent="${LOCAL_CI_LIVE_FIRST_AGENT:-claude}"
  local max_iterations="${LOCAL_CI_LIVE_MAX_ITERATIONS:-1}"
  local role_preset="${LOCAL_CI_LIVE_ROLE_PRESET:-balanced}"
  local require_claude_turn="${LOCAL_CI_REQUIRE_CLAUDE_TURN:-0}"
  local require_codex_turn="${LOCAL_CI_REQUIRE_CODEX_TURN:-0}"
  local cleanup="${LOCAL_CI_LIVE_CLEANUP:-0}"
  local turn_timeout="${LOCAL_CI_LIVE_TURN_TIMEOUT:-}"
  local task="${LOCAL_CI_LIVE_TASK:-}"
  local validation_command="${LOCAL_CI_LIVE_VALIDATION_COMMAND:-}"
  local session_prefix="${LOCAL_CI_LIVE_SESSION_PREFIX:-local-ci-live}"
  local session_name=""
  local base_dir=""
  local workspace=""
  local log_dir=""
  local args=()

  register_pid_cleanup

  if [ -n "${LOCAL_CI_LIVE_SESSION_NAME:-}" ]; then
    session_name="$LOCAL_CI_LIVE_SESSION_NAME"
  else
    session_name="${session_prefix}-$(commit_short_sha)-$(date '+%Y%m%d-%H%M%S')"
  fi

  base_dir="${LOCAL_CI_LIVE_BASE_DIR:-$ROOT_DIR/logs/local-ci/$session_name}"
  workspace="${LOCAL_CI_LIVE_WORKSPACE:-$base_dir/workspace}"
  log_dir="${LOCAL_CI_LIVE_LOG_DIR:-$base_dir/logs}"

  args=(
    --mode "$mode"
    --first-agent "$first_agent"
    --max-iterations "$max_iterations"
    --role-preset "$role_preset"
    --workspace "$workspace"
    --log-dir "$log_dir"
    --session-name "$session_name"
  )

  if [ -n "$task" ]; then
    args+=(--task "$task")
  fi

  if [ -n "$validation_command" ]; then
    args+=(--validation-command "$validation_command")
  fi

  if [ "$require_claude_turn" = "1" ]; then
    args+=(--require-claude-turn)
  fi

  if [ "$require_codex_turn" = "1" ]; then
    args+=(--require-codex-turn)
  fi

  if [ "$cleanup" = "1" ]; then
    args+=(--cleanup)
  fi

  if [ -n "$turn_timeout" ]; then
    args+=(-- --turn-timeout "$turn_timeout")
  fi

  echo "[local-ci] Running live E2E"
  echo "[local-ci]   mode: $mode"
  echo "[local-ci]   first agent: $first_agent"
  echo "[local-ci]   session: $session_name"
  echo "[local-ci]   workspace: $workspace"
  echo "[local-ci]   logs: $log_dir"

  cd "$ROOT_DIR"
  bash tests/e2e_live_pair_loop.sh "${args[@]}"
}

start_live_background() {
  local log_root=""
  local pid_file=""
  local existing_pid=""
  local commit_sha=""
  local log_file=""
  local child_pid=""

  if [ "${LOCAL_CI_SKIP_POST_COMMIT_LIVE:-0}" = "1" ]; then
    echo "[local-ci] Skipping post-commit live E2E because LOCAL_CI_SKIP_POST_COMMIT_LIVE=1"
    return 0
  fi

  log_root="$(local_ci_log_root)"
  mkdir -p "$log_root"
  pid_file="$log_root/live-e2e.pid"

  if [ -f "$pid_file" ]; then
    existing_pid="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
      echo "[local-ci] Live E2E already running (pid $existing_pid); skipping"
      return 0
    fi
    rm -f "$pid_file"
  fi

  commit_sha="$(commit_short_sha)"
  log_file="$log_root/post-commit-${commit_sha}-$(date '+%Y%m%d-%H%M%S').log"

  nohup env LOCAL_CI_PID_FILE="$pid_file" "$SELF_PATH" live >"$log_file" 2>&1 < /dev/null &
  child_pid=$!
  printf '%s\n' "$child_pid" > "$pid_file"

  echo "[local-ci] Started background live E2E (pid $child_pid)"
  echo "[local-ci] Log file: $log_file"
}

install_hooks() {
  cd "$ROOT_DIR"
  git config core.hooksPath .githooks
  echo "[local-ci] Configured git core.hooksPath=.githooks"
}

COMMAND="${1:-help}"

case "$COMMAND" in
  deterministic)
    run_deterministic
    ;;
  live)
    run_live
    ;;
  live-background)
    start_live_background
    ;;
  all)
    run_deterministic
    run_live
    ;;
  install-hooks)
    install_hooks
    ;;
  help|-h|--help)
    usage
    ;;
  *)
    die "unknown command: $COMMAND"
    ;;
esac
