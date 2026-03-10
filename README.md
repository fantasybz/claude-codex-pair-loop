# Claude Code <-> Codex Pair Tools

Local launcher scripts for running repeatable pair-programming loops between Claude Code and Codex.

The tools share a workspace, maintain structured loop state, write per-turn logs and handoffs, and support validation-driven stop conditions. They are designed for local use with authenticated CLIs already installed.

`workspace/` and `logs/` are generated runtime directories. They are disposable by default and ignored by Git.

## Overview

| Tool | Purpose | Recommended use |
| --- | --- | --- |
| [`pair_loop.sh`](./pair_loop.sh) | Alternating turns between Claude and Codex | Default choice for most runs |
| [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) | Alternating turns plus cross-agent MCP delegation inside each turn | Experimental runs that need richer agent-to-agent interaction |
| [`skills/claude-first-pair-loop`](./skills/claude-first-pair-loop) | Wrapper skill for Claude-first runs | Reusable agent workflow |
| [`skills/codex-first-pair-loop`](./skills/codex-first-pair-loop) | Wrapper skill for Codex-first runs | Reusable agent workflow |

If you want the most predictable execution path, start with `pair_loop.sh`.

## Requirements

These scripts are intended for a local machine, not a hosted CI environment.

- Bash
- Node.js v20+
- `claude` CLI
- `codex` CLI
- `npx`

Expected local setup:

- `pair_loop.sh` expects `claude -p --dangerously-skip-permissions` to work.
- `pair_loop.sh` expects `codex exec --full-auto` to work.
- `pair_loop_mcp.sh` expects Claude to load the repo-local [`.mcp.json`](./.mcp.json).
- `pair_loop_mcp.sh` may register a `claude-code` MCP server for Codex if it does not already exist.

The current Codex-side MCP registration command is:

```bash
codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest
```

If the MCP packages are not already cached, `npx` may need network access on the first run.

## Quick Start

If the scripts are not executable in your clone:

```bash
chmod +x pair_loop.sh pair_loop_mcp.sh
```

Run the standard loop:

```bash
./pair_loop.sh "Build a Python CLI that parses Markdown front matter and outputs JSON" 3
```

Run the MCP-enabled loop:

```bash
./pair_loop_mcp.sh "Build a Python CLI that parses Markdown front matter and outputs JSON" 3
```

Resume an existing run:

```bash
./pair_loop.sh --resume --workspace ./workspace --log-dir ./logs
```

Run in non-destructive mode:

```bash
./pair_loop.sh --non-destructive --task "Improve an existing CLI tool"
```

Run with Codex starting first:

```bash
./pair_loop.sh --codex-first --task "Improve an existing CLI tool"
```

Run with explicit model and effort settings:

```bash
./pair_loop_mcp.sh \
  --claude-model sonnet \
  --claude-effort high \
  --codex-model gpt-5.3-codex \
  --codex-effort xhigh \
  --task "Continue the current project" \
  --resume
```

Run with session grouping, validation, stop conditions, and checkpoints:

```bash
./pair_loop.sh \
  --session-name hardening-pass \
  --role-preset docs-refactor \
  --validation-command "pytest -q" \
  --until-tests-pass \
  --until-checklist-complete \
  --checkpoint-commits \
  --task "Stabilize the service"
```

Run through the skill wrappers:

```bash
./skills/claude-first-pair-loop/scripts/run-pair-loop.sh \
  --task "Build a CLI tool" \
  --max-iterations 3

./skills/codex-first-pair-loop/scripts/run-pair-loop.sh \
  --mcp \
  --task "Continue the current project" \
  --resume
```

Run startup checks only:

```bash
./pair_loop.sh --healthcheck-only
```

## Command Reference

Positional arguments:

- First argument: task description passed to both agents.
- Second argument: maximum number of iterations.

If you omit the task, each script uses its built-in default Python CLI prompt. If you omit `max_iterations`, both scripts default to `999999`.

Task and execution control:

- `--task TEXT`
- `--max-iterations N`
- `--workspace PATH`
- `--log-dir PATH`
- `--session-name NAME`
- `--first-agent claude|codex`
- `--claude-first`
- `--codex-first`
- `--turn-timeout SECONDS`
- `--healthcheck-only`

Model, effort, and role configuration:

- `--profile fast|balanced|deep`
- `--fast`
- `--balanced`
- `--deep`
- `--claude-model MODEL`
- `--codex-model MODEL`
- `--claude-effort low|medium|high`
- `--codex-effort low|medium|high|xhigh`
- `--role-preset balanced|docs-refactor|reviewer-builder`

Validation, stop conditions, and checkpoints:

- `--validation-command CMD`
- `--until-tests-pass`
- `--until-checklist-complete`
- `--until-clean-git`
- `--checkpoint-commits`
- `--checkpoint-tags`

State preservation:

- `--resume`
- `--keep-logs`
- `--keep-workspace`
- `--non-destructive`

