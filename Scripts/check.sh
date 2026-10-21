#!/bin/bash
# The repository's quality gate. Runs every selected step (a failing step does not stop the others), prints a
# PASS/FAIL line for each and exits non-zero if any failed. CI runs the same steps through this script.
#
# Usage: Scripts/check.sh [--full] [--list] [step...]
#
#   (no arguments)  fast gate: format swiftlint shellcheck build test analyzers
#   --full          fast gate plus: asan tsan ubsan release coverage
#   step...         run only the named steps, in the order given (see --list)
#   --list          print the steps and exit
#
# Steps:
#  * format      swift-format lint --strict -r Sources Tests
#  * swiftlint   swiftlint lint --quiet            (config: .swiftlint.yml)
#  * shellcheck  ShellCheck on Scripts/*.sh and .githooks/*
#  * build       swift build
#  * test        swift test
#  * analyzers   arcleak, dolly, deadwood          (Scripts/analyzers.sh; pinned releases, .*.json configs)
#  * asan        swift test --sanitize=address     (.build-asan)
#  * tsan        swift test --sanitize=thread      (.build-tsan)
#  * ubsan       swift test --sanitize=undefined   (.build-ubsan)
#  * release     swift build -c release            (.build-release)
#  * coverage    line coverage of the logic layer must stay at or above COVERAGE_MIN (.build-cov)
#
# Coverage is a ratchet: COVERAGE_MIN (default 55) is a floor below the measured value (60.9% when it was
# introduced), not a goal. Raise the default whenever coverage rises; never lower it to make a change pass.
# The measured "logic layer" excludes code that needs a display and the virtualization entitlement and so
# cannot run in a unit test: Views, VMRunnerApp, VMController, Provisioner, ConfigurationBuilder.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

fast_steps=(format swiftlint shellcheck build test analyzers)
full_steps=(asan tsan ubsan release coverage)
coverage_min="${COVERAGE_MIN:-55}"
coverage_ignore='Tests/|\.build|/Views/|VMRunnerApp|VMController|Provisioner|ConfigurationBuilder'

usage() {
    sed -n '2,/^[^#]/{/^#/p;}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "error: '$1' not found in PATH" >&2
        return 1
    }
}

# ---- steps (each runs in a subshell with errexit, so the first failing command fails the step) ---------

step_format() {
    local tool
    tool="$(command -v swift-format || xcrun --find swift-format)"
    "$tool" lint --strict -r Sources Tests
}

step_swiftlint() {
    need swiftlint
    swiftlint lint --quiet
}

step_shellcheck() {
    need shellcheck
    local files=()
    local file
    for file in Scripts/*.sh .githooks/*; do
        [ -f "$file" ] && files+=("$file")
    done
    shellcheck -x "${files[@]}"
}

step_build() {
    swift build
}

# SWIFT_TEST_FLAGS adds flags to the plain test run (CI uses it for --xunit-output).
step_test() {
    local flags=()
    read -r -a flags <<<"${SWIFT_TEST_FLAGS:-}"
    swift test ${flags[@]+"${flags[@]}"}
}

step_analyzers() {
    Scripts/analyzers.sh run
}

step_asan() {
    swift test --sanitize=address --scratch-path .build-asan
}

step_tsan() {
    swift test --sanitize=thread --scratch-path .build-tsan
}

step_ubsan() {
    swift test --sanitize=undefined --scratch-path .build-ubsan
}

step_release() {
    swift build -c release --scratch-path .build-release
}

step_coverage() {
    swift test --enable-code-coverage --scratch-path .build-cov
    local products=".build-cov/out/Products/Debug"
    local binary="$products/VMRunnerTests.xctest/Contents/MacOS/VMRunnerTests"
    local profile="$products/codecov/default.profdata"
    [ -f "$binary" ] || {
        echo "error: test binary not found at $binary" >&2
        return 1
    }
    [ -f "$profile" ] || {
        echo "error: coverage profile not found at $profile" >&2
        return 1
    }
    local summary percent
    summary="$(xcrun llvm-cov export -summary-only "$binary" -instr-profile="$profile" -ignore-filename-regex="$coverage_ignore")"
    printf '%s\n' "$summary" >.build-cov/coverage-summary.json
    percent="$(python3 -I -c 'import json, sys; print(json.load(sys.stdin)["data"][0]["totals"]["lines"]["percent"])' <<<"$summary")"
    echo "logic-layer line coverage: $(printf '%.1f' "$percent")% (minimum $coverage_min%)"
    python3 -I -c 'import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)' "$percent" "$coverage_min" || {
        echo "error: coverage fell below COVERAGE_MIN=$coverage_min" >&2
        return 1
    }
}

# ---- runner ---------------------------------------------------------------------------------------------

results=()
failures=0

run_step() {
    local name="$1" status="PASS" started="$SECONDS" elapsed
    echo
    echo "==> $name"
    set +e
    (
        set -e
        "step_$name"
    )
    local code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        status="FAIL"
        failures=$((failures + 1))
    fi
    elapsed=$((SECONDS - started))
    echo "$status  $name (${elapsed}s)"
    results+=("$status  $name (${elapsed}s)")
}

is_step() {
    local candidate
    for candidate in "${fast_steps[@]}" "${full_steps[@]}"; do
        [ "$candidate" = "$1" ] && return 0
    done
    return 1
}

full=0
requested=()
for arg in "$@"; do
    case "$arg" in
        --full) full=1 ;;
        --list)
            printf '%s\n' "${fast_steps[@]}" "${full_steps[@]}"
            exit 0
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "error: unknown option '$arg'" >&2
            usage >&2
            exit 64
            ;;
        *)
            is_step "$arg" || {
                echo "error: unknown step '$arg' (see --list)" >&2
                exit 64
            }
            requested+=("$arg")
            ;;
    esac
done

if [ "${#requested[@]}" -gt 0 ]; then
    if [ "$full" -eq 1 ]; then
        echo "error: --full and explicit steps are mutually exclusive" >&2
        exit 64
    fi
    steps=("${requested[@]}")
elif [ "$full" -eq 1 ]; then
    steps=("${fast_steps[@]}" "${full_steps[@]}")
else
    steps=("${fast_steps[@]}")
fi

total_started="$SECONDS"
for name in "${steps[@]}"; do
    run_step "$name"
done

echo
echo "==== summary ($((SECONDS - total_started))s) ===="
printf '%s\n' "${results[@]}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
        echo '### Quality gate'
        echo '```'
        printf '%s\n' "${results[@]}"
        echo '```'
    } >>"$GITHUB_STEP_SUMMARY"
fi

if [ "$failures" -gt 0 ]; then
    echo "FAILED: $failures of ${#steps[@]} step(s)"
    exit 1
fi
echo "OK: all ${#steps[@]} step(s) passed"
