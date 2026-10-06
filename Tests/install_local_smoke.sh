#!/bin/bash
set -euo pipefail
if [ $# -ne 1 ]; then
  echo 'Usage: bash Tests/install_local_smoke.sh /absolute/DerivedData'
  exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="$1"
case "$build_root" in /*) ;; *) echo 'Use an absolute DerivedData path'; exit 2 ;; esac
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/install/CodexUsageMonitor.app"
printf 'previous version\n' > "$scratch/install/CodexUsageMonitor.app/marker"
cat > "$scratch/bin/pluginkit" <<'STUB'
#!/bin/sh
exit 0
STUB
cat > "$scratch/bin/open" <<'STUB'
#!/bin/sh
exit 1
STUB
chmod 700 "$scratch/bin/open" "$scratch/bin/pluginkit"
if CODEX_INSTALL_DIR="$scratch/install" CODEX_BUILD_DIR="$build_root" \
   PATH="$scratch/bin:$PATH" bash "$project_root/Scripts/install-local.sh" > "$scratch/result.log" 2>&1; then
  echo 'Expected the simulated open failure'
  exit 1
fi
test "$(cat "$scratch/install/CodexUsageMonitor.app/marker")" = 'previous version'
test "$(find "$scratch/install" -maxdepth 1 -name '.CodexUsageMonitor-install.*' | wc -l | tr -d ' ')" = 0
rm -r "$scratch/install/CodexUsageMonitor.app"
ln -s "$scratch/install/elsewhere" "$scratch/install/CodexUsageMonitor.app"
if CODEX_INSTALL_DIR="$scratch/install" CODEX_BUILD_DIR="$build_root" \
   PATH="$scratch/bin:$PATH" bash "$project_root/Scripts/install-local.sh" > "$scratch/result.log" 2>&1; then
  echo 'Expected the destination symlink to be rejected'
  exit 1
fi
test -L "$scratch/install/CodexUsageMonitor.app"
echo 'PASS: prior bundle restored on installation failure; destination symlink rejected'
