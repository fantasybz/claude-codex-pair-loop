# Security Policy

## Reporting a Vulnerability

Please do not open a public GitHub issue for security-sensitive findings.

Instead:

- use GitHub's private vulnerability reporting for this repository if it is enabled
- or contact the repository owner directly through GitHub before public disclosure

Include as much of the following as possible:

- affected script, flag, or workflow
- impact and attack scenario
- reproduction steps
- environment details such as OS, shell, CLI versions, and whether MCP mode was involved
- any relevant logs with secrets removed

## Security-Relevant Areas

This project is especially sensitive in these areas:

- shell command execution
- filesystem cleanup and deletion behavior
- Git automation such as checkpoint commits and tags
- local authentication state for `claude` and `codex`
- MCP dependencies launched through `npx`
- log files, handoff files, and generated state that may contain sensitive content

## Supported Versions

| Version | Supported |
| --- | --- |
| `main` | Yes |
| older commits and forks | Best effort only |

## Disclosure Expectations

- Please allow reasonable time to investigate and prepare a fix before public disclosure.
- If the issue depends on upstream CLI or MCP behavior, remediation may require coordination outside this repository.
