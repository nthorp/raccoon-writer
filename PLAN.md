# iso-sword — Implementation Plan

> A native macOS app (Swift/SwiftUI) that writes `.iso` / `.img` images to removable USB drives.
> Similar in function to balenaEtcher and Fedora Media Writer.

**Plan created:** 2026-10-07 · **Owner:** Nick · **Agents:** Claude Code and/or Codex, working sequentially.

---

## 0. How to use this file (READ FIRST, every session)

1. Read `AGENTS.md` (conventions), then this file.
2. Look at the **Progress Tracker** (section 2). Pick the **first task whose status is `TODO` and whose dependencies are all `DONE`**. Do not skip ahead.
3. Set its status to `IN_PROGRESS` and add the date before writing code.
4. Do the work, following the task's **Steps** and meeting every **Acceptance criterion**.
5. Run `scripts/test.sh` (and `scripts/build.sh` once T00 exists). A task is not `DONE` until these pass.
6. Update the tracker row and fill in the task's **Handoff notes** (what you built, where, gotchas, deviations, anything the next agent must know). Keep notes concise but specific.
7. Commit: `T05: <short summary>`. One task per commit (or a small series), never mix tasks.
8. If you are blocked or need a decision, set status `BLOCKED`, explain in Handoff notes, and stop.
9. Tasks marked 🧑 are **human checkpoints**. The agent prepares everything, sets status `NEEDS_HUMAN`, writes exact instructions for Nick, and stops. Do not mark them `DONE` yourself.

**Status values:** `TODO` · `IN_PROGRESS` · `BLOCKED` · `NEEDS_HUMAN` · `DONE`

**Hard safety rule for all agents:** never run anything that writes to a real block device. No `dd`, no `authopen`, no `diskutil erase*` against real disks. Tests use temp files, fixtures and fakes only. Real-device work happens only in human checkpoints.

---

## 1. Decisions and scope

### Confirmed decisions

| Area | Decision |
| --- | --- |
| App name / folder | **iso-sword** (display name "ISO Sword", target `IsoSword`) |
| Bundle ID | `com.example.isosword` (placeholder; change before any public release) |
| Language / UI | Swift 5 language mode (targeted concurrency checking on), SwiftUI, Observation framework |
| Platform | macOS 14+, universal binary (arm64 + x86_64) |
| Project structure | Swift Package `ImageWriterCore` (UI-free, testable) + thin SwiftUI app target |
| Project generation | **XcodeGen** (`project.yml`); never hand-edit `.pbxproj` (it is gitignored) |
| Privilege model | **`authopen`** now, behind a `DeviceOpener` protocol so an SMAppService helper can replace it later |
| Image formats | `.iso` and `.img` only, raw block copy |
| Verification | Always on (no toggle) |
| Drive filter | Default: external, removable, USB-attached physical disks only. Toggle "Show all external disks". The boot disk and internal disks are **never** shown. |
| Confirmation | Show drive name, size, mount points; explicit "Erase and Write" click |
| Distribution | Personal / open source now. App Sandbox **off**. No Mac App Store. Signing and notarization deferred. |
| Features | Minimal v1: no drag-and-drop, no SHA-256 display, no localization |
| Agent files | `AGENTS.md` is the source of truth; `CLAUDE.md` imports it |

### Non-goals (v1)

Windows ISOs or any file-extraction mode, compressed images (`.xz`, `.gz`, `.zip`), persistence partitions, multi-drive writes, Mac App Store, Developer ID signing and notarization, localization.

### Runtime flow (target behavior)

```
Select image → Select drive → Confirm → [SafetyGuard re-check] → unmount disk
  → authopen (admin password prompt, returns fd) → write → fsync → verify (read back via same fd)
  → eject → Done
```

Error and cancel are possible from any step after Confirm. After a cancel or failure the drive contents are undefined; the UI must say so.

### Key technical notes (for implementers)

