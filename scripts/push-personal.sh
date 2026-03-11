#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)"
REMOTE_NAME="${PUSH_PERSONAL_REMOTE:-personal}"
DEFAULT_USERNAME="${PUSH_PERSONAL_USERNAME:-fantasybz}"

die() {
  echo "error: $*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bash scripts/push-personal.sh [branch]

Push the selected branch to the repo-local `personal` remote using the
PAT-compatible HTTPS flow, while bypassing the global GitHub HTTPS->SSH rewrite.

Environment overrides:
  PUSH_PERSONAL_REMOTE      Remote name to use (default: personal)
  PUSH_PERSONAL_USERNAME    GitHub username for PAT auth (default: fantasybz)
EOF
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

cd "$ROOT_DIR"

if ! git remote get-url "$REMOTE_NAME" >/dev/null 2>&1; then
  die "remote '$REMOTE_NAME' does not exist"
fi

branch="${1:-$(git branch --show-current)}"
[ -n "$branch" ] || die "could not determine branch; pass one explicitly"

push_url="$(GIT_CONFIG_GLOBAL=/dev/null git remote get-url --push "$REMOTE_NAME" 2>/dev/null || true)"
[ -n "$push_url" ] || die "could not resolve push URL for remote '$REMOTE_NAME'"

echo "[push-personal] remote: $REMOTE_NAME"
echo "[push-personal] branch: $branch"
echo "[push-personal] push URL: $push_url"

exec env -u GIT_ASKPASS -u SSH_ASKPASS \
  GIT_CONFIG_GLOBAL=/dev/null \
  git \
    -c credential.helper= \
    -c credential.username="$DEFAULT_USERNAME" \
    push "$REMOTE_NAME" "$branch"