Behavior notes:

- `--resume` implies preserving both workspace and logs.
- Profile presets only affect effort defaults. They do not force a specific model.
- Explicit `--claude-effort` or `--codex-effort` overrides the profile default for that agent.
- Claude effort is passed through as `claude --effort`.
- Codex effort is passed through as `codex exec -c model_reasoning_effort="..."`.

## How the Loop Works

At startup, both scripts:

1. Parse flags and resolve runtime configuration.
2. Run startup health checks for Claude, Codex, Node.js, and MCP availability.
3. Clean or preserve `workspace/` and `logs/` based on the selected flags.
4. Ensure the workspace is a Git repository because Codex expects one.
5. Create or reuse structured state files under `logs/.../state/loop_state.md` and `logs/.../state/loop_state.json`.
6. Initialize `run_summary.json` for the active session.

During each iteration:

1. The scripts perform a lightweight availability check for both agents.
2. The first agent takes a turn or is skipped if unavailable.
3. The runner writes a per-turn log and a diff-aware handoff summary.
4. The second agent takes a turn or is skipped if unavailable.
5. The runner runs validation if configured or auto-detectable.
6. Stop conditions are evaluated and the state files are regenerated.
7. The loop either continues, stops because conditions were met, or exits when interrupted or capped by `max_iterations`.

Availability checks currently work like this:

- Claude: a lightweight `claude -p` ping
- Codex: `codex login status`

If a check fails, the runner writes a skip log and continues with the next available agent instead of aborting immediately.

## State and Artifacts

Primary runtime artifacts:

- `logs/.../state/loop_state.md`: human-readable loop state
- `logs/.../state/loop_state.json`: machine-readable loop state
- `logs/.../*.log`: per-turn and validation logs
- `logs/.../*handoff_iterN.md`: handoff summaries between turns
- `logs/.../run_summary.json`: runner-owned final summary for the session
- `logs/<session>/state/`: session-scoped mirrors of the state files when `--session-name` is used

State behavior:

- `loop_state.md` preserves human-managed sections such as Success Criteria, File Focus, Open Decisions, and Risks.
- The runner regenerates Session, Current Status, Next Handoff, Iteration Ledger, and stop-condition status.
- Handoff files are diff-aware. They include a change summary, current Git status, workspace snapshot, and a runner-owned state snapshot.
- Turn logs record both configured and resolved runtime model and effort when the underlying CLI exposes those values.
- `loop_state.json` and `run_summary.json` split stop-condition data into `configured`, `current`, and `summary` so tooling can distinguish enabled checks from checks that are currently met.
- The workspace is reserved for generated project files. Runner state and handoff artifacts are kept under `logs/`.

Session behavior:

- Without `--session-name`, logs are written directly under `logs/`.
- With `--session-name`, logs, handoffs, validation logs, `run_summary.json`, and state mirrors are grouped under `logs/<session>/`.

## Script Details

### `pair_loop.sh`

`pair_loop.sh` is the simpler and more explicit mode.

- Claude starts first by default.
- You can switch to Codex-first with `--first-agent codex` or `--codex-first`.
- The agents alternate direct turns against the same workspace.
- The first agent receives the previous handoff summary from the other agent.
- The second agent receives the current handoff summary from the first agent.

Use this mode when you want clearer logs, fewer moving parts, and easier debugging.

### `pair_loop_mcp.sh`

`pair_loop_mcp.sh` keeps the same outer loop, but changes what happens inside each turn.

- Claude can delegate back to Codex through MCP during Claude's turn.
- Codex can delegate back to Claude through MCP during Codex's turn.
- The outer script still alternates turns, so MCP delegation happens inside the turn rather than replacing the loop.

Use this mode when you want richer collaboration patterns and you are comfortable with a more fragile runtime model.

### Current MCP Components

As configured in this repository, MCP mode depends on external MCP projects:

