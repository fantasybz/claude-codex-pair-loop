#!/usr/bin/env bash
# pair_loop_mcp.sh — Bidirectional MCP pair-programming loop for Claude Code and Codex.
#
# Usage:
#   ./pair_loop_mcp.sh [options] [task_description] [max_iterations]
#
# Options:
#   --workspace PATH        Workspace directory (default: ./workspace)
#   --log-dir PATH          Log directory (default: ./logs)
#   --task TEXT             Task description
#   --max-iterations N      Maximum iterations (default: 999999)
#   --profile NAME          Effort preset: fast, balanced, or deep
#   --claude-model MODEL    Claude model override
#   --codex-model MODEL     Codex model override
#   --claude-effort LEVEL   Claude effort: low, medium, or high
#   --codex-effort LEVEL    Codex effort: low, medium, high, or xhigh
#   --role-preset NAME      Role split: balanced, docs-refactor, reviewer-builder
#   --session-name NAME     Group logs and state artifacts under a session-specific log directory
#   --validation-command CMD
#                          Validation command to run after each iteration
#   --state-max-ledger-entries N
#                          Number of recent iterations to keep expanded in .loop_state.md
#   --until-tests-pass      Stop when validation succeeds
#   --until-checklist-complete
#                          Stop when all Success Criteria checkboxes are checked
#   --until-clean-git       Stop when the workspace Git status is clean
#   --checkpoint-commits    Create a checkpoint commit after each iteration when there are changes
#   --checkpoint-tags       Create a checkpoint tag after each iteration
#   --first-agent NAME      Turn order: claude or codex (default: claude)
#   --claude-first          Alias for --first-agent claude
#   --codex-first           Alias for --first-agent codex
#   --fast                  Alias for --profile fast
#   --balanced              Alias for --profile balanced
#   --deep                  Alias for --profile deep
#   --resume                Resume from existing workspace/logs without cleaning
#   --keep-logs             Preserve existing logs on startup
#   --keep-workspace        Preserve existing workspace on startup
#   --non-destructive       Alias for --keep-logs --keep-workspace
#   -h, --help              Show this help message

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_WORKSPACE="$SCRIPT_DIR/workspace"
DEFAULT_LOG_DIR="$SCRIPT_DIR/logs"
DEFAULT_TASK="Build a CLI tool in Python that converts CSV files to JSON with filtering, sorting, and pretty-print options. Iteratively improve it with tests, docs, and optimizations."

WORKSPACE="$DEFAULT_WORKSPACE"
LOG_DIR="$DEFAULT_LOG_DIR"
TASK=""
MAX_ITERATIONS="999999"
FIRST_AGENT="claude"
STATUS_CHECK_TIMEOUT="${STATUS_CHECK_TIMEOUT:-20}"
RESUME=0
KEEP_LOGS=0
KEEP_WORKSPACE=0
PROFILE=""
CLAUDE_MODEL=""
CLAUDE_EFFORT=""
CODEX_MODEL=""
CODEX_EFFORT=""
MODE="mcp"
ROLE_PRESET="balanced"
SESSION_NAME=""
VALIDATION_COMMAND=""
VALIDATION_COMMAND_USED=""
STATE_MAX_LEDGER_ENTRIES="12"
UNTIL_TESTS_PASS=0
UNTIL_CHECKLIST_COMPLETE=0
UNTIL_CLEAN_GIT=0
CHECKPOINT_COMMITS=0
CHECKPOINT_TAGS=0
TASK_FROM_FLAG=0
MAX_ITERATIONS_FROM_FLAG=0
ITERATION=0
RUN_START_ITERATION=0
FIRST_ITERATION_OF_THIS_RUN=1
STATE_FILE=""
STATE_JSON_FILE=""
EXISTING_TASK=""
CLAUDE_MCP_CONFIG="$SCRIPT_DIR/.mcp.json"
ACTIVE_LOG_DIR=""
SESSION_STATE_DIR=""
ITERATION_HISTORY_FILE=""
RUN_STARTED_AT=""
CURRENT_PHASE="starting"
CURRENT_HEALTH="yellow"
CURRENT_BLOCKER="none recorded"
CURRENT_OWNER="unassigned"
CURRENT_VALIDATION_STATUS="not-run"
CURRENT_VALIDATION_REASON="No validation has run yet."
STOP_CHECKS_SUMMARY="No stop conditions configured."
NEXT_HANDOFF_CONTENT="- Waiting for the first completed turn."
CLAUDE_ROLE_FOCUS=""
CODEX_ROLE_FOCUS=""
LAST_CHECKPOINT_STATUS="not-run"
LAST_CHECKPOINT_REASON=""
LAST_CHECKPOINT_REF=""
VALIDATION_LOG=""
CLAUDE_DURATION_SECONDS=0
CLAUDE_EXIT_STATUS=0
CLAUDE_CHANGED_FILES=""
CODEX_DURATION_SECONDS=0
CODEX_EXIT_STATUS=0
CODEX_CHANGED_FILES=""

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
  sed -n '1,40p' "$0"
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

display_value() {
  if [ -n "$1" ]; then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$2"
  fi
}

apply_profile_defaults() {
  case "$PROFILE" in
    "")
      ;;
    fast)
      [ -n "$CLAUDE_EFFORT" ] || CLAUDE_EFFORT="low"
      [ -n "$CODEX_EFFORT" ] || CODEX_EFFORT="low"
      ;;
    balanced)
      [ -n "$CLAUDE_EFFORT" ] || CLAUDE_EFFORT="medium"
      [ -n "$CODEX_EFFORT" ] || CODEX_EFFORT="medium"
      ;;
    deep)
      [ -n "$CLAUDE_EFFORT" ] || CLAUDE_EFFORT="high"
      [ -n "$CODEX_EFFORT" ] || CODEX_EFFORT="high"
      ;;
    *)
      die "profile must be one of: fast, balanced, deep"
      ;;
  esac
}

validate_effort_settings() {
  case "$CLAUDE_EFFORT" in
    ""|low|medium|high)
      ;;
    *)
      die "claude effort must be one of: low, medium, high"
      ;;
  esac

  case "$CODEX_EFFORT" in
    ""|low|medium|high|xhigh)
      ;;
    *)
      die "codex effort must be one of: low, medium, high, xhigh"
      ;;
  esac
}

sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9._-' '-'
}

