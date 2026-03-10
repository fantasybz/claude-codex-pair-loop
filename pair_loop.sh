#!/usr/bin/env bash
# pair_loop.sh — Infinite pair programming loop between Claude Code and OpenAI Codex
# Claude Code (via claude CLI) ←→ Codex (via codex CLI), taking turns improving code.
#
# Usage:
#   ./pair_loop.sh [task_description] [max_iterations]
#
# Requirements:
#   - claude CLI installed + --dangerously-skip-permissions accepted
#   - codex CLI installed + authenticated (codex login --api-key "...")
#   - Node.js v20+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/workspace"
STATE_FILE="$WORKSPACE/.loop_state.md"
LOG_DIR="$SCRIPT_DIR/logs"
MAX_ITERATIONS="${2:-999999}"  # effectively infinite by default
STATUS_CHECK_TIMEOUT="${STATUS_CHECK_TIMEOUT:-20}"
ITERATION=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# Clean workspace and logs from previous runs
echo -e "${YELLOW}Cleaning workspace and logs from previous runs...${NC}"
rm -rf "$WORKSPACE"/* "$WORKSPACE"/.* 2>/dev/null || true
rm -rf "$LOG_DIR"/* 2>/dev/null || true

mkdir -p "$LOG_DIR" "$WORKSPACE"

# Codex requires a git repo
git -C "$WORKSPACE" init -q

# Default task if none provided
TASK="${1:-"Build a CLI tool in Python that converts CSV files to JSON with filtering, sorting, and pretty-print options. Start simple, then iteratively improve: add error handling, tests, documentation, and performance optimizations."}"

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Claude Code ↔ Codex — Infinite Pair Programming Loop  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Task:${NC} $TASK"
echo -e "${YELLOW}Workspace:${NC} $WORKSPACE"
echo -e "${YELLOW}Max iterations:${NC} $MAX_ITERATIONS"
echo ""

# Initialize state file
cat > "$STATE_FILE" << EOF
# Pair Loop State

## Task
$TASK

## History
EOF

# ─── Helper: run a command with a timeout ───
run_with_timeout() {
  local timeout_seconds="$1"
  shift

  local output_file pid elapsed status
  output_file="$(mktemp)"

  "$@" >"$output_file" 2>&1 &
  pid=$!
  elapsed=0

  while kill -0 "$pid" 2>/dev/null; do
    if [ "$elapsed" -ge "$timeout_seconds" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 1
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      cat "$output_file"
      rm -f "$output_file"
      return 124
    fi

    sleep 1
    elapsed=$((elapsed + 1))
  done

  if wait "$pid"; then
    status=0
  else
    status=$?
  fi

  cat "$output_file"
  rm -f "$output_file"
  return "$status"
}

# ─── Helper: check agent availability ───
check_claude_status() {
  local status=0
  CLAUDE_STATUS_REASON="ready"

  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_STATUS_REASON="claude CLI not found"
    return 1
  fi

  if run_with_timeout "$STATUS_CHECK_TIMEOUT" \
    claude -p \
      --dangerously-skip-permissions \
      --no-session-persistence \
      --tools "" \
      --output-format text \
      "Reply with exactly: OK" >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    CLAUDE_STATUS_REASON="account/usage check timed out"
  else
    CLAUDE_STATUS_REASON="account/usage check failed"
  fi
  return 1
}

check_codex_status() {
  local status=0
  CODEX_STATUS_REASON="ready"

  if ! command -v codex >/dev/null 2>&1; then
    CODEX_STATUS_REASON="codex CLI not found"
    return 1
  fi

  if run_with_timeout "$STATUS_CHECK_TIMEOUT" codex login status >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    CODEX_STATUS_REASON="status check timed out"
  else
    CODEX_STATUS_REASON="status check failed"
  fi
  return 1
}

print_agent_status() {
  local name="$1"
  local available="$2"
  local reason="$3"
  local ok_color="$4"

  if [ "$available" -eq 1 ]; then
    echo -e "${ok_color}  $name: available${NC}"
  else
    echo -e "${YELLOW}  $name: unavailable ($reason)${NC}"
  fi
}

write_skip_log() {
  local log_file="$1"
  local agent_name="$2"
  local reason="$3"

  cat > "$log_file" << EOF
[$(date '+%Y-%m-%d %H:%M:%S')] ${agent_name} skipped for iteration ${ITERATION}
Reason: ${reason}
EOF
}

# ─── Helper: run Claude Code ───
run_claude() {
  local prompt="$1"
  local log_file="$LOG_DIR/claude_iter${ITERATION}.log"

  echo -e "${GREEN}🤖 [Claude Code] Iteration $ITERATION${NC}"
  echo -e "${GREEN}   Prompt: ${NC}${prompt:0:120}..."
  echo ""

  (cd "$WORKSPACE" && claude -p \
    --dangerously-skip-permissions \
    --output-format text \
    "$prompt") \
    2>&1 | tee "$log_file"

  echo ""
}

# ─── Helper: run Codex ───
run_codex() {
  local prompt="$1"
  local log_file="$LOG_DIR/codex_iter${ITERATION}.log"

  echo -e "${BLUE}🧠 [Codex] Iteration $ITERATION${NC}"
  echo -e "${BLUE}   Prompt: ${NC}${prompt:0:120}..."
  echo ""

  codex exec --full-auto \
    -C "$WORKSPACE" \
    "$prompt" \
    2>&1 | tee "$log_file"

  echo ""
}

# ─── Helper: get file listing of workspace ───
workspace_snapshot() {
  find "$WORKSPACE" -type f \
    ! -path '*/.git/*' \
    ! -path '*/__pycache__/*' \
    ! -path '*/.loop_state.md' \
    ! -name '*.pyc' \
    -exec echo "  - {}" \; 2>/dev/null || echo "  (empty)"
}

