# Claude Code <-> Codex Pair Tools

This README documents only the two launcher scripts in this repository:

- [`pair_loop.sh`](./pair_loop.sh) runs a simple alternating turn-based loop.
- [`pair_loop_mcp.sh`](./pair_loop_mcp.sh) runs a more experimental loop where each agent can also delegate back to the other through MCP during its turn.

The checked-in [`workspace/`](./workspace) and [`logs/`](./logs) directories are sample artifacts from an MCP trial. They are output examples, not part of the tool implementation. Both scripts treat those directories as disposable and wipe them at the beginning of a new run.

## What each script does

| Script | Mode | Best for |
| --- | --- | --- |
| `pair_loop.sh` | Alternating CLI turns | Simpler, easier-to-debug pair runs |
| `pair_loop_mcp.sh` | Alternating CLI turns plus cross-agent MCP delegation | Experiments where each agent should be able to call the other mid-turn |

## How the loop works

At startup, both scripts do the same base setup:

1. Delete existing contents under `workspace/` and `logs/`.
2. Recreate those directories.
3. Initialize a fresh Git repository inside `workspace/` because Codex expects one.
4. Write `workspace/.loop_state.md` to track task history between turns.

During each iteration:

1. Claude takes a turn and writes a transcript to `logs/`.
2. Codex takes a turn and writes a transcript to `logs/`.
3. The loop pauses briefly, then continues until it reaches `max_iterations` or you stop it with `Ctrl-C`.

The scripts pass a lightweight summary between agents by taking the last 80 lines of the previous agent log. This is simple and transparent, but it is not a robust state-sharing mechanism. Important context can be lost if the log is noisy.

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

Arguments:

- First argument: task description passed to both agents.
- Second argument: maximum number of iterations.

If you omit the task, each script falls back to its built-in default Python CLI prompt.

If you omit `max_iterations`, both scripts default to `999999`, which is effectively "run until stopped".

## Runtime output

The scripts generate temporary output in two directories:

- `workspace/`: the current generated project state, including `workspace/.loop_state.md`
- `logs/`: per-iteration transcripts such as `claude_iterN.log`, `codex_iterN.log`, `claude_mcp_iterN.log`, and `codex_mcp_iterN.log`

The terminal output also prints:

- the active task
- the workspace path
- the current iteration number
- the log file paths for each completed iteration

## `pair_loop.sh` details

`pair_loop.sh` is the more straightforward version.

- Claude always goes first.
- On iteration 1, Claude starts from the task plus an empty workspace.
- On later iterations, Claude receives the tail of the previous Codex log.
- Codex then receives the tail of the current Claude log.
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

- They delete the contents of `workspace/` at the start of every run.
- They delete the contents of `logs/` at the start of every run.
- The checked-in contents currently visible in those folders are only sample output from a prior MCP experiment.
- Anything stored there should be considered disposable unless you copy it elsewhere first.

Other practical caveats:

- The scripts use `set -euo pipefail`, so an unhandled command failure stops the loop.
- The shared context is based on log tails, not diffs or structured state.
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
  That may be expected if the run failed early or if you started a new run, because startup cleanup is destructive.

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

1. Add a non-destructive mode that preserves `workspace/` and `logs/`.
2. Replace log-tail handoff with a diff-aware summary.
3. Add argument parsing for flags such as `--workspace`, `--resume`, and `--keep-logs`.
4. Add a `.gitignore` for generated logs and disposable workspace output.
5. Add health checks up front for `claude`, `codex`, `node`, and MCP availability.
