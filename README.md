# Raccoon Writer

**Raccoon Writer** (formerly Red Delicious Media Writer, and before that ISO Sword, which is why the repo is `iso-sword`) is a native macOS app (Swift/SwiftUI) that writes `.iso` and `.img` disk images to USB drives, for example to make a bootable Linux installer. It does the same job as balenaEtcher and Fedora Media Writer: pick an image, pick a drive, confirm, and it writes the image, reads it back to verify it, then ejects the drive.

> **Status:** v1 is feature-complete and covered by unit tests. It has not yet been tested on real USB hardware. That test is under way, using [`docs/HARDWARE_TESTS.md`](docs/HARDWARE_TESTS.md). Until it is done, use only drives whose contents you don't need. See [`PLAN.md`](PLAN.md) for progress.

## Safety: what the app erases

**Writing an image erases the entire target drive**: every partition and every volume on it, not just one volume. The data cannot be recovered.

Several checks keep the wrong disk from being written:

- **The drive list hides disks that are never safe targets.** The boot disk (including its APFS container and the physical disk behind it) and every internal disk never appear, under any setting. By default the list shows external USB drives that macOS reports as removable or ejectable. That covers USB sticks and card readers, but also most USB hard drives and SSDs, so a backup or Time Machine drive can appear. "Show all external disks" adds other external disks, such as Thunderbolt SSDs. If the app can't work out which disk is the boot disk, the list stays empty.
- **Drives over 500 GB are marked "Large drive"** in the list, and the confirm screen warns that the drive may be a backup or external hard drive. USB sticks are rarely that big. The warning doesn't stop the write.
- **Volume names are shown** on each drive's row in the list (for example "STICK · 16 GB · /dev/disk4 · USB") and on the confirm screen, so two identical sticks can be told apart.
- **A confirm screen** shows the drive's name, size, `/dev/diskN`, volume names and mounted volumes, and requires a click on **Erase and Write**.
- **macOS asks for an administrator password** before every write, in a dialog that names Raccoon Writer. The app hands the resulting authorization to `authopen`, the macOS tool that opens the disk and passes it back. The app itself never runs as root.
- **A safety check right after the password dialog** queries the disk again and stops if it has disappeared, changed (different size, name, block size or bus), or no longer passes the filter. It runs after the dialog, not before, because the dialog can stay open indefinitely: if the drive is unplugged meanwhile, another disk can take over its `/dev/diskN` name.
- **The opened disk is checked too.** Its size and block size must match the disk the safety check just approved, or nothing is written.

After a cancelled or failed write, the drive's contents are undefined. The app says so and tells you what state the drive was left in.

## Requirements

- macOS 14 or later, on Apple Silicon or Intel. The app is a universal binary.
- To build: Xcode 16 or later. Command Line Tools alone can run the unit tests but not build the app.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
scripts/test.sh
scripts/build.sh
scripts/build.sh --release
open build/RaccoonWriter.app
```

- `scripts/test.sh` runs the unit tests for ImageWriterCore (`swift test`).
- `scripts/build.sh` generates `RaccoonWriter.xcodeproj` and builds a universal Debug `build/RaccoonWriter.app`.
- `scripts/build.sh --release` builds Release, then checks that no debug-only test switches are in it.

The Xcode project is generated from `project.yml` and is not checked in. The app is ad-hoc signed only (see Limitations).

### Debug-only test modes

These exist only in Debug builds. The Release build check fails if any of them leaks into a Release app.

- `RACCOONWRITER_SIMULATE=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter` runs the whole UI against simulated drives backed by temp files. It never calls `diskutil` or `authopen`. Each simulated drive scripts one outcome (success, drive pulled out, verification mismatch, password prompt cancelled, drive too small, a 1 TB USB hard drive that shows the large-drive warning, and an open blocked by the privacy settings). See T10 in `PLAN.md`.
- `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter` also lists **unmounted** disk images, so you can test a real write against a RAM disk (`hdiutil attach -nomount ram://1048576`) without a USB stick. See H2 in `docs/HARDWARE_TESTS.md`.

### Logs

The app logs to the unified log under subsystem `com.example.raccoonwriter`:

