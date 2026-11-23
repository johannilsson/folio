#!/usr/bin/env bash
# Builds everything and runs all checks: the generated design tokens, the frontend build, Rust tests, and on macOS
# the app's unit tests (FolioKit) and its self-test.
# Runs every step even if one fails, then reports a summary.
# Usage: scripts/verify.sh [--skip-macos] [--changed [<base>]]
#   --changed runs only what the files changed since <base> (default origin/main) can affect; anything it
#   does not recognise, or a base it cannot find, runs everything. See docs/development.md.
cd "$(dirname "$0")/.."

# What to run. Everything, unless --changed narrows it.
run_frontend=1 run_rust=1 run_macos_build=1 run_swift_tests=1 run_selftest=1
areas=""   # a comma-separated list for the self-test's --only; empty means all of it

args=" $* "
if [[ "$args" == *" --changed"* ]]; then
  base=origin/main
  for a in "$@"; do [[ $a != --* ]] && base=$a; done
  if changed=$(git diff --name-only "$(git merge-base "$base" HEAD 2>/dev/null)" 2>/dev/null) && [[ -n $changed ]]; then
    run_frontend=0 run_rust=0 run_macos_build=0 run_swift_tests=0 run_selftest=0
    add_area() { [[ ",$areas," == *",$1,"* ]] || areas="${areas:+$areas,}$1"; }
    full() { run_frontend=1 run_rust=1 run_macos_build=1 run_swift_tests=1 run_selftest=1 areas=""; }
    while IFS= read -r f; do
      case "$f" in
        docs/*|*.md|examples/*|LICENSE*|.github/*) ;;
        src/*|Cargo.toml|Cargo.lock)
          run_rust=1 run_macos_build=1 run_swift_tests=1 run_selftest=1
          for a in annotations inline sets wiki items; do add_area $a; done ;;
        frontend/*) run_frontend=1 run_macos_build=1 run_selftest=1; add_area preview ;;
        macos/Sources/FolioKit/*|macos/Tests/*) run_macos_build=1 run_swift_tests=1 ;;
        macos/Sources/Folio/SelfTest/SelfTest+Preview*|macos/Sources/Folio/SelfTest/SelfTest+MCP.swift|macos/Sources/Folio/Preview/*)
          run_macos_build=1 run_selftest=1; add_area preview ;;
        macos/Sources/Folio/SelfTest/SelfTest+Source.swift) run_macos_build=1 run_selftest=1; add_area source ;;
        macos/Sources/Folio/SelfTest/SelfTest+Scrolling.swift) run_macos_build=1 run_selftest=1; add_area scrolling ;;
        macos/Sources/Folio/SelfTest/SelfTest+Annotations.swift) run_macos_build=1 run_selftest=1; add_area annotations ;;
        macos/Sources/Folio/SelfTest/SelfTest+Inline.swift) run_macos_build=1 run_selftest=1; add_area inline ;;
        macos/Sources/Folio/SelfTest/SelfTest+Sets.swift) run_macos_build=1 run_selftest=1; add_area sets ;;
        macos/Sources/Folio/SelfTest/SelfTest+Wiki.swift) run_macos_build=1 run_selftest=1; add_area wiki; add_area items ;;
        macos/Sources/Folio/SelfTest/SelfTest+Welcome.swift) run_macos_build=1 run_selftest=1; add_area welcome ;;
        *) full; break ;;
      esac
    done <<< "$changed"
    echo "▸ --changed: frontend=$run_frontend rust=$run_rust macos-build=$run_macos_build swift-tests=$run_swift_tests self-test=${run_selftest}${areas:+ ($areas)}"
  else
    echo "▸ --changed: no base to compare with, running everything"
  fi
fi

failed=()
step() {
  local name=$1; shift
  echo "▸ $name"
  "$@" || failed+=("$name")
}

step "design tokens" node scripts/tokens.mjs --check
((run_frontend)) && step "frontend build" bash -c 'cd frontend && pnpm build'
if ((run_rust)); then
  step "rust build" cargo build
  step "rust tests" cargo test
fi
# A Windows client calls the engine as a DLL. Not a crate type in Cargo.toml: next to libfolio.a,
# a libfolio.dylib would be what the macOS app links.
if ((run_rust)) && [[ "$OS" == "Windows_NT" ]]; then
  step "windows dll" cargo rustc --release --lib --crate-type cdylib
fi
# The macOS app opens real windows, so it needs a logged-in desktop session.
if [[ "$(uname)" == "Darwin" && " $* " != *" --skip-macos "* ]]; then
  ((run_macos_build)) && step "macos build" bash -c 'cargo build --release && swift build --package-path macos'
  ((run_swift_tests)) && step "macos unit tests" swift test --package-path macos
  ((run_selftest)) && step "macos self-test" macos/.build/debug/Folio --self-test ${areas:+--only "$areas"} macos/selftest.md
fi

if ((${#failed[@]})); then
  echo "✗ failed: ${failed[*]}"
  exit 1
fi
echo "✓ all checks passed"
