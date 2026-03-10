#!/usr/bin/env bash
# pair_loop.sh — Alternating pair-programming loop between Claude Code and Codex.
#
# Usage:
#   ./pair_loop.sh [options] [task_description] [max_iterations]
#
# Options:
#   --workspace PATH        Workspace directory (default: ./workspace)
#   --log-dir PATH          Log directory (default: ./logs)
#   --task TEXT             Task description
#   --max-iterations N      Maximum iterations (default: 999999)
#   --first-agent NAME      Turn order: claude or codex (default: claude)
#   --claude-first          Alias for --first-agent claude
#   --codex-first           Alias for --first-agent codex
#   --resume                Resume from existing workspace/logs without cleaning
#   --keep-logs             Preserve existing logs on startup
#   --keep-workspace        Preserve existing workspace on startup
#   --non-destructive       Alias for --keep-logs --keep-workspace
#   -h, --help              Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_WORKSPACE="$SCRIPT_DIR/workspace"
DEFAULT_LOG_DIR="$SCRIPT_DIR/logs"
DEFAULT_TASK="Build a CLI tool in Python that converts CSV files to JSON with filtering, sorting, and pretty-print options. Start simple, then iteratively improve: add error handling, tests, documentation, and performance optimizations."

WORKSPACE="$DEFAULT_WORKSPACE"
LOG_DIR="$DEFAULT_LOG_DIR"
TASK=""
MAX_ITERATIONS="999999"
FIRST_AGENT="claude"
STATUS_CHECK_TIMEOUT="${STATUS_CHECK_TIMEOUT:-20}"
RESUME=0
KEEP_LOGS=0
KEEP_WORKSPACE=0
TASK_FROM_FLAG=0
MAX_ITERATIONS_FROM_FLAG=0
ITERATION=0
RUN_START_ITERATION=0
FIRST_ITERATION_OF_THIS_RUN=1
STATE_FILE=""
EXISTING_TASK=""

STARTUP_NODE_AVAILABLE=0
STARTUP_NODE_REASON=""
STARTUP_CLAUDE_AVAILABLE=0
STARTUP_CLAUDE_REASON=""
STARTUP_CODEX_AVAILABLE=0
STARTUP_CODEX_REASON=""
STARTUP_MCP_AVAILABLE=0
STARTUP_MCP_REASON=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

usage() {
  sed -n '1,20p' "$0"
}

die() {
  echo -e "${RED}Error:${NC} $*" >&2
  exit 1
}

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$PWD/$1" ;;
  esac
}

clean_directory_contents() {
  local dir="$1"
  [ -d "$dir" ] || return 0
  find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
}

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

check_node_status() {
  NODE_STATUS_REASON="ready"

  if ! command -v node >/dev/null 2>&1; then
    NODE_STATUS_REASON="node CLI not found"
    return 1
  fi

  if node --version >/dev/null 2>&1; then
    return 0
  fi

  NODE_STATUS_REASON="node version check failed"
  return 1
}

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

check_mcp_status() {
  MCP_STATUS_REASON="not required in standard mode"
  return 0
}

print_status_line() {
  local label="$1"
  local available="$2"
  local reason="$3"
  local ok_color="${4:-$GREEN}"

  if [ "$available" -eq 1 ]; then
    if [ -n "$reason" ] && [ "$reason" != "ready" ]; then
      echo -e "${ok_color}  $label: available ($reason)${NC}"
    else
      echo -e "${ok_color}  $label: available${NC}"
    fi
  else
    echo -e "${YELLOW}  $label: unavailable ($reason)${NC}"
  fi
}

read_state_task() {
  [ -f "$STATE_FILE" ] || return 0
  awk '
    /^## Task$/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$STATE_FILE"
}

init_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  cat > "$STATE_FILE" << EOF
# Pair Loop State

## Task
$TASK

## History
EOF
}

prepare_task() {
  EXISTING_TASK="$(read_state_task)"

  if [ -z "$TASK" ]; then
    if [ -n "$EXISTING_TASK" ]; then
      TASK="$EXISTING_TASK"
    else
      TASK="$DEFAULT_TASK"
    fi
  fi
}

