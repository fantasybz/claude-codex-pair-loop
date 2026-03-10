---
name: codex-first-pair-loop
description: Run the local Claude Code and Codex pair-loop tools from this repository with Codex taking the first turn. Use when Codex should start, resume, or continue an iterative pair-programming loop for a coding task, and the desired turn order is Codex-first. Supports both standard mode and MCP mode, plus preserve and resume flags.
---

# Codex-First Pair Loop

## Overview

Launch the repository pair-loop scripts with the turn order fixed to Codex-first. Prefer this skill when the user wants Codex to lead each iteration and Claude Code to respond second.

## Workflow

1. Verify that the repository still contains `pair_loop.sh` and `pair_loop_mcp.sh` at the project root.
2. Choose the mode:
   - Use standard mode unless the user explicitly asks for MCP delegation.
   - Use MCP mode only when both MCP dependencies are expected to be available.
3. Prefer preserving state:
   - Use `--resume` to continue an existing run.
   - Use `--non-destructive` when the user wants to keep current `workspace/` and `logs/`.
   - Only start destructive fresh runs when the user clearly wants a clean reset.
   - Use `--profile`, `--claude-model`, `--codex-model`, `--claude-effort`, and `--codex-effort` when the user wants explicit model or reasoning control.
   - Use `--role-preset`, `--session-name`, `--validation-command`, stop-condition flags, and checkpoint flags when the user wants tighter run orchestration.
4. Launch the wrapper script in `scripts/run-pair-loop.sh`.
5. Inspect the generated logs and handoff files after the run if the user asks for results or debugging.

## Commands

Use the wrapper script so the skill always enforces Codex-first order.

Standard mode:

```bash
./skills/codex-first-pair-loop/scripts/run-pair-loop.sh --task "Build a CLI tool" --max-iterations 3
```

MCP mode:

```bash
./skills/codex-first-pair-loop/scripts/run-pair-loop.sh --mcp --task "Build a CLI tool" --max-iterations 3
```

Resume mode:

```bash
./skills/codex-first-pair-loop/scripts/run-pair-loop.sh --resume --task "Continue the current project"
```

Explicit model and effort control:

```bash
./skills/codex-first-pair-loop/scripts/run-pair-loop.sh --profile deep --claude-model sonnet --codex-model gpt-5.3-codex --codex-effort xhigh --session-name hardening-pass --task "Continue the current project"
```

## Notes

- The wrapper script automatically adds `--codex-first`.
- Use the companion `claude-first-pair-loop` skill when the user wants Claude Code to lead instead.
- The underlying repository scripts handle `--workspace`, `--log-dir`, `--profile`, `--claude-model`, `--codex-model`, `--claude-effort`, `--codex-effort`, `--role-preset`, `--session-name`, `--validation-command`, `--until-tests-pass`, `--until-checklist-complete`, `--until-clean-git`, `--checkpoint-commits`, `--checkpoint-tags`, `--resume`, `--keep-logs`, `--keep-workspace`, and `--non-destructive`.
