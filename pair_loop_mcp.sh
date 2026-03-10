#!/usr/bin/env bash
# pair_loop_mcp.sh — Infinite loop using BOTH MCP servers (true agent-in-agent)
#
# Bidirectional MCP loop:
#   Step A: Claude Code (with codex-mcp-server) → can call Codex as MCP tool
#   Step B: Codex (with claude-code-mcp) → can call Claude as MCP tool
#
# Each agent works on the task AND can delegate to the other via MCP.
#
# Usage:
#   ./pair_loop_mcp.sh [task_description] [max_iterations]
#
# Prerequisites:
#   - claude CLI + --dangerously-skip-permissions accepted
#   - codex CLI + authenticated
#   - Node.js v20+

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$SCRIPT_DIR/workspace"
LOG_DIR="$SCRIPT_DIR/logs"
MAX_ITERATIONS="${2:-999999}"
STATUS_CHECK_TIMEOUT="${STATUS_CHECK_TIMEOUT:-20}"
ITERATION=0

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

TASK="${1:-"Build a CLI tool in Python that converts CSV files to JSON with filtering, sorting, and pretty-print options. Iteratively improve it with tests, docs, and optimizations."}"

# ─── MCP config for Claude (to call Codex) ───
# Uses .mcp.json in project root with codex-mcp-server
CLAUDE_MCP_CONFIG="$SCRIPT_DIR/.mcp.json"

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Claude Code ↔ Codex — Bidirectional MCP Agent-in-Agent Loop ║${NC}"
echo -e "${CYAN}║                                                               ║${NC}"
echo -e "${CYAN}║  Claude → codex-mcp-server → Codex CLI                       ║${NC}"
echo -e "${CYAN}║  Codex  → claude-code-mcp  → Claude CLI                      ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Task:${NC} $TASK"
echo -e "${YELLOW}Workspace:${NC} $WORKSPACE"
echo ""

# Initialize state
cat > "$WORKSPACE/.loop_state.md" << EOF
# Pair Loop State (Bidirectional MCP Mode)

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

ensure_claude_code_mcp() {
  local mcp_list=""
  local status=0

  if mcp_list=$(run_with_timeout "$STATUS_CHECK_TIMEOUT" codex mcp list); then
    if printf '%s\n' "$mcp_list" | grep -q '^claude-code[[:space:]]'; then
      return 0
    fi
  fi

  echo -e "${YELLOW}Registering claude-code-mcp for Codex...${NC}"
  if run_with_timeout "$STATUS_CHECK_TIMEOUT" \
    codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest >/dev/null 2>&1; then
    return 0
  else
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    CODEX_STATUS_REASON="claude-code MCP registration timed out"
  else
    CODEX_STATUS_REASON="claude-code MCP registration failed"
  fi
  return 1
}