# ═══════════════════════════════════════════════════════
# MAIN LOOP
# ═══════════════════════════════════════════════════════

echo -e "${CYAN}━━━ Starting infinite pair loop ━━━${NC}"
echo ""

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  ITERATION $ITERATION${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  CLAUDE_AVAILABLE=0
  CODEX_AVAILABLE=0
  if check_claude_status; then
    CLAUDE_AVAILABLE=1
  fi
  if check_codex_status; then
    CODEX_AVAILABLE=1
  fi

  echo -e "${CYAN}Agent status:${NC}"
  print_agent_status "Claude Code" "$CLAUDE_AVAILABLE" "$CLAUDE_STATUS_REASON" "$GREEN"
  print_agent_status "Codex" "$CODEX_AVAILABLE" "$CODEX_STATUS_REASON" "$BLUE"
  echo ""

  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    CODEX_STATUS_NOTE="Codex is available for this iteration."
  else
    CODEX_STATUS_NOTE="Codex is unavailable for this iteration (${CODEX_STATUS_REASON}). Work independently and leave clear notes for the next available turn."
  fi

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    CLAUDE_STATUS_NOTE="Claude Code is available for this iteration."
  else
    CLAUDE_STATUS_NOTE="Claude Code is unavailable for this iteration (${CLAUDE_STATUS_REASON}). Work independently and leave clear notes for the next available turn."
  fi

  FILES_SNAPSHOT=$(workspace_snapshot)
  CLAUDE_LOG="$LOG_DIR/claude_iter${ITERATION}.log"
  CODEX_LOG="$LOG_DIR/codex_iter${ITERATION}.log"

  # ─── Step A: Claude Code's turn ───
  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    if [ "$ITERATION" -eq 1 ]; then
      CLAUDE_PROMPT="You are in a pair programming loop with OpenAI Codex. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE
$CODEX_STATUS_NOTE

Start implementing the task. Write clean, working code. After you're done, leave a brief note in $WORKSPACE/.loop_state.md describing what you did and what the next person (Codex) should focus on improving.

Current workspace files:
$FILES_SNAPSHOT"
    else
      CODEX_LAST_LOG="$LOG_DIR/codex_iter$((ITERATION - 1)).log"
      CODEX_SUMMARY=""
      if [ -f "$CODEX_LAST_LOG" ]; then
        CODEX_SUMMARY=$(tail -80 "$CODEX_LAST_LOG")
      fi

      CLAUDE_PROMPT="You are in a pair programming loop with OpenAI Codex. It's your turn (iteration $ITERATION).

TASK: $TASK
WORKSPACE: $WORKSPACE
$CODEX_STATUS_NOTE

Codex just finished their turn. Here's a summary of what they did:
---
$CODEX_SUMMARY
---

Current workspace files:
$FILES_SNAPSHOT

Review what Codex did. Then improve the code further:
- Fix any bugs or issues you find
- Add features, tests, or documentation
- Refactor for better quality
- Update .loop_state.md with what you did and what Codex should do next

Be constructive — build on their work, don't rewrite everything."
    fi

    if ! run_claude "$CLAUDE_PROMPT"; then
      echo -e "${YELLOW}Claude Code failed during iteration $ITERATION. Continuing if Codex is available.${NC}"
      echo ""
    fi
  else
    echo -e "${YELLOW}Skipping Claude Code for iteration $ITERATION: $CLAUDE_STATUS_REASON${NC}"
    write_skip_log "$CLAUDE_LOG" "Claude Code" "Unavailable at iteration start: $CLAUDE_STATUS_REASON"
    echo ""
  fi

  # ─── Step B: Codex's turn ───
  FILES_SNAPSHOT=$(workspace_snapshot)
  CLAUDE_SUMMARY=""
  if [ -f "$CLAUDE_LOG" ]; then
    CLAUDE_SUMMARY=$(tail -80 "$CLAUDE_LOG")
  fi

  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    CODEX_PROMPT="You are in a pair programming loop with Claude Code. It's your turn (iteration $ITERATION).

TASK: $TASK
WORKSPACE: $WORKSPACE
$CLAUDE_STATUS_NOTE

Claude just finished their turn. Here's a summary of what they did:
---
$CLAUDE_SUMMARY
---

Current workspace files:
$FILES_SNAPSHOT

Review what Claude did. Then improve the code further:
- Fix any bugs or issues you find
- Add features, tests, or documentation
- Refactor for better quality
- Update .loop_state.md with what you did and what Claude should do next

Be constructive — build on their work, don't rewrite everything."

    if ! run_codex "$CODEX_PROMPT"; then
      echo -e "${YELLOW}Codex failed during iteration $ITERATION. Continuing to the next iteration.${NC}"
      echo ""
    fi
  else
    echo -e "${YELLOW}Skipping Codex for iteration $ITERATION: $CODEX_STATUS_REASON${NC}"
    write_skip_log "$CODEX_LOG" "Codex" "Unavailable at iteration start: $CODEX_STATUS_REASON"
    echo ""
  fi

  # ─── Summary ───
  echo -e "${CYAN}━━━ Iteration $ITERATION complete ━━━${NC}"
  echo -e "  Logs: $CLAUDE_LOG"
  echo -e "        $CODEX_LOG"
  echo ""

  # Brief pause to allow ctrl-c
  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
