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

  FILES_SNAPSHOT=$(workspace_snapshot)

  # ─── Step A: Claude Code's turn ───
  if [ "$ITERATION" -eq 1 ]; then
    CLAUDE_PROMPT="You are in a pair programming loop with OpenAI Codex. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE

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

  CLAUDE_OUTPUT=$(run_claude "$CLAUDE_PROMPT")

  # ─── Step B: Codex's turn ───
  FILES_SNAPSHOT=$(workspace_snapshot)
  CLAUDE_LAST_LOG="$LOG_DIR/claude_iter${ITERATION}.log"
  CLAUDE_SUMMARY=""
  if [ -f "$CLAUDE_LAST_LOG" ]; then
    CLAUDE_SUMMARY=$(tail -80 "$CLAUDE_LAST_LOG")
  fi

  CODEX_PROMPT="You are in a pair programming loop with Claude Code. It's your turn (iteration $ITERATION).

TASK: $TASK
WORKSPACE: $WORKSPACE

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

  CODEX_OUTPUT=$(run_codex "$CODEX_PROMPT")

  # ─── Summary ───
  echo -e "${CYAN}━━━ Iteration $ITERATION complete ━━━${NC}"
  echo -e "  Logs: $LOG_DIR/claude_iter${ITERATION}.log"
  echo -e "        $LOG_DIR/codex_iter${ITERATION}.log"
  echo ""

  # Brief pause to allow ctrl-c
  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