check_claude_status() {
  local status=0
  CLAUDE_STATUS_REASON="ready"

  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_STATUS_REASON="claude CLI not found"
    return 1
  fi

  if [ ! -f "$CLAUDE_MCP_CONFIG" ]; then
    CLAUDE_STATUS_REASON="missing MCP config at $CLAUDE_MCP_CONFIG"
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
    if ensure_claude_code_mcp; then
      return 0
    fi
    return 1
  else
    status=$?
    if [ "$status" -eq 124 ]; then
      CODEX_STATUS_REASON="status check timed out"
    else
      CODEX_STATUS_REASON="status check failed"
    fi
    return 1
  fi
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

run_claude() {
  local prompt="$1"
  local log_file="$LOG_DIR/claude_mcp_iter${ITERATION}.log"

  echo -e "${GREEN}🤖 [Claude Code + Codex MCP] working...${NC}"
  (cd "$WORKSPACE" && claude -p \
    --dangerously-skip-permissions \
    --no-session-persistence \
    --mcp-config "$CLAUDE_MCP_CONFIG" \
    --output-format text \
    "$prompt") \
    2>&1 | tee "$log_file"
  echo ""
}

run_codex() {
  local prompt="$1"
  local log_file="$LOG_DIR/codex_mcp_iter${ITERATION}.log"

  echo -e "${BLUE}🧠 [Codex + Claude Code MCP] working...${NC}"
  codex exec --full-auto \
    -C "$WORKSPACE" \
    "$prompt" \
    2>&1 | tee "$log_file"
  echo ""
}

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))

  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  ITERATION $ITERATION${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

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
    CLAUDE_DELEGATION_STEP="3. Use the 'codex' MCP tool to delegate work to Codex. Ask it to:
   - Review your changes
   - Improve or extend the code
   - Fix any issues
   Give it a specific, actionable prompt."
    CLAUDE_FOLLOWUP_STEP="4. Review Codex's response and apply any good suggestions."
  else
    CODEX_STATUS_NOTE="Codex is unavailable for this iteration (${CODEX_STATUS_REASON}). Do not attempt Codex delegation this turn."
    CLAUDE_DELEGATION_STEP="3. Codex is unavailable this iteration. Do not call the 'codex' MCP tool. Continue the work on your own."
    CLAUDE_FOLLOWUP_STEP="4. Since Codex is unavailable, leave a clear handoff note for the next available Codex turn."
  fi

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    CLAUDE_STATUS_NOTE="Claude Code is available for this iteration."
    CODEX_DELEGATION_STEP="3. Use the 'claude_code' MCP tool to delegate work back to Claude. Ask it to:
   - Review your changes
   - Suggest further improvements
   - Run tests or validate
   Give it a specific prompt with the workspace path."
    CODEX_FOLLOWUP_STEP="4. Review Claude's response and apply good suggestions."
  else
    CLAUDE_STATUS_NOTE="Claude Code is unavailable for this iteration (${CLAUDE_STATUS_REASON}). Do not attempt Claude delegation this turn."
    CODEX_DELEGATION_STEP="3. Claude Code is unavailable this iteration. Do not call the 'claude_code' MCP tool. Continue the work on your own."
    CODEX_FOLLOWUP_STEP="4. Since Claude Code is unavailable, leave a clear handoff note for the next available Claude turn."
  fi

  # ─── Step A: Claude Code (with Codex MCP tool) ───
  CLAUDE_LOG="$LOG_DIR/claude_mcp_iter${ITERATION}.log"
  CODEX_LOG="$LOG_DIR/codex_mcp_iter${ITERATION}.log"

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    CLAUDE_PROMPT="You are in a pair-programming loop with OpenAI Codex. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE
$CODEX_STATUS_NOTE

## Your workflow:

1. Read .loop_state.md and review current workspace files.

2. Do YOUR part: implement, fix bugs, add tests, improve docs, refactor.

$CLAUDE_DELEGATION_STEP

$CLAUDE_FOLLOWUP_STEP

5. Update .loop_state.md with what happened this iteration.

Build incrementally. Don't rewrite everything."
    if ! run_claude "$CLAUDE_PROMPT"; then
      echo -e "${YELLOW}Claude Code failed during iteration $ITERATION. Continuing if Codex is available.${NC}"
      echo ""
    fi
  else
    echo -e "${YELLOW}Skipping Claude Code for iteration $ITERATION: $CLAUDE_STATUS_REASON${NC}"
    write_skip_log "$CLAUDE_LOG" "Claude Code" "Unavailable at iteration start: $CLAUDE_STATUS_REASON"
    echo ""
  fi

  # ─── Step B: Codex (with Claude Code MCP tool) ───
  CLAUDE_SUMMARY=""
  if [ -f "$CLAUDE_LOG" ]; then
    CLAUDE_SUMMARY=$(tail -80 "$CLAUDE_LOG")
  fi

  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    CODEX_PROMPT="You are in a pair-programming loop with Claude Code. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE
$CLAUDE_STATUS_NOTE

Claude just finished. Here's what they did:
---
$CLAUDE_SUMMARY
---

## Your workflow:

1. Review the workspace files and .loop_state.md.

2. Do YOUR part: improve code, fix bugs, add tests, refactor.

$CODEX_DELEGATION_STEP

$CODEX_FOLLOWUP_STEP

5. Update .loop_state.md with what happened.

Build incrementally. Don't rewrite everything."
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
  echo -e "  Claude log: $CLAUDE_LOG"
  echo -e "  Codex log:  $CODEX_LOG"
  echo ""

  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
