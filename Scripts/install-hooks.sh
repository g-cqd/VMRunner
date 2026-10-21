#!/bin/bash
# Points git at the versioned hooks in .githooks/ (pre-commit: format lint, SwiftLint, ShellCheck on staged files).
# Usage: Scripts/install-hooks.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "error: $root is not a git repository" >&2
    exit 1
}
chmod +x .githooks/*
git config core.hooksPath .githooks
echo "git hooks installed: core.hooksPath = $(git config core.hooksPath)"
