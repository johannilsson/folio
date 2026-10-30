#!/usr/bin/env bash
# The Windows client's checks, the way CI runs them (.github/workflows/windows.yml): builds the engine as a DLL
# (a shared library elsewhere) and the CLI, then the .NET projects and their tests. On Windows it then drives
# the real app with its --self-test. Everywhere else the WPF project is only compiled, since it cannot run.
# Runs every step even if one fails, then reports a summary.
# Usage: windows/verify.sh
cd "$(dirname "$0")/.."

failed=()
step() {
  local name=$1; shift
  echo "▸ $name"
  "$@" || failed+=("$name")
}

# Not a crate type in Cargo.toml: next to libfolio.a, a libfolio.dylib would be what the macOS app links.
step "engine library" cargo rustc --release --lib --crate-type cdylib
step "cli" cargo build
exe=folio; [[ "$OS" == "Windows_NT" ]] && exe=folio.exe
export FOLIO_CLI="$PWD/target/debug/$exe"

step "build" dotnet build windows/Folio.Windows.sln --nologo
step "unit tests" dotnet test windows/Folio.Core.Tests --nologo --no-build

if [[ "$OS" == "Windows_NT" ]]; then
  step "app self-test" bash windows/self-test.sh
fi

if ((${#failed[@]})); then
  echo "✗ failed: ${failed[*]}"
  exit 1
fi
echo "✓ all checks passed"
