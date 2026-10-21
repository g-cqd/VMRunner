#!/bin/bash
# Builds build/VMRunner.app and ad-hoc signs it with the virtualization entitlement.
# Usage: Scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
config="${1:-release}"
app="$root/build/VMRunner.app"

swift build --package-path "$root" -c "$config"
bin="$(swift build --package-path "$root" -c "$config" --show-bin-path)/VMRunner"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/VMRunner"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$root/Resources/VMRunner.entitlements" "$app"
codesign --verify --verbose=1 "$app"
echo "Built $app"
