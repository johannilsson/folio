#!/usr/bin/env bash
# Builds everything and runs all checks: the generated design tokens, the frontend build, Rust tests, and on macOS
# the app's unit tests (FolioKit) and its self-test.
# Runs every step even if one fails, then reports a summary.
# Usage: scripts/verify.sh [--skip-macos]
cd "$(dirname "$0")/.."

failed=()
step() {
  local name=$1; shift
  echo "▸ $name"
  "$@" || failed+=("$name")
}

step "design tokens" node scripts/tokens.mjs --check
step "frontend build" bash -c 'cd frontend && pnpm build'
step "rust build" cargo build
step "rust tests" cargo test
# A Windows client calls the engine as a DLL. Not a crate type in Cargo.toml: next to libfolio.a,
# a libfolio.dylib would be what the macOS app links.
if [[ "$OS" == "Windows_NT" ]]; then
  step "windows dll" cargo rustc --release --lib --crate-type cdylib
fi
# The macOS app opens real windows, so it needs a logged-in desktop session.
if [[ "$(uname)" == "Darwin" && " $* " != *" --skip-macos "* ]]; then
  step "macos build" bash -c 'cargo build --release && swift build --package-path macos'
  step "macos unit tests" swift test --package-path macos
  step "macos self-test" macos/.build/debug/Folio --self-test macos/selftest.md
fi

if ((${#failed[@]})); then
  echo "✗ failed: ${failed[*]}"
  exit 1
fi
echo "✓ all checks passed"
