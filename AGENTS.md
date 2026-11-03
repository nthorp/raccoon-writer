# AGENTS.md — Raccoon Writer

Native macOS app (Swift/SwiftUI) that writes `.iso` / `.img` images to USB drives. Read this file, then `PLAN.md`, at the start of every session.

## Workflow

- Work from `PLAN.md`: take the first `TODO` task whose dependencies are `DONE`. Update the tracker and the task's Handoff notes when you finish. One task per commit, message format `T05: short summary`.
- When no task is `TODO`, small changes don't need one: make the change, then add a row to the change log in `PLAN.md` (section 6). Larger work gets a new task first: the next free ID, a tracker row and a task section. If unsure which applies, ask the human.
- Tasks marked 🧑 are human checkpoints: prepare, set `NEEDS_HUMAN`, stop. After the human reports results, record them and mark the task `DONE` yourself if every step (agent and human) and acceptance criterion is complete.
- If blocked or if the plan seems wrong, set `BLOCKED`, explain in Handoff notes, and stop rather than improvising a large change.

## Safety (non-negotiable)

- **Never write to a real block device.** Do not run `dd`, `authopen`, `diskutil erase*`, `diskutil partitionDisk`, or anything similar against real disks. Tests use temp files, fixtures and fakes only.
- The boot disk and internal disks must never appear as targets, under any setting, with one exception: a built-in SD card reader, recognised only when **all** of these hold: `BusProtocol` is exactly `Secure Digital`, `RemovableMedia` is true, `VirtualOrPhysical` is `Physical`, and it is a whole disk. A missing key means it is not one. Every other rule still applies to it, the boot disk rule included. Disk discovery and filtering must **fail closed**.
- The debug-only "allow virtual disks" mode must stay inside `#if DEBUG` and be absent from Release builds.

## Stack and conventions

- Swift 5 language mode, targeted strict concurrency. SwiftUI + Observation. macOS 14+, universal binary.
- `Sources/ImageWriterCore` is UI-free (no SwiftUI/AppKit imports) and holds all logic. `App/` is a thin SwiftUI layer with no I/O logic.
- Side effects go behind protocols (`DeviceOpener`, `OpenedDevice`, `DiskDiscovery`, `DiskManager`, `CommandRunner`) so everything is testable with fakes.
- Errors are typed enums with human-readable descriptions. No `try!`, no force unwraps in production code, no silent `catch {}`.
- Raw device I/O uses aligned buffers and block-size multiples. Always use `/dev/rdiskN` for writes.
- Validate BSD disk names against `^disk[0-9]+$` before passing them to any command. Never build shell strings; use `Process` with an argument array.
- Keep dependencies at zero unless the plan says otherwise (system frameworks only).
- Do not hand-edit or commit `*.xcodeproj`. Edit `project.yml` and regenerate.

## Commands

- `scripts/test.sh` — run unit tests (`swift test`). Must pass before marking any task `DONE`.
- `scripts/build.sh` — generate the project with XcodeGen and build the universal Debug app. `--release` builds Release and runs the release-flag check.
- Requires: Xcode 26+ (the Icon Composer app icon, `App/AppIcon.icon`, needs it), `brew install xcodegen`.
- Tests use Swift Testing (`import Testing`), not XCTest, so they run with only the Command Line Tools installed. This needs Xcode 16+ or the matching CLT.

## Style

- Small files, one primary type per file. Prefer `struct`/`enum` and value semantics; use `actor` for mutable shared state.
- Comments explain why, not what. Document any deviation from `PLAN.md` in that task's Handoff notes.
