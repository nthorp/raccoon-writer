#!/usr/bin/env bash
# Fails if a debug-only test switch made it into a built app bundle.
# Usage: scripts/check-release-flags.sh path/to/IsoSword.app
# Called by scripts/build.sh --release. Exit 0: clean. Exit 1: a marker was found.
# Exit 2: bad usage or the bundle could not be searched (fails closed).
set -euo pipefail

# Keep in sync with Sources/ImageWriterCore/DebugTestMode.swift and
# Simulation/SimulationMode.swift; a unit test checks that the environment keys match.
# The type and property names catch the code itself leaking even if a key string were
# to change.
markers=(
    ISOSWORD_ALLOW_VIRTUAL_DISKS
    DebugTestMode
    allowVirtualDisks
    ISOSWORD_SIMULATE
    SimulationMode
    SimulatedDrive
)

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 path/to/App.app" >&2
    exit 2
fi
bundle="$1"
executables="$bundle/Contents/MacOS"
if [[ ! -d "$executables" ]] || [[ -z "$(ls -A "$executables")" ]]; then
    echo "error: $bundle has no executable in Contents/MacOS" >&2
    exit 2
fi

leaked=0
for marker in "${markers[@]}"; do
    status=0
    hits="$(grep -rlaF -- "$marker" "$bundle")" || status=$?
    case $status in
        0)
            echo "error: debug-only marker '$marker' found in:" >&2
            echo "$hits" | sed 's/^/  /' >&2
            leaked=1
            ;;
        1) ;;
        *)
            echo "error: could not search $bundle (grep exit $status)" >&2
            exit 2
            ;;
    esac
done

if [[ $leaked -ne 0 ]]; then
    exit 1
fi
echo "Release flag check passed: no debug-only markers in $bundle"
