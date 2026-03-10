#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"

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

  cat > "$fake_bin/claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "OK"
EOF
  chmod +x "$fake_bin/claude"

  cat > "$fake_bin/codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

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

assert_no_iteration_three() {
  local log_dir="$1"

  if find "$log_dir" -type f -name '*iter3*' | grep -q .; then
    die "unexpected iteration 3 artifacts in $log_dir"
  fi
}

assert_iteration_two_exists() {
  local log_dir="$1"

  if ! find "$log_dir" -type f -name '*iter2*' | grep -q .; then
    die "missing iteration 2 artifacts in $log_dir"
  fi
}

run_case() {
  local script_name="$1"
  local tmp_dir fake_bin workspace log_dir

  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/pairloop-parse-testXXXXXX")"
  fake_bin="$tmp_dir/bin"
  workspace="$tmp_dir/workspace"
  log_dir="$tmp_dir/logs"

  make_fake_bin "$fake_bin"

  (
    cd "$ROOT_DIR"
    PATH="$fake_bin:$PATH" "./$script_name" \
      --non-destructive \
      --workspace "$workspace" \
      --log-dir "$log_dir" \
      --task "parser regression" \
      2 \
      > "$tmp_dir/${script_name}.out" 2>&1
  )

  assert_iteration_two_exists "$log_dir"
  assert_no_iteration_three "$log_dir"

  rm -rf "$tmp_dir"
}

run_case "pair_loop.sh"
run_case "pair_loop_mcp.sh"

echo "positional argument regression checks passed"
