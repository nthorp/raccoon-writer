# iso-sword

**ISO Sword** is a native macOS app (Swift/SwiftUI) that writes `.iso` and `.img` disk images to USB drives, for example to make a bootable Linux installer. It does the same job as balenaEtcher and Fedora Media Writer: pick an image, pick a drive, confirm, and it writes the image, reads it back to verify it, then ejects the drive.

> **Status:** v1 is feature-complete and covered by unit tests. It has not yet been tested on real USB hardware. That test is under way, using [`docs/HARDWARE_TESTS.md`](docs/HARDWARE_TESTS.md). Until it is done, use only drives whose contents you don't need. See [`PLAN.md`](PLAN.md) for progress.

## Safety: what the app erases

**Writing an image erases the entire target drive**: every partition and every volume on it, not just one volume. The data cannot be recovered.

Several checks keep the wrong disk from being written:

- **The drive list hides disks that are never safe targets.** The boot disk (including its APFS container and the physical disk behind it) and every internal disk never appear, under any setting. By default only external, removable USB drives are listed. "Show all external disks" adds other external disks, such as Thunderbolt SSDs. If the app can't work out which disk is the boot disk, the list stays empty.
- **A confirm screen** shows the drive's name, size, `/dev/diskN` and mounted volumes, and requires a click on **Erase and Write**.
- **A safety check right before writing** queries the disk again and stops if it has disappeared, changed (different size, name, block size or bus), or no longer passes the filter.
- **macOS asks for an administrator password** before every write. The dialog says *"authopen wants to make changes"*: `authopen` is the macOS tool that opens the disk for the app. The app itself never runs as root.

After a cancelled or failed write, the drive's contents are undefined. The app says so and tells you what state the drive was left in.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel. The app is a universal binary.
- To build: Xcode 16 or later. Command Line Tools alone can run the unit tests but not build the app.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
scripts/test.sh             # unit tests for ImageWriterCore (swift test)
scripts/build.sh            # Debug build: generates IsoSword.xcodeproj, builds a universal build/IsoSword.app
scripts/build.sh --release  # Release build, plus a check that no debug-only test switches are in it
open build/IsoSword.app
```

The Xcode project is generated from `project.yml` and is not checked in. The app is ad-hoc signed only (see Limitations).

### Debug-only test modes

These exist only in Debug builds. The Release build check fails if any of them leaks into a Release app.

- `ISOSWORD_SIMULATE=1 build/IsoSword.app/Contents/MacOS/IsoSword` runs the whole UI against simulated drives backed by temp files. It never calls `diskutil` or `authopen`. Each simulated drive scripts one outcome (success, drive pulled out, verification mismatch, password prompt cancelled, drive too small). See T10 in `PLAN.md`.
- `ISOSWORD_ALLOW_VIRTUAL_DISKS=1 build/IsoSword.app/Contents/MacOS/IsoSword` also lists **unmounted** disk images, so you can test a real write against a RAM disk (`hdiutil attach -nomount ram://1048576`) without a USB stick. See H2 in `docs/HARDWARE_TESTS.md`.

### Logs

The app logs to the unified log under subsystem `com.example.isosword`:

```sh
log stream --predicate 'subsystem == "com.example.isosword"' --info
```

## How it works

```
Select image → Select drive → Confirm → safety re-check → diskutil unmountDisk
  → authopen (password prompt, returns an open file descriptor)
  → write to /dev/rdiskN → flush → read back and compare → diskutil eject → Done
```

- One password prompt covers the write and the verify, because both use the same file descriptor.
- Writes go to the raw device (`/dev/rdiskN`) in about 4 MiB chunks, with aligned buffers and the system cache bypassed. The final flush uses `F_FULLFSYNC`, or `fsync` on devices that don't support it.
- Verification is always on. It compares every byte of the image with what the drive returns.
- The Mac is kept from idle-sleeping during a write. The window can't be closed mid-write, and quitting asks first, then stops the write cleanly.

## Known limitations

- **Hybrid ISOs only.** The image is copied byte for byte. That works for images built to boot from USB: most Linux ISOs (Fedora, Ubuntu, Debian, Arch…) and raw `.img` files. An ISO with no partition table (plain ISO 9660, often meant for optical discs) gets a "may not boot from a USB drive" warning. It can still be written, but probably won't boot.
- **Windows installer ISOs are not supported.** They need their files extracted onto a formatted drive, not a raw copy.
- **No compressed images.** Decompress `.xz`, `.gz` or `.zip` images first (for example `xz -dk image.img.xz`).
- **One drive at a time.** No persistence partitions.
- **A password prompt on every write.** macOS doesn't cache the authorization across `authopen` runs.
- **The dialog names `authopen`, not ISO Sword.**
- **After a cancelled password prompt the drive stays unmounted.** Unplug and reinsert it to get its volumes back.
- **Not signed or notarized.** Build from source. A copy downloaded or AirDropped from elsewhere is blocked by Gatekeeper until you remove the quarantine flag (`xattr -dr com.apple.quarantine IsoSword.app`).
- English only. No drag-and-drop and no checksum display.

## Roadmap

- **A privileged helper** registered with `SMAppService`, so writes no longer need a password every time. Needs Developer ID signing, and the helper must re-check the target disk itself.
- **A branded password prompt**, by creating the authorization in-app (`authopen -extauth`), so the dialog names ISO Sword instead of authopen.
- **Developer ID signing, notarization** and a DMG download.
- Later: compressed images, SHA-256 display, drag-and-drop, localization.

## Layout

- `Sources/ImageWriterCore/`: all logic, UI-free (disk discovery and filtering, safety guard, write engine, verifier, coordinator)
- `App/`: thin SwiftUI app target
- `Tests/ImageWriterCoreTests/`: unit tests (Swift Testing) and fixtures. No test touches a real disk.
- `docs/HARDWARE_TESTS.md`: the manual checklist for real hardware
- `Spikes/`: throwaway experiments (the `authopen` spike)
- `scripts/`: build, test and release-check entry points
- `PLAN.md`, `AGENTS.md`: the implementation plan and the rules for coding agents working on this repo