apply_role_preset() {
  case "$ROLE_PRESET" in
    balanced)
      CLAUDE_ROLE_FOCUS="Prioritize correctness, tests, documentation, and reviewer-style feedback."
      CODEX_ROLE_FOCUS="Prioritize implementation speed, refactoring, feature delivery, and performance."
      ;;
    docs-refactor)
      CLAUDE_ROLE_FOCUS="Prioritize tests, docs, edge cases, and API clarity."
      CODEX_ROLE_FOCUS="Prioritize implementation, refactoring, cleanup, and performance improvements."
      ;;
    reviewer-builder)
      CLAUDE_ROLE_FOCUS="Act as the reviewer and planner: tighten tests, catch bugs, challenge weak designs, and improve docs."
      CODEX_ROLE_FOCUS="Act as the builder: implement changes, wire features, and carry larger refactors."
      ;;
    *)
      die "role preset must be one of: balanced, docs-refactor, reviewer-builder"
      ;;
  esac
}

append_unique_line() {
  local file="$1"
  local line="$2"
  touch "$file"
  if ! grep -Fxq "$line" "$file" 2>/dev/null; then
    printf '%s\n' "$line" >> "$file"
  fi
}

ensure_workspace_git_excludes() {
  local exclude_file="$WORKSPACE/.git/info/exclude"
  mkdir -p "$(dirname "$exclude_file")"
  append_unique_line "$exclude_file" ".loop_state.md"
  append_unique_line "$exclude_file" ".loop_state.json"
}

prepare_session_layout() {
  local session_slug meta_file

  ACTIVE_LOG_DIR="$LOG_DIR"
  if [ -n "$SESSION_NAME" ]; then
    session_slug="$(sanitize_name "$SESSION_NAME")"
    [ -n "$session_slug" ] || die "session name must contain at least one alphanumeric character"
    ACTIVE_LOG_DIR="$LOG_DIR/$session_slug"
    SESSION_NAME="$session_slug"
  fi

  SESSION_STATE_DIR="$ACTIVE_LOG_DIR/state"
  ITERATION_HISTORY_FILE="$SESSION_STATE_DIR/iteration_history.jsonl"
  mkdir -p "$ACTIVE_LOG_DIR" "$SESSION_STATE_DIR"

  meta_file="$SESSION_STATE_DIR/session_meta.env"
  if [ -f "$meta_file" ]; then
    # shellcheck disable=SC1090
    . "$meta_file"
  fi

  if [ -z "$RUN_STARTED_AT" ]; then
    RUN_STARTED_AT="$(date '+%Y-%m-%d %H:%M:%S')"
    cat > "$meta_file" << EOF
RUN_STARTED_AT='$RUN_STARTED_AT'
EOF
  fi
}

