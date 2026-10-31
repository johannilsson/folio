#!/usr/bin/env bash
# The Windows client's checks, the way CI runs them (.github/workflows/windows.yml): builds the engine as a DLL
# (a shared library elsewhere), the CLI and the diagram page, then the .NET projects and their tests. On Windows it then drives
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

# Not a crate type in Cargo.toml, and built in a target folder of its own: next to the macOS app's libfolio.a in
# target/release, a libfolio.dylib would be what the app links.
step "engine library" cargo rustc --release --lib --crate-type cdylib --target-dir target/cdylib
step "cli" cargo build
exe=folio; [[ "$OS" == "Windows_NT" ]] && exe=folio.exe
export FOLIO_CLI="$PWD/target/debug/$exe"
# Sets made by the tests and the self-test go to a throwaway folder, not the real ~/.config/folio.
export FOLIO_CONFIG_DIR="$(mktemp -d)"

# The diagram page, which the app's build copies next to it (its dependencies installed with pnpm install).
step "frontend" bash -c 'cd frontend && pnpm build'
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
