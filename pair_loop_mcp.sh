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

# ─── MCP config for Codex (to call Claude via claude-code-mcp) ───
# Register claude-code-mcp for codex if not already configured
if ! codex mcp list 2>&1 | grep -q "claude-code"; then
  echo -e "${YELLOW}Registering claude-code-mcp for Codex...${NC}"
  codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest 2>&1 || true
fi

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

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  ITERATION=$((ITERATION + 1))

  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  ITERATION $ITERATION${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  # ─── Step A: Claude Code (with Codex MCP tool) ───
  CLAUDE_LOG="$LOG_DIR/claude_mcp_iter${ITERATION}.log"
  CLAUDE_PROMPT="You are in a pair-programming loop with OpenAI Codex. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE

## Your workflow:

1. Read .loop_state.md and review current workspace files.

2. Do YOUR part: implement, fix bugs, add tests, improve docs, refactor.

3. Use the 'codex' MCP tool to delegate work to Codex. Ask it to:
   - Review your changes
   - Improve or extend the code
   - Fix any issues
   Give it a specific, actionable prompt.

4. Review Codex's response and apply any good suggestions.

5. Update .loop_state.md with what happened this iteration.

Build incrementally. Don't rewrite everything."

  echo -e "${GREEN}🤖 [Claude Code + Codex MCP] working...${NC}"
  (cd "$WORKSPACE" && claude -p \
    --dangerously-skip-permissions \
    --output-format text \
    "$CLAUDE_PROMPT") \
    2>&1 | tee "$CLAUDE_LOG"
  echo ""

  # ─── Step B: Codex (with Claude Code MCP tool) ───
  CODEX_LOG="$LOG_DIR/codex_mcp_iter${ITERATION}.log"

  CLAUDE_SUMMARY=""
  if [ -f "$CLAUDE_LOG" ]; then
    CLAUDE_SUMMARY=$(tail -80 "$CLAUDE_LOG")
  fi

  CODEX_PROMPT="You are in a pair-programming loop with Claude Code. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE

Claude just finished. Here's what they did:
---
$CLAUDE_SUMMARY
---

## Your workflow:

1. Review the workspace files and .loop_state.md.

2. Do YOUR part: improve code, fix bugs, add tests, refactor.

3. Use the 'claude_code' MCP tool to delegate work back to Claude. Ask it to:
   - Review your changes
   - Suggest further improvements
   - Run tests or validate
   Give it a specific prompt with the workspace path.

4. Review Claude's response and apply good suggestions.

5. Update .loop_state.md with what happened.

Build incrementally. Don't rewrite everything."

  echo -e "${BLUE}🧠 [Codex + Claude Code MCP] working...${NC}"
  codex exec --full-auto \
    -C "$WORKSPACE" \
    "$CODEX_PROMPT" \
    2>&1 | tee "$CODEX_LOG"
  echo ""

  # ─── Summary ───
  echo -e "${CYAN}━━━ Iteration $ITERATION complete ━━━${NC}"
  echo -e "  Claude log: $CLAUDE_LOG"
  echo -e "  Codex log:  $CODEX_LOG"
  echo ""

  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
