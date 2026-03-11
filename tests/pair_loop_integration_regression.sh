#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
# shellcheck disable=SC1091
. "$ROOT_DIR/tests/fake_pair_loop_test_lib.sh"

assert_no_iteration_two() {
  local log_dir="$1"
  if find "$log_dir" -type f -name '*iter2*' | grep -q .; then
    die "unexpected iteration 2 artifacts in $log_dir"
  fi
}

run_healthcheck_only_case() {
  local script_name="$1"
  local tmp_dir fake_bin workspace log_dir out

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-healthcheckXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  out="$tmp_dir/output.txt"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" "./$script_name" \
      --healthcheck-only \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      > "$out" 2>&1
  )

  grep -q "Health checks completed successfully" "$out" || die "missing healthcheck-only success message for $script_name"
  [ ! -e "$workspace/.loop_state.md" ] || die "healthcheck-only should not create workspace state for $script_name"
  [ ! -d "$log_dir" ] || [ -z "$(find "$log_dir" -mindepth 1 -print -quit)" ] || die "healthcheck-only should not create log artifacts for $script_name"

  rm -rf "$tmp_dir"
}

run_resume_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-resumeXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="resume-case"
  summary_file="$log_dir/$session/run_summary.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=resume ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "resume regression" \
      --max-iterations 1 \
      > "$tmp_dir/first.out" 2>&1
  )

  test -f "$workspace/claude-iter-1.txt" || die "first run did not preserve claude iteration artifact"
  test -f "$workspace/codex-iter-1.txt" || die "first run did not preserve codex iteration artifact"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=resume ./pair_loop.sh \
      --resume \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "resume regression" \
      --max-iterations 2 \
      > "$tmp_dir/second.out" 2>&1
  )

  test -f "$workspace/claude-iter-1.txt" || die "resume run lost first-run workspace artifact"
  test -f "$workspace/codex-iter-2.txt" || die "resume run did not create second-run workspace artifact"
  test -f "$log_dir/$session/claude_iter1.log" || die "resume run lost iteration 1 Claude log"
  test -f "$log_dir/$session/codex_iter2.log" || die "resume run did not create iteration 2 Codex log"

  node - "$summary_file" <<'EOF'
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (summary.iterationsCompleted !== 2) {
  throw new Error(`expected iterationsCompleted=2, got ${summary.iterationsCompleted}`);
}
if (!summary.config.resume) {
  throw new Error("expected resume=true in run summary");
}
EOF

  rm -rf "$tmp_dir"
}

