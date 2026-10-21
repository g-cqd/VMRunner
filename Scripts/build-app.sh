#!/bin/bash
# Builds build/VMRunner.app, ad-hoc signs it with the hardened runtime and the entitlements it needs, then
# verifies the result (signature, effective entitlements, architecture, hardened-runtime flag).
#
# Usage: Scripts/build-app.sh [debug|release] [--hardened] [--arm64e]
#   debug|release  build configuration (default: release)
#   --hardened     sign with Resources/VMRunner.hardened.entitlements: Apple's Enhanced Security
#                  (hardened process, hardened heap, read-only dyld state, platform restrictions v2)
#   --arm64e       build an arm64e (pointer authentication) executable instead of the default arm64,
#                  in a separate scratch path (.build-arm64e) so the default build is untouched
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="release"
hardened=0
arm64e=0

usage() {
    sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        debug | release) config="$arg" ;;
        --hardened) hardened=1 ;;
        --arm64e) arm64e=1 ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument '$arg'" >&2
            usage >&2
            exit 64
            ;;
    esac
done

app="$root/build/VMRunner.app"
entitlements="$root/Resources/VMRunner.entitlements"
if [ "$hardened" -eq 1 ]; then
    entitlements="$root/Resources/VMRunner.hardened.entitlements"
fi

build_args=(--package-path "$root" -c "$config")
if [ "$arm64e" -eq 1 ]; then
    build_args+=(--arch arm64e --scratch-path "$root/.build-arm64e")
fi

swift build "${build_args[@]}"
bin="$(swift build "${build_args[@]}" --show-bin-path)/VMRunner"

rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$bin" "$app/Contents/MacOS/VMRunner"
cp "$root/Resources/Info.plist" "$app/Contents/Info.plist"
codesign --force --sign - --options runtime --entitlements "$entitlements" "$app"

# --- verification -----------------------------------------------------------------------------------
codesign --verify --strict --deep --verbose=1 "$app"

# Effective entitlements, read back from the signed bundle, must equal the file we signed with: nothing
# added, nothing dropped, and never get-task-allow in a release build (it lets any process attach).
effective="$(codesign -d --entitlements :- "$app" 2>/dev/null | plutil -convert json -r -o - -)"
expected="$(plutil -convert json -r -o - "$entitlements")"
python3 -I - "$config" "$effective" "$expected" <<'PY'
import json
import sys

config, effective, expected = sys.argv[1], json.loads(sys.argv[2]), json.loads(sys.argv[3])
failures = []
if config == "release" and "com.apple.security.get-task-allow" in effective:
    failures.append("get-task-allow is present in a release build")
for key in sorted(set(effective) - set(expected)):
    failures.append(f"unexpected entitlement {key} = {effective[key]!r}")
for key in sorted(set(expected) - set(effective)):
    failures.append(f"missing entitlement {key}")
for key in sorted(set(expected) & set(effective)):
    if effective[key] != expected[key]:
        failures.append(f"entitlement {key} is {effective[key]!r}, expected {expected[key]!r}")
if failures:
    print("entitlement check FAILED:", file=sys.stderr)
    for failure in failures:
        print(f"  - {failure}", file=sys.stderr)
    sys.exit(1)
print("entitlements OK (" + ", ".join(sorted(effective)) + ")")
PY

# The hardened file must stay a strict superset of the default one, so --hardened never loses a capability.
python3 -I - "$(plutil -convert json -r -o - "$root/Resources/VMRunner.entitlements")" \
    "$(plutil -convert json -r -o - "$root/Resources/VMRunner.hardened.entitlements")" <<'PY'
import json
import sys

base, hardened = json.loads(sys.argv[1]), json.loads(sys.argv[2])
lost = {key for key, value in base.items() if hardened.get(key) != value}
if lost:
    print("VMRunner.hardened.entitlements drifted from VMRunner.entitlements: " + ", ".join(sorted(lost)), file=sys.stderr)
    sys.exit(1)
PY

signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
if ! grep -Eq 'flags=0x[0-9a-f]+\([^)]*runtime' <<<"$signature"; then
    echo "error: hardened runtime flag is missing from the signature" >&2
    exit 1
fi
echo "code signature: $(grep -E '^CodeDirectory' <<<"$signature" | sed 's/.*flags=/flags=/')"
echo "architecture:   $(lipo -archs "$app/Contents/MacOS/VMRunner")"
if [ "$hardened" -eq 1 ]; then
    echo "profile:        hardened (Enhanced Security entitlements)"
fi
echo "Built $app"
