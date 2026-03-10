#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="${PAIR_LOOP_E2E_MODE:-standard}"
FIRST_AGENT="${PAIR_LOOP_E2E_FIRST_AGENT:-claude}"
MAX_ITERATIONS="${PAIR_LOOP_E2E_MAX_ITERATIONS:-1}"
SESSION_NAME="${PAIR_LOOP_E2E_SESSION_NAME:-e2e-live-$(date '+%Y%m%d-%H%M%S')}"
WORKSPACE="${PAIR_LOOP_E2E_WORKSPACE:-/tmp/pair-loop-e2e-workspace-$$}"
LOG_DIR="${PAIR_LOOP_E2E_LOG_DIR:-/tmp/pair-loop-e2e-logs-$$}"
TASK="${PAIR_LOOP_E2E_TASK:-Create a file named smoke.txt at the workspace root containing exactly one line: smoke test. Update the shared state as needed. Do not install dependencies. Do not use the network.}"
VALIDATION_COMMAND="${PAIR_LOOP_E2E_VALIDATION_COMMAND:-test \"\$(wc -l < smoke.txt)\" -eq 1 && test \"\$(wc -c < smoke.txt)\" -eq 11 && printf 'smoke test\\n' | cmp -s - smoke.txt}"
ROLE_PRESET="${PAIR_LOOP_E2E_ROLE_PRESET:-balanced}"
CLEANUP=0
SUCCESS=0
REQUIRE_CLAUDE_TURN=0
REQUIRE_CODEX_TURN=0
EXTRA_LOOP_ARGS=()

usage() {
  cat <<'EOF'
Usage: ./tests/e2e_live_pair_loop.sh [options] [-- extra pair-loop args]

Runs a live authenticated smoke test against pair_loop.sh or pair_loop_mcp.sh.
This test is manual/integration-oriented: it consumes real Claude/Codex usage and
requires network access plus authenticated local CLIs.

Options:
  --mode standard|mcp       Loop mode to test (default: standard)
  --first-agent NAME        claude or codex (default: claude)
  --max-iterations N        Iterations to run (default: 1)
  --session-name NAME       Session name to use in the log directory
  --workspace PATH          Workspace directory to use
  --log-dir PATH            Log directory root to use
  --task TEXT               Task for the smoke test
  --validation-command CMD  Validation command to pass into the loop
  --role-preset NAME        balanced, docs-refactor, or reviewer-builder
  --require-claude-turn     Fail unless the last iteration records Claude as completed
  --require-codex-turn      Fail unless the last iteration records Codex as completed
  --cleanup                 Remove generated workspace/log directories after success
  -h, --help                Show this help message

Environment overrides:
  PAIR_LOOP_E2E_MODE
  PAIR_LOOP_E2E_FIRST_AGENT
  PAIR_LOOP_E2E_MAX_ITERATIONS
  PAIR_LOOP_E2E_SESSION_NAME
  PAIR_LOOP_E2E_WORKSPACE
  PAIR_LOOP_E2E_LOG_DIR
  PAIR_LOOP_E2E_TASK
  PAIR_LOOP_E2E_VALIDATION_COMMAND
  PAIR_LOOP_E2E_ROLE_PRESET
EOF
}

