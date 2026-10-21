#!/bin/bash
# Runs the g-cqd static analyzers over Sources and Tests, using the exact releases pinned in
# Scripts/analyzers.lock (downloaded once into .tools/ and verified against a pinned SHA-256).
#
#   arcleak    retain cycles, anchor leaks and premature releases (ARC)   gate: --strict
#   dolly      duplicate code: exact, near and structural clones          gate: exact-clone only (.dolly.json)
#   deadwood   unreferenced declarations and provably dead branches       gate: --strict, production mode
#
# Usage: Scripts/analyzers.sh [run|install|baseline|versions|pins] [tool...]
#   run       (default) analyze; PASS/FAIL per tool, exit 1 if any tool failed
#   install   download and verify the pinned releases without running them
#   baseline  accept the current findings of dolly and deadwood (or the named tools) into
#             .<tool>-baseline.json, so only NEW findings fail the gate; commit the result
#   versions  print the pinned versions
#   pins      check that .github/workflows/ci.yml pins the same releases as analyzers.lock
#
# Configuration: .arcleak.json, .dolly.json, .deadwood.json. Baselines: .<tool>-baseline.json (optional).
# Environment: ARCLEAK_BIN / DOLLY_BIN / DEADWOOD_BIN use your own binary instead of the pinned download
#              (for example a build of a newer analyzer); ANALYZERS_DIR moves the download directory.
#
# Exit codes of the analyzers themselves: 1 = findings, 64 = usage, 70 = nothing analyzed, 74 = write error,
# 78 = bad configuration or baseline. Only 1 means "the code has findings"; the others mean the gate is broken.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# shellcheck source=Scripts/analyzers.lock
source "$root/Scripts/analyzers.lock"

all_tools=(arcleak dolly deadwood)
tools_dir="${ANALYZERS_DIR:-$root/.tools}"
cache_dir="$root/.build-analyzers"
scratch=""

usage() {
    sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

cleanup() {
    if [ -n "$scratch" ]; then
        rm -rf "$scratch"
    fi
}
trap cleanup EXIT

die() {
    echo "error: $*" >&2
    exit 1
}

# pin <tool> <FIELD>: reads <TOOL>_<FIELD> from analyzers.lock.
pin() {
    local name
    name="$(printf '%s_%s' "$1" "$2" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${!name}"
}

# bin_override <tool>: the <TOOL>_BIN environment override, or empty.
bin_override() {
    local name
    name="$(printf '%s_BIN' "$1" | tr '[:lower:]' '[:upper:]')"
    printf '%s' "${!name:-}"
}

install_tool() {
    local tool="$1" version sha dest url archive actual
    version="$(pin "$tool" VERSION)"
    sha="$(pin "$tool" SHA256_MACOS_ARM64)"
    dest="$tools_dir/$tool-$version"
    if [ -x "$dest/$tool" ]; then
        return 0
    fi
    [ "$(uname -s)-$(uname -m)" = "Darwin-arm64" ] ||
        die "the pinned $tool release is macOS arm64 only; set $(printf '%s_BIN' "$tool" | tr '[:lower:]' '[:upper:]') to a binary you trust"

    mkdir -p "$tools_dir"
    scratch="$(mktemp -d "$tools_dir/.download.XXXXXX")"
    url="https://github.com/g-cqd/$tool/releases/download/v$version/$tool-$version-macos-arm64.tar.gz"
    archive="$scratch/$tool.tar.gz"
    echo "installing $tool $version from $url"
    curl --fail --silent --show-error --location --retry 3 --proto '=https' --tlsv1.2 --output "$archive" "$url"

    actual="$(shasum -a 256 "$archive" | cut -d ' ' -f 1)"
    if [ "$actual" != "$sha" ]; then
        die "$tool $version: SHA-256 mismatch (expected $sha, got $actual); refusing to run it"
    fi
    if tar -tzf "$archive" | grep -Eq '^/|(^|/)\.\.(/|$)'; then
        die "$tool $version: archive contains absolute or parent-relative paths"
    fi

    mkdir "$scratch/extract"
    tar -xzf "$archive" -C "$scratch/extract"
    [ -x "$scratch/extract/$tool-$version-macos-arm64/$tool" ] || die "$tool $version: archive layout changed"
    actual="$("$scratch/extract/$tool-$version-macos-arm64/$tool" --version)"
    [ "$actual" = "$version" ] || die "$tool binary reports '$actual', expected '$version'"
    mv "$scratch/extract/$tool-$version-macos-arm64" "$dest"
    rm -rf "$scratch"
    scratch=""
}

# resolve_bin <tool>: prints the path of the binary to run, installing the pinned release if needed.
resolve_bin() {
    local tool="$1" override
    override="$(bin_override "$tool")"
    if [ -n "$override" ]; then
        [ -x "$override" ] || die "$override is not an executable"
        printf '%s' "$override"
        return 0
    fi
    install_tool "$tool" >&2
    printf '%s/%s-%s/%s' "$tools_dir" "$tool" "$(pin "$tool" VERSION)" "$tool"
}

# gate_flags <tool>: the flags that define each tool's gate. dolly is gated through .dolly.json instead
# (exact-clone is an error, near and structural clones stay advisory), so it takes no --strict.
gate_flags() {
    case "$1" in
        arcleak | deadwood) printf '%s' "--strict" ;;
        *) ;;
    esac
}

