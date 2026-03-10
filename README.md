# Claude Code <-> Codex Pair Tools

This README documents only the two launcher scripts in this repository:

- [`pair_loop.sh`](./pair_loop.sh) runs a simple alternating turn-based loop.
- [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) runs a more experimental loop where each agent can also delegate back to the other through MCP during its turn.

The checked-in [`workspace/`](./workspace) and [`logs/`](./logs) directories are sample artifacts from an MCP trial. They are output examples, not part of the tool implementation.

## What each script does

| Script | Mode | Best for |
| --- | --- | --- |
| `pair_loop.sh` | Alternating CLI turns | Simpler, easier-to-debug pair runs |
| `pair_loop_mcp.sh` | Alternating CLI turns plus cross-agent MCP delegation | Experiments where each agent should be able to call the other mid-turn |

## How the loop works

At startup, both scripts now do the following:

1. Parse flags such as `--workspace`, `--log-dir`, `--resume`, `--keep-logs`, and `--non-destructive`.
2. Run up-front health checks for Claude, Codex, Node.js, and MCP availability.
3. Clean or preserve `workspace/` and `logs/` based on the selected flags.
4. Ensure the workspace is a Git repository because Codex expects one.
5. Create or reuse `workspace/.loop_state.md`.

During each iteration:

1. The scripts perform a lightweight availability check for both agents.
2. Claude takes a turn and writes a transcript to `logs/`, or the turn is skipped if Claude is unavailable.
3. Codex takes a turn and writes a transcript to `logs/`, or the turn is skipped if Codex is unavailable.
4. After each turn, the script writes a diff-aware handoff summary for the next agent.
5. The loop pauses briefly, then continues until it reaches `max_iterations` or you stop it with `Ctrl-C`.

The handoff is now diff-aware instead of log-tail based. Each turn compares the workspace before and after the agent run, writes a file-change summary, includes current Git status, and carries forward the latest `.loop_state.md` tail.

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
- `--resume`: continue from the current workspace and existing logs without cleaning them
- `--keep-logs`: preserve existing log files on startup
- `--keep-workspace`: preserve the existing workspace on startup
- `--non-destructive`: preserve both workspace and logs

`--resume` implies preserving both workspace and logs.

## Runtime output

The scripts generate temporary output in two directories:

- `workspace/`: the current generated project state, including `workspace/.loop_state.md`
- `logs/`: per-iteration transcripts such as `claude_iterN.log`, `codex_iterN.log`, `claude_mcp_iterN.log`, and `codex_mcp_iterN.log`
- handoff files in `logs/`: diff-aware summaries such as `claude_handoff_iterN.md`, `codex_handoff_iterN.md`, `claude_mcp_handoff_iterN.md`, and `codex_mcp_handoff_iterN.md`

The terminal output also prints:

- the active task
- the workspace path
- the log directory path
- the current iteration number
- the log file paths for each completed iteration

## `pair_loop.sh` details

`pair_loop.sh` is the more straightforward version.

- Claude always goes first.
- By default it starts from a fresh workspace, but `--resume` and `--non-destructive` preserve existing state.
- Claude receives the previous Codex handoff summary instead of a raw log tail.
- Codex then receives the current Claude handoff summary.
- Both agents are instructed to improve the same codebase incrementally and update `.loop_state.md`.

This mode is easier to reason about because all collaboration is explicit in the alternating turns.

## `pair_loop_mcp.sh` details

`pair_loop_mcp.sh` keeps the same outer loop, but changes what happens inside each turn.

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
- The checked-in contents currently visible in those folders are only sample output from a prior MCP experiment.
- Use `--keep-workspace`, `--keep-logs`, `--non-destructive`, or `--resume` if you want to preserve existing state.
- Anything stored there should be considered disposable unless you explicitly preserve it.

Other practical caveats:

- The scripts use `set -euo pipefail`, so an unhandled command failure stops the loop.
- Claude availability checks consume a lightweight `claude -p` request because there is no equivalent local status command for account/usage.
- The shared context is now diff-aware, but still summary-based rather than a full semantic review.
- There is no branch management, commit choreography, or checkpointing beyond the files left in `workspace/`.
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

1. Add automated tests for the shell flag parsing and resume behavior.
2. Make the diff-aware handoff smarter by grouping changes by feature or file type.
3. Add a dedicated `--session-name` or run-id flag so preserved logs can be grouped more cleanly.
4. Add stricter validation for custom workspace/log directory combinations.
5. Pin MCP package versions instead of relying on `@latest`.