die() {
  echo "Error: $*" >&2
  exit 1
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

cleanup_artifacts() {
  if [ "$CLEANUP" -eq 1 ] && [ "$SUCCESS" -eq 1 ]; then
    rm -rf "$WORKSPACE" "$LOG_DIR"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      [ "$#" -ge 2 ] || die "--mode requires a value"
      MODE="$2"
      shift 2
      ;;
    --first-agent)
      [ "$#" -ge 2 ] || die "--first-agent requires a value"
      FIRST_AGENT="$2"
      shift 2
      ;;
    --max-iterations)
      [ "$#" -ge 2 ] || die "--max-iterations requires a value"
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    --session-name)
      [ "$#" -ge 2 ] || die "--session-name requires a value"
      SESSION_NAME="$2"
      shift 2
      ;;
    --workspace)
      [ "$#" -ge 2 ] || die "--workspace requires a value"
      WORKSPACE="$2"
      shift 2
      ;;
    --log-dir)
      [ "$#" -ge 2 ] || die "--log-dir requires a value"
      LOG_DIR="$2"
      shift 2
      ;;
    --task)
      [ "$#" -ge 2 ] || die "--task requires a value"
      TASK="$2"
      shift 2
      ;;
    --validation-command)
      [ "$#" -ge 2 ] || die "--validation-command requires a value"
      VALIDATION_COMMAND="$2"
      shift 2
      ;;
    --role-preset)
      [ "$#" -ge 2 ] || die "--role-preset requires a value"
      ROLE_PRESET="$2"
      shift 2
      ;;
    --require-claude-turn)
      REQUIRE_CLAUDE_TURN=1
      shift
      ;;
    --require-codex-turn)
      REQUIRE_CODEX_TURN=1
      shift
      ;;
    --cleanup)
      CLEANUP=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      while [ "$#" -gt 0 ]; do
        EXTRA_LOOP_ARGS+=("$1")
        shift
      done
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$MODE" in
  standard)
    LOOP_SCRIPT="$REPO_ROOT/pair_loop.sh"
    ;;
  mcp)
    LOOP_SCRIPT="$REPO_ROOT/pair_loop_mcp.sh"
    ;;
  *)
    die "mode must be one of: standard, mcp"
    ;;
esac

case "$FIRST_AGENT" in
  claude|codex)
    ;;
  *)
    die "first agent must be one of: claude, codex"
    ;;
esac

case "$MAX_ITERATIONS" in
  ''|*[!0-9]*)
    die "max iterations must be a non-negative integer"
    ;;
esac

for required_cmd in node claude codex; do
  command -v "$required_cmd" >/dev/null 2>&1 || die "missing required command: $required_cmd"
done

if [ "$MODE" = "mcp" ]; then
  command -v npx >/dev/null 2>&1 || die "missing required command for MCP mode: npx"
fi

SESSION_SLUG="$(sanitize_name "$SESSION_NAME")"
[ -n "$SESSION_SLUG" ] || die "session name must contain at least one alphanumeric character"
ACTIVE_LOG_DIR="$LOG_DIR/$SESSION_SLUG"
RUN_SUMMARY_FILE="$ACTIVE_LOG_DIR/run_summary.json"

mkdir -p "$WORKSPACE" "$LOG_DIR"
trap cleanup_artifacts EXIT

echo "Running live pair-loop E2E smoke test"
echo "  mode: $MODE"
echo "  first agent: $FIRST_AGENT"
echo "  workspace: $WORKSPACE"
echo "  log dir: $ACTIVE_LOG_DIR"
echo "  session: $SESSION_SLUG"
echo ""

LOOP_ARGS=(
  --workspace "$WORKSPACE"
  --log-dir "$LOG_DIR"
  --session-name "$SESSION_NAME"
  --task "$TASK"
  --max-iterations "$MAX_ITERATIONS"
  --validation-command "$VALIDATION_COMMAND"
  --until-tests-pass
  --role-preset "$ROLE_PRESET"
)

if [ "$FIRST_AGENT" = "codex" ]; then
  LOOP_ARGS+=(--codex-first)
else
  LOOP_ARGS+=(--claude-first)
fi

if [ "${#EXTRA_LOOP_ARGS[@]}" -gt 0 ]; then
  LOOP_ARGS+=("${EXTRA_LOOP_ARGS[@]}")
fi

"$LOOP_SCRIPT" "${LOOP_ARGS[@]}"

