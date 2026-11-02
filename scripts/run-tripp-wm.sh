#!/bin/bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
source="$repo"
package=$(mktemp -d "${TMPDIR:-/tmp}/tripp-wm-tests.XXXXXX")
trap 'rm -rf "$package"' EXIT

cp "$source/Package.swift" "$source/Package.resolved" "$package/"
cp -R "$source/Sources" "$source/Tests" "$package/"
cp "$repo/config/config.toml" "$package/config.toml"

TRIPP_WM_CONFIG="$package/config.toml" \
    swift test --package-path "$package" --force-resolved-versions "$@"