prepare_workspace_and_logs() {
  echo -e "${CYAN}Preparing workspace and logs...${NC}"
  mkdir -p "$WORKSPACE" "$LOG_DIR"

  if [ "$KEEP_WORKSPACE" -eq 0 ]; then
    echo -e "${YELLOW}Cleaning workspace...${NC}"
    clean_directory_contents "$WORKSPACE"
  else
    echo -e "${YELLOW}Preserving workspace contents.${NC}"
  fi

  if [ "$KEEP_LOGS" -eq 0 ]; then
    echo -e "${YELLOW}Cleaning logs...${NC}"
    clean_directory_contents "$LOG_DIR"
  else
    echo -e "${YELLOW}Preserving log contents.${NC}"
  fi

  mkdir -p "$WORKSPACE" "$LOG_DIR"

  if [ ! -d "$WORKSPACE/.git" ]; then
    git -C "$WORKSPACE" init -q
  fi

  if [ ! -f "$STATE_FILE" ]; then
    init_state_file
  elif [ -n "$EXISTING_TASK" ] && [ "$EXISTING_TASK" != "$TASK" ]; then
    cat >> "$STATE_FILE" << EOF

### Run Restart ($(date '+%Y-%m-%d %H:%M:%S'))
- Task updated for this run: $TASK
EOF
  fi
}

detect_last_iteration() {
  local max=0
  local file num

  for file in \
    "$LOG_DIR"/claude_iter*.log \
    "$LOG_DIR"/codex_iter*.log \
    "$LOG_DIR"/claude_handoff_iter*.md \
    "$LOG_DIR"/codex_handoff_iter*.md; do
    [ -e "$file" ] || continue
    num="${file##*iter}"
    num="${num%.*}"
    case "$num" in
      ''|*[!0-9]*) continue ;;
    esac
    if [ "$num" -gt "$max" ]; then
      max="$num"
    fi
  done

  printf '%s\n' "$max"
}

workspace_snapshot() {
  local files
  if [ ! -d "$WORKSPACE" ]; then
    echo "  (missing workspace)"
    return 0
  fi

  files="$(
    cd "$WORKSPACE" &&
      find . -type f \
        ! -path './.git/*' \
        ! -path './__pycache__/*' \
        ! -name '*.pyc' \
        | sed 's|^\./|  - |' \
        | sort
  )"

  if [ -n "$files" ]; then
    printf '%s\n' "$files"
  else
    echo "  (empty)"
  fi
}

snapshot_workspace() {
  local destination="$1"
  mkdir -p "$destination"

  (
    cd "$WORKSPACE"
    tar --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' -cf - .
  ) | (
    cd "$destination"
    tar -xf -
  )
}

list_snapshot_files() {
  local snapshot_dir="$1"
  if [ ! -d "$snapshot_dir" ]; then
    return 0
  fi

  (
    cd "$snapshot_dir"
    find . -type f \
      ! -path './__pycache__/*' \
      ! -name '*.pyc' \
      | sed 's|^\./||' \
      | sort
  )
}

write_change_summary() {
  local before_snapshot="$1"
  local after_snapshot="$2"
  local before_list after_list file
  local stat_output printed

  before_list="$(mktemp)"
  after_list="$(mktemp)"
  list_snapshot_files "$before_snapshot" > "$before_list"
  list_snapshot_files "$after_snapshot" > "$after_list"

  stat_output="$(git diff --no-index --shortstat -- "$before_snapshot" "$after_snapshot" 2>/dev/null || true)"
  printed=0

  if [ -n "$stat_output" ]; then
    printf '%s\n\n' "$stat_output"
  fi

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf -- '- added %s\n' "$file"
    printed=1
  done < <(comm -13 "$before_list" "$after_list")

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf -- '- removed %s\n' "$file"
    printed=1
  done < <(comm -23 "$before_list" "$after_list")

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! cmp -s "$before_snapshot/$file" "$after_snapshot/$file"; then
      printf -- '- modified %s\n' "$file"
      printed=1
    fi
  done < <(comm -12 "$before_list" "$after_list")

  if [ "$printed" -eq 0 ] && [ -z "$stat_output" ]; then
    echo "No workspace file changes detected."
  fi

  rm -f "$before_list" "$after_list"
}