run_checklist_stop_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-checklistXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="checklist-case"
  summary_file="$log_dir/$session/run_summary.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=checklist ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "checklist regression" \
      --max-iterations 3 \
      --until-checklist-complete \
      > "$tmp_dir/output.txt" 2>&1
  )

  assert_no_iteration_two "$log_dir/$session"
  node - "$summary_file" <<'EOF'
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (summary.iterationsCompleted !== 1) {
  throw new Error(`expected iterationsCompleted=1, got ${summary.iterationsCompleted}`);
}
if (summary.finalStatus.stopReason !== "stop conditions satisfied") {
  throw new Error(`unexpected stop reason: ${summary.finalStatus.stopReason}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_clean_git_stop_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file status

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-clean-gitXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="clean-git-case"
  summary_file="$log_dir/$session/run_summary.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=clean-git ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "clean git regression" \
      --max-iterations 3 \
      --until-clean-git \
      > "$tmp_dir/output.txt" 2>&1
  )

  assert_no_iteration_two "$log_dir/$session"
  status="$(git -C "$workspace" status --short --untracked-files=normal)"
  [ -z "$status" ] || die "expected clean git workspace, got: $status"
  node - "$summary_file" <<'EOF'
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (summary.finalStatus.stopReason !== "stop conditions satisfied") {
  throw new Error(`unexpected stop reason: ${summary.finalStatus.stopReason}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_checkpoint_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file tag_name

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-checkpointXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="checkpoint-case"
  summary_file="$log_dir/$session/run_summary.json"
  tag_name="pair-loop-${session}-iter-1"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=checkpoint ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "checkpoint regression" \
      --max-iterations 1 \
      --checkpoint-commits \
      --checkpoint-tags \
      > "$tmp_dir/output.txt" 2>&1
  )

  git -C "$workspace" rev-parse --verify HEAD >/dev/null 2>&1 || die "checkpoint run did not create a commit"
  git -C "$workspace" rev-parse --verify "$tag_name" >/dev/null 2>&1 || die "checkpoint run did not create tag $tag_name"
  node - "$summary_file" "$tag_name" <<'EOF'
const fs = require("fs");
const [summaryPath, tagName] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
if (!summary.checkpoint.ref.includes(tagName)) {
  throw new Error(`expected checkpoint ref to mention ${tagName}, got ${summary.checkpoint.ref}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_timeout_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-timeoutXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="timeout-case"
  summary_file="$log_dir/$session/run_summary.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=timeout-codex PAIR_LOOP_FAKE_SLEEP_SECONDS=2 ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "timeout regression" \
      --max-iterations 1 \
      --turn-timeout 1 \
      --codex-first \
      > "$tmp_dir/output.txt" 2>&1
  )

  grep -q 'exit_status: 124' "$log_dir/$session/codex_iter1.log" || die "expected timeout exit status in Codex log"
  node - "$summary_file" <<'EOF'
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const codex = summary.lastIteration.agents.find((agent) => agent.name === "Codex");
if (!codex) {
  throw new Error("missing Codex summary");
}
if (codex.status !== "failed") {
  throw new Error(`expected Codex status=failed, got ${codex.status}`);
}
if (!codex.reason.includes("timed out")) {
  throw new Error(`expected timeout reason, got ${codex.reason}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_metadata_and_state_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file state_json

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-metadataXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="metadata-case"
  summary_file="$log_dir/$session/run_summary.json"
  state_json="$log_dir/$session/state/loop_state.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=smoke ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "metadata regression" \
      --max-iterations 1 \
      --claude-model claude-configured \
      --claude-effort medium \
      --codex-model codex-configured \
      --codex-effort low \
      --until-checklist-complete \
      > "$tmp_dir/output.txt" 2>&1
  )

  grep -q 'configured_model: claude-configured' "$log_dir/$session/claude_iter1.log" || die "expected configured Claude model in turn log"
  grep -q 'configured_effort: medium' "$log_dir/$session/claude_iter1.log" || die "expected configured Claude effort in turn log"
  grep -q 'resolved_model: claude-runtime-sonnet' "$log_dir/$session/claude_iter1.log" || die "expected resolved Claude model in turn log"
  grep -q 'resolved_effort: high' "$log_dir/$session/claude_iter1.log" || die "expected resolved Claude effort in turn log"
  grep -q 'configured_model: codex-configured' "$log_dir/$session/codex_iter1.log" || die "expected configured Codex model in turn log"
  grep -q 'configured_effort: low' "$log_dir/$session/codex_iter1.log" || die "expected configured Codex effort in turn log"
  grep -q 'resolved_model: codex-runtime-gpt5' "$log_dir/$session/codex_iter1.log" || die "expected resolved Codex model in turn log"
  grep -q 'resolved_effort: xhigh' "$log_dir/$session/codex_iter1.log" || die "expected resolved Codex effort in turn log"
  grep -q '## State Snapshot' "$log_dir/$session/claude_handoff_iter1.md" || die "expected structured state snapshot in Claude handoff"
  if grep -q '## State File Tail' "$log_dir/$session/claude_handoff_iter1.md"; then
    die "Claude handoff should not include raw state tails"
  fi
  [ ! -e "$workspace/.loop_state.md" ] || die "workspace should not contain .loop_state.md"
  [ ! -e "$workspace/.loop_state.json" ] || die "workspace should not contain .loop_state.json"
  if find "$workspace" -maxdepth 1 -type f \( -name 'claude_handoff_iter*.md' -o -name 'codex_handoff_iter*.md' -o -name 'claude_mcp_handoff_iter*.md' -o -name 'codex_mcp_handoff_iter*.md' \) | grep -q .; then
    die "workspace should not contain handoff markdown files"
  fi

  node - "$summary_file" "$state_json" <<'EOF'
const fs = require("fs");
const [summaryPath, statePath] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
const claude = summary.lastIteration.agents.find((agent) => agent.name === "Claude Code");
const codex = summary.lastIteration.agents.find((agent) => agent.name === "Codex");
if (!claude || !codex) {
  throw new Error("missing agent metadata in run summary");
}
if (claude.configuredModel !== "claude-configured" || claude.resolvedModel !== "claude-runtime-sonnet") {
  throw new Error(`unexpected Claude metadata: ${JSON.stringify(claude)}`);
}
if (codex.configuredEffort !== "low" || codex.resolvedEffort !== "xhigh") {
  throw new Error(`unexpected Codex metadata: ${JSON.stringify(codex)}`);
}
if (!summary.stopConditions.configured.untilChecklistComplete) {
  throw new Error("expected configured.untilChecklistComplete=true in run summary");
}
if (summary.stopConditions.current.untilChecklistComplete !== true) {
  throw new Error(`expected current.untilChecklistComplete=true in run summary, got ${summary.stopConditions.current.untilChecklistComplete}`);
}
if (summary.stopConditions.current.untilTestsPass !== null) {
  throw new Error(`expected current.untilTestsPass=null in run summary, got ${summary.stopConditions.current.untilTestsPass}`);
}
if (!state.stopConditions.configured.untilChecklistComplete) {
  throw new Error("expected configured.untilChecklistComplete=true in state json");
}
if (state.stopConditions.current.untilChecklistComplete !== true) {
  throw new Error(`expected current.untilChecklistComplete=true in state json, got ${state.stopConditions.current.untilChecklistComplete}`);
}
if (state.stopConditions.current.untilCleanGit !== null) {
  throw new Error(`expected current.untilCleanGit=null in state json, got ${state.stopConditions.current.untilCleanGit}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_validation_preset_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file state_json

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-validation-presetXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="validation-preset-case"
  summary_file="$log_dir/$session/run_summary.json"
  state_json="$log_dir/$session/state/loop_state.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=python-pytest-layout ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "validation preset regression" \
      --max-iterations 2 \
      --validation-preset pytest \
      --until-tests-pass \
      > "$tmp_dir/output.txt" 2>&1
  )

  grep -q 'command: pytest -q' "$log_dir/$session/validation_iter1.log" || die "expected pytest validation command"
  grep -q 'preset: pytest' "$log_dir/$session/validation_iter1.log" || die "expected pytest preset in validation log"
  grep -q 'detected_layout: python-pytest-root-files' "$log_dir/$session/validation_iter1.log" || die "expected pytest layout detection in validation log"
  assert_no_iteration_two "$log_dir/$session"

  node - "$summary_file" "$state_json" <<'EOF'
const fs = require("fs");
const [summaryPath, statePath] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
if (summary.validation.status !== "passed") {
  throw new Error(`expected summary.validation.status=passed, got ${summary.validation.status}`);
}
if (summary.config.validationPreset !== "pytest") {
  throw new Error(`expected config.validationPreset=pytest, got ${summary.config.validationPreset}`);
}
if (summary.config.validationSelectionMode !== "preset") {
  throw new Error(`expected config.validationSelectionMode=preset, got ${summary.config.validationSelectionMode}`);
}
if (summary.validation.detected.layout !== "python-pytest-root-files") {
  throw new Error(`unexpected validation layout: ${summary.validation.detected.layout}`);
}
if (state.validation.preset !== "pytest") {
  throw new Error(`expected state.validation.preset=pytest, got ${state.validation.preset}`);
}
if (state.validation.detected.layout !== "python-pytest-root-files") {
  throw new Error(`unexpected state validation layout: ${state.validation.detected.layout}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_validation_warning_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file state_json

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-validation-warningXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="validation-warning-case"
  summary_file="$log_dir/$session/run_summary.json"
  state_json="$log_dir/$session/state/loop_state.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=python-pytest-layout ./pair_loop.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "validation warning regression" \
      --max-iterations 1 \
      --validation-command "python3 -m unittest discover -s tests" \
      --until-tests-pass \
      > "$tmp_dir/output.txt" 2>&1
  )

  grep -q 'warning: Validation command references tests/, but the workspace has no tests/ directory.' "$log_dir/$session/validation_iter1.log" || die "expected tests-dir warning in validation log"
  grep -q 'hint: Detected python-pytest-root-files' "$log_dir/$session/validation_iter1.log" || die "expected pytest hint in validation log"

  node - "$summary_file" "$state_json" <<'EOF'
const fs = require("fs");
const [summaryPath, statePath] = process.argv.slice(2);
const summary = JSON.parse(fs.readFileSync(summaryPath, "utf8"));
const state = JSON.parse(fs.readFileSync(statePath, "utf8"));
if (summary.validation.status !== "failed") {
  throw new Error(`expected summary.validation.status=failed, got ${summary.validation.status}`);
}
if (!summary.validation.warning || !summary.validation.warning.includes("no tests/ directory")) {
  throw new Error(`missing validation warning: ${summary.validation.warning}`);
}
if (!summary.validation.hint || !summary.validation.hint.includes("pytest -q")) {
  throw new Error(`missing validation hint: ${summary.validation.hint}`);
}
if (summary.validation.detected.layout !== "python-pytest-root-files") {
  throw new Error(`unexpected detected layout: ${summary.validation.detected.layout}`);
}
if (!state.validation.warning || !state.validation.hint) {
  throw new Error("expected validation warning and hint in state json");
}
EOF

  rm -rf "$tmp_dir"
}

run_mcp_summary_case() {
  local tmp_dir fake_bin workspace log_dir session summary_file

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-mcpXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"
  session="mcp-case"
  summary_file="$log_dir/$session/run_summary.json"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" PAIR_LOOP_FAKE_SCENARIO=python-pytest-layout ./pair_loop_mcp.sh \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --session-name "$session" \
      --task "mcp regression" \
      --max-iterations 2 \
      --claude-model claude-mcp-configured \
      --claude-effort low \
      --codex-model codex-mcp-configured \
      --codex-effort medium \
      --validation-preset pytest \
      --until-tests-pass \
      > "$tmp_dir/output.txt" 2>&1
  )

  test -f "$log_dir/$session/claude_mcp_iter1.log" || die "missing Claude MCP log"
  test -f "$log_dir/$session/codex_mcp_iter1.log" || die "missing Codex MCP log"
  grep -q 'resolved_model: claude-runtime-sonnet' "$log_dir/$session/claude_mcp_iter1.log" || die "expected resolved Claude MCP model in turn log"
  grep -q 'resolved_model: codex-runtime-gpt5' "$log_dir/$session/codex_mcp_iter1.log" || die "expected resolved Codex MCP model in turn log"
  grep -q '## State Snapshot' "$log_dir/$session/claude_mcp_handoff_iter1.md" || die "expected structured state snapshot in Claude MCP handoff"
  if grep -q '## State File Tail' "$log_dir/$session/claude_mcp_handoff_iter1.md"; then
    die "Claude MCP handoff should not include raw state tails"
  fi
  node - "$summary_file" <<'EOF'
const fs = require("fs");
const summary = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
if (summary.session.mode !== "mcp") {
  throw new Error(`expected session.mode=mcp, got ${summary.session.mode}`);
}
if (!summary.healthChecks.mcp.available) {
  throw new Error("expected MCP health check to be available");
}
if (summary.validation.status !== "passed") {
  throw new Error(`expected validation.status=passed, got ${summary.validation.status}`);
}
if (summary.config.validationPreset !== "pytest") {
  throw new Error(`expected validation preset pytest, got ${summary.config.validationPreset}`);
}
const claude = summary.lastIteration.agents.find((agent) => agent.name === "Claude Code");
if (!claude || claude.resolvedModel !== "claude-runtime-sonnet") {
  throw new Error("expected resolved Claude metadata in MCP summary");
}
if (summary.validation.detected.layout !== "python-pytest-root-files") {
  throw new Error(`unexpected MCP validation layout: ${summary.validation.detected.layout}`);
}
EOF

  rm -rf "$tmp_dir"
}

run_healthcheck_only_case "pair_loop.sh"
run_healthcheck_only_case "pair_loop_mcp.sh"
run_resume_case
run_checklist_stop_case
run_clean_git_stop_case
run_checkpoint_case
run_timeout_case
run_metadata_and_state_case
run_validation_preset_case
run_validation_warning_case
run_mcp_summary_case

echo "pair loop integration regression checks passed"