extract_state_section() {
  local heading="$1"
  [ -f "$STATE_FILE" ] || return 0
  awk -v target="## ${heading}" '
    $0 == target { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$STATE_FILE"
}

section_to_temp_file() {
  local heading="$1"
  local default_value="$2"
  local temp_file
  temp_file="$(mktemp)"
  extract_state_section "$heading" > "$temp_file"
  if [ ! -s "$temp_file" ]; then
    printf '%s\n' "$default_value" > "$temp_file"
  fi
  printf '%s\n' "$temp_file"
}

sync_state_session_mirrors() {
  [ -d "$SESSION_STATE_DIR" ] || return 0
  [ -f "$STATE_FILE" ] || return 0
  [ -f "$STATE_JSON_FILE" ] || return 0
  cp "$STATE_FILE" "$SESSION_STATE_DIR/loop_state.md"
  cp "$STATE_JSON_FILE" "$SESSION_STATE_DIR/loop_state.json"
}

render_state_files() {
  local success_file focus_file decisions_file risks_file

  success_file="$(section_to_temp_file "Success Criteria" "- [ ] Core implementation works
- [ ] Validation or tests pass
- [ ] Usage notes or documentation are updated")"
  focus_file="$(section_to_temp_file "File Focus" "- (update as needed)")"
  decisions_file="$(section_to_temp_file "Open Decisions" "- (none recorded)")"
  risks_file="$(section_to_temp_file "Risks" "- (none recorded)")"

  TASK="$TASK" \
  SESSION_NAME="$SESSION_NAME" \
  MODE="$MODE" \
  RUN_STARTED_AT="$RUN_STARTED_AT" \
  FIRST_AGENT="$FIRST_AGENT" \
  ROLE_PRESET="$ROLE_PRESET" \
  WORKSPACE="$WORKSPACE" \
  ACTIVE_LOG_DIR="$ACTIVE_LOG_DIR" \
  CURRENT_PHASE="$CURRENT_PHASE" \
  CURRENT_HEALTH="$CURRENT_HEALTH" \
  CURRENT_BLOCKER="$CURRENT_BLOCKER" \
  CURRENT_OWNER="$CURRENT_OWNER" \
  CURRENT_VALIDATION_STATUS="$CURRENT_VALIDATION_STATUS" \
  CURRENT_VALIDATION_REASON="$CURRENT_VALIDATION_REASON" \
  STOP_CHECKS_SUMMARY="$STOP_CHECKS_SUMMARY" \
  NEXT_HANDOFF_CONTENT="$NEXT_HANDOFF_CONTENT" \
  UNTIL_TESTS_PASS="$UNTIL_TESTS_PASS" \
  UNTIL_CHECKLIST_COMPLETE="$UNTIL_CHECKLIST_COMPLETE" \
  UNTIL_CLEAN_GIT="$UNTIL_CLEAN_GIT" \
  VALIDATION_COMMAND_USED="$VALIDATION_COMMAND_USED" \
  STATE_MAX_LEDGER_ENTRIES="$STATE_MAX_LEDGER_ENTRIES" \
    node "$SCRIPT_DIR/pair_loop_state_renderer.js" \
      "$STATE_FILE" \
      "$STATE_JSON_FILE" \
      "$ITERATION_HISTORY_FILE" \
      "$success_file" \
      "$focus_file" \
      "$decisions_file" \
      "$risks_file"

  rm -f "$success_file" "$focus_file" "$decisions_file" "$risks_file"
  sync_state_session_mirrors
}

join_lines_with_comma() {
  tr '\n' ',' | sed 's/,$//'
}

json_escape_inline() {
  printf '%s' "$1" | tr '\n' ' ' | sed 's/\\/\\\\/g; s/"/\\"/g'
}

changed_files_list() {
  local before_snapshot="$1"
  local after_snapshot="$2"
  local before_list after_list file

  before_list="$(mktemp)"
  after_list="$(mktemp)"
  list_snapshot_files "$before_snapshot" > "$before_list"
  list_snapshot_files "$after_snapshot" > "$after_list"

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '%s\n' "$file"
  done < <(comm -13 "$before_list" "$after_list")

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    printf '%s\n' "$file"
  done < <(comm -23 "$before_list" "$after_list")

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! cmp -s "$before_snapshot/$file" "$after_snapshot/$file"; then
      printf '%s\n' "$file"
    fi
  done < <(comm -12 "$before_list" "$after_list")

  rm -f "$before_list" "$after_list"
}

format_changed_files() {
  local before_snapshot="$1"
  local after_snapshot="$2"
  local files

  files="$(changed_files_list "$before_snapshot" "$after_snapshot" | sort -u)"
  if [ -n "$files" ]; then
    printf '%s\n' "$files"
  else
    echo "none"
  fi
}

set_next_handoff_content() {
  local next_agent="$1"
  local handoff_file="$2"
  local changed_files="$3"
  local role_focus="$4"

  NEXT_HANDOFF_CONTENT="- Next agent: $next_agent
- Review changed files: $(printf '%s\n' "$changed_files" | join_lines_with_comma)
- Role focus: $role_focus
- Handoff file: $handoff_file"
}

workspace_git_is_clean() {
  local status
  status="$(git -C "$WORKSPACE" status --short --untracked-files=normal 2>/dev/null || true)"
  [ -z "$status" ]
}

detect_validation_command() {
  if [ -n "$VALIDATION_COMMAND" ]; then
    printf '%s\n' "$VALIDATION_COMMAND"
    return 0
  fi

  if [ -f "$WORKSPACE/Makefile" ] && grep -q '^test:' "$WORKSPACE/Makefile" 2>/dev/null; then
    echo "make test"
    return 0
  fi
  if [ -f "$WORKSPACE/package.json" ] && command -v npm >/dev/null 2>&1; then
    echo "npm test"
    return 0
  fi
  if [ -f "$WORKSPACE/pyproject.toml" ] || [ -f "$WORKSPACE/pytest.ini" ] || [ -d "$WORKSPACE/tests" ]; then
    if command -v pytest >/dev/null 2>&1; then
      echo "pytest -q"
      return 0
    fi
  fi
  if [ -f "$WORKSPACE/Cargo.toml" ] && command -v cargo >/dev/null 2>&1; then
    echo "cargo test"
    return 0
  fi
  if [ -f "$WORKSPACE/go.mod" ] && command -v go >/dev/null 2>&1; then
    echo "go test ./..."
    return 0
  fi

  return 1
}

run_iteration_validation() {
  local cmd status started_at duration
  VALIDATION_LOG="$ACTIVE_LOG_DIR/validation_iter${ITERATION}.log"

  if ! cmd="$(detect_validation_command)"; then
    CURRENT_VALIDATION_STATUS="unavailable"
    CURRENT_VALIDATION_REASON="No validation command configured or auto-detected."
    VALIDATION_COMMAND_USED=""
    VALIDATION_LOG=""
    return 0
  fi

  VALIDATION_COMMAND_USED="$cmd"
  started_at="$(date '+%Y-%m-%d %H:%M:%S')"
  local start_seconds end_seconds
  start_seconds="$(date +%s)"

  if (
    cd "$WORKSPACE" &&
    bash -lc "$cmd"
  ) > "$VALIDATION_LOG.raw" 2>&1; then
    status=0
  else
    status=$?
  fi

  end_seconds="$(date +%s)"
  duration=$((end_seconds - start_seconds))

  {
    echo "# Validation Metrics"
    echo "timestamp: $started_at"
    echo "command: $cmd"
    echo "duration_seconds: $duration"
    echo "exit_status: $status"
    echo "token_cost_info: unavailable"
    echo
    echo "# Raw Output"
    cat "$VALIDATION_LOG.raw"
  } > "$VALIDATION_LOG"
  rm -f "$VALIDATION_LOG.raw"

  if [ "$status" -eq 0 ]; then
    CURRENT_VALIDATION_STATUS="passed"
    CURRENT_VALIDATION_REASON="$cmd"
  else
    CURRENT_VALIDATION_STATUS="failed"
    CURRENT_VALIDATION_REASON="$cmd exited with status $status"
  fi
}

count_unchecked_success_criteria() {
  extract_state_section "Success Criteria" | grep -c '^- \[ \]' || true
}

evaluate_stop_conditions() {
  local reasons=() tests_met=1 checklist_met=1 clean_git_met=1 unchecked_count=0

  if [ "$UNTIL_TESTS_PASS" -eq 1 ]; then
    if [ "$CURRENT_VALIDATION_STATUS" = "passed" ]; then
      tests_met=1
    else
      tests_met=0
      reasons+=("tests pending")
    fi
  fi

  if [ "$UNTIL_CHECKLIST_COMPLETE" -eq 1 ]; then
    unchecked_count="$(count_unchecked_success_criteria)"
    if [ "$unchecked_count" -eq 0 ]; then
      checklist_met=1
    else
      checklist_met=0
      reasons+=("checklist has ${unchecked_count} unchecked item(s)")
    fi
  fi

  if [ "$UNTIL_CLEAN_GIT" -eq 1 ]; then
    if workspace_git_is_clean; then
      clean_git_met=1
    else
      clean_git_met=0
      reasons+=("git working tree is not clean")
    fi
  fi

  STOP_CHECKS_SUMMARY="- until-tests-pass: $([ "$tests_met" -eq 1 ] && echo met || echo pending)
- until-checklist-complete: $([ "$checklist_met" -eq 1 ] && echo met || echo pending)
- until-clean-git: $([ "$clean_git_met" -eq 1 ] && echo met || echo pending)"

  if [ "$UNTIL_TESTS_PASS" -eq 0 ] && [ "$UNTIL_CHECKLIST_COMPLETE" -eq 0 ] && [ "$UNTIL_CLEAN_GIT" -eq 0 ]; then
    return 1
  fi

  if [ "$tests_met" -eq 1 ] && [ "$checklist_met" -eq 1 ] && [ "$clean_git_met" -eq 1 ]; then
    return 0
  fi

  CURRENT_BLOCKER="${reasons[*]}"
  return 1
}

maybe_checkpoint_iteration() {
  local tag_name commit_message dirty=0 commit_output=""
  LAST_CHECKPOINT_STATUS="disabled"
  LAST_CHECKPOINT_REASON=""
  LAST_CHECKPOINT_REF=""

  if [ "$CHECKPOINT_COMMITS" -eq 0 ] && [ "$CHECKPOINT_TAGS" -eq 0 ]; then
    return 0
  fi

  if ! workspace_git_is_clean; then
    dirty=1
  fi

  if [ "$dirty" -eq 0 ]; then
    LAST_CHECKPOINT_STATUS="skipped"
    LAST_CHECKPOINT_REASON="workspace clean"
    return 0
  fi

  if [ "$CHECKPOINT_COMMITS" -eq 1 ]; then
    git -C "$WORKSPACE" add -A >/dev/null 2>&1 || true
    commit_message="pair-loop: ${SESSION_NAME:-default} iteration ${ITERATION}"
    if commit_output="$(git -C "$WORKSPACE" commit -m "$commit_message" 2>&1)"; then
      LAST_CHECKPOINT_STATUS="commit-created"
      LAST_CHECKPOINT_REF="$(git -C "$WORKSPACE" rev-parse --short HEAD 2>/dev/null || true)"
    else
      LAST_CHECKPOINT_STATUS="failed"
      LAST_CHECKPOINT_REASON="$commit_output"
      return 0
    fi
  fi

  if [ "$CHECKPOINT_TAGS" -eq 1 ]; then
    tag_name="pair-loop-${SESSION_NAME:-default}-iter-${ITERATION}"
    if git -C "$WORKSPACE" tag "$tag_name" >/dev/null 2>&1; then
      if [ -n "$LAST_CHECKPOINT_REF" ]; then
        LAST_CHECKPOINT_REF="${LAST_CHECKPOINT_REF}, ${tag_name}"
      else
        LAST_CHECKPOINT_REF="$tag_name"
      fi
      if [ "$LAST_CHECKPOINT_STATUS" = "disabled" ] || [ "$LAST_CHECKPOINT_STATUS" = "skipped" ]; then
        LAST_CHECKPOINT_STATUS="tag-created"
      fi
    else
      if [ "$LAST_CHECKPOINT_STATUS" = "disabled" ] || [ "$LAST_CHECKPOINT_STATUS" = "skipped" ]; then
        LAST_CHECKPOINT_STATUS="failed"
      fi
      LAST_CHECKPOINT_REASON="failed to create tag ${tag_name}"
    fi
  fi
}

append_iteration_record() {
  local temp_json
  temp_json="$(mktemp)"

  cat > "$temp_json" << EOF
{
  "iteration": $ITERATION,
  "timestamp": "$(date '+%Y-%m-%d %H:%M:%S')",
  "mode": "$MODE",
  "validation": {
    "status": "$CURRENT_VALIDATION_STATUS",
    "reason": "$(json_escape_inline "$CURRENT_VALIDATION_REASON")"
  },
  "checkpoint": {
    "status": "$LAST_CHECKPOINT_STATUS",
    "reason": "$(json_escape_inline "$LAST_CHECKPOINT_REASON")",
    "ref": "$(json_escape_inline "$LAST_CHECKPOINT_REF")"
  },
  "stopChecks": {
    "until-tests-pass": $([ "$UNTIL_TESTS_PASS" -eq 1 ] && [ "$CURRENT_VALIDATION_STATUS" = "passed" ] && echo true || echo false),
    "until-checklist-complete": $([ "$UNTIL_CHECKLIST_COMPLETE" -eq 1 ] && [ "$(count_unchecked_success_criteria)" -eq 0 ] && echo true || echo false),
    "until-clean-git": $([ "$UNTIL_CLEAN_GIT" -eq 1 ] && workspace_git_is_clean && echo true || echo false)
  },
  "agents": [
    {
      "name": "Claude Code",
      "status": "$CLAUDE_TURN_STATUS",
      "reason": "$(json_escape_inline "$CLAUDE_TURN_REASON")",
      "model": "$(display_value "$CLAUDE_MODEL" "default")",
      "effort": "$(display_value "$CLAUDE_EFFORT" "default")",
      "durationSeconds": $CLAUDE_DURATION_SECONDS,
      "exitStatus": $CLAUDE_EXIT_STATUS,
      "changedFiles": [$(printf '%s\n' "$CLAUDE_CHANGED_FILES" | sed '/^$/d;s/"/\\"/g;s/.*/"&"/' | paste -sd, -)]
    },
    {
      "name": "Codex",
      "status": "$CODEX_TURN_STATUS",
      "reason": "$(json_escape_inline "$CODEX_TURN_REASON")",
      "model": "$(display_value "$CODEX_MODEL" "default")",
      "effort": "$(display_value "$CODEX_EFFORT" "default")",
      "durationSeconds": $CODEX_DURATION_SECONDS,
      "exitStatus": $CODEX_EXIT_STATUS,
      "changedFiles": [$(printf '%s\n' "$CODEX_CHANGED_FILES" | sed '/^$/d;s/"/\\"/g;s/.*/"&"/' | paste -sd, -)]
    }
  ],
  "nextHandoff": "$(json_escape_inline "$NEXT_HANDOFF_CONTENT")"
}
EOF

  cat "$temp_json" >> "$ITERATION_HISTORY_FILE"
  printf '\n' >> "$ITERATION_HISTORY_FILE"
  rm -f "$temp_json"
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

ensure_claude_code_mcp() {
  local mcp_list=""
  local status=0

  if mcp_list=$(run_with_timeout "$STATUS_CHECK_TIMEOUT" codex mcp list); then
    if printf '%s\n' "$mcp_list" | grep -q '^claude-code[[:space:]]'; then
      CODEX_STATUS_REASON="ready"
      return 0
    fi
  fi

  if run_with_timeout "$STATUS_CHECK_TIMEOUT" \
    codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest >/dev/null 2>&1; then
    CODEX_STATUS_REASON="claude-code MCP registered"
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
  local status=0 cmd=() output="" reason_line=""
  CLAUDE_STATUS_REASON="ready"

  if ! command -v claude >/dev/null 2>&1; then
    CLAUDE_STATUS_REASON="claude CLI not found"
    return 1
  fi

  if [ ! -f "$CLAUDE_MCP_CONFIG" ]; then
    CLAUDE_STATUS_REASON="missing MCP config at $CLAUDE_MCP_CONFIG"
    return 1
  fi

  cmd=(
    claude -p
    --dangerously-skip-permissions
    --no-session-persistence
    --tools ""
    --output-format text
  )
  if [ -n "$CLAUDE_MODEL" ]; then
    cmd+=(--model "$CLAUDE_MODEL")
  fi
  if [ -n "$CLAUDE_EFFORT" ]; then
    cmd+=(--effort "$CLAUDE_EFFORT")
  fi
  cmd+=("Reply with exactly: OK")

  if output="$(run_with_timeout "$STATUS_CHECK_TIMEOUT" "${cmd[@]}" 2>&1)"; then
    return 0
  else
    status=$?
  fi

  if [ "$status" -eq 124 ]; then
    CLAUDE_STATUS_REASON="account/usage check timed out"
  elif printf '%s\n' "$output" | grep -qi "hit your limit"; then
    CLAUDE_STATUS_REASON="usage limit hit; resets 10pm (Asia/Taipei)"
  else
    reason_line="$(printf '%s\n' "$output" | awk 'NF { print; exit }')"
    if [ -n "$reason_line" ]; then
      CLAUDE_STATUS_REASON="$reason_line"
    else
      CLAUDE_STATUS_REASON="account/usage check failed"
    fi
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
  fi

  if [ "$status" -eq 124 ]; then
    CODEX_STATUS_REASON="status check timed out"
  else
    CODEX_STATUS_REASON="status check failed"
  fi
  return 1
}

check_mcp_status() {
  MCP_STATUS_REASON="ready"

  if ! command -v npx >/dev/null 2>&1; then
    MCP_STATUS_REASON="npx not found"
    return 1
  fi

  if [ ! -f "$CLAUDE_MCP_CONFIG" ]; then
    MCP_STATUS_REASON="missing MCP config at $CLAUDE_MCP_CONFIG"
    return 1
  fi

  if ! grep -q 'codex-mcp-server' "$CLAUDE_MCP_CONFIG"; then
    MCP_STATUS_REASON="codex-mcp-server not referenced in .mcp.json"
    return 1
  fi

  if ! command -v codex >/dev/null 2>&1; then
    MCP_STATUS_REASON="codex CLI not found"
    return 1
  fi

  if ensure_claude_code_mcp; then
    MCP_STATUS_REASON="ready"
    return 0
  fi

  MCP_STATUS_REASON="$CODEX_STATUS_REASON"
  return 1
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
  local source_file="$STATE_FILE"
  if [ -n "$SESSION_NAME" ]; then
    local session_state_file
    session_state_file="$LOG_DIR/$(sanitize_name "$SESSION_NAME")/state/loop_state.md"
    if [ -f "$session_state_file" ]; then
      source_file="$session_state_file"
    fi
  fi
  [ -f "$source_file" ] || return 0
  awk '
    /^## Task$/ { capture = 1; next }
    capture && /^## / { exit }
    capture { print }
  ' "$source_file"
}

init_state_file() {
  mkdir -p "$(dirname "$STATE_FILE")"
  : > "$ITERATION_HISTORY_FILE"
  render_state_files
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
  prepare_session_layout
  mkdir -p "$WORKSPACE" "$LOG_DIR" "$ACTIVE_LOG_DIR"

  if [ "$KEEP_WORKSPACE" -eq 0 ]; then
    echo -e "${YELLOW}Cleaning workspace...${NC}"
    clean_directory_contents "$WORKSPACE"
  else
    echo -e "${YELLOW}Preserving workspace contents.${NC}"
  fi

  if [ "$KEEP_LOGS" -eq 0 ]; then
    echo -e "${YELLOW}Cleaning logs...${NC}"
    clean_directory_contents "$ACTIVE_LOG_DIR"
    RUN_STARTED_AT=""
    prepare_session_layout
  else
    echo -e "${YELLOW}Preserving log contents.${NC}"
  fi

  mkdir -p "$WORKSPACE" "$ACTIVE_LOG_DIR"

  if [ ! -d "$WORKSPACE/.git" ]; then
    git -C "$WORKSPACE" init -q
  fi
  ensure_workspace_git_excludes

  if [ ! -f "$STATE_FILE" ] || [ ! -f "$STATE_JSON_FILE" ]; then
    init_state_file
  elif [ -n "$EXISTING_TASK" ] && [ "$EXISTING_TASK" != "$TASK" ]; then
    CURRENT_BLOCKER="Task updated for this run."
    render_state_files
  else
    render_state_files
  fi
}

detect_last_iteration() {
  local max=0
  local file num

  for file in \
    "$ACTIVE_LOG_DIR"/claude_mcp_iter*.log \
    "$ACTIVE_LOG_DIR"/codex_mcp_iter*.log \
    "$ACTIVE_LOG_DIR"/claude_mcp_handoff_iter*.md \
    "$ACTIVE_LOG_DIR"/codex_mcp_handoff_iter*.md; do
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
  local git_status model effort duration exit_status

  git_status="$(git -C "$WORKSPACE" status --short 2>/dev/null || true)"
  if [ "$agent_name" = "Claude Code" ]; then
    model="$(display_value "$CLAUDE_MODEL" "default")"
    effort="$(display_value "$CLAUDE_EFFORT" "default")"
    duration="$CLAUDE_DURATION_SECONDS"
    exit_status="$CLAUDE_EXIT_STATUS"
  else
    model="$(display_value "$CODEX_MODEL" "default")"
    effort="$(display_value "$CODEX_EFFORT" "default")"
    duration="$CODEX_DURATION_SECONDS"
    exit_status="$CODEX_EXIT_STATUS"
  fi

  {
    echo "# Handoff Summary"
    echo
    echo "- Agent: $agent_name"
    echo "- Iteration: $ITERATION"
    echo "- Session: $(display_value "$SESSION_NAME" "default")"
    echo "- Mode: $MODE"
    echo "- Model: $model"
    echo "- Effort: $effort"
    echo "- Duration seconds: $duration"
    echo "- Exit status: $exit_status"
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
# Turn Metrics
timestamp: $(date '+%Y-%m-%d %H:%M:%S')
session: $(display_value "$SESSION_NAME" "default")
mode: $MODE
agent: ${agent_name}
exit_status: skipped
duration_seconds: 0
token_cost_info: unavailable

# Raw Output
[$(date '+%Y-%m-%d %H:%M:%S')] ${agent_name} skipped for iteration ${ITERATION}
Reason: ${reason}
EOF
}

run_claude() {
  local prompt="$1"
  local log_file="$ACTIVE_LOG_DIR/claude_mcp_iter${ITERATION}.log"
  local raw_log start_seconds end_seconds started_at status
  local cmd=()

  echo -e "${GREEN}🤖 [Claude Code + Codex MCP] Iteration $ITERATION${NC}"
  echo -e "${GREEN}   Prompt:${NC} ${prompt:0:120}..."
  echo ""

  cmd=(
    claude -p
    --dangerously-skip-permissions
    --no-session-persistence
    --mcp-config "$CLAUDE_MCP_CONFIG"
    --output-format text
  )
  if [ -n "$CLAUDE_MODEL" ]; then
    cmd+=(--model "$CLAUDE_MODEL")
  fi
  if [ -n "$CLAUDE_EFFORT" ]; then
    cmd+=(--effort "$CLAUDE_EFFORT")
  fi
  cmd+=("$prompt")

  raw_log="$(mktemp)"
  started_at="$(date '+%Y-%m-%d %H:%M:%S')"
  start_seconds="$(date +%s)"

  if (
    cd "$WORKSPACE" &&
    "${cmd[@]}"
  ) > "$raw_log" 2>&1; then
    status=0
  else
    status=$?
  fi

  end_seconds="$(date +%s)"
  CLAUDE_DURATION_SECONDS=$((end_seconds - start_seconds))
  CLAUDE_EXIT_STATUS="$status"

  {
    echo "# Turn Metrics"
    echo "timestamp: $started_at"
    echo "session: $(display_value "$SESSION_NAME" "default")"
    echo "mode: $MODE"
    echo "agent: Claude Code"
    echo "model: $(display_value "$CLAUDE_MODEL" "default")"
    echo "effort: $(display_value "$CLAUDE_EFFORT" "default")"
    echo "exit_status: $CLAUDE_EXIT_STATUS"
    echo "duration_seconds: $CLAUDE_DURATION_SECONDS"
    echo "token_cost_info: unavailable"
    echo
    echo "# Raw Output"
    cat "$raw_log"
  } > "$log_file"
  cat "$log_file"
  rm -f "$raw_log"

  echo ""
  return "$status"
}

run_codex() {
  local prompt="$1"
  local log_file="$ACTIVE_LOG_DIR/codex_mcp_iter${ITERATION}.log"
  local raw_log start_seconds end_seconds started_at status
  local cmd=()

  echo -e "${BLUE}🧠 [Codex + Claude Code MCP] Iteration $ITERATION${NC}"
  echo -e "${BLUE}   Prompt:${NC} ${prompt:0:120}..."
  echo ""

  cmd=(
    codex exec
    --full-auto
    -C "$WORKSPACE"
  )
  if [ -n "$CODEX_MODEL" ]; then
    cmd+=(--model "$CODEX_MODEL")
  fi
  if [ -n "$CODEX_EFFORT" ]; then
    cmd+=(-c "model_reasoning_effort=\"$CODEX_EFFORT\"")
  fi
  cmd+=("$prompt")

  raw_log="$(mktemp)"
  started_at="$(date '+%Y-%m-%d %H:%M:%S')"
  start_seconds="$(date +%s)"

  if "${cmd[@]}" > "$raw_log" 2>&1; then
    status=0
  else
    status=$?
  fi

  end_seconds="$(date +%s)"
  CODEX_DURATION_SECONDS=$((end_seconds - start_seconds))
  CODEX_EXIT_STATUS="$status"

  {
    echo "# Turn Metrics"
    echo "timestamp: $started_at"
    echo "session: $(display_value "$SESSION_NAME" "default")"
    echo "mode: $MODE"
    echo "agent: Codex"
    echo "model: $(display_value "$CODEX_MODEL" "default")"
    echo "effort: $(display_value "$CODEX_EFFORT" "default")"
    echo "exit_status: $CODEX_EXIT_STATUS"
    echo "duration_seconds: $CODEX_DURATION_SECONDS"
    echo "token_cost_info: unavailable"
    echo
    echo "# Raw Output"
    cat "$raw_log"
  } > "$log_file"
  cat "$log_file"
  rm -f "$raw_log"

  echo ""
  return "$status"
}

execute_claude_turn() {
  local incoming_summary="$1"
  local is_first_turn="$2"
  local files_snapshot tmp_root next_agent next_role

  files_snapshot="$(workspace_snapshot)"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/pairloopmcpclaudeXXXXXX")"
  snapshot_workspace "$tmp_root/before"
  CLAUDE_CHANGED_FILES="none"

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    if [ "$is_first_turn" -eq 1 ]; then
      CLAUDE_PROMPT="You are in a pair-programming loop with OpenAI Codex. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE
$CODEX_STATUS_NOTE

ROLE FOCUS:
$CLAUDE_ROLE_FOCUS

Current workspace files:
$files_snapshot

## Your workflow:

1. Read .loop_state.md and review the workspace.
   - Update Success Criteria, File Focus, Open Decisions, and Risks when useful.
   - Do not rewrite Current Status, Next Handoff, or Iteration Ledger; the loop script regenerates them.
2. Do your part: implement, fix bugs, add tests, improve docs, or refactor.
$CLAUDE_DELEGATION_STEP
$CLAUDE_FOLLOWUP_STEP
5. Leave the workspace in a clean incremental state.

Build incrementally. Do not rewrite everything."
    else
      CLAUDE_PROMPT="You are in a pair-programming loop with OpenAI Codex. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE
$CODEX_STATUS_NOTE

Codex handoff summary:
---
$incoming_summary
---

ROLE FOCUS:
$CLAUDE_ROLE_FOCUS

Current workspace files:
$files_snapshot

## Your workflow:

1. Read .loop_state.md and review the workspace.
   - Update Success Criteria, File Focus, Open Decisions, and Risks when useful.
   - Do not rewrite Current Status, Next Handoff, or Iteration Ledger; the loop script regenerates them.
2. Do your part: implement, fix bugs, add tests, improve docs, or refactor.
$CLAUDE_DELEGATION_STEP
$CLAUDE_FOLLOWUP_STEP
5. Leave the workspace in a clean incremental state.

Build incrementally. Do not rewrite everything."
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
    CLAUDE_DURATION_SECONDS=0
    CLAUDE_EXIT_STATUS=0
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
  CLAUDE_CHANGED_FILES="$(format_changed_files "$tmp_root/before" "$tmp_root/after")"
  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    next_agent="Codex"
    next_role="$CODEX_ROLE_FOCUS"
  else
    next_agent="Any next available agent"
    next_role="$CODEX_ROLE_FOCUS"
  fi
  set_next_handoff_content "$next_agent" "$CLAUDE_HANDOFF" "$CLAUDE_CHANGED_FILES" "$next_role"
  CURRENT_PHASE="running"
  CURRENT_OWNER="$next_agent"
  if [ "$CLAUDE_TURN_STATUS" = "completed" ]; then
    CURRENT_HEALTH="green"
    CURRENT_BLOCKER="none recorded"
  else
    CURRENT_HEALTH="yellow"
    CURRENT_BLOCKER="$CLAUDE_TURN_REASON"
  fi
  render_state_files
  rm -rf "$tmp_root"
}

execute_codex_turn() {
  local incoming_summary="$1"
  local is_first_turn="$2"
  local files_snapshot tmp_root next_agent next_role

  files_snapshot="$(workspace_snapshot)"
  tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/pairloopmcpcodexXXXXXX")"
  snapshot_workspace "$tmp_root/before"
  CODEX_CHANGED_FILES="none"

  if [ "$CODEX_AVAILABLE" -eq 1 ]; then
    if [ "$is_first_turn" -eq 1 ]; then
      CODEX_PROMPT="You are in a pair-programming loop with Claude Code. You go first.

TASK: $TASK

This is iteration $ITERATION. The workspace is currently at: $WORKSPACE
$CLAUDE_STATUS_NOTE

ROLE FOCUS:
$CODEX_ROLE_FOCUS

Current workspace files:
$files_snapshot

## Your workflow:

1. Read .loop_state.md and review the workspace.
   - Update Success Criteria, File Focus, Open Decisions, and Risks when useful.
   - Do not rewrite Current Status, Next Handoff, or Iteration Ledger; the loop script regenerates them.
2. Do your part: improve code, fix bugs, add tests, or refactor.
$CODEX_DELEGATION_STEP
$CODEX_FOLLOWUP_STEP
5. Leave the workspace in a clean incremental state.

Build incrementally. Do not rewrite everything."
    else
      CODEX_PROMPT="You are in a pair-programming loop with Claude Code. This is iteration $ITERATION.

TASK: $TASK
WORKSPACE: $WORKSPACE
$CLAUDE_STATUS_NOTE

Claude handoff summary:
---
$incoming_summary
---

ROLE FOCUS:
$CODEX_ROLE_FOCUS

Current workspace files:
$files_snapshot

## Your workflow:

1. Read .loop_state.md and review the workspace.
   - Update Success Criteria, File Focus, Open Decisions, and Risks when useful.
   - Do not rewrite Current Status, Next Handoff, or Iteration Ledger; the loop script regenerates them.
2. Do your part: improve code, fix bugs, add tests, or refactor.
$CODEX_DELEGATION_STEP
$CODEX_FOLLOWUP_STEP
5. Leave the workspace in a clean incremental state.

Build incrementally. Do not rewrite everything."
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
    CODEX_DURATION_SECONDS=0
    CODEX_EXIT_STATUS=0
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
  CODEX_CHANGED_FILES="$(format_changed_files "$tmp_root/before" "$tmp_root/after")"
  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    next_agent="Claude Code"
    next_role="$CLAUDE_ROLE_FOCUS"
  else
    next_agent="Any next available agent"
    next_role="$CLAUDE_ROLE_FOCUS"
  fi
  set_next_handoff_content "$next_agent" "$CODEX_HANDOFF" "$CODEX_CHANGED_FILES" "$next_role"
  CURRENT_PHASE="running"
  CURRENT_OWNER="$next_agent"
  if [ "$CODEX_TURN_STATUS" = "completed" ]; then
    CURRENT_HEALTH="green"
    CURRENT_BLOCKER="none recorded"
  else
    CURRENT_HEALTH="yellow"
    CURRENT_BLOCKER="$CODEX_TURN_REASON"
  fi
  render_state_files
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
      --profile)
        [ "$#" -ge 2 ] || die "--profile requires a value"
        PROFILE="$2"
        shift 2
        ;;
      --claude-model)
        [ "$#" -ge 2 ] || die "--claude-model requires a value"
        CLAUDE_MODEL="$2"
        shift 2
        ;;
      --codex-model)
        [ "$#" -ge 2 ] || die "--codex-model requires a value"
        CODEX_MODEL="$2"
        shift 2
        ;;
      --claude-effort)
        [ "$#" -ge 2 ] || die "--claude-effort requires a value"
        CLAUDE_EFFORT="$2"
        shift 2
        ;;
      --codex-effort)
        [ "$#" -ge 2 ] || die "--codex-effort requires a value"
        CODEX_EFFORT="$2"
        shift 2
        ;;
      --role-preset)
        [ "$#" -ge 2 ] || die "--role-preset requires a value"
        ROLE_PRESET="$2"
        shift 2
        ;;
      --session-name)
        [ "$#" -ge 2 ] || die "--session-name requires a value"
        SESSION_NAME="$2"
        shift 2
        ;;
      --validation-command)
        [ "$#" -ge 2 ] || die "--validation-command requires a value"
        VALIDATION_COMMAND="$2"
        shift 2
        ;;
      --state-max-ledger-entries)
        [ "$#" -ge 2 ] || die "--state-max-ledger-entries requires a value"
        STATE_MAX_LEDGER_ENTRIES="$2"
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
      --until-tests-pass)
        UNTIL_TESTS_PASS=1
        shift
        ;;
      --until-checklist-complete)
        UNTIL_CHECKLIST_COMPLETE=1
        shift
        ;;
      --until-clean-git)
        UNTIL_CLEAN_GIT=1
        shift
        ;;
      --checkpoint-commits)
        CHECKPOINT_COMMITS=1
        shift
        ;;
      --checkpoint-tags)
        CHECKPOINT_TAGS=1
        shift
        ;;
      --fast)
        PROFILE="fast"
        shift
        ;;
      --balanced)
        PROFILE="balanced"
        shift
        ;;
      --deep)
        PROFILE="deep"
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

  expected_positionals=0
  if [ "$TASK_FROM_FLAG" -eq 0 ]; then
    expected_positionals=$((expected_positionals + 1))
  fi
  if [ "$MAX_ITERATIONS_FROM_FLAG" -eq 0 ]; then
    expected_positionals=$((expected_positionals + 1))
  fi

  if [ "${#positional[@]}" -gt "$expected_positionals" ]; then
    die "Too many positional arguments"
  fi

  positional_index=0
  if [ "$TASK_FROM_FLAG" -eq 0 ] && [ "${#positional[@]}" -gt "$positional_index" ]; then
    TASK="${positional[$positional_index]}"
    positional_index=$((positional_index + 1))
  fi

  if [ "$MAX_ITERATIONS_FROM_FLAG" -eq 0 ] && [ "${#positional[@]}" -gt "$positional_index" ]; then
    MAX_ITERATIONS="${positional[$positional_index]}"
  fi

  case "$MAX_ITERATIONS" in
    ''|*[!0-9]*)
      die "max_iterations must be a non-negative integer"
      ;;
  esac

  case "$STATE_MAX_LEDGER_ENTRIES" in
    ''|*[!0-9]*)
      die "state max ledger entries must be a non-negative integer"
      ;;
  esac

  case "$FIRST_AGENT" in
    claude|codex)
      ;;
    *)
      die "first agent must be either 'claude' or 'codex'"
      ;;
  esac

  apply_profile_defaults
  validate_effort_settings
  apply_role_preset
}