- **Use the raw node** `/dev/rdiskN`, not `/dev/diskN`. It bypasses the buffer cache and is much faster.
- **Unmount first.** The whole disk must be unmounted (`diskutil unmountDisk`) before opening for write, or the open fails.
- **authopen:** `/usr/libexec/authopen -stdoutpipe -o <open-flags> /dev/rdiskN` shows the system admin prompt and passes an open file descriptor back over its stdout socket using `SCM_RIGHTS` (`recvmsg`). The app itself never runs as root. Confirm exact flags with `man authopen` in the T01 spike.
- **One privileged open.** Each authopen call prompts for a password, so open `O_RDWR` once and reuse that fd for both the write and the verify read-back.
- **Raw device I/O must be block-aligned.** Use `posix_memalign`-ed buffers, I/O sizes that are multiples of the device block size (query with `DKIOCGETBLOCKSIZE` / `DKIOCGETBLOCKCOUNT` from `<sys/disk.h>`), chunk size around 4 MiB. Zero-pad the final partial block when writing; compare only the true image length when verifying.
- **Cache and sync:** set `F_NOCACHE` on the fd; call `fcntl(fd, F_FULLFSYNC)` after the last write.
- **Hybrid detection:** read the first 64 KiB of the image. MBR signature `0x55 0xAA` at offset 510. GPT header `"EFI PART"` at offset 512. ISO 9660 `"CD001"` at offset `0x8001`. An ISO with `CD001` but no MBR or GPT gets a non-blocking "may not boot from USB" warning.
- **Disk discovery** uses `diskutil list -plist` and `diskutil info -plist` (parsed with `PropertyListDecoder`). DiskArbitration is optional, for live add/remove notifications only.
- **Boot disk exclusion:** resolve the disk backing `/` via `diskutil info -plist /`. On APFS this is a synthesized container, so also resolve its physical store(s) (`APFSPhysicalStores`). Exclude any disk that matches, plus anything with `Internal == true`.
- **Debug-only test mode:** a `#if DEBUG` flag may let the filter accept `hdiutil` virtual disks so Nick can test without a spare USB. It must be compiled out of Release builds, and a test must assert that.

### Repo layout (created in T00)

```
iso-sword/
├── AGENTS.md
├── CLAUDE.md                 # one line: @AGENTS.md
├── PLAN.md
├── README.md
├── project.yml               # XcodeGen
├── Package.swift             # ImageWriterCore + tests
├── Sources/ImageWriterCore/
├── Tests/ImageWriterCoreTests/
│   └── Fixtures/
├── App/                      # SwiftUI app target sources + Info.plist + entitlements
├── Spikes/                   # throwaway experiments (T01)
├── scripts/
│   ├── build.sh              # xcodegen + xcodebuild (universal)
│   └── test.sh               # swift test
└── docs/
    └── HARDWARE_TESTS.md     # human checklist (T12)
```

---

## 2. Progress tracker

Update this table whenever a task changes state. Keep it in sync with the task sections below.

| ID | Task | Depends on | Status | Done date | Owner |
| --- | --- | --- | --- | --- | --- |
| T00 | Scaffolding: repo, package, XcodeGen, scripts | none | DONE | 2026-10-07 | Claude |
| T01 | 🧑 Spike: authopen fd passing | T00 | NEEDS_HUMAN | | Claude (prep) / Nick (run) |
| T02 | DeviceOpener protocol, AuthopenOpener, fakes | T01 | TODO | | |
| T03 | Disk model and discovery with filtering | T00 | TODO | | |
| T04 | ImageInspector | T00 | TODO | | |
| T05 | WriteEngine | T02 | TODO | | |
| T06 | Verifier | T05 | TODO | | |
| T07 | Unmount and eject | T03 | TODO | | |
| T08 | SafetyGuard and debug test mode | T03, T07 | TODO | | |
| T09 | WriteCoordinator (orchestration, state machine) | T04, T06, T07, T08 | TODO | | |
| T10 | SwiftUI shell and screens | T09 | TODO | | |
| T11 | Error states, cancel, disconnect handling, polish | T10 | TODO | | |
| T12 | 🧑 Hardware test checklist and README | T11 | TODO | | |

Tasks are written so they can be done in ID order. T03 and T04 do not depend on the spike, so if T01 is waiting on Nick, an agent may proceed with T03 and T04, then T07. Do not start T05 until T02 is `DONE`.

---

## 3. Task details

### T00 — Scaffolding

**Goal:** a building, testing empty skeleton that all later tasks can rely on.

