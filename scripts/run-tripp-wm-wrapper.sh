#!/usr/bin/env bash
# Exercise the supported build entry point without Swift, signing, or keychain access.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/local/bin" "$work/local/libexec/tripp-wm" "$work/tools"
cp "$repo/bin/tripp-wm" "$work/local/bin/tripp-wm"
chmod +x "$work/local/bin/tripp-wm"
touch "$work/local/libexec/tripp-wm/Package.swift" "$work/local/libexec/tripp-wm/Info.plist"
export TEST_LOG="$work/log"
export XDG_CACHE_HOME="$work/cache"
export PATH="$work/tools:$PATH"
cat > "$work/tools/swift" <<'MOCK'
#!/usr/bin/env bash
set -eu
while [ "$#" -gt 0 ]; do
    if [ "$1" = --scratch-path ]; then
        shift
        mkdir -p "$1/release"
        printf '#!/bin/sh\nexit 0\n' > "$1/release/tripp-wm"
        cp "$1/release/tripp-wm" "$1/release/tripp-wmctl"
        chmod +x "$1/release/"*
    fi
    shift
done
MOCK
cat > "$work/tools/codesign" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TEST_LOG"
[ "$1" = --force ] && [ "$2" = --sign ] && [ "$3" = - ]
MOCK
cat > "$work/tools/security" <<'MOCK'
#!/usr/bin/env bash
printf 'Unexpected keychain access\n' >> "$TEST_LOG"
exit 1
MOCK
chmod +x "$work/tools/"*
"$work/local/bin/tripp-wm" --build
grep -q '^--force --sign - --identifier dev.tripp.tripp-wm ' "$TEST_LOG"
[ "$(wc -l < "$TEST_LOG" | tr -d ' ')" = 1 ]
[ -x "$work/cache/dotfiles/tripp-wm/tripp-wm.app/Contents/MacOS/tripp-wm" ]
"$work/local/bin/tripp-wm" --build
[ "$(wc -l < "$TEST_LOG" | tr -d ' ')" = 1 ]
echo 'PASS: ad hoc build, no keychain lookup, cached build reused'
