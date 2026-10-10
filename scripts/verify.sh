#!/usr/bin/env bash
# Builds everything and runs all checks: Rust tests, frontend unit tests, e2e.
# Runs every step even if one fails, then reports a summary.
# Usage: scripts/verify.sh [--skip-e2e]
cd "$(dirname "$0")/.."

failed=()
step() {
  local name=$1; shift
  echo "▸ $name"
  "$@" || failed+=("$name")
}

step "frontend build" bash -c 'cd frontend && pnpm build'
touch src/main.rs
export FOLIO_SKIP_FRONTEND_BUILD=1
step "rust build" cargo build
step "rust tests" cargo test
step "frontend unit tests" bash -c 'cd frontend && pnpm test'
if [[ "${1:-}" != "--skip-e2e" ]]; then
  step "e2e" bash -c 'cd frontend && pnpm e2e'
fi

if ((${#failed[@]})); then
  echo "✗ failed: ${failed[*]}"
  exit 1
fi
echo "✓ all checks passed"
