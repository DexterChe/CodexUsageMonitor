#!/bin/bash
set -euo pipefail
refresh_widget_host=false
case "${1:-}" in
  '') ;;
  --refresh-widget-host) refresh_widget_host=true ;;
  *) echo 'Usage: install-local.sh [--refresh-widget-host]'; exit 2 ;;
esac
project_root="$(cd "$(dirname "$0")/.." && pwd)"
build_root="${CODEX_BUILD_DIR:-$project_root/build}"
app="$build_root/Build/Products/Release/CodexUsageMonitor.app"
install_dir="${CODEX_INSTALL_DIR:-$HOME/Applications}"
destination="$install_dir/CodexUsageMonitor.app"
if [ ! -d "$app" ]; then
  echo 'Build first: bash Scripts/build-local.sh Release'
  exit 1
fi
if pgrep -f "$destination/Contents/MacOS/CodexUsageMonitor" >/dev/null; then
  echo 'Quit CodexUsageMonitor before replacing the installed app.'
  exit 1
fi
mkdir -p "$install_dir"
if [ -L "$destination" ]; then
  echo 'Refusing to replace a symbolic-link destination.'
  exit 1
fi
codesign --verify --deep --strict "$app"
if [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" != 'com.dexterche.CodexUsageMonitor' ]; then
  echo 'Unexpected application bundle identifier.'
  exit 1
fi
staging="$(mktemp -d "$install_dir/.CodexUsageMonitor-install.XXXXXX")"
installed=false
restore_installation() {
  if [ "$installed" = false ] && [ -d "$staging/previous.app" ]; then
    if [ -e "$destination" ]; then rm -rf "$destination"; fi
    mv "$staging/previous.app" "$destination"
  fi
  rm -rf "$staging"
}
trap restore_installation EXIT
ditto "$app" "$staging/new.app"
codesign --verify --deep --strict "$staging/new.app"
for configuration in Debug Release; do
  temporary_app="$build_root/Build/Products/$configuration/CodexUsageMonitor.app"
  if [ -d "$temporary_app" ]; then
    pluginkit -r "$temporary_app/Contents/PlugIns/CodexUsageWidget.appex" || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
      -u "$temporary_app" || true
  fi
done
# Replace the whole verified bundle rather than merging stale executable files.
if [ -e "$destination" ]; then mv "$destination" "$staging/previous.app"; fi
mv "$staging/new.app" "$destination"
pluginkit -a "$destination/Contents/PlugIns/CodexUsageWidget.appex"
if [ "$refresh_widget_host" = true ]; then
  # Explicit recovery for launchd retaining a development extension path.
  # Restarts the current user's widget host; no widget preferences are deleted.
  killall -u "$(id -un)" chronod 2>/dev/null || true
fi
open "$destination"
installed=true
echo "Installed: $destination"