analyze() {
    local tool="$1" bin flags status=0
    bin="$(resolve_bin "$tool")"
    mkdir -p "$cache_dir"
    args=(analyze Sources Tests --relative-to . --config ".$tool.json" --cache-path "$cache_dir/$tool-facts.json")
    flags="$(gate_flags "$tool")"
    if [ -n "$flags" ]; then
        args+=("$flags")
    fi
    if [ -f ".$tool-baseline.json" ]; then
        args+=(--baseline ".$tool-baseline.json")
    fi
    echo "--- $tool $("$bin" --version): ${args[*]}"
    "$bin" "${args[@]}" || status=$?
    return "$status"
}

run_tools() {
    local failed=0 tool status
    for tool in "$@"; do
        status=0
        analyze "$tool" || status=$?
        case "$status" in
            0) echo "PASS  $tool" ;;
            1)
                echo "FAIL  $tool: findings (exit 1)"
                failed=1
                ;;
            *)
                echo "FAIL  $tool: the analyzer itself failed (exit $status: 64 usage, 70 nothing analyzed, 78 bad config or baseline)"
                failed=1
                ;;
        esac
    done
    return "$failed"
}

write_baselines() {
    local tool bin
    for tool in "$@"; do
        bin="$(resolve_bin "$tool")"
        mkdir -p "$cache_dir"
        "$bin" analyze Sources Tests --relative-to . --config ".$tool.json" --cache-path "$cache_dir/$tool-facts.json" \
            --write-baseline ".$tool-baseline.json"
    done
}

# check_pins: the CI workflow has to pin the same analyzer releases as analyzers.lock, or local and CI gates
# silently diverge. ci.yml carries one "uses: g-cqd/<tool>@<commit> # v<version>" line and one
# "version: '<version>'" line per tool.
check_pins() {
    local tool commit version failed=0 workflow=".github/workflows/ci.yml"
    for tool in "${all_tools[@]}"; do
        commit="$(pin "$tool" COMMIT)"
        version="$(pin "$tool" VERSION)"
        if ! grep -Eq "uses: g-cqd/$tool@$commit +# v$version\$" "$workflow"; then
            echo "pins: $workflow does not pin g-cqd/$tool@$commit # v$version" >&2
            failed=1
        fi
        if ! grep -Eq "version: '$version' +# $tool\$" "$workflow"; then
            echo "pins: $workflow does not set version: '$version' # $tool" >&2
            failed=1
        fi
    done
    if [ "$failed" -eq 0 ]; then
        echo "PASS  pins (workflow and analyzers.lock agree)"
    else
        echo "FAIL  pins"
    fi
    return "$failed"
}

command="run"
if [ $# -gt 0 ]; then
    case "$1" in
        run | install | baseline | versions | pins)
            command="$1"
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *) ;;
    esac
fi

selected=()
for arg in "$@"; do
    case " ${all_tools[*]} " in
        *" $arg "*) selected+=("$arg") ;;
        *)
            echo "error: unknown tool '$arg' (expected one of: ${all_tools[*]})" >&2
            exit 64
            ;;
    esac
done

if [ "${#selected[@]}" -eq 0 ]; then
    if [ "$command" = "baseline" ]; then
        selected=(dolly deadwood)
    else
        selected=("${all_tools[@]}")
    fi
fi

case "$command" in
    run)
        pins_status=0
        check_pins || pins_status=1
        run_tools "${selected[@]}" || pins_status=1
        exit "$pins_status"
        ;;
    pins) check_pins ;;
    install)
        for tool in "${selected[@]}"; do
            install_tool "$tool"
        done
        ;;
    baseline) write_baselines "${selected[@]}" ;;
    versions)
        for tool in "${all_tools[@]}"; do
            echo "$tool $(pin "$tool" VERSION) (commit $(pin "$tool" COMMIT))"
        done
        ;;
    *) ;;
esac
