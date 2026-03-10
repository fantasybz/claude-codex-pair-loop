#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/tests/fake_pair_loop_test_lib.sh"

SUCCESS_VALIDATION_COMMAND="test -f codex-iter-2.txt && test \"\$(wc -l < smoke.txt)\" -eq 1 && test \"\$(wc -c < smoke.txt)\" -eq 11 && printf 'smoke test\n' | cmp -s - smoke.txt"

run_standard_success_case() {
  local tmp_dir fake_bin workspace log_dir session

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-e2e-standardXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="e2e-standard"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=smoke ./tests/e2e_live_pair_loop.sh \
      --mode standard \
      --first-agent claude \
      --max-iterations 2 \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --validation-command "$SUCCESS_VALIDATION_COMMAND" \
      --require-claude-turn \
      --require-codex-turn \
      > "$tmp_dir/output.txt" 2>&1
  )

  test -f "$workspace/smoke.txt" || die "standard E2E success case lost workspace artifacts"
  test -f "$log_dir/$session/run_summary.json" || die "standard E2E success case missing run summary"
  test -f "$log_dir/$session/validation_iter2.log" || die "standard E2E success case did not validate iteration 2"

  rm -rf "$tmp_dir"
}

run_mcp_success_cleanup_case() {
  local tmp_dir fake_bin workspace log_dir session

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-e2e-mcpXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="e2e-mcp"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=smoke ./tests/e2e_live_pair_loop.sh \
      --mode mcp \
      --first-agent claude \
      --max-iterations 2 \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --validation-command "$SUCCESS_VALIDATION_COMMAND" \
      --require-claude-turn \
      --require-codex-turn \
      --cleanup \
      > "$tmp_dir/output.txt" 2>&1
  )

  [ ! -e "$workspace" ] || die "successful cleanup case should remove workspace"
  [ ! -e "$log_dir" ] || die "successful cleanup case should remove log root"

  rm -rf "$tmp_dir"
}

run_failure_cleanup_preserved_case() {
  local tmp_dir fake_bin workspace log_dir session status

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-e2e-failureXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="e2e-failure"

  make_fake_bin "$fake_bin"

  status=0
  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=smoke ./tests/e2e_live_pair_loop.sh \
      --mode standard \
      --first-agent claude \
      --max-iterations 1 \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --validation-command "false" \
      --cleanup \
      > "$tmp_dir/output.txt" 2>&1
  ) || status=$?

  [ "$status" -ne 0 ] || die "failure cleanup case should exit non-zero"
  [ -d "$workspace" ] || die "failed E2E run should preserve workspace for debugging"
  [ -d "$log_dir" ] || die "failed E2E run should preserve logs for debugging"
  test -f "$log_dir/$session/run_summary.json" || die "failed E2E run should preserve run summary"

  rm -rf "$tmp_dir"
}

run_standard_success_case
run_mcp_success_cleanup_case
run_failure_cleanup_preserved_case

echo "E2E harness regression checks passed"