write_turn_handoff() {
  local agent_name="$1"
  local summary_file="$2"
  local turn_status="$3"
  local reason="$4"
  local before_snapshot="$5"
  local after_snapshot="$6"
  local git_status

  git_status="$(git -C "$WORKSPACE" status --short 2>/dev/null || true)"

  {
    echo "# Handoff Summary"
    echo
    echo "- Agent: $agent_name"
    echo "- Iteration: $ITERATION"
    echo "- Status: $turn_status"
    if [ -n "$reason" ]; then
      echo "- Note: $reason"
    fi
    echo
    echo "## Change Summary"
    write_change_summary "$before_snapshot" "$after_snapshot"
    echo
    echo "## Current Git Status"
    if [ -n "$git_status" ]; then
      printf '%s\n' "$git_status"
    else
      echo "(clean working tree)"
    fi
    echo
    echo "## Workspace Files"
    workspace_snapshot
    echo
    if [ -f "$STATE_FILE" ]; then
      echo "## State File Tail"
      tail -40 "$STATE_FILE"
    fi
  } > "$summary_file"
}

read_handoff_summary() {
  local summary_file="$1"
  local fallback="$2"

  if [ -f "$summary_file" ]; then
    sed -n '1,160p' "$summary_file"
  else
    printf '%s\n' "$fallback"
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
  local log_file="$LOG_DIR/claude_iter${ITERATION}.log"

  echo -e "${GREEN}🤖 [Claude Code] Iteration $ITERATION${NC}"
  echo -e "${GREEN}   Prompt:${NC} ${prompt:0:120}..."
  echo ""

  (
    cd "$WORKSPACE" &&
    claude -p \
      --dangerously-skip-permissions \
      --output-format text \
      "$prompt"
  ) 2>&1 | tee "$log_file"

  echo ""
}

run_codex() {
  local prompt="$1"
  local log_file="$LOG_DIR/codex_iter${ITERATION}.log"

  echo -e "${BLUE}🧠 [Codex] Iteration $ITERATION${NC}"
  echo -e "${BLUE}   Prompt:${NC} ${prompt:0:120}..."
  echo ""

  codex exec --full-auto \
    -C "$WORKSPACE" \
    "$prompt" \
    2>&1 | tee "$log_file"

  echo ""
}

execute_claude_turn() {
  local incoming_summary="$1"
  local is_first_turn="$2"
  local files_snapshot tmp_root

  files_snapshot="$(workspace_snapshot)"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/pairloopstandardclaudeXXXXXX")"
  snapshot_workspace "$tmp_root/before"

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    if [ "$is_first_turn" -eq 1 ]; then
      CLAUDE_PROMPT="You are in a pair programming loop with OpenAI Codex. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE
$CODEX_STATUS_NOTE

Start implementing the task. Write clean, working code. After you're done, leave a brief note in $WORKSPACE/.loop_state.md describing what you did and what the next person (Codex) should focus on improving.

Current workspace files:
$files_snapshot"
    else
      CLAUDE_PROMPT="You are in a pair programming loop with OpenAI Codex. It's your turn (iteration $ITERATION).

TASK: $TASK
WORKSPACE: $WORKSPACE
$CODEX_STATUS_NOTE

Codex handoff summary:
---
$incoming_summary
---

Current workspace files:
$files_snapshot

Review what Codex changed. Then improve the code further:
- Fix any bugs or issues you find
- Add features, tests, or documentation
- Refactor for better quality
- Update .loop_state.md with what you did and what Codex should do next

Be constructive and build on the current state."
    fi

    if run_claude "$CLAUDE_PROMPT"; then
      CLAUDE_TURN_STATUS="completed"
      CLAUDE_TURN_REASON=""
    else
      CLAUDE_TURN_STATUS="failed"
      CLAUDE_TURN_REASON="Claude Code execution failed; inspect $CLAUDE_LOG"
      echo -e "${YELLOW}Claude Code failed during iteration $ITERATION. Continuing if Codex is available.${NC}"
      echo ""
    fi
  else
    write_skip_log "$CLAUDE_LOG" "Claude Code" "Unavailable at iteration start: $CLAUDE_STATUS_REASON"
    CLAUDE_TURN_STATUS="skipped"
    CLAUDE_TURN_REASON="Unavailable at iteration start: $CLAUDE_STATUS_REASON"
    echo -e "${YELLOW}Skipping Claude Code for iteration $ITERATION: $CLAUDE_STATUS_REASON${NC}"
    echo ""
  fi

  snapshot_workspace "$tmp_root/after"
  write_turn_handoff \
    "Claude Code" \
    "$CLAUDE_HANDOFF" \
    "$CLAUDE_TURN_STATUS" \
    "$CLAUDE_TURN_REASON" \
    "$tmp_root/before" \
    "$tmp_root/after"
  rm -rf "$tmp_root"
}

