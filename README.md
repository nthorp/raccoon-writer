# iso-sword

**ISO Sword** is a native macOS app (Swift/SwiftUI) that writes `.iso` and `.img`
images to USB drives, similar to balenaEtcher and Fedora Media Writer.

> Work in progress. See `PLAN.md` for the roadmap and current status.

## Requirements

- macOS 14 or later
- Xcode 16 or later (full Xcode for the app; Command Line Tools are enough for `scripts/test.sh`)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and test

```sh
scripts/test.sh             # unit tests for ImageWriterCore (swift test)
scripts/build.sh            # generate IsoSword.xcodeproj and build a universal build/IsoSword.app
scripts/build.sh --release  # Release configuration
```

The Xcode project is generated from `project.yml` and is not checked in.

## Layout

- `Sources/ImageWriterCore/`: all logic, UI-free
- `App/`: thin SwiftUI app target
- `Tests/ImageWriterCoreTests/`: unit tests (Swift Testing) and fixtures
- `Spikes/`: throwaway experiments
- `scripts/`: build and test entry points