test -f "$WORKSPACE/smoke.txt" || die "missing smoke.txt in workspace"
test -f "$ACTIVE_LOG_DIR/state/loop_state.md" || die "missing session loop_state.md mirror"
test -f "$ACTIVE_LOG_DIR/state/loop_state.json" || die "missing session loop_state.json mirror"
test -f "$RUN_SUMMARY_FILE" || die "missing run summary"
[ ! -e "$WORKSPACE/.loop_state.md" ] || die "workspace should not contain .loop_state.md"
[ ! -e "$WORKSPACE/.loop_state.json" ] || die "workspace should not contain .loop_state.json"
if find "$WORKSPACE" -maxdepth 1 -type f \( -name 'claude_handoff_iter*.md' -o -name 'codex_handoff_iter*.md' -o -name 'claude_mcp_handoff_iter*.md' -o -name 'codex_mcp_handoff_iter*.md' \) | grep -q .; then
  die "workspace should not contain handoff markdown files"
fi

expected_file="$(mktemp)"
printf 'smoke test\n' > "$expected_file"
cmp -s "$WORKSPACE/smoke.txt" "$expected_file" || die "smoke.txt content did not match expected output"
rm -f "$expected_file"

FINAL_ITERATION="$(node - "$RUN_SUMMARY_FILE" "$MODE" "$REQUIRE_CLAUDE_TURN" "$REQUIRE_CODEX_TURN" <<'EOF'
const fs = require("fs");

const [summaryPath, mode, requireClaudeTurn, requireCodexTurn] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));

if (!summary.session || summary.session.mode !== mode) {
  throw new Error(`expected summary.session.mode=${mode}, got ${summary.session && summary.session.mode}`);
}

if (!summary.healthChecks || !summary.healthChecks.node) {
  throw new Error("missing healthChecks section in run summary");
}

if (summary.validation.status !== "passed") {
  throw new Error(`expected validation.status=passed, got ${summary.validation.status}`);
}

if (!Number.isInteger(summary.iterationsCompleted) || summary.iterationsCompleted < 1) {
  throw new Error(`expected iterationsCompleted >= 1, got ${summary.iterationsCompleted}`);
}

if (!summary.lastIteration || summary.lastIteration.iteration !== summary.iterationsCompleted) {
  throw new Error("run summary lastIteration did not match iterationsCompleted");
}

const last = summary.lastIteration;
const claude = last.agents.find((agent) => agent.name === "Claude Code");
const codex = last.agents.find((agent) => agent.name === "Codex");

if (!claude || !codex) {
  throw new Error("missing Claude or Codex agent record in iteration history");
}

if (requireClaudeTurn === "1" && claude.status !== "completed") {
  throw new Error(`expected Claude turn to complete, got ${claude.status}`);
}

if (requireCodexTurn === "1" && codex.status !== "completed") {
  throw new Error(`expected Codex turn to complete, got ${codex.status}`);
}

process.stdout.write(String(summary.iterationsCompleted));
EOF
)"

[ -n "$FINAL_ITERATION" ] || die "failed to resolve final iteration from run summary"
test -f "$ACTIVE_LOG_DIR/validation_iter${FINAL_ITERATION}.log" || die "missing validation log for final iteration"

if [ "$MODE" = "mcp" ]; then
  test -f "$ACTIVE_LOG_DIR/claude_mcp_iter${FINAL_ITERATION}.log" || die "missing Claude MCP log for final iteration"
  test -f "$ACTIVE_LOG_DIR/codex_mcp_iter${FINAL_ITERATION}.log" || die "missing Codex MCP log for final iteration"
else
  test -f "$ACTIVE_LOG_DIR/claude_iter${FINAL_ITERATION}.log" || die "missing Claude log for final iteration"
  test -f "$ACTIVE_LOG_DIR/codex_iter${FINAL_ITERATION}.log" || die "missing Codex log for final iteration"
fi

SUCCESS=1

echo ""
echo "E2E smoke test passed."
echo "  workspace: $WORKSPACE"
echo "  state: $ACTIVE_LOG_DIR/state/loop_state.md"
echo "  logs: $ACTIVE_LOG_DIR"
echo "  summary: $RUN_SUMMARY_FILE"