execute_codex_turn() {
  local incoming_summary="$1"
  local is_first_turn="$2"
  local files_snapshot tmp_root

  files_snapshot="$(workspace_snapshot)"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/pairloopstandardcodexXXXXXX")"
  snapshot_workspace "$tmp_root/before"

  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    if [ "$is_first_turn" -eq 1 ]; then
      CODEX_PROMPT="You are in a pair programming loop with Claude Code. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE
$CLAUDE_STATUS_NOTE

Start implementing the task. Write clean, working code. After you're done, leave a brief note in $WORKSPACE/.loop_state.md describing what you did and what the next person (Claude Code) should focus on improving.

Current workspace files:
$files_snapshot"
    else
      CODEX_PROMPT="You are in a pair programming loop with Claude Code. It's your turn (iteration $ITERATION).

TASK: $TASK
WORKSPACE: $WORKSPACE
$CLAUDE_STATUS_NOTE

Claude handoff summary:
---
$incoming_summary
---

Current workspace files:
$files_snapshot

Review what Claude changed. Then improve the code further:
- Fix any bugs or issues you find
- Add features, tests, or documentation
- Refactor for better quality
- Update .loop_state.md with what you did and what Claude should do next

Be constructive and build on the current state."
    fi

    if run_codex "$CODEX_PROMPT"; then
      CODEX_TURN_STATUS="completed"
      CODEX_TURN_REASON=""
    else
      CODEX_TURN_STATUS="failed"
      CODEX_TURN_REASON="Codex execution failed; inspect $CODEX_LOG"
      echo -e "${YELLOW}Codex failed during iteration $ITERATION. Continuing to the next iteration.${NC}"
      echo ""
    fi
  else
    write_skip_log "$CODEX_LOG" "Codex" "Unavailable at iteration start: $CODEX_STATUS_REASON"
    CODEX_TURN_STATUS="skipped"
    CODEX_TURN_REASON="Unavailable at iteration start: $CODEX_STATUS_REASON"
    echo -e "${YELLOW}Skipping Codex for iteration $ITERATION: $CODEX_STATUS_REASON${NC}"
    echo ""
  fi

  snapshot_workspace "$tmp_root/after"
  write_turn_handoff \
    "Codex" \
    "$CODEX_HANDOFF" \
    "$CODEX_TURN_STATUS" \
    "$CODEX_TURN_REASON" \
    "$tmp_root/before" \
    "$tmp_root/after"
  rm -rf "$tmp_root"
}

run_startup_health_checks() {
  echo -e "${CYAN}Startup health checks:${NC}"

  if check_node_status; then
    STARTUP_NODE_AVAILABLE=1
    STARTUP_NODE_REASON="$NODE_STATUS_REASON"
  else
    STARTUP_NODE_REASON="$NODE_STATUS_REASON"
  fi
  print_status_line "Node.js" "$STARTUP_NODE_AVAILABLE" "$STARTUP_NODE_REASON" "$GREEN"

  if check_claude_status; then
    STARTUP_CLAUDE_AVAILABLE=1
    STARTUP_CLAUDE_REASON="$CLAUDE_STATUS_REASON"
  else
    STARTUP_CLAUDE_REASON="$CLAUDE_STATUS_REASON"
  fi
  print_status_line "Claude Code" "$STARTUP_CLAUDE_AVAILABLE" "$STARTUP_CLAUDE_REASON" "$GREEN"

  if check_codex_status; then
    STARTUP_CODEX_AVAILABLE=1
    STARTUP_CODEX_REASON="$CODEX_STATUS_REASON"
  else
    STARTUP_CODEX_REASON="$CODEX_STATUS_REASON"
  fi
  print_status_line "Codex" "$STARTUP_CODEX_AVAILABLE" "$STARTUP_CODEX_REASON" "$BLUE"

  if check_mcp_status; then
    STARTUP_MCP_AVAILABLE=1
    STARTUP_MCP_REASON="$MCP_STATUS_REASON"
  else
    STARTUP_MCP_REASON="$MCP_STATUS_REASON"
  fi
  print_status_line "MCP" "$STARTUP_MCP_AVAILABLE" "$STARTUP_MCP_REASON" "$CYAN"
  echo ""

  if [ "$STARTUP_CLAUDE_AVAILABLE" -eq 0 ] && [ "$STARTUP_CODEX_AVAILABLE" -eq 0 ]; then
    die "Both Claude Code and Codex are unavailable. Refusing to start the loop."
  fi
}

