# Claude Code <-> Codex Pair Tools

This README documents the two launcher scripts in this repository and the wrapper skills built on top of them:

- [`pair_loop.sh`](./pair_loop.sh) runs a simple alternating turn-based loop.
- [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) runs a more experimental loop where each agent can also delegate back to the other through MCP during its turn.
- [`skills/claude-first-pair-loop`](./skills/claude-first-pair-loop) wraps the scripts with Claude-first turn order.
- [`skills/codex-first-pair-loop`](./skills/codex-first-pair-loop) wraps the scripts with Codex-first turn order.

`workspace/` and `logs/` are generated runtime output directories. They are disposable by default and are ignored by Git.

## What each script does

| Script | Mode | Best for |
| --- | --- | --- |
| `pair_loop.sh` | Alternating CLI turns | Simpler, easier-to-debug pair runs |
| `pair_loop_mcp.sh` | Alternating CLI turns plus cross-agent MCP delegation | Experiments where each agent should be able to call the other mid-turn |

## How the loop works

At startup, both scripts now do the following:

1. Parse flags such as `--workspace`, `--log-dir`, `--profile`, `--claude-model`, `--codex-model`, `--session-name`, `--validation-command`, `--resume`, `--keep-logs`, and `--non-destructive`.
2. Run up-front health checks for Claude, Codex, Node.js, and MCP availability.
3. Clean or preserve `workspace/` and `logs/` based on the selected flags.
4. Ensure the workspace is a Git repository because Codex expects one.
5. Create or reuse structured state files at `workspace/.loop_state.md` and `workspace/.loop_state.json`.

During each iteration:

1. The scripts perform a lightweight availability check for both agents.
2. Claude takes a turn and writes a transcript to `logs/`, or the turn is skipped if Claude is unavailable.
3. Codex takes a turn and writes a transcript to `logs/`, or the turn is skipped if Codex is unavailable.
4. After each turn, the script writes a diff-aware handoff summary for the next agent.
5. The loop pauses briefly, then continues until it reaches `max_iterations` or you stop it with `Ctrl-C`.

The handoff is now diff-aware instead of log-tail based. Each turn compares the workspace before and after the agent run, writes a file-change summary, includes current Git status, and carries forward the latest `.loop_state.md` tail.

The state file is now structured instead of freeform. The scripts preserve human-managed sections such as Success Criteria, File Focus, Open Decisions, and Risks, while automatically regenerating Session, Current Status, Next Handoff, Iteration Ledger, and the `.loop_state.json` mirror.

Availability checks currently work like this:

- Claude: a lightweight `claude -p` ping, which acts as an account/usage check
- Codex: `codex login status`

If a check fails, the script writes a skip note into that iteration's log file and continues with the next available agent instead of exiting immediately.

## Requirements

The scripts are written for a local machine with the relevant CLIs already installed and authenticated.

- Bash
- Node.js v20+
- `claude` CLI
- `codex` CLI
- `npx`

Expected setup from the scripts themselves:

- `pair_loop.sh` expects `claude -p --dangerously-skip-permissions` to work.
- `pair_loop.sh` expects `codex exec --full-auto` to work.
- `pair_loop_mcp.sh` expects Claude to load the repo-local [`.mcp.json`](./.mcp.json), which currently launches `codex-mcp-server` through `npx`.
- `pair_loop_mcp.sh` attempts to register a `claude-code` MCP server for Codex if it does not already exist:

```bash
codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest
```

If the required MCP packages are not cached locally, `npx` may need network access the first time it runs.

## Current MCP components

As currently configured in this repo, [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) depends on two external MCP projects:

| Direction | Local config | Upstream project |
| --- | --- | --- |
| Claude -> Codex | [`.mcp.json`](./.mcp.json) starts `npx -y codex-mcp-server` under the MCP server name `codex-cli` | [`codex-mcp-server`](https://github.com/tuannvm/codex-mcp-server) |
| Codex -> Claude | [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) runs `codex mcp add claude-code -- npx -y @steipete/claude-code-mcp@latest` when the server is not already registered | [`@steipete/claude-code-mcp`](https://github.com/steipete/claude-code-mcp) |

Notes:

- These MCP dependencies are referenced from upstream packages and are not vendored into this repository.
- The current script uses `@latest` for `@steipete/claude-code-mcp`, so future runs may pick up newer upstream behavior.
- The current [`.mcp.json`](./.mcp.json) also does not pin a specific `codex-mcp-server` version.

## Quick start

If the scripts are not executable in your clone:

```bash
chmod +x pair_loop.sh pair_loop_mcp.sh
```

Run the basic loop:

```bash
./pair_loop.sh "Build a Python CLI that parses Markdown front matter and outputs JSON" 3
```

Run the MCP-enabled loop:

```bash
./pair_loop_mcp.sh "Build a Python CLI that parses Markdown front matter and outputs JSON" 3
```

Run in non-destructive mode:

```bash
./pair_loop.sh --non-destructive --task "Improve an existing CLI tool"
```

Resume an existing MCP run:

```bash
./pair_loop_mcp.sh --resume --workspace ./workspace --log-dir ./logs
```

Run with Codex starting first:

```bash
./pair_loop.sh --codex-first --task "Improve an existing CLI tool"
```

Run with a deeper reasoning preset:

```bash
./pair_loop.sh --deep --task "Refactor and harden this service"
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

Run with session grouping, stop conditions, and checkpoints:

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

Run through the generated skill wrappers:

```bash
./skills/claude-first-pair-loop/scripts/run-pair-loop.sh --task "Build a CLI tool" --max-iterations 3
./skills/codex-first-pair-loop/scripts/run-pair-loop.sh --mcp --task "Continue the current project" --resume
```

Arguments:

- First argument: task description passed to both agents.
- Second argument: maximum number of iterations.

If you omit the task, each script falls back to its built-in default Python CLI prompt.

If you omit `max_iterations`, both scripts default to `999999`, which is effectively "run until stopped".

Supported flags:

- `--workspace PATH`: use a custom workspace directory
- `--log-dir PATH`: use a custom log directory
- `--task TEXT`: pass the task as a flag instead of a positional argument
- `--max-iterations N`: pass the iteration count as a flag
- `--profile fast|balanced|deep`: set effort defaults for both agents
- `--fast`, `--balanced`, `--deep`: aliases for `--profile`
- `--claude-model MODEL`: choose the Claude model for each Claude turn
- `--codex-model MODEL`: choose the Codex model for each Codex turn
- `--claude-effort low|medium|high`: choose Claude effort level
- `--codex-effort low|medium|high|xhigh`: choose Codex reasoning effort
- `--role-preset balanced|docs-refactor|reviewer-builder`: bias each agent toward a different role
- `--session-name NAME`: group logs and session state artifacts under `logs/NAME/`
- `--validation-command CMD`: run a validation command after each iteration
- `--state-max-ledger-entries N`: keep only the most recent N detailed iterations in `.loop_state.md`
- `--until-tests-pass`: stop when validation succeeds
- `--until-checklist-complete`: stop when all Success Criteria checkboxes are checked
- `--until-clean-git`: stop when the workspace Git status is clean
- `--checkpoint-commits`: create a checkpoint commit after each iteration if there are changes
- `--checkpoint-tags`: create a checkpoint tag after each iteration
- `--first-agent claude|codex`: choose which agent starts each iteration
- `--claude-first`: alias for `--first-agent claude`
- `--codex-first`: alias for `--first-agent codex`
- `--resume`: continue from the current workspace and existing logs without cleaning them
- `--keep-logs`: preserve existing log files on startup
- `--keep-workspace`: preserve the existing workspace on startup
- `--non-destructive`: preserve both workspace and logs

`--resume` implies preserving both workspace and logs.

Notes on model and effort settings:

- The profile presets only affect effort defaults. They do not force a specific model.
- Explicit `--claude-effort` or `--codex-effort` overrides the profile default for that agent.
- Claude effort is passed through as the native `claude --effort` option.
- Codex effort is passed through as `codex exec -c model_reasoning_effort="..."`.

Notes on state, sessions, and stop conditions:

- The live state mirrors are always `workspace/.loop_state.md` and `workspace/.loop_state.json`.
- When `--session-name` is set, logs, handoffs, validation logs, and session copies of the state files are grouped under `logs/<session>/`.
- `--until-tests-pass` uses `--validation-command` when provided, or attempts a best-effort auto-detection of common test commands.
- `--until-checklist-complete` reads unchecked boxes from the `Success Criteria` section of `.loop_state.md`.
- `--until-clean-git` checks the workspace repo while ignoring the generated `.loop_state` files.

## Runtime output

The scripts generate temporary output in two directories:

- `workspace/`: the current generated project state, including `workspace/.loop_state.md` and `workspace/.loop_state.json`
- `logs/`: per-iteration transcripts such as `claude_iterN.log`, `codex_iterN.log`, `claude_mcp_iterN.log`, and `codex_mcp_iterN.log`
- handoff files in `logs/`: diff-aware summaries such as `claude_handoff_iterN.md`, `codex_handoff_iterN.md`, `claude_mcp_handoff_iterN.md`, and `codex_mcp_handoff_iterN.md`
- validation logs in `logs/`: files such as `validation_iterN.log`
- session state mirrors in `logs/<session>/state/` when `--session-name` is used

The terminal output also prints:

- the active task
- the workspace path
- the log directory path
- the active profile, model, and effort settings
- the active role preset and session name
- the current iteration number
- the log file paths for each completed iteration

## `pair_loop.sh` details

`pair_loop.sh` is the more straightforward version.

- Claude starts first by default, but you can switch to Codex-first with `--first-agent codex` or `--codex-first`.
- By default it starts from a fresh workspace, but `--resume` and `--non-destructive` preserve existing state.
- The first agent receives the previous handoff summary from the other agent instead of a raw log tail.
- The second agent then receives the current handoff summary from the first agent.
- Both agents are instructed to improve the same codebase incrementally and update `.loop_state.md`.

This mode is easier to reason about because all collaboration is explicit in the alternating turns.

## Agent skills

The repository now includes two lightweight agent-skill packages under [`skills/`](./skills):

| Skill | Path | What it enforces |
| --- | --- | --- |
| `claude-first-pair-loop` | [`skills/claude-first-pair-loop`](./skills/claude-first-pair-loop) | Runs `pair_loop.sh` or `pair_loop_mcp.sh` with `--claude-first` |
| `codex-first-pair-loop` | [`skills/codex-first-pair-loop`](./skills/codex-first-pair-loop) | Runs `pair_loop.sh` or `pair_loop_mcp.sh` with `--codex-first` |

Each skill contains:

- `SKILL.md`: the usage instructions and trigger guidance
- `agents/openai.yaml`: agent metadata
- `scripts/run-pair-loop.sh`: a wrapper that selects standard or MCP mode and injects the fixed first-agent flag

The wrapper scripts accept the same core flags as the underlying tools, including `--profile`, `--claude-model`, `--codex-model`, `--claude-effort`, `--codex-effort`, `--role-preset`, `--session-name`, and `--validation-command`. Pass `--mcp` to switch from standard mode to MCP mode.

## `pair_loop_mcp.sh` details

`pair_loop_mcp.sh` keeps the same outer loop, but changes what happens inside each turn.

- Claude starts first by default, but you can switch to Codex-first with `--first-agent codex` or `--codex-first`.
- Claude is expected to work directly in `workspace/` and then delegate additional work to Codex through an MCP tool.
- Codex is expected to work directly in `workspace/` and then delegate back to Claude through an MCP tool.
- The script still alternates turns, so delegation happens inside each turn rather than replacing the loop.

This mode is more powerful, but also more fragile:

- it depends on both MCP server setups working correctly
- it introduces agent-in-agent behavior that can be harder to debug
- failures may be less obvious because some work is delegated indirectly

Use this mode when you want to experiment with richer collaboration patterns, not when you need the most predictable execution path.

## Safety notes

These scripts are intentionally aggressive about cleaning state.

- By default they clean the contents of `workspace/` at startup.
- By default they clean the contents of `logs/` at startup.
- Use `--keep-workspace`, `--keep-logs`, `--non-destructive`, or `--resume` if you want to preserve existing state.
- Anything stored there should be considered disposable unless you explicitly preserve it.

Other practical caveats:

- The scripts use `set -euo pipefail`, so an unhandled command failure stops the loop.
- Claude availability checks consume a lightweight `claude -p` request because there is no equivalent local status command for account/usage.
- The shared context is now diff-aware and state-aware, but still summary-based rather than a full semantic review.
- Checkpoint commits and tags are optional and only run when you enable the relevant flags.
- MCP mode assumes the installed CLI behavior matches what the script expects.

## Troubleshooting

If a run fails, start with the generated logs under [`logs/`](./logs).

Common issues:

- `claude: command not found` or `codex: command not found`
  Install the missing CLI and ensure it is on `PATH`.

- authentication failures
  Re-authenticate the affected CLI before rerunning.

- MCP server not available in `pair_loop_mcp.sh`
  Check [`.mcp.json`](./.mcp.json), run `codex mcp list`, and confirm `npx` can launch the required packages.

- nothing useful remains in `workspace/`
  That may be expected if the run failed early or if you started a new run without a preserve flag.

- loop keeps running
  Press `Ctrl-C` to stop it.

## When to use which script

Use `pair_loop.sh` if you want:

- simpler execution
- clearer logs
- fewer moving parts

Use `pair_loop_mcp.sh` if you want:

- Claude to call Codex during Claude's turn
- Codex to call Claude during Codex's turn
- to experiment with more autonomous cross-agent workflows

## Suggested next improvements

If you plan to keep evolving these tools, the highest-value follow-ups are:

1. Add automated tests for the shell flag parsing, structured state rendering, and resume behavior.
2. Improve validation auto-detection with more ecosystems and project-specific overrides.
3. Add smarter checkpoint strategies such as branches or worktrees in addition to commits and tags.
4. Record token and cost metrics if future CLI versions expose them reliably.
5. Pin MCP package versions instead of relying on `@latest`.