| Direction | Local config | Upstream project |
| --- | --- | --- |
| Claude -> Codex | [`.mcp.json`](./.mcp.json) starts `npx -y codex-mcp-server` under the MCP server name `codex-cli` | [`codex-mcp-server`](https://github.com/tuannvm/codex-mcp-server) |
| Codex -> Claude | [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) runs `codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest` when needed | [`@steipete/claude-code-mcp`](https://github.com/steipete/claude-code-mcp) |

Operational notes:

- These MCP dependencies are referenced from upstream packages and are not vendored into this repository.
- The current setup does not pin a specific `codex-mcp-server` version.
- The current setup uses `@latest` for `@steipete/claude-code-mcp`, so future runs may pick up newer upstream behavior.

## Testing and Local Automation

### Local CI and Hooks

This repository includes a local-only workflow for deterministic checks and live authenticated smoke tests:

- [`scripts/local-ci.sh`](./scripts/local-ci.sh): local runner for deterministic checks, live E2E, and hook installation
- [`.githooks/pre-commit`](./.githooks/pre-commit): fast deterministic checks before each commit
- [`.githooks/post-commit`](./.githooks/post-commit): background live E2E after each commit

Enable the hooks for this clone:

```bash
chmod +x scripts/local-ci.sh .githooks/pre-commit .githooks/post-commit
bash scripts/local-ci.sh install-hooks
```

Useful commands:

```bash
bash scripts/local-ci.sh deterministic
bash scripts/local-ci.sh live
bash scripts/local-ci.sh all
```

Operational notes:

- The post-commit hook is non-blocking.
- Background live E2E output is written under `logs/local-ci/`.
- Only one background live E2E is started at a time.
- Live runs use your local authenticated `claude` and `codex` CLIs and consume real usage.
- You can copy [`.local-ci.env.example`](./.local-ci.env.example) to `.local-ci.env` to override local defaults.

### Live E2E Smoke Test

The repository includes a live smoke test at [`tests/e2e_live_pair_loop.sh`](./tests/e2e_live_pair_loop.sh).

What it does:

- runs `pair_loop.sh` by default, or `pair_loop_mcp.sh` with `--mode mcp`
- uses a throwaway workspace and log directory under `/tmp`
- asks the loop to create `smoke.txt` with exact content
- verifies the state files under `logs/.../state/`, final-iteration validation logs, and `run_summary.json`
- checks the runner-owned summary to confirm validation finished with `passed`
- removes generated artifacts only when `--cleanup` is requested and the run succeeds

Useful options:

- `--mode standard|mcp`
- `--first-agent claude|codex`
- `--require-claude-turn`
- `--require-codex-turn`
- `--cleanup`
- `--` to pass additional flags through to the underlying loop script

Important limitations:

- this is a real integration test, not a mocked unit test
- it consumes real Claude and Codex usage
- it requires authenticated local CLIs and working network access
- it is not suitable for sandboxed or offline CI by default

## Agent Skills

The repository includes two lightweight skill packages under [`skills/`](./skills):

| Skill | Path | Purpose |
| --- | --- | --- |
| `claude-first-pair-loop` | [`skills/claude-first-pair-loop`](./skills/claude-first-pair-loop) | Runs the pair loop with Claude taking the first turn |
| `codex-first-pair-loop` | [`skills/codex-first-pair-loop`](./skills/codex-first-pair-loop) | Runs the pair loop with Codex taking the first turn |

Each skill contains:

- `SKILL.md` with usage instructions
- `agents/openai.yaml` with agent metadata
- `scripts/run-pair-loop.sh` as the wrapper entrypoint

The wrapper scripts accept the same core flags as the underlying tools. Pass `--mcp` to switch from standard mode to MCP mode.

## Safety and Operational Notes

These scripts are intentionally aggressive about cleaning generated state.

- By default they clean the contents of `workspace/` at startup.
- By default they clean the contents of `logs/` at startup.
- Use `--keep-workspace`, `--keep-logs`, `--non-destructive`, or `--resume` if you want to preserve existing state.
- Anything stored in those directories should be treated as disposable unless you explicitly preserve it.

Other practical caveats:

- The scripts use `set -euo pipefail`.
- Claude availability checks consume a lightweight Claude request because there is no equivalent local status command for account and usage.
- Shared context is diff-aware and state-aware, but still summary-based.
- Checkpoint commits and tags are optional and only run when enabled.
- MCP mode assumes the installed CLI behavior matches what the scripts expect.

## Troubleshooting

If a run fails, start with the generated files under [`logs/`](./logs).

Common issues:

- `claude: command not found` or `codex: command not found`
- authentication failures
- MCP server not available in `pair_loop_mcp.sh`
- expected files missing from `workspace/`
- loop keeps running longer than expected

Typical fixes:

- Install the missing CLI and ensure it is on `PATH`.
- Re-authenticate the affected CLI.
- Check [`.mcp.json`](./.mcp.json), run `codex mcp list`, and confirm `npx` can launch the required packages.
- Re-run with `--keep-workspace`, `--keep-logs`, `--non-destructive`, or `--resume` if you need to preserve debugging artifacts.
- Use `Ctrl-C` to stop a long-running loop manually.

## Choosing a Mode

Use `pair_loop.sh` when you want:

- simpler execution
- clearer logs
- fewer moving parts
- easier debugging

Use `pair_loop_mcp.sh` when you want:

- Claude to call Codex during Claude's turn
- Codex to call Claude during Codex's turn
- to experiment with more autonomous cross-agent workflows

## Suggested Improvements

If you plan to keep evolving these tools, the highest-value follow-ups are:

1. Pin MCP package versions instead of relying on `@latest`.
2. Improve validation auto-detection with more ecosystems and project-specific overrides.
3. Add richer checkpoint strategies such as branches or worktrees in addition to commits and tags.
4. Record token and cost metrics if future CLI versions expose them reliably.
5. Expand regression coverage as new loop behaviors are added.