**Steps**
1. `git init`; add `.gitignore` (Xcode user data, `.build/`, `*.xcodeproj`, `DerivedData/`, `.DS_Store`).
2. Confirm `AGENTS.md` and `CLAUDE.md` exist (they were provided). Do not rewrite them; only append to the "Commands" section if needed.
3. `Package.swift`: tools 5.10, platform `.macOS(.v14)`, library `ImageWriterCore`, test target `ImageWriterCoreTests`, Swift 5 language mode, `-strict-concurrency=targeted`. Add one trivial type and one passing test.
4. `project.yml` (XcodeGen): app target `IsoSword`, bundle ID `com.example.isosword`, deployment target 14.0, `ARCHS = arm64 x86_64`, `ONLY_ACTIVE_ARCH = NO` for Release, App Sandbox **disabled** (empty entitlements or `com.apple.security.app-sandbox = false`), depends on the local package `ImageWriterCore`. A minimal `@main` SwiftUI app showing "iso-sword".
5. `scripts/test.sh` (runs `swift test`) and `scripts/build.sh` (runs `xcodegen generate` then `xcodebuild` for scheme `IsoSword`, universal, ad-hoc signed, output under `build/`). Make both executable. If `xcodegen` is missing, print `brew install xcodegen` and exit non-zero.
6. Minimal `README.md` (what the project is, how to build).

**Acceptance criteria**
- `scripts/test.sh` passes.
- `scripts/build.sh` produces `IsoSword.app`; `lipo -archs` on its binary lists `arm64` and `x86_64`.
- Launching the app shows a window.
- No file in git is generated (`*.xcodeproj` is ignored).

**Files:** `.gitignore`, `Package.swift`, `project.yml`, `scripts/*`, `App/*`, `Sources/ImageWriterCore/*`, `Tests/*`, `README.md`

**Handoff notes:**
- **Verified 2026-10-07** with Xcode 26.6 and XcodeGen from Homebrew: `scripts/test.sh` passes. `scripts/build.sh` and `scripts/build.sh --release` both succeed and report `x86_64 arm64`. `build/IsoSword.app` launches and shows a window titled "ISO Sword". `IsoSword.xcodeproj` is git-ignored. Harmless build log noise: `appintentsmetadataprocessor ... No AppIntents.framework dependency found`.
- **Deviation: Swift Testing instead of XCTest.** XCTest isn't available with CLT alone. Swift Testing ships with the toolchain (no package dependency), but SwiftPM on CLT doesn't add its framework path. `scripts/test.sh` adds `-F`/`-rpath` for `$(xcode-select -p)/Library/Developer/Frameworks` only when the active dev dir is CommandLineTools. Effective minimum is Xcode 16 / CLT 16, noted in `AGENTS.md` Commands and `README.md`. Write all later tests with `import Testing`, `@Test`, `#expect`.
- Strict concurrency is set via `.enableExperimentalFeature("StrictConcurrency=targeted")` in `Package.swift` (the 5.10 manifest has no first-class setting) and `SWIFT_STRICT_CONCURRENCY: targeted` in `project.yml`.
- Test target declares `resources: [.copy("Fixtures")]`, so fixtures are accessible via `Bundle.module` (T03). `Fixtures/`, `Spikes/` and `docs/` hold `.gitkeep` placeholders.
- `build.sh`: Debug by default, `--release` for Release. It always passes `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` and ad-hoc signs with `CODE_SIGN_IDENTITY=-`, outputs to `build/IsoSword.app`, and fails if either arch is missing from the binary. With `--release` it already calls `scripts/check-release-flags.sh build/IsoSword.app` if that script exists and is executable (T08 should create it with that signature).
- Sandbox off via `App/IsoSword.entitlements` (`com.apple.security.app-sandbox = false`); hardened runtime off for now.

---

### T01 — 🧑 Spike: authopen fd passing

**Goal:** prove we can obtain a writable fd to a raw disk via `authopen` from Swift, and learn the real behavior before building on it. This is a human checkpoint because it needs an admin password.

**Agent steps**
1. Create `Spikes/AuthopenSpike/` as a standalone SwiftPM executable (not part of the main package).
2. Implement: take a `/dev/rdiskN` argument; refuse to proceed unless `--i-know-this-is-a-test-disk` is passed and the disk's `diskutil info -plist` says it is a virtual disk image (`VirtualOrPhysical == Virtual`); unmount it; spawn `authopen -stdoutpipe -o <O_RDWR>`; receive the fd via `recvmsg`/`SCM_RIGHTS`; read the device block size and block count with `ioctl`; write a known 1 MiB pattern at offset 0 with an aligned buffer; `F_FULLFSYNC`; read it back via the same fd and compare; close; eject.
3. Write `Spikes/AuthopenSpike/README.md` with the exact commands for Nick, including creating the virtual disk: `hdiutil attach -nomount ram://65536` (32 MiB RAM disk) and detaching it afterwards.
4. Set this task to `NEEDS_HUMAN` and stop.