parse_args "$@"
WORKSPACE="$(abs_path "$WORKSPACE")"
LOG_DIR="$(abs_path "$LOG_DIR")"
STATE_FILE="$WORKSPACE/.loop_state.md"
STATE_JSON_FILE="$WORKSPACE/.loop_state.json"
prepare_task
run_startup_health_checks
prepare_workspace_and_logs

RUN_START_ITERATION="$(detect_last_iteration)"
ITERATION="$RUN_START_ITERATION"
FIRST_ITERATION_OF_THIS_RUN=$((RUN_START_ITERATION + 1))

echo -e "${CYAN}╔═══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║  Claude Code ↔ Codex — Bidirectional MCP Pair Loop          ║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${YELLOW}Task:${NC} $TASK"
echo -e "${YELLOW}Workspace:${NC} $WORKSPACE"
echo -e "${YELLOW}Log dir:${NC} $ACTIVE_LOG_DIR"
echo -e "${YELLOW}MCP config:${NC} $CLAUDE_MCP_CONFIG"
echo -e "${YELLOW}Max iterations:${NC} $MAX_ITERATIONS"
echo -e "${YELLOW}Profile:${NC} $(display_value "$PROFILE" "custom")"
echo -e "${YELLOW}Claude model:${NC} $(display_value "$CLAUDE_MODEL" "default")"
echo -e "${YELLOW}Claude effort:${NC} $(display_value "$CLAUDE_EFFORT" "default")"
echo -e "${YELLOW}Codex model:${NC} $(display_value "$CODEX_MODEL" "default")"
echo -e "${YELLOW}Codex effort:${NC} $(display_value "$CODEX_EFFORT" "default")"
echo -e "${YELLOW}Role preset:${NC} $ROLE_PRESET"
echo -e "${YELLOW}Session:${NC} $(display_value "$SESSION_NAME" "default")"
echo -e "${YELLOW}Validation command:${NC} $(display_value "$VALIDATION_COMMAND" "auto")"
echo -e "${YELLOW}First agent:${NC} $FIRST_AGENT"
echo -e "${YELLOW}Resume mode:${NC} $RESUME"
echo -e "${YELLOW}Keep workspace:${NC} $KEEP_WORKSPACE"
echo -e "${YELLOW}Keep logs:${NC} $KEEP_LOGS"
echo ""

