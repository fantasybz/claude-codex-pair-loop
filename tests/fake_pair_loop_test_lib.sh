#!/usr/bin/env bash

die() {
  echo "error: $*" >&2
  exit 1
}

make_fake_bin() {
  local fake_bin="$1"
  local real_node

  real_node="$(command -v node)"
  [ -n "$real_node" ] || die "node is required to run the state renderer"

  mkdir -p "$fake_bin"

  cat > "$fake_bin/fake_agent_common.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

extract_iteration() {
  printf '%s\n' "$1" | tr '\n' ' ' | sed -n 's/.*iteration \([0-9][0-9]*\).*/\1/p' | head -n 1
}

mark_success_criteria() {
  local workdir="$1"
  local state_file="$workdir/.loop_state.md"
  [ -f "$state_file" ] || return 0
  perl -0pi -e 's/^- \[ \]/- [x]/mg' "$state_file"
}

ensure_git_identity() {
  local workdir="$1"
  git -C "$workdir" config user.name "fake-agent" >/dev/null 2>&1 || true
  git -C "$workdir" config user.email "fake-agent@example.com" >/dev/null 2>&1 || true
}

perform_fake_turn() {
  local agent="$1"
  local workdir="$2"
  local prompt="$3"
  local scenario iteration

  scenario="${PAIR_LOOP_FAKE_SCENARIO:-default}"
  iteration="$(extract_iteration "$prompt")"
  [ -n "$iteration" ] || iteration="0"

  mkdir -p "$workdir"

  case "$scenario" in
    default|smoke)
      printf 'smoke test\n' > "$workdir/smoke.txt"
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/${agent}-iter-${iteration}.txt"
      mark_success_criteria "$workdir"
      ;;
    resume)
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/${agent}-iter-${iteration}.txt"
      ;;
    checklist)
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/checklist-${agent}.txt"
      mark_success_criteria "$workdir"
      ;;
    clean-git)
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/clean-git.txt"
      ensure_git_identity "$workdir"
      git -C "$workdir" add -A >/dev/null 2>&1 || true
      git -C "$workdir" commit -m "fake clean git ${iteration}" >/dev/null 2>&1 || true
      ;;
    checkpoint)
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/checkpoint-${agent}-${iteration}.txt"
      ;;
    timeout-codex)
      if [ "$agent" = "codex" ]; then
        sleep "${PAIR_LOOP_FAKE_SLEEP_SECONDS:-3}"
      fi
      printf '%s iteration %s\n' "$agent" "$iteration" > "$workdir/${agent}-iter-${iteration}.txt"
      ;;
    *)
      echo "unknown fake scenario: $scenario" >&2
      exit 1
      ;;
  esac
}
EOF
  chmod +x "$fake_bin/fake_agent_common.sh"

  cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/fake_agent_common.sh"

prompt="${*: -1}"
if printf '%s\n' "$prompt" | grep -q "Reply with exactly: OK"; then
  echo "OK"
  exit 0
fi

perform_fake_turn "claude" "$PWD" "$prompt"
echo "model: claude-runtime-sonnet"
echo "effort: high"
echo "OK"
EOF
  chmod +x "$fake_bin/claude"

  cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$script_dir/fake_agent_common.sh"

case "${1:-}" in
  login)
    [ "${2:-}" = "status" ] || exit 1
    exit 0
    ;;
  mcp)
    case "${2:-}" in
      list)
        echo "claude-code connected"
        exit 0
        ;;
      add)
        exit 0
        ;;
    esac
    ;;
  exec)
    workdir="$PWD"
    prompt=""
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -C|--model|-c)
          [ "$#" -ge 2 ] || exit 1
          if [ "$1" = "-C" ]; then
            workdir="$2"
          fi
          shift 2
          ;;
        --full-auto)
          shift
          ;;
        *)
          prompt="$1"
          shift
          ;;
      esac
    done
    [ -n "$prompt" ] || exit 1
    perform_fake_turn "codex" "$workdir" "$prompt"
    echo "model: codex-runtime-gpt5"
    echo "reasoning effort: xhigh"
    echo "OK"
    exit 0
    ;;
esac

exit 1
EOF
  chmod +x "$fake_bin/codex"

  cat > "$fake_bin/node" <<EOF
#!/usr/bin/env bash
set -euo pipefail
"$real_node" "\$@"
EOF
  chmod +x "$fake_bin/node"

  cat > "$fake_bin/npx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$fake_bin/npx"
}