**Human steps (Nick)**
Run the spike against the RAM disk, then (optionally, with a spare USB stick holding nothing important) against a real USB disk number. Record results under Handoff notes: Did the password prompt appear? Which exact flags worked? Did reads on the same fd work? Any TCC or "operation not permitted" prompts? Any difference between Apple Silicon and Intel (if you have both)?

**Acceptance criteria**
- Spike compiles. Documented outcome of the real run is recorded below.
- Findings that change the plan (e.g., different flags, extra prompts, read-back not possible on the same fd) are written down and the affected tasks (T02, T05, T06) are amended in this file.

**Handoff notes:**
- **Agent prep done 2026-10-07, now `NEEDS_HUMAN`.** The spike is in `Spikes/AuthopenSpike/`, a standalone SwiftPM package that the root package ignores. Build it with `cd Spikes/AuthopenSpike && swift build` (Swift 6.3.3, builds clean). **Nick: follow `Spikes/AuthopenSpike/README.md`** and paste the printed Findings block, plus answers to its checklist, under "Results" below.
- The agent never invoked `authopen` and never wrote to any disk. It verified only the paths that stop before any side effect, against a temporary RAM disk (attached, then detached):
  - `--dry-run` accepts the RAM disk.
  - Refused: `disk0` (internal), `disk3` (APFS container, internal), `disk5` (mounted iOS Simulator `.dmg`, "virtual but not ram://"), the RAM disk together with `--allow-physical-usb`, `/dev/disk7`, `/dev/rdisk7s1`, `/dev/rdisk7;ls`, a missing disk, a missing acknowledgement flag, and a wrong typed confirmation.
- **Deviations from the steps above:**
  1. The guard requires a `ram://` image in `hdiutil info`, not just `VirtualOrPhysical == Virtual`, because mounted `.dmg`s (here, the iOS Simulator runtime) are also `Virtual` whole disks.
  2. The human steps mention an optional real-USB run, which step 2's virtual-only rule would block. `--allow-physical-usb` covers it: external, USB, removable or ejectable, whole, not the boot disk.
  3. Added `--dry-run`, `--open-flags N`, `--no-eject` and a typed disk-name confirmation.
  4. authopen is spawned with `posix_spawn`, not `Process`, for exact control over which socketpair end becomes the child's stdout. The parent must close the child's end so `recvmsg` sees EOF if authopen exits without sending an fd. T02 can decide whether `Process` is good enough.
