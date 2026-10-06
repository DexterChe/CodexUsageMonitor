#!/bin/bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Use Debug or Release'; exit 2 ;; esac
build_root="${CODEX_BUILD_DIR:-$project_root/build}"

xcodebuild -project "$project_root/CodexUsageMonitor.xcodeproj" \
  -scheme CodexUsageMonitor -configuration "$configuration" \
  -destination 'platform=macOS' -derivedDataPath "$build_root" \
  CODE_SIGNING_ALLOWED=NO build

temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT
for component in App Widget; do
  cp "$project_root/Configuration/$component.entitlements" "$temporary/$component.plist"
done
app="$build_root/Build/Products/$configuration/CodexUsageMonitor.app"
codesign --force --sign - --options runtime --entitlements "$temporary/Widget.plist" \
  "$app/Contents/PlugIns/CodexUsageWidget.appex"
codesign --force --sign - --options runtime --entitlements "$temporary/App.plist" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "Local ad-hoc build: $app"
echo 'Run --self-check and verify the installed widget separately.'
