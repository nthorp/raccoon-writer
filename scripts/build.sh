#!/usr/bin/env bash
# Generates the Xcode project with XcodeGen and builds a universal RaccoonWriter.app
# into build/. Usage: scripts/build.sh [--release]
set -euo pipefail
cd "$(dirname "$0")/.."

config=Debug
for arg in "$@"; do
    case "$arg" in
        --release) config=Release ;;
        *) echo "Unknown argument: $arg" >&2; exit 2 ;;
    esac
done

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen not found. Install it with: brew install xcodegen" >&2
    exit 1
fi
if ! xcodebuild -version >/dev/null 2>&1; then
    echo "xcodebuild needs a full Xcode install (Command Line Tools are not enough)." >&2
    echo "Install Xcode, then run: sudo xcode-select -s /Applications/Xcode.app" >&2
    exit 1
fi

xcodegen generate --quiet

derived=build/DerivedData
xcodebuild \
    -project RaccoonWriter.xcodeproj \
    -scheme RaccoonWriter \
    -configuration "$config" \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY=- \
    build

app_src="$derived/Build/Products/$config/RaccoonWriter.app"
rm -rf build/RaccoonWriter.app
cp -R "$app_src" build/RaccoonWriter.app

archs="$(lipo -archs build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter)"
echo "Built build/RaccoonWriter.app ($config) — architectures: $archs"
for required in arm64 x86_64; do
    if [[ " $archs " != *" $required "* ]]; then
        echo "error: binary is missing architecture $required" >&2
        exit 1
    fi
done

if [[ "$config" == Release && -x scripts/check-release-flags.sh ]]; then
    scripts/check-release-flags.sh build/RaccoonWriter.app
fi