- **Implementation facts for T02:** `SCM_RIGHTS` needs an `AF_UNIX` socketpair (a `pipe(2)` won't carry fds). On this machine `CMSG_SPACE(sizeof(int))` is 16 and the `cmsghdr` header is 12 bytes. `<sys/disk.h>` ioctls aren't importable, so they're hard-coded: `DKIOCGETBLOCKSIZE = 0x40046418` and `DKIOCGETBLOCKCOUNT = 0x40086419` (checked against the C headers). `O_RDWR = 2` and `O_EXLOCK = 0x20`. Swift has no `WIFEXITED`, so status is decoded as `(s >> 8) & 0xff` and the signal as `s & 0x7f`.
- **Facts observed for T03 (macOS 26.3.1, arm64, read-only `diskutil` queries):**
  - Internal `disk0` reports `VirtualOrPhysical = Unknown`, not `Physical`. APFS volumes omit the key. Don't require `== "Physical"`; treat only `"Virtual"` as virtual.
  - Internal disks report `BusProtocol = Apple Fabric`. Disk images report `BusProtocol = Disk Image`, `Internal = false`, `Removable = true`, `Ejectable = true` and `MediaName = Disk Image`.
  - `diskutil info -plist /` returns the snapshot `disk3s3s1` with `ParentWholeDisk = disk3` and `APFSPhysicalStores = [{APFSPhysicalStore: disk0s2}]`. Each store's `ParentWholeDisk` (here `disk0`) must also be excluded.
  - `DiskUUID` is absent on whole disks, so T08's identity check can't rely on it.
- **Results, run 1 (Nick, 2026-10-07, M3 Max, macOS 26.3.1, RAM disk owned by the user):**
  - **No password prompt.** This is expected for user-owned nodes. `hdiutil attach` makes `/dev/rdiskN` `uid=nick 0640`, and setuid-root `authopen` returns the fd without asking for authorization when the caller can already open the node. Real disks are `root:operator 0640`, so this run does **not** exercise the prompt. Run 2 (below) uses `sudo chown root:operator` on the RAM disk nodes to cover it. The spike now prints the node owner.
  - `authopen -stdoutpipe -o 2` works as documented. The fd arrives through `SCM_RIGHTS` with 2 data bytes (`00 00`) and authopen exits 0. `fstat` shows a character device, and `F_GETFL` is `O_RDWR`.
  - `DKIOCGETBLOCKSIZE`/`DKIOCGETBLOCKCOUNT` give 512 × 65536, which matches `diskutil`. `F_NOCACHE` succeeds.
  - Unaligned **length** (100 bytes) and unaligned **offset** (1) both fail with `EINVAL`. Misaligned **memory** with an aligned length and offset succeeds on this device. Keep aligned buffers anyway: USB drivers may be stricter, and it's cheap. → **T02:** `FileBackedDevice` must reject requests whose length or offset isn't a block multiple with `EINVAL`, to emulate a raw device.
  - **`F_FULLFSYNC` fails with `ENOTTY` (25) on the RAM disk.** → **T02/T05:** `fullSync()` must not treat `ENOTTY`/`ENOTSUP` as fatal. Fall back to `fsync()`, and verify on a USB stick whether `F_FULLFSYNC` is supported there.
  - Writing and reading back 1 MiB through the same fd matches, so **one privileged open for write and verify works.** No change is needed to T06.
  - Unmount and eject work without elevated rights for a user-attached image.
- **Results, run 2 (pending, Nick):** the RAM disk with `root:operator` nodes (see the README, step 2). Record whether the dialog appears and what it says, the exit status on Cancel, and whether a second run within 5 minutes prompts again. Optionally run on a real USB stick and record the `F_FULLFSYNC` result. Then amend T02/T05 from these notes and mark T01 `DONE`.

---

### T02 — DeviceOpener, AuthopenOpener, fakes

**Goal:** the privilege seam. Everything downstream depends only on the protocol.

**Steps**
1. Define in `ImageWriterCore`:
   - `protocol DeviceOpener { func openForReadWrite(bsdName: String) async throws -> OpenedDevice }`
   - `OpenedDevice` (or `DeviceHandle`) wrapping the fd with `blockSize: Int`, `blockCount: UInt64`, `byteCount`, `read(into:at:)`, `write(from:at:)`, `fullSync()`, `close()`. Make it a protocol too so tests can use file-backed fakes.
2. `AuthopenOpener`: production implementation from the T01 spike, mapped to typed errors (`userCancelled`, `permissionDenied`, `deviceBusy`, `authopenFailed(status)`).
3. `FileBackedDevice` / `FakeDeviceOpener`: backed by a temp file with a configurable block size (use 512 and 4096 in tests), plus failure-injection hooks (fail on Nth write, short write, fail on sync).
4. Block-aligned I/O helpers (`AlignedBuffer` using `posix_memalign`).

**Acceptance criteria**
- Unit tests cover the fake device (aligned and unaligned requests, injected failures).
- `AuthopenOpener` compiles and is covered only by tests that do not invoke authopen (e.g., error mapping from exit statuses, fd-parsing from a canned `recvmsg` over a local socketpair).
- No test invokes `authopen`.

**Handoff notes:** _(empty)_

---

### T03 — Disk model and discovery

**Goal:** list candidate target disks correctly and safely.

**Steps**
1. Model `DiskInfo`: `bsdName` (`disk4`), `devicePath`, `rawDevicePath`, `mediaName`, `sizeBytes`, `busProtocol`, `isInternal`, `isRemovable`, `isEjectable`, `isVirtual`, `isWholeDisk`, `mountPoints: [String]` (aggregated across child partitions), `mediaUUID`/identity fields, `volumeNames`.
2. `DiskDiscovery` protocol with `func listDisks() async throws -> [DiskInfo]`, and a `DiskutilDiscovery` implementation that runs `diskutil list -plist` and `diskutil info -plist <disk>` through an injectable `CommandRunner` (so tests feed fixture plists).
3. `DiskFilter`: given `[DiskInfo]`, the boot-disk set and `showAllExternal: Bool`, return the display list.
   - Default: `isWholeDisk && !isInternal && !isVirtual && busProtocol == "USB"` and (removable or ejectable).
   - With `showAllExternal`: any whole, non-internal, non-virtual disk.
   - **Always** exclude the boot disk and its APFS physical stores, and anything internal.
4. `BootDiskResolver` using `diskutil info -plist /` and the APFS physical store keys.
5. Fixtures in `Tests/ImageWriterCoreTests/Fixtures/` captured from realistic plists (internal NVMe, APFS synthesized container, external USB stick with two partitions, external Thunderbolt SSD, SD card reader, disk image). If real captures are not available, hand-write them from the documented plist keys and note it in Handoff notes.

**Acceptance criteria**
- Tests prove: default list shows only the USB stick; toggle adds the Thunderbolt SSD and SD card; the boot disk, its APFS container and the internal disk never appear under either setting; disk images are hidden.
- Failure mode: if the boot disk cannot be resolved, `listDisks` filtering **fails closed** (returns an error or an empty list), never an unfiltered list.

**Handoff notes:** _(empty)_

---

### T04 — ImageInspector

**Goal:** validate the chosen file and warn about images that probably will not boot from USB.

**Steps**
1. `ImageInspector.inspect(url:) throws -> ImageInfo` with `url`, `fileName`, `sizeBytes`, `kind` (`.iso` / `.img`), `hasMBR`, `hasGPT`, `isISO9660`, `bootWarning: BootWarning?`.
2. Accept only `.iso` and `.img` extensions (case-insensitive); reject directories, empty files, unreadable files, with typed errors.
3. Read the first 64 KiB and detect the signatures listed in section 1. Warning rule: ISO 9660 present and neither MBR nor GPT present gives `.mayNotBootFromUSB`. Do not warn for `.img` files that lack the ISO signature.
4. Build tiny synthetic fixtures in code (byte arrays written to temp files). Do not commit real distro ISOs.

**Acceptance criteria**
- Tests cover: valid hybrid ISO, ISO-only (warning), plain `.img` with MBR, `.img` with GPT, wrong extension, empty file, missing file, file shorter than 64 KiB.
- Does not read the whole file.

**Handoff notes:** _(empty)_

---

### T05 — WriteEngine

**Goal:** stream an image onto an opened device with progress, speed and cancellation.

**Steps**
1. `WriteEngine.write(image:to:) -> AsyncThrowingStream<WriteProgress, Error>` (or an async function plus an `AsyncStream` of progress). `WriteProgress`: `bytesWritten`, `totalBytes`, `fractionComplete`, `bytesPerSecond` (smoothed with an exponential moving average over about 1 s windows), `estimatedSecondsRemaining`.
2. Pre-checks: device `byteCount >= image size`, else throw `imageTooLarge`.
3. Loop: read a chunk (about 4 MiB, a multiple of the device block size) from the source file into an aligned buffer; zero-pad the last partial block; write at the correct offset; handle short writes by retrying the remainder; check `Task.isCancelled` between chunks; `fullSync()` at the end.
4. Set `F_NOCACHE` on the device handle when applicable (inside the production handle, not the engine).
5. Emit progress at a throttled rate (at most about 10 per second).

**Acceptance criteria**
- Tests with `FileBackedDevice` (block sizes 512 and 4096): output file equals image bytes for sizes that are exact multiples, one byte over a multiple, and one chunk plus one byte; padding is zeros.
- Cancellation test stops within one chunk and does not call `fullSync` as success.
- Injected write failure and short write handled.
- Speed calculation unit-tested with a fake clock.

**Handoff notes:** _(empty)_

---

### T06 — Verifier

**Goal:** read back the device and compare to the source. Always runs after a successful write.

**Steps**
1. `Verifier.verify(image:against:) -> AsyncThrowingStream<VerifyProgress, Error>` with the same progress shape as the writer.
2. Read the device with aligned buffers via the same `OpenedDevice`; compare against the source chunk by chunk, only for the true image length (ignore the zero padding).
3. On mismatch throw `verificationFailed(atOffset:)`.
4. Support cancellation.

**Acceptance criteria**
- Tests: matching data passes; a single flipped byte at the start, middle and last byte of the image is detected with the right offset; cancellation works.
- If T01 found that same-fd read-back does not work, amend this task (for example, re-open read-only through `authopen` and accept a second prompt) before proceeding, and note it here.

**Handoff notes:** _(empty)_

---

### T07 — Unmount and eject

**Goal:** release the disk before writing and eject it afterwards.

**Steps**
1. `DiskManager` protocol: `unmountWholeDisk(bsdName:)`, `eject(bsdName:)`. Production implementation shells out to `diskutil unmountDisk /dev/diskN` and `diskutil eject /dev/diskN` through `CommandRunner`.
2. Typed errors: `busy` (parse "Unmount failed … busy"), `notFound`, `commandFailed(output)`.
3. Idempotent unmount (already unmounted is success). Eject failure after a successful write is reported as a warning, not a failed write.

**Acceptance criteria**
- Tests with a fake `CommandRunner` for success, busy, already unmounted, eject failure.
- Only `/dev/diskN` whole-disk names matching `^disk[0-9]+$` are accepted; anything else throws before running a command (no path injection).

**Handoff notes:** _(empty)_

---

### T08 — SafetyGuard and debug test mode

**Goal:** the last line of defense, run immediately before the privileged open.

**Steps**
1. `SafetyGuard.validate(confirmed: DiskInfo) async throws`: re-query the disk and require it to still exist and match the confirmed identity (BSD name, size, media name, media UUID where available); require not internal, not boot disk (re-resolve), whole disk, and still in the display list under the setting the user used. Any mismatch throws `diskChanged` or `forbiddenTarget`.
2. Fail closed on any query error.
3. Debug test mode: a `#if DEBUG` environment variable (for example `ISOSWORD_ALLOW_VIRTUAL_DISKS=1`) that makes `DiskFilter` accept `isVirtual` disks. Must not exist in Release builds.
4. A Release-configuration check: `scripts/check-release-flags.sh` that greps the Release build for the env-var name and exits non-zero if found. Wire it into `scripts/build.sh --release`.

**Acceptance criteria**
- Tests: unchanged disk passes; swapped disk (same BSD name, different size or UUID) is rejected; boot disk rejected; internal rejected; query error rejected.
- The release check passes on a Release build and would fail if the flag leaked.

**Handoff notes:** _(empty)_

---

### T09 — WriteCoordinator

**Goal:** a UI-free orchestrator and state machine the SwiftUI layer can bind to.

**Steps**
1. `enum WriteState`: `.idle`, `.imageSelected(ImageInfo)`, `.driveSelected(ImageInfo, DiskInfo)`, `.awaitingConfirmation`, `.preparing`, `.writing(WriteProgress)`, `.verifying(VerifyProgress)`, `.finishing`, `.finished(Summary)`, `.failed(WriteFailure)`, `.cancelled`.
2. `actor WriteCoordinator` (or an `@Observable` class wrapping an actor) with: `selectImage`, `selectDrive`, `requestConfirmation`, `confirmAndStart`, `cancel`, `reset`.
3. Pipeline on start: `SafetyGuard.validate` → `unmountWholeDisk` → `DeviceOpener.openForReadWrite` → `WriteEngine` → `Verifier` → close → eject (non-fatal on failure) → `.finished`.
4. Always close the device handle (use `defer`/structured cleanup), including on cancel and error.
5. Summary: image name, drive name, bytes, total duration, average speed.
6. Enforce legal transitions; illegal calls are ignored or throw.

**Acceptance criteria**
- Tests with all fakes: happy path state sequence; each stage failing yields `.failed` with the stage identified; cancel during write and during verify; handle closed in every path; start without confirmation is impossible.

**Handoff notes:** _(empty)_

---

### T10 — SwiftUI shell and screens

**Goal:** the minimal GUI. One window, linear flow.

**Steps**
1. `App/` views bound to `WriteCoordinator` state:
   - **Image step:** "Select Image…" using `NSOpenPanel` (or `.fileImporter`) limited to `.iso`/`.img`; shows name and size; shows the non-boot warning if present.
   - **Drive step:** list of disks (name, size, BSD name); checkbox "Show all external disks"; refresh button and auto-refresh on disk changes (DiskArbitration notifications or a 2 s poll); empty state text ("Insert a USB drive").
   - **Confirm step:** "You are about to erase **<name>** (<size>, /dev/diskN). Mounted volumes: …. All data on this drive will be permanently lost." Buttons: Cancel, **Erase and Write** (destructive style).
   - **Progress step:** phase label (Writing / Verifying), progress bar, percent, speed (MB/s), ETA, Cancel button.
   - **Done step:** "Finished. You can remove the drive." with duration and average speed; "Write another" button.
   - **Error step:** plain-language message, what happened to the drive, "Try again".
2. Window sizing, no extras, no menu customization beyond defaults. Dark mode comes for free.
3. Keep views dumb: no disk or I/O logic in views.

**Acceptance criteria**
- `scripts/build.sh` succeeds.
- A SwiftUI preview or UI-less snapshot of each step compiles using a fake coordinator state (previews for every state).
- Walkthrough in the debug app with a fake pipeline (a `#if DEBUG` "Simulate" switch using `FakeDeviceOpener` and a temp file) shows every step including progress, done, and error. Record how to run the simulation in Handoff notes.

**Handoff notes:** _(empty)_

---

### T11 — Error states, cancel, disconnect handling, polish

**Goal:** make failure paths honest and safe.

**Steps**
1. Map every typed error to a human message and a statement about drive state ("The drive may be partially written and is not bootable").
2. Handle drive removal mid-write (write returns `ENXIO`/`EIO`): stop, report, never retry on a different disk.
3. Handle admin prompt cancelled (return to the confirm step with no scary error).
4. Disable the window close and quit during a write, or confirm with an alert.
5. Prevent system sleep during the write (`ProcessInfo.beginActivity` with `.idleSystemSleepDisabled`).
6. Show a clear message if the image is larger than the drive (before confirmation, from `DiskInfo.sizeBytes`).
7. App icon placeholder and an About box are optional; skip unless trivial.

**Acceptance criteria**
- Unit tests for the error-to-message mapping and the "image too large" pre-check.
- Fault-injection tests through the coordinator: removal mid-write, sync failure, verification mismatch, prompt cancelled.

**Handoff notes:** _(empty)_

---

### T12 — 🧑 Hardware test checklist and README

**Goal:** document and execute the first real-world validation.

**Agent steps**
1. Write `docs/HARDWARE_TESTS.md` as a checklist with expected results, covering: RAM-disk dry run (debug flag), real USB stick with a hybrid Linux ISO (boots on a test machine), an `.img` write, an image bigger than the stick, ejecting the stick mid-write (use a spare stick), cancelling during write and during verify, cancelling the password prompt, boot disk and internal disks absent from both list modes, Apple Silicon and Intel runs if available.
2. Finish `README.md`: what it is, requirements, build instructions, safety notes (what the app erases), known limitations (hybrid ISOs only, Windows ISOs unsupported), and the roadmap (SMAppService helper, signing and notarization).
3. Set status to `NEEDS_HUMAN` and stop.

**Human steps (Nick):** run the checklist, record pass/fail and notes in the file, file issues for failures.

**Acceptance criteria:** checklist completed by Nick; README accurate.

**Handoff notes:** _(empty)_

---

## 4. Future work (not in scope)

- `HelperOpener` using an SMAppService-registered privileged XPC helper (removes per-write password prompt). Requires Developer ID signing; design must re-validate targets inside the helper.
- Developer ID signing, notarization, DMG packaging.
- Compressed image support, SHA-256 display, drag-and-drop, localization.

## 5. Open risks

| Risk | Mitigation |
| --- | --- |
| authopen behavior differs from assumptions (flags, read-back on same fd) | T01 spike first; T02, T05 and T06 are amended from its findings |
| Wrong disk written | Layered defenses: filtered list, explicit confirm screen, `SafetyGuard` re-check, fail-closed discovery, tests for boot disk and internal exclusion |
| Raw I/O alignment bugs | Aligned buffers, block-size-parametrized tests at 512 and 4096 |
| TCC or privacy prompts on removable media | Observed in T01 and documented in README |
| Agents touching real disks | Hard safety rule in sections 0 and `AGENTS.md`; real-device work only in human checkpoints |

## 6. Change log

| Date | Change | By |
| --- | --- | --- |
| 2026-10-07 | Plan created | Claude |
| 2026-10-07 | T00 scaffolding written; BLOCKED on Xcode/XcodeGen install. Tests switched to Swift Testing | Claude |
| 2026-10-07 | T00 DONE after Xcode and XcodeGen were installed and the build was verified | Claude |
| 2026-10-07 | T01 spike written; NEEDS_HUMAN for the authopen run | Claude |