```sh
log stream --predicate 'subsystem == "com.example.raccoonwriter"' --info
```

## How it works

```
Select image → Select drive → Confirm
  → password prompt (Security.framework, names Raccoon Writer)
  → safety re-check → diskutil unmountDisk
  → authopen -extauth (no second prompt; opens the disk, returns an open file descriptor)
  → size check of the opened disk
  → write to /dev/rdiskN → flush → read back and compare → diskutil eject → Done
```

- One password prompt covers the write and the verify, because both use the same file descriptor. The app creates the authorization for `sys.openfile.readwrite./dev/rdiskN` itself and passes it to `authopen` on stdin (`-extauth`), so the dialog names Raccoon Writer.
- The prompt comes first so that the safety check, unmount and open run back to back after it. The authorization is for a device path, and a path can change hands while the dialog is open. Cancelling the dialog leaves the drive as it was, still mounted.
- Writes go to the raw device (`/dev/rdiskN`) in about 4 MiB chunks, with aligned buffers and the system cache bypassed. The final flush asks the drive to empty its write cache with `DKIOCSYNCHRONIZE`, falling back to `F_FULLFSYNC` and then `fsync` where it isn't supported. On a raw device `fsync` doesn't reach the drive; the eject that follows flushes it.
- Verification is always on. It compares every byte of the image with what the drive returns.
- The Mac is kept from idle-sleeping during a write. The window can't be closed mid-write, and quitting asks first, then stops the write cleanly.

## Troubleshooting

### "macOS blocked access to removable drives"

At launch macOS may ask whether Raccoon Writer can access files on a removable volume. Listing drives triggers it, and writing needs the access. If you press Don't Allow, the drive list still works, but every write fails right after you enter the password, and the failed screen says macOS blocked access to removable drives.

To fix it, either:

- press **Open Privacy Settings…** on that screen (or open System Settings › Privacy & Security › Files & Folders), turn on **Removable Volumes** under Raccoon Writer, then try again; or
- run `tccutil reset SystemPolicyRemovableVolumes com.example.raccoonwriter`, relaunch the app and press Allow when asked.

If you build from source: macOS treats each ad-hoc-signed rebuild as a new app (the log shows tccd "Failed to match existing code requirement"), so the prompt can come back after rebuilding.

## Known limitations

- **Hybrid ISOs only.** The image is copied byte for byte. That works for images built to boot from USB: most Linux ISOs (Fedora, Ubuntu, Debian, Arch…) and raw `.img` files. An ISO with no partition table (plain ISO 9660, often meant for optical discs) gets a "may not boot from a USB drive" warning. It can still be written, but probably won't boot.
- **Windows installer ISOs are not supported.** They need their files extracted onto a formatted drive, not a raw copy.
- **No compressed images.** Decompress `.xz`, `.gz` or `.zip` images first (for example `xz -dk image.img.xz`).
- **One drive at a time.** No persistence partitions.
- **SD cards in a Mac's built-in slot are not listed.** macOS reports the built-in reader as an internal disk, and Raccoon Writer never shows internal disks. Use a USB card reader instead.
- **USB hard drives and SSDs are listed by default.** macOS reports most of them as ejectable, like sticks, so the app can't tell them apart reliably. Drives over 500 GB get a "Large drive" warning; a smaller backup drive doesn't, so check the name, volume names and size on the confirm screen.
- **A password prompt on every write.** The app discards the authorization as soon as the disk is open, so the next write asks again.
- **Two identical drives look the same.** The checks compare size, name, block size and bus. If you swap in an identical drive while the password dialog is open, that drive is written. Don't swap drives during a write.
- **The password dialog has no custom icon yet.** macOS also adds its own headline above the app's message, which can't be removed.
- **Not signed or notarized.** Build from source. A copy downloaded or AirDropped from elsewhere is blocked by Gatekeeper until you remove the quarantine flag (`xattr -dr com.apple.quarantine RaccoonWriter.app`). The Hardened Runtime is already on, so notarization only needs a Developer ID signature.
- English only. No drag-and-drop and no checksum display.

## Roadmap

- **A privileged helper** registered with `SMAppService`, so writes no longer need a password every time. Needs Developer ID signing, and the helper must re-check the target disk itself.
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
