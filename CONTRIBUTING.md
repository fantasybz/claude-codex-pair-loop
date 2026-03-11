# Contributing

Thanks for considering a contribution.

This repository is a local automation tool for coordinating Claude Code and Codex against the same workspace. Good changes are usually small, well-scoped, and backed by deterministic regression coverage.

## Before You Start

- Open an issue or discussion first for larger feature ideas, behavior changes, or workflow changes.
- Keep generated runtime artifacts out of commits. `workspace/` and `logs/` are disposable runtime directories.
- Do not include local auth state, tokens, or screenshots that expose secrets.

## Development Workflow

1. Make the smallest change that fully solves the problem.
2. Update documentation when flags, defaults, artifacts, or behavior change.
3. Add or update regression coverage in `tests/` for new flags, state fields, lifecycle changes, or failure handling.
4. Run the deterministic local checks before opening a PR:

```bash
bash scripts/local-ci.sh deterministic
```

## Pull Request Guidelines

- Keep each PR focused on one behavior change, one refactor, or one documentation improvement.
- Explain the user-visible behavior change clearly in the PR description.
- Mention what you tested locally.
- Include example commands, logs, or state-file changes when they help reviewers understand the impact.

## Project-Specific Expectations

- Preserve the distinction between generated workspace content and runner-owned log/state artifacts.
- Prefer regression tests for runner behavior over ad hoc manual verification.
- Be careful with cleanup behavior, Git side effects, and anything that could make debugging harder after a failed run.
- When changing MCP behavior, document any new external dependency, version assumption, or network requirement.
