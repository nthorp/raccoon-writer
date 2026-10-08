#!/usr/bin/env bash
# Runs the ImageWriterCore unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."

args=()
dev_dir="$(xcode-select -p 2>/dev/null || true)"
# With only the Command Line Tools installed, SwiftPM does not put the bundled
# Swift Testing framework on the search path, so add it explicitly.
if [[ "$dev_dir" == *CommandLineTools* ]]; then
    fw="$dev_dir/Library/Developer/Frameworks"
    args+=(-Xswiftc -F -Xswiftc "$fw" -Xlinker -rpath -Xlinker "$fw")
fi

exec swift test ${args[@]+"${args[@]}"} "$@"