parse_args() {
  local positional=()

  while [ "$#" -gt 0 ]; do
    case "$1" in
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
        TASK_FROM_FLAG=1
        shift 2
        ;;
      --max-iterations)
        [ "$#" -ge 2 ] || die "--max-iterations requires a value"
        MAX_ITERATIONS="$2"
        MAX_ITERATIONS_FROM_FLAG=1
        shift 2
        ;;
      --first-agent)
        [ "$#" -ge 2 ] || die "--first-agent requires a value"
        FIRST_AGENT="$2"
        shift 2
        ;;
      --claude-first)
        FIRST_AGENT="claude"
        shift
        ;;
      --codex-first)
        FIRST_AGENT="codex"
        shift
        ;;
      --resume)
        RESUME=1
        KEEP_LOGS=1
        KEEP_WORKSPACE=1
        shift
        ;;
      --keep-logs)
        KEEP_LOGS=1
        shift
        ;;
      --keep-workspace)
        KEEP_WORKSPACE=1
        shift
        ;;
      --non-destructive|--preserve)
        KEEP_LOGS=1
        KEEP_WORKSPACE=1
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --)
        shift
        while [ "$#" -gt 0 ]; do
          positional+=("$1")
          shift
        done
        ;;
      -*)
        die "Unknown option: $1"
        ;;
      *)
        positional+=("$1")
        shift
        ;;
    esac
  done

  if [ "${#positional[@]}" -gt 2 ]; then
    die "Too many positional arguments"
  fi

  if [ "${#positional[@]}" -ge 1 ] && [ "$TASK_FROM_FLAG" -eq 0 ]; then
    TASK="${positional[0]}"
  fi

  if [ "${#positional[@]}" -ge 2 ] && [ "$MAX_ITERATIONS_FROM_FLAG" -eq 0 ]; then
    MAX_ITERATIONS="${positional[1]}"
  fi

  case "$MAX_ITERATIONS" in
    ''|*[!0-9]*)
      die "max_iterations must be a non-negative integer"
      ;;
  esac

  case "$FIRST_AGENT" in
    claude|codex)
      ;;
    *)
      die "first agent must be either 'claude' or 'codex'"
      ;;
  esac
}

parse_args "$@"
WORKSPACE="$(abs_path "$WORKSPACE")"
LOG_DIR="$(abs_path "$LOG_DIR")"
STATE_FILE="$WORKSPACE/.loop_state.md"
prepare_task
run_startup_health_checks
prepare_workspace_and_logs

RUN_START_ITERATION="$(detect_last_iteration)"
ITERATION="$RUN_START_ITERATION"
FIRST_ITERATION_OF_THIS_RUN=$((RUN_START_ITERATION + 1))

echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║   Claude Code ↔ Codex — Pair Programming Loop           ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Task:${NC} $TASK"
echo -e "${YELLOW}Workspace:${NC} $WORKSPACE"
echo -e "${YELLOW}Log dir:${NC} $LOG_DIR"
echo -e "${YELLOW}Max iterations:${NC} $MAX_ITERATIONS"
echo -e "${YELLOW}First agent:${NC} $FIRST_AGENT"
echo -e "${YELLOW}Resume mode:${NC} $RESUME"
echo -e "${YELLOW}Keep workspace:${NC} $KEEP_WORKSPACE"
echo -e "${YELLOW}Keep logs:${NC} $KEEP_LOGS"
echo ""