echo -e "${CYAN}━━━ Starting MCP pair loop ━━━${NC}"
echo ""

while [ "$ITERATION" -lt "$MAX_ITERATIONS" ]; do
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
    CLAUDE_DELEGATION_STEP="3. Use the 'codex' MCP tool to delegate work to Codex. Ask it to review your changes, extend the code, or fix issues with a specific prompt."
    CLAUDE_FOLLOWUP_STEP="4. Review Codex's response and apply the good suggestions."
  else
    CODEX_STATUS_NOTE="Codex is unavailable for this iteration (${CODEX_STATUS_REASON}). Do not attempt Codex delegation this turn."
    CLAUDE_DELEGATION_STEP="3. Codex is unavailable this iteration. Do not call the 'codex' MCP tool. Continue the work on your own."
    CLAUDE_FOLLOWUP_STEP="4. Since Codex is unavailable, leave a clear handoff note for the next available Codex turn."
  fi

  if [ "$CLAUDE_AVAILABLE" -eq 1 ]; then
    CLAUDE_STATUS_NOTE="Claude Code is available for this iteration."
    CODEX_DELEGATION_STEP="3. Use the 'claude_code' MCP tool to delegate work back to Claude. Ask it to review your changes, suggest improvements, or validate the code with a specific prompt."
    CODEX_FOLLOWUP_STEP="4. Review Claude's response and apply the good suggestions."
  else
    CLAUDE_STATUS_NOTE="Claude Code is unavailable for this iteration (${CLAUDE_STATUS_REASON}). Do not attempt Claude delegation this turn."
    CODEX_DELEGATION_STEP="3. Claude Code is unavailable this iteration. Do not call the 'claude_code' MCP tool. Continue the work on your own."
    CODEX_FOLLOWUP_STEP="4. Since Claude Code is unavailable, leave a clear handoff note for the next available Claude turn."
  fi

  CLAUDE_LOG="$ACTIVE_LOG_DIR/claude_mcp_iter${ITERATION}.log"
  CODEX_LOG="$ACTIVE_LOG_DIR/codex_mcp_iter${ITERATION}.log"
  CLAUDE_HANDOFF="$ACTIVE_LOG_DIR/claude_mcp_handoff_iter${ITERATION}.md"
  CODEX_HANDOFF="$ACTIVE_LOG_DIR/codex_mcp_handoff_iter${ITERATION}.md"

  if [ "$FIRST_AGENT" = "claude" ]; then
    if [ "$ITERATION" -eq "$FIRST_ITERATION_OF_THIS_RUN" ] && [ "$RESUME" -eq 0 ]; then
      FIRST_TURN_SUMMARY="No prior Codex handoff summary is available for this run."
      FIRST_TURN_IS_FRESH=1
    else
      FIRST_TURN_SUMMARY="$(read_handoff_summary "$ACTIVE_LOG_DIR/codex_mcp_handoff_iter$((ITERATION - 1)).md" "No prior Codex handoff summary is available.")"
      FIRST_TURN_IS_FRESH=0
    fi
  else
    if [ "$ITERATION" -eq "$FIRST_ITERATION_OF_THIS_RUN" ] && [ "$RESUME" -eq 0 ]; then
      FIRST_TURN_SUMMARY="No prior Claude handoff summary is available for this run."
      FIRST_TURN_IS_FRESH=1
    else
      FIRST_TURN_SUMMARY="$(read_handoff_summary "$ACTIVE_LOG_DIR/claude_mcp_handoff_iter$((ITERATION - 1)).md" "No prior Claude handoff summary is available.")"
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

  run_iteration_validation
  if evaluate_stop_conditions; then
    CURRENT_PHASE="complete"
    CURRENT_HEALTH="green"
    CURRENT_BLOCKER="none recorded"
  else
    CURRENT_PHASE="running"
    [ -n "$CURRENT_BLOCKER" ] || CURRENT_BLOCKER="Loop still has open work."
  fi
  maybe_checkpoint_iteration
  append_iteration_record
  render_state_files

  echo -e "${CYAN}━━━ Iteration $ITERATION complete ━━━${NC}"
  echo -e "  Claude log: $CLAUDE_LOG"
  echo -e "  Codex log:  $CODEX_LOG"
  echo -e "  Handoff:    $CLAUDE_HANDOFF"
  echo -e "              $CODEX_HANDOFF"
  if [ -n "$VALIDATION_LOG" ]; then
    echo -e "  Validation: $VALIDATION_LOG"
  fi
  echo ""

  if [ "$CURRENT_PHASE" = "complete" ]; then
    echo -e "${GREEN}Stop conditions satisfied after iteration $ITERATION.${NC}"
    break
  fi

  sleep 2
done

echo -e "${GREEN}Loop completed after $ITERATION iterations.${NC}"