echo -e "${CYAN}━━━ Starting pair loop ━━━${NC}"
echo ""

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
  local_before_root=""
  local_after_root=""
  previous_codex_handoff=""
  claude_handoff_file=""
  codex_handoff_file=""

  ITERATION=$((ITERATION + 1))
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${YELLOW}  ITERATION $ITERATION${NC}"
  echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  if [ "$ITERATION" -eq "$FIRST_ITERATION_OF_THIS_RUN" ]; then
    CLAUDE_AVAILABLE="$STARTUP_CLAUDE_AVAILABLE"
    CLAUDE_STATUS_REASON="$STARTUP_CLAUDE_REASON"
    CODEX_AVAILABLE="$STARTUP_CODEX_AVAILABLE"
    CODEX_STATUS_REASON="$STARTUP_CODEX_REASON"
  else
    CLAUDE_AVAILABLE=0
    CODEX_AVAILABLE=0
    if check_claude_status; then
      CLAUDE_AVAILABLE=1
    fi
    if check_codex_status; then
      CODEX_AVAILABLE=1
    fi
  fi

  echo -e "${CYAN}Agent status:${NC}"
  print_status_line "Claude Code" "$CLAUDE_AVAILABLE" "$CLAUDE_STATUS_REASON" "$GREEN"
  print_status_line "Codex" "$CODEX_AVAILABLE" "$CODEX_STATUS_REASON" "$BLUE"
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

  CLAUDE_LOG="$LOG_DIR/claude_iter${ITERATION}.log"
  CODEX_LOG="$LOG_DIR/codex_iter${ITERATION}.log"
  CLAUDE_HANDOFF="$LOG_DIR/claude_handoff_iter${ITERATION}.md"
  CODEX_HANDOFF="$LOG_DIR/codex_handoff_iter${ITERATION}.md"

  if [ "$FIRST_AGENT" = "claude" ]; then
    if [ "$ITERATION" -eq "$FIRST_ITERATION_OF_THIS_RUN" ] && [ "$RESUME" -eq 0 ]; then
      FIRST_TURN_SUMMARY="No prior Codex handoff summary is available for this run."
      FIRST_TURN_IS_FRESH=1
    else
      FIRST_TURN_SUMMARY="$(read_handoff_summary "$LOG_DIR/codex_handoff_iter$((ITERATION - 1)).md" "No prior Codex handoff summary is available.")"
      FIRST_TURN_IS_FRESH=0
    fi
  else
    if [ "$ITERATION" -eq "$FIRST_ITERATION_OF_THIS_RUN" ] && [ "$RESUME" -eq 0 ]; then
      FIRST_TURN_SUMMARY="No prior Claude handoff summary is available for this run."
      FIRST_TURN_IS_FRESH=1
    else
      FIRST_TURN_SUMMARY="$(read_handoff_summary "$LOG_DIR/claude_handoff_iter$((ITERATION - 1)).md" "No prior Claude handoff summary is available.")"
      FIRST_TURN_IS_FRESH=0
    fi
  fi

  if [ "$FIRST_AGENT" = "claude" ]; then
    execute_claude_turn "$FIRST_TURN_SUMMARY" "$FIRST_TURN_IS_FRESH"
    NEXT_TURN_SUMMARY="$(read_handoff_summary "$CLAUDE_HANDOFF" "No Claude handoff summary is available for this iteration.")"
    execute_codex_turn "$NEXT_TURN_SUMMARY" 0
  else
    execute_codex_turn "$FIRST_TURN_SUMMARY" "$FIRST_TURN_IS_FRESH"
    NEXT_TURN_SUMMARY="$(read_handoff_summary "$CODEX_HANDOFF" "No Codex handoff summary is available for this iteration.")"
    execute_claude_turn "$NEXT_TURN_SUMMARY" 0
  fi

  echo -e "${CYAN}━━━ Iteration $ITERATION complete ━━━${NC}"
  echo -e "  Logs: $CLAUDE_LOG"
  echo -e "        $CODEX_LOG"
  echo -e "  Handoff: $CLAUDE_HANDOFF"
  echo -e "           $CODEX_HANDOFF"
  echo ""

  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
