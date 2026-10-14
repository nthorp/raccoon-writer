# Raccoon Writer (repo: iso-sword) — Implementation Plan

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
9. Tasks marked 🧑 are **human checkpoints**. The agent prepares everything, sets status `NEEDS_HUMAN`, writes exact instructions for Nick, and stops. Once Nick reports back, the agent may mark the task `DONE` itself, provided every agent step and human step is complete, the results are recorded in Handoff notes, and every acceptance criterion is met. If any human step was skipped or failed, leave it `NEEDS_HUMAN` (or set `BLOCKED`) and say what is missing.

**Status values:** `TODO` · `IN_PROGRESS` · `BLOCKED` · `NEEDS_HUMAN` · `DONE`

**Hard safety rule for all agents:** never run anything that writes to a real block device. No `dd`, no `authopen`, no `diskutil erase*` against real disks. Tests use temp files, fixtures and fakes only. Real-device work happens only in human checkpoints.

---

## 1. Decisions and scope

### Confirmed decisions

| Area | Decision |
| --- | --- |
| App name / folder | **Raccoon Writer** (full and short name), target `RaccoonWriter`. Folder and repo stay `iso-sword`. Was "ISO Sword" / `IsoSword` until T14, then "Red Delicious Media Writer" / `RedDelicious` until T23 |
| Bundle ID | `com.example.raccoonwriter` (placeholder; change before any public release). Was `com.example.isosword` until T14, then `com.example.reddelicious` until T23 |
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
Select image → Select drive → Confirm → admin password prompt
  → [SafetyGuard re-check] → unmount disk → authopen -extauth (no prompt, returns fd)
  → [size check of the opened fd] → write → fsync → verify (read back via same fd)
  → eject → Done
```

The prompt comes first since T16: it can stay open indefinitely, and the authorization covers a device path that another disk can take over meanwhile.

Error and cancel are possible from any step after Confirm. After a cancel or failure the drive contents are undefined; the UI must say so.

### Key technical notes (for implementers)

- **Use the raw node** `/dev/rdiskN`, not `/dev/diskN`. It bypasses the buffer cache and is much faster.
- **Unmount first.** The whole disk must be unmounted (`diskutil unmountDisk`) before opening for write, or the open fails.
- **authopen:** `/usr/libexec/authopen -stdoutpipe -o <open-flags> /dev/rdiskN` shows the system admin prompt and passes an open file descriptor back over its stdout socket using `SCM_RIGHTS` (`recvmsg`). The app itself never runs as root. Confirm exact flags with `man authopen` in the T01 spike.
- **One privileged open.** Each authopen call prompts for a password, so open `O_RDWR` once and reuse that fd for both the write and the verify read-back.
- **Raw device I/O must be block-aligned.** Use `posix_memalign`-ed buffers, I/O sizes that are multiples of the device block size (query with `DKIOCGETBLOCKSIZE` / `DKIOCGETBLOCKCOUNT` from `<sys/disk.h>`), chunk size around 4 MiB. Zero-pad the final partial block when writing; compare only the true image length when verifying.
- **Cache and sync:** set `F_NOCACHE` on the fd. After the last write, flush with `ioctl(fd, DKIOCSYNCHRONIZE)` (a zeroed `dk_synchronize_t`; the disk driver sends the drive a SYNCHRONIZE CACHE), falling back to `fcntl(fd, F_FULLFSYNC)` and then `fsync()`, each only when the previous call fails with `ENOTTY`/`ENOTSUP` (T19). On a raw node `F_FULLFSYNC` returns `ENOTTY` (T01, T12) and `fsync` does nothing, so before T19 the drive's cache was never flushed by the app.
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
| T01 | 🧑 Spike: authopen fd passing | T00 | DONE | 2026-10-07 | Claude (prep) / Nick (run) |
| T02 | DeviceOpener protocol, AuthopenOpener, fakes | T01 | DONE | 2026-10-07 | Claude |
| T03 | Disk model and discovery with filtering | T00 | DONE | 2026-10-07 | Claude |
| T04 | ImageInspector | T00 | DONE | 2026-10-09 | Claude |
| T05 | WriteEngine | T02 | DONE | 2026-10-09 | Claude |
| T06 | Verifier | T05 | DONE | 2026-10-09 | Claude |
| T07 | Unmount and eject | T03 | DONE | 2026-10-09 | Claude |
| T08 | SafetyGuard and debug test mode | T03, T07 | DONE | 2026-10-09 | Claude |
| T09 | WriteCoordinator (orchestration, state machine) | T04, T06, T07, T08 | DONE | 2026-10-09 | Claude |
| T10 | SwiftUI shell and screens | T09 | DONE | 2026-10-09 | Claude |
| T11 | Error states, cancel, disconnect handling, polish | T10 | DONE | 2026-10-09 | Claude |
| T12 | 🧑 Hardware test checklist and README | T11 | NEEDS_HUMAN | | Claude (prep) / Nick (run) |
| T13 | 🧑 Branded password prompt (`authopen -extauth`) | T11 | DONE | 2026-10-12 | Claude (prep) / Nick (run) |
| T14 | Rename to Red Delicious Media Writer | T13 | DONE | 2026-10-12 | Claude |
| T15 | App icon | T14 | DONE | 2026-10-12 | Claude |
| T16 | 🧑 Password prompt before the safety check; size check after open | T15 | DONE | 2026-10-12 | Claude (prep) / Nick (run) |
| T17 | 🧑 Layered app icon (Icon Composer) with dark variant | T15 | DONE | 2026-10-13 | Claude (prep) / Nick (check) |
| T18 | 🧑 Make the password-cancelled notice stand out | T16 | DONE | 2026-10-13 | Claude (prep) / Nick (check) |
| T23 | Rename to Raccoon Writer, with the raccoon icon | T16 | DONE | 2026-10-13 | Claude |
| T19 | 🧑 Flush the drive cache with `DKIOCSYNCHRONIZE` | T16 | DONE | 2026-10-13 | Claude (prep) / Nick (run) |
| T20 | 🧑 Warn for drives over 500 GB; README says USB hard drives are listed | T18 | TODO | | Claude (prep) / Nick (check) |
| T21 | Hardening: close-on-exec device descriptor, partial-block I/O, image identity, diskutil kill | T16 | TODO | | Claude |
| T22 | 🧑 Volume names on screen, debug-only fakes, Info.plist keys, Hardened Runtime | T20, T21 | TODO | | Claude (prep) / Nick (run) |

Tasks are written so they can be done in ID order, except that T23 is listed above T19 so it is done first. T03 and T04 do not depend on the spike, so if T01 is waiting on Nick, an agent may proceed with T03 and T04, then T07. Do not start T05 until T02 is `DONE`.

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
- **Results, run 2 (Nick, 2026-10-07, same machine, RAM disk nodes `chown root:operator`):**
  - **The macOS dialog appeared: "authopen wants to make changes."** It names `authopen`, not ISO Sword. After the password was entered, the fd arrived (exit 0, 35 s including the prompt). The write, read-back match, `EINVAL` probes and `F_FULLFSYNC` `ENOTTY` results were identical to run 1.
  - **Cancel:** authopen prints `AuthorizationCreate failed: The authorization was canceled by the user.` to stderr and **exits 1**, with no fd. Exit status 1 is generic, so a cancel can only be told apart by the stderr text. → T02 amended.
  - **No credential caching.** A second run within 5 minutes of a successful authorization prompted again, despite the right's `timeout = 300`. That run was also cancelled, with the same status and message. Each authopen call is a fresh process, so **every write prompts once**. The single-open design (one prompt per write, covering write and verify) is confirmed.
  - `diskutil unmountDisk` and `eject` work as the user even when the nodes are root-owned.
- **Not covered:** a real USB stick (optional, skipped) and Intel. `F_FULLFSYNC` support on USB media is still unknown, so T05's fallback handles both outcomes, and T12 records which one happens.
- **Plan amendments made from these findings:** section 1 (sync fallback), T02 steps 2–3 (stderr-based cancel mapping, `EINVAL` emulation, sync fallback), T05 step 3, T10 confirm copy, T12 checklist, and section 4 (`-extauth` for a branded prompt).

---

### T02 — DeviceOpener, AuthopenOpener, fakes

**Goal:** the privilege seam. Everything downstream depends only on the protocol.

**Steps**
1. Define in `ImageWriterCore`:
   - `protocol DeviceOpener { func openForReadWrite(bsdName: String) async throws -> OpenedDevice }`
   - `OpenedDevice` (or `DeviceHandle`) wrapping the fd with `blockSize: Int`, `blockCount: UInt64`, `byteCount`, `read(into:at:)`, `write(from:at:)`, `fullSync()`, `close()`. Make it a protocol too so tests can use file-backed fakes.
2. `AuthopenOpener`: production implementation from the T01 spike (`Spikes/AuthopenSpike/Sources/AuthopenSpike/Authopen.swift`, which handles the socketpair, spawn and `recvmsg`), mapped to typed errors (`userCancelled`, `permissionDenied`, `deviceBusy`, `authopenFailed(status, message)`).
   - Exact invocation (verified in T01): `/usr/libexec/authopen -stdoutpipe -o 2 /dev/rdiskN` (`2` = `O_RDWR`), with stdout on one end of an `AF_UNIX` `socketpair`. authopen sends 2 data bytes (`00 00`) with the `SCM_RIGHTS` message, then exits 0.
   - **Capture authopen's stderr through a pipe.** A cancel exits **1** with `AuthorizationCreate failed: The authorization was canceled by the user.`, and exit 1 is generic. Map stderr containing "canceled by the user" to `userCancelled`. Map other recognizable texts (for example "busy", "not permitted") to `deviceBusy`/`permissionDenied`; everything else becomes `authopenFailed(status, stderr)`. A clean exit with no fd is also `authopenFailed`. Tests cover this mapping with canned `(status, stderr)` pairs.
   - The parent must close its copy of the child's socket end after spawning, or `recvmsg` never sees EOF when authopen fails.
3. `FileBackedDevice` / `FakeDeviceOpener`: backed by a temp file with a configurable block size (use 512 and 4096 in tests), plus failure-injection hooks (fail on Nth write, short write, fail on sync).
   - Emulate raw-device rules observed in T01: a read or write whose **length or offset is not a block multiple fails with `EINVAL`**. Misaligned *memory* was accepted by the RAM disk, but production code still uses aligned buffers.
   - `fullSync()` in the production handle: `F_FULLFSYNC`, falling back to `fsync()` on `ENOTTY`/`ENOTSUP` (the RAM disk returns `ENOTTY`). Any other error is a real sync failure. The fake can simulate "F_FULLFSYNC unsupported" to test the fallback.
4. Block-aligned I/O helpers (`AlignedBuffer` using `posix_memalign`).

**Acceptance criteria**
- Unit tests cover the fake device (aligned and unaligned requests, injected failures).
- `AuthopenOpener` compiles and is covered only by tests that do not invoke authopen (e.g., error mapping from exit statuses, fd-parsing from a canned `recvmsg` over a local socketpair).
- No test invokes `authopen`.

**Handoff notes:**
- **Done 2026-10-07.** `scripts/test.sh` passes 49 tests. `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings.
- **Files** (all in `Sources/ImageWriterCore/`): `DeviceOpener`, `OpenedDevice` (protocols); `AuthopenOpener` (production opener); `DescriptorReceiver` (`SCM_RIGHTS` receive, from the spike); `RawDevice` (production handle); `SyncMethod` (`F_FULLFSYNC` → `fsync` fallback); `AlignedBuffer`; `BlockMath`; `BSDName`; `PosixIO` (EINTR-retrying `pread`/`pwrite`); `DeviceOpenError`, `DeviceIOError`; `Fakes/FileBackedDevice`, `Fakes/FakeDeviceOpener`.
- **API shape for T05/T06:**
  - `OpenedDevice` is `AnyObject & Sendable`. `read(into: UnsafeMutableRawBufferPointer, at: UInt64) -> Int` and `write(from: UnsafeRawBufferPointer, at: UInt64) -> Int` make **one** call and return the byte count. `read` returns 0 at the end of the device. `write` may return less than requested, so **T05 owns the retry loop**. Treat a 0-byte return for a non-empty request as an error, or the loop never ends. `byteCount` is a protocol extension.
  - `fullSync()` is `@discardableResult` and returns `SyncMethod` (`.fullFsync` / `.fsyncFallback`). `RawDevice` logs which method it used (`os.Logger`, subsystem `com.example.isosword`, category `device`). T12 can read it with `log stream --predicate 'subsystem == "com.example.isosword"' --info`.
  - `close()` is idempotent. Any I/O after it throws `DeviceIOError.closed`. `RawDevice` also closes in `deinit`.
  - `AlignedBuffer(count:blockSize:)` aligns to `max(pagesize, blockSize)` and starts zero-filled. `zero(_ range:)` handles the final-block padding. `bytes` exposes it as a raw buffer.
  - I/O errors are `DeviceIOError.posix(operation:code:)`. T11 can check `code` for `ENXIO`/`EIO` (drive removed).
- **`AuthopenOpener`:**
  - Validates the name with `BSDName.isWholeDisk` (an ASCII-only `^disk[0-9]+$`, reusable by T07) before anything runs.
  - Runs authopen on a GCD thread, so the password prompt doesn't block the cooperative pool. Cancellation is honored only before the spawn.
  - Wraps the received fd in `RawDevice(fd:)`, which reads the geometry ioctls and sets `F_NOCACHE`. **T05 step 4 is therefore already done.**
  - Kept `posix_spawn` instead of `Process`. With `POSIX_SPAWN_CLOEXEC_DEFAULT` the child gets only stdin=`/dev/null`, stdout=socket and stderr=pipe. The parent's ends are `FD_CLOEXEC`, so a concurrent `Process` launch (diskutil) can't hold the socket open and stall `recvmsg`. A test proves an inheritable fd doesn't leak into the child, and it fails if the spawn flag is removed (checked by mutation).
  - If an fd arrives but authopen exits nonzero, the fd is closed and an error is thrown.
- **Error mapping** (`AuthopenOpener.failure(for:stderr:)`), checked in this order:
  1. "canceled/cancelled by the user" → `userCancelled`
  2. signal → `authopenTerminated(signal:)`
  3. "busy" → `deviceBusy`
  4. "not permitted" or "denied" → `permissionDenied`
  5. anything else → `authopenFailed(status:message:)`, including exit 0 with no fd
  Only the cancel text was seen in T01; the busy and denied texts are guesses. stderr is logged under category `authopen`.
- **`RawDevice` holds its lock across each I/O call,** so `close()` can't free the fd number mid-call. A reused number could otherwise point at an unrelated file. The cost is that `close()` waits for an in-flight chunk, which matters for T09 cancel.
- **`FileBackedDevice` semantics:**
  - Creates a zero-filled temp file of `blockSize × blockCount` bytes, deleted on `deinit`. `contents()` works after `close()`.
  - A length or offset that isn't a block multiple fails with `EINVAL`.
  - At the end of the device: a read returns 0, or is clamped if it crosses the end. A write at or past the end fails with `ENOSPC`. A write that crosses the end is clamped, which looks like a short write.
  - `Faults`: `failWrite`/`failRead` (`call:` is 1-based, `code:` defaults to `EIO`; use `ENXIO` for removal), `shortWriteOnCall` (writes half the request, rounded down to blocks, at least one block), `syncError`, `fullFsyncUnsupported` (`ENOTTY`, which exercises the real fallback code). `faults` can be changed at runtime.
  - Counters: `writeCallCount`, `readCallCount`, `syncCallCount`, `closeCallCount`, `isClosed`, `lastSyncMethod` (the last *successful* sync; T05's cancel test can assert it is nil).
- **`FakeDeviceOpener`** takes `init(device:)`, `init(error:)` or `init(factory:)`. It applies the same name validation as production, and `openAttempts` records each attempt.
- **Deviations:**
  1. `permissionDenied` and `deviceBusy` carry no payload, as the plan lists them. The stderr text goes to the log.
  2. Added `invalidDiskName`, `authopenTerminated` and `posix` cases to `DeviceOpenError`.
  3. The fakes live in the library, not the test target, and are **not** wrapped in `#if DEBUG`, because T10's Simulate mode needs them in the app. They only touch temp files. T10 should gate its use of them behind `#if DEBUG`.
  4. The process tests run `/bin/sh` stand-in scripts through the internal `AuthopenOpener(executable:)` to cover spawn, argv, stderr capture, cancel, exit 0 without an fd, a signal and `ENOENT`. The public `init()` always uses `/usr/libexec/authopen`.

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

**Handoff notes:**
- **Done 2026-10-07.** `scripts/test.sh` passes 98 tests. `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings. A throwaway probe (scratchpad only, not committed) ran discovery read-only on the real machine and got the boot set `{disk0, disk3}`. Every disk was rejected for the expected reason, and both lists were empty.
- **Files** (in `Sources/ImageWriterCore/`): `CommandRunner` (protocol and `CommandResult`), `ProcessCommandRunner`, `CommandRunnerError`, `Fakes/FakeCommandRunner`; `DiskInfo`; `DiskDiscovery` (protocol), `DiskutilDiscovery`; `Diskutil` (internal helper that runs and decodes `list`/`info`), `DiskutilList`, `DiskutilInfo` (internal `Decodable` subsets); `BootDiskSet`, `BootDiskResolver` (and the `BootDiskResolving` protocol); `DiskFilter`, `DiskRejection`; `TargetDiskLister`; `DiskDiscoveryError`.
- **Entry point for T10:** `TargetDiskLister(runner:).targets(showAllExternal:)`. It resolves the boot disks **first**, and if that throws, it throws without running `diskutil list`. `DiskFilter.rejection(for:bootDisks:)` returns the first rule a disk breaks. T08 can reuse it to give reasons.
- **Fail-closed design:**
  - `DiskFilter` takes a `BootDiskSet`, whose failable init refuses an empty set or a non-whole-disk name. Filtering without a resolved boot disk therefore doesn't compile.
  - `BootDiskResolver` throws if `/` has no valid `ParentWholeDisk`, if an APFS root (`FilesystemType == apfs` or `APFSContainerReference`) lists no physical stores, or if any store fails to resolve. Every store is included (Fusion-style containers).
  - A missing `Internal` key means internal. A missing `WholeDisk` key means not whole.
- **Filter rules,** checked in this order: invalid name, not whole, internal, boot disk, system volume mounted (`/` or `/System/Volumes/…`), APFS container, virtual, size 0 (`noMedia`, e.g. an empty card reader). Default mode then also requires `BusProtocol == "USB"` and removable or ejectable. The system-volume rule backstops boot resolution. APFS synthesized containers (`APFSPhysicalStores` present) are always rejected, even after T08 allows virtual disks. Their physical disk is the target.
- **Mount points:** `DiskInfo.mountPoints`/`volumeNames` come from `diskutil list -plist`. They include partitions, APFS volumes and mounted snapshots. **A container's volumes are also credited to the physical disk that holds its store.** So an APFS-formatted stick shows its real volumes on the confirm screen, and the internal `disk0` shows `/`.
- **Discovery details:**
  - `diskutil info` runs concurrently for each whole disk, and the results keep diskutil's order.
  - A disk is left out (and logged under category `discovery`) when its `info` fails, decodes badly, or describes a different identifier. This is usually a stick pulled mid-refresh, and leaving a disk out is always safe.
  - `CommandRunnerError` (launch failure, timeout) propagates instead, because it means diskutil itself is broken.
  - Names from `WholeDisks` that fail `BSDName.isWholeDisk` are never passed to a command.
- **diskutil errors:** with `-plist`, diskutil reports failures **as a plist on stdout** (`Error`, `ErrorMessage`, `ExitCode`), not on stderr. `Diskutil` maps them to `commandFailed(command:status:message:)`. The real reply is in fixture `info-missing.plist`. T07's `diskutil unmountDisk`/`eject` don't use `-plist` and print text, so T07 must read both stdout and stderr.
- **`ProcessCommandRunner`** (for T07):
  - Uses `Process` with an argument array and stdin set to `/dev/null`.
  - Drains stdout and stderr concurrently, so it can't deadlock on full pipes.
  - Has a 30 s default timeout, after which it sends SIGTERM and throws `timedOut`.
  - A nonzero exit is **returned**, not thrown.
- **`FakeCommandRunner`** is in the library (like the T02 fakes) for T07 tests and T10's Simulate mode. Unknown commands exit 1. `invocations` records `[executable] + arguments`.
- **`BSDName.isDeviceIdentifier`** (`^disk[0-9]+(s[0-9]+)*$`, at most 32 bytes) is used **only** for read-only `diskutil info` on partitions (APFS stores). Opens and unmounts still require `isWholeDisk`.
- **Fixtures** (`Tests/ImageWriterCoreTests/Fixtures/diskutil/`):
  - Real captures from this machine (macOS 26.3.1, M3 Max), with the SMART dictionary removed: `info-root`, `info-disk0`, `info-disk3`, `info-disk0s2`, `info-missing`.
  - **Hand-written** from the real key set (no hardware was available): `list` (the composed fixture machine), `info-disk4` (USB stick), `info-disk5` (Thunderbolt SSD, `BusProtocol = PCI-Express`), `info-disk6` (its APFS container), `info-disk7` (SD card, `Secure Digital`, `Internal = false`), `info-disk8` (disk image). The machine is described in `DiskutilFixtures.swift`.
- **Deviations:**
  1. `devicePath`/`rawDevicePath` are computed from `bsdName`.
  2. `mediaUUID` is diskutil's `DiskUUID`, which is usually absent on whole disks. T08 must not rely on it; size + media name + block size are what is available.
  3. Added `isAPFSContainer` and `blockSize`.
  4. Added `TargetDiskLister`, which is where the "fail closed" acceptance criterion lives, since `listDisks()` itself is unfiltered.
- **For T12:** the Thunderbolt and SD fixtures are guesses. Built-in SD slots may report `Internal = true`; if so, they are hidden under both settings by design. Record what a real USB stick, SD slot and Thunderbolt disk report.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 121 tests (23 new test functions in `ImageInspectorTests`). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings.
- **Files** (in `Sources/ImageWriterCore/`): `ImageInspector`, `ImageInfo`, `ImageKind`, `BootWarning`, `ImageSignatures` (internal, pure detection on a byte array), `ImageInspectorError`.
- **API:** `ImageInspector()` is a `Sendable` struct; call `inspect(url:)` (synchronous, `throws`) off the main actor. `BootWarning.message` is the user-facing text for T10. `ImageInspectorError` conforms to `LocalizedError`.
- **Order of checks:**
  1. Not a `file:` URL gives `notAFileURL`.
  2. The extension is checked **before any I/O**. A wrong extension gives `unsupportedExtension` even when the file is missing.
  3. The file is opened with `O_RDONLY | O_NONBLOCK`, so a FIFO cannot hang the open. `ENOENT`/`ENOTDIR` give `notFound` and `EACCES`/`EPERM` give `permissionDenied`.
  4. The file type is checked with `fstat` on that descriptor, so there is no check-then-open race. A directory gives `isDirectory`; a device node, FIFO or socket gives `notRegularFile`.
  5. Size 0 gives `empty`.
  6. Then at most 64 KiB is read with `pread`.
- Symlinks are followed. `fileName` is the name the user picked (the link's name), not the target's.
- **Detection:** short files are fine. A signature is present only if all its bytes fit in the file. The warning depends only on the signatures, not the extension: a renamed ISO-only `.img` also gets `.mayNotBootFromUSB`. A plain `.img` without `CD001` never does.
- **Deviations:**
  1. Added `notAFileURL`, `notRegularFile` and `posix` error cases beyond the plan's list.
  2. GPT is checked only at offset 512, as the plan says, not at 4096 (4Kn images). `hasGPT` only affects the ISO warning, and a 4Kn ISO is not a realistic input.
- **"Does not read the whole file"** is shown two ways. `readHeader` returns exactly 64 KiB from a 1 MiB file. A 1 TiB sparse file is inspected in well under the 5 s limit.
- **For T05/T09:** `ImageInfo.sizeBytes` is the true image length (`st_size`). It is captured at inspect time, so T05 should still treat a short read before that length as an error (the file changed), not as EOF.

---

### T05 — WriteEngine

**Goal:** stream an image onto an opened device with progress, speed and cancellation.

**Steps**
1. `WriteEngine.write(image:to:) -> AsyncThrowingStream<WriteProgress, Error>` (or an async function plus an `AsyncStream` of progress). `WriteProgress`: `bytesWritten`, `totalBytes`, `fractionComplete`, `bytesPerSecond` (smoothed with an exponential moving average over about 1 s windows), `estimatedSecondsRemaining`.
2. Pre-checks: device `byteCount >= image size`, else throw `imageTooLarge`.
3. Loop: read a chunk (about 4 MiB, a multiple of the device block size) from the source file into an aligned buffer; zero-pad the last partial block; write at the correct offset; handle short writes by retrying the remainder; check `Task.isCancelled` between chunks; `fullSync()` at the end (the handle owns the `F_FULLFSYNC` → `fsync` fallback from T02; the engine just treats a thrown error as failure).
4. Set `F_NOCACHE` on the device handle when applicable (inside the production handle, not the engine).
5. Emit progress at a throttled rate (at most about 10 per second).

**Acceptance criteria**
- Tests with `FileBackedDevice` (block sizes 512 and 4096): output file equals image bytes for sizes that are exact multiples, one byte over a multiple, and one chunk plus one byte; padding is zeros.
- Cancellation test stops within one chunk and does not call `fullSync` as success.
- Injected write failure and short write handled.
- Speed calculation unit-tested with a fake clock.

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 159 tests (38 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings. The engine tests were run 8 times with no flakes. Two mutations were caught: removing the padding zero-fill and removing the pre-sync cancel check.
- **Files** (in `Sources/ImageWriterCore/`): `WriteEngine`, `WriteEngineError`, `WriteResult`; shared with T06: `TransferProgress` (plus `typealias WriteProgress`), `SpeedEstimator`, `ProgressMeter`, `MonotonicClock`, `CancellationFlag`, `ImageSource`, `ImageSourceError`. Test helpers: `steppingClock`/`Recorder` in `TestSupport.swift`; `Gate`, `GatedDevice`, `ZeroWriteDevice` in `TestDevices.swift`.
- **API:** `WriteEngine(chunkSize: = 4 MiB, clock: = .system)`. The chunk is rounded down to a multiple of the device block size, minimum one block. There are two entry points:
  - `write(image:to:) -> AsyncThrowingStream<WriteProgress, Error>`, the plan's shape. Ending the iteration or cancelling the consumer cancels the write, but the in-flight chunk finishes in the background after the stream has ended.
  - `write(image:to:onProgress:) async throws -> WriteResult`, which returns or throws **only once the device is idle**. `onProgress` runs on the I/O thread. **T09 should use this one**, so the handle is not closed under a running chunk. Closing is still safe, because `RawDevice` locks per call.
  - Both run the synchronous `run(image:device:isCancelled:onProgress:)` on a GCD thread. `withTaskCancellationHandler` sets a `CancellationFlag` that the loop checks before each chunk and once more before `fullSync()`.
- **Progress:** `TransferProgress` has `completedBytes`, `totalBytes`, `bytesPerSecond?`, and computed `fractionComplete`/`estimatedSecondsRemaining`.
  - Speed is an EMA (newest window weighted 0.3) over windows that close at the first sample ≥ 1 s after they open. It is **nil for roughly the first second**, so T10 should show "—" until then.
  - Updates are throttled to one per 0.1 s. The 0-byte update and the one reaching `totalBytes` are always published.
  - The 100 % update goes out **before** `fullSync()`, which can take seconds on a USB stick. T09/T10 should show something like "Finishing…" until the call returns.
- **Errors:** pre-check `imageTooLarge` (nothing written); `write(DeviceIOError)` (T11: `ENXIO`/`EIO` = removal); `stalled(atOffset:)` for a 0-byte write; `sync(DeviceIOError)`; `ImageSourceError.changed` (size or type differs from `ImageInfo`, checked at open with `fstat`) and `.truncated(atOffset:)` (file ended early); `CancellationError` for cancel. Errors that are not `DeviceIOError` pass through unwrapped.
- **`WriteResult`:** `bytesWritten` (image bytes, without padding), `syncMethod`, `elapsedSeconds`.
- **For T06:** reuse `ImageSource.readFully`, `ProgressMeter`, `CancellationFlag`, `MonotonicClock` and the same GCD + cancellation-handler shape. Declare `typealias VerifyProgress = TransferProgress`.
- **Deviations:**
  1. One shared `TransferProgress` struct, with `completedBytes` instead of the plan's `bytesWritten`, so the verifier can reuse it.
  2. `fractionComplete` and `estimatedSecondsRemaining` are computed properties.
  3. Added the `onProgress` overload, `WriteResult`, `stalled`, and `ImageSourceError`.
  4. Step 4 (`F_NOCACHE`) was already done in T02 by `RawDevice`.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 177 tests (18 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings. T01 confirmed same-fd read-back, so the task needed no amendment. The verifier tests were run 8 times with no flakes. Three mutations were caught: comparing the padding too, removing the per-chunk cancel check, and reporting the mismatch index without the chunk's offset.
- **Files** (in `Sources/ImageWriterCore/`): `Verifier` (with `typealias VerifyProgress = TransferProgress`), `VerifierError`, `VerifyResult`. Tests: `VerifierTests`. `GatedDevice` (in `TestDevices.swift`) can now hold a read call (`gatedRead:`). Both of its gates are optional.
- **API:** it mirrors `WriteEngine`. `Verifier(chunkSize: = 4 MiB, clock: = .system)` has two entry points:
  - `verify(image:against:) -> AsyncThrowingStream<VerifyProgress, Error>`
  - `verify(image:against:onProgress:) async throws -> VerifyResult`. **T09 should use this one**, for the same reason as the write: it returns only once the device is idle.
  - `VerifyResult` has `bytesVerified` and `elapsedSeconds`.
  - The verifier never writes, syncs or closes the device. It opens the image again through `ImageSource`, so a file that changed size since it was selected throws `ImageSourceError.changed`.
- **Comparison:** each chunk reads the image bytes, then reads the device rounded up to whole blocks, and compares only the image length. The final block's padding is ignored, and the tests fill it with `0xEE` to prove that. `memcmp` decides whether a chunk matches, and only a mismatching chunk is scanned byte by byte to find the offset.
- **Errors** (`VerifierError`):
  - `imageTooLarge` is a pre-check, made before any read.
  - `read(DeviceIOError)`: for T11, `ENXIO`/`EIO` means the drive was removed.
  - `deviceEnded(atOffset:)`: a 0-byte read inside the device's size.
  - `verificationFailed(atOffset:)`: the image offset of the first differing byte.
  - `CancellationError` on cancel. Short reads are retried.
- **Cancellation** is checked before each chunk. A cancel that lands after the last chunk still returns success, because every byte was already compared (the write engine differs here, since it must not report a flush that didn't happen). T09 should check for cancellation itself after `verify` returns, if it wants a late cancel to win.
- **`FileBackedDevice`:** added `Faults.shortReadOnCall`, which returns half the request like `shortWriteOnCall`. It has its own test.
- **Deviations:**
  1. Added the `onProgress` overload, `VerifyResult`, and the `imageTooLarge`, `read` and `deviceEnded` error cases.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 197 tests (20 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings. Two mutations were caught: removing the name check and removing the dissent-text busy detection.
- **Files** (in `Sources/ImageWriterCore/`): `DiskManager` (protocol plus the `ejectAfterWrite` extension), `DiskutilDiskManager`, `DiskManagerError`, `EjectWarning`, `Fakes/FakeDiskManager`. Tests: `DiskutilDiskManagerTests` (includes `FakeDiskManagerTests`).
- **Real diskutil output.** It was captured on macOS 26.3.1 from a scratch file-backed `.dmg` (`hdiutil create`/`attach`). The script checked `BusProtocol == Disk Image` before each diskutil call, then detached and deleted the image. No real disk was touched. The texts are used verbatim in the tests:
  - **unmountDisk success, and already unmounted:** exit 0, stdout `Unmount of all volumes on diskN was successful`. Idempotency needs no extra code.
  - **Busy (unmountDisk and eject alike):** exit 1, stderr `Unmount of diskN failed: at least one volume could not be unmounted` / `Unmount was dissented by PID 57474 (/bin/sleep)` / `Dissenter parent PPID …`. **The word "busy" does not appear**, so the plan's "parse … busy" was widened: "dissented by", "could not be unmounted" or "busy" all map to `busy(dissenter:)`. The dissenter is the process path from the "dissented by PID" line, and the error message shows its last path component.
  - **Missing disk, unmountDisk:** exit 1, stderr only `Unmount failed for /dev/diskN`. This is mapped to `notFound` only when it is the **entire** output for **this** disk. Anything else is `commandFailed`.
  - **Missing disk, eject:** exit 1, stderr `Failed to find disk /dev/diskN`. This maps to `notFound`, as do `unable to find disk` and `could not find disk`.
  - **eject success:** exit 0, stdout `Disk /dev/diskN ejected`.
  - Both commands write text, not a plist, so failures are recognized from stdout and stderr combined (each trimmed, joined with a newline). `commandFailed.output` carries that text.
- **API:** `DiskutilDiskManager(runner: = ProcessCommandRunner())` runs `/usr/sbin/diskutil unmountDisk|eject /dev/diskN`. Exit 0 is success, whatever the text says. Failures are logged under category `diskmanager`. `CommandRunnerError` (launch failure, 30 s timeout) propagates unwrapped, as it does in discovery.
- **Step 3 (eject failure is a warning):** `DiskManager.ejectAfterWrite(bsdName:) async -> EjectWarning?` never throws. **T09 should use it for the final eject** and put the warning in the summary. `EjectWarning` is `Equatable` and carries `bsdName`, `reason` (the error's description) and `message` (done-screen text).
- **`FakeDiskManager`** is in the library for T09 tests and T10 Simulate mode. It takes `unmountError:`/`ejectError:` (both settable at runtime), records `calls` (`.unmount`/`.eject`), and validates names like production.
- **For T11:** `busy` during unmount means the user should close files or apps. `notFound` means the drive was removed between confirm and start. T08's SafetyGuard runs before unmount, so it should catch most removals first.
- **Deviations:**
  1. `busy` carries `dissenter: String?`, `notFound` carries `bsdName`, and `commandFailed` carries `command`, `status` and `output`. Added `invalidDiskName`.
  2. Busy detection matches the real dissent text, not just "busy" (see above).
  3. Added `ejectAfterWrite`, `EjectWarning` and `FakeDiskManager`.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 233 tests (36 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings, and `--release` now ends with "Release flag check passed". Run against the **Debug** app, the check finds all three markers in `IsoSword.debug.dylib` and exits 1. The Release binary still contains `DiskFilter`, `SafetyGuard` and `showAllExternal`, so the markers are gone because of `#if DEBUG`, not because unused code was stripped. Two mutations were caught: skipping the identity comparison, and accepting mounted disk images in debug mode.
- **Files** (in `Sources/ImageWriterCore/`): `SafetyGuard`, `SafetyGuardError`, `DiskIdentityField` (plus `DiskInfo.identityDifference(from:)`), `DebugTestMode` (the whole file is `#if DEBUG`). Changed: `DiskFilter` (debug-only `allowVirtualDisks`, `configured(showAllExternal:)`), `DiskRejection` (`explanation` text), `TargetDiskLister` (`targets(filter:)`). Script: `scripts/check-release-flags.sh`. Tests: `SafetyGuardTests`, `DebugTestModeTests` (`#if DEBUG`), `ReleaseFlagCheckTests`.
- **API for T09/T10:**
  - Build one filter with `DiskFilter.configured(showAllExternal:)` and use it for both `TargetDiskLister.targets(filter:)` and `SafetyGuard(runner:).validate(confirmed:filter:)`. `validate` takes the filter because the plan requires the disk to still be in the list "under the setting the user used". `targets(showAllExternal:)` still works and uses `configured` internally.
  - `validate` returns the freshly queried `DiskInfo` (`@discardableResult`). Its mount points may differ from the confirmed snapshot, so T09 can pass the fresh one on.
  - Order: invalid name (nothing run) → re-resolve boot disks → `listDisks` → exactly one entry with that name → identity → filter. It is the same diskutil query as the drive list (one `list` plus one `info` per disk), usually well under a second.
- **Errors** (`SafetyGuardError`, all mean nothing was unmounted or written):
  - `diskMissing(bsdName:)`: not listed any more (removed, or its `info` failed and discovery left it out).
  - `diskChanged(bsdName:field:)`: the first `DiskIdentityField` that differs. The fields are size, media name, block size, bus protocol and `DiskUUID`. Optionals are compared strictly, so a UUID that appears or vanishes counts as a change. Mount points and volume names are not identity.
  - `forbiddenTarget(bsdName:reason: DiskRejection)`: the fresh disk fails the filter, including `.bootDisk` from the fresh resolution and `.notUSB` when the setting no longer allows it. `DiskRejection.explanation` is a user-facing sentence, which T11 can reuse.
  - `queryFailed(reason:)`: any boot-resolution or discovery error, `CommandRunnerError` included, and a disk listed twice. `CancellationError` passes through unwrapped.
  - Refusals are logged under category `safety`.
- **Debug test mode:** run a Debug build with `ISOSWORD_ALLOW_VIRTUAL_DISKS=1` (exactly `1`), e.g. `ISOSWORD_ALLOW_VIRTUAL_DISKS=1 build/IsoSword.app/Contents/MacOS/IsoSword`. Under both settings the filter then also accepts **unmounted** disk images, such as `hdiutil attach -nomount ram://65536`. Every other rule still applies (internal, boot, APFS container, size 0). Virtual disks skip only the default-mode USB/removable rules, since an image is never on the USB bus. In Release, `DebugTestMode` and `DiskFilter.allowVirtualDisks` don't exist, and `configured` returns the plain filter.
- **`check-release-flags.sh <App.app>`** greps every file in the bundle for `ISOSWORD_ALLOW_VIRTUAL_DISKS`, `DebugTestMode` and `allowVirtualDisks`. It exits 1 on a leak and 2 (fails closed) if the bundle is missing, has no executable, or can't be searched. `build.sh --release` already called it when it existed, so `build.sh` was not changed. `ReleaseFlagCheckTests` runs it on fake bundles (clean, each marker, a marker in a non-executable file, missing or empty) and checks that the script lists `DebugTestMode.environmentKey`.
- **Deviations:**
  1. Added `diskMissing` and `queryFailed` beyond the plan's `diskChanged`/`forbiddenTarget`, so T11 can word a removal and a query failure differently.
  2. `validate(confirmed:filter:)` takes the filter (see above).
  3. Debug mode accepts only **unmounted** disk images. A mounted image is probably in use: on this machine, the iOS Simulator runtime is a mounted `Virtual` disk (seen in T01). The fixture `disk8` (mounted) stays hidden even with the switch on.
  4. Identity also compares block size and bus protocol, which are cheap and stable. Per T03, `DiskUUID` is usually absent on whole disks, so in practice the check rests on size, name, block size and bus.
  5. Added `DiskRejection.explanation` and `TargetDiskLister.targets(filter:)`.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 264 tests (31 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings, and the release flag check passes. The coordinator tests were run 8 times with no flakes. Four mutations were caught: removing the `defer` close, removing the cancel check after the open, treating an error after a cancel request as a failure, and skipping the safety guard.
- **Files** (in `Sources/ImageWriterCore/`): `WriteCoordinator`, `WriteState` (with `Phase` and `isRunning`), `PipelineStage`, `WriteFailure`, `WriteSummary`, `WriteCoordinatorError`. Tests: `WriteCoordinatorTests` (with `StateLog`, `EjectProbe`, `GatedOpener`, `CorruptingDevice`).
- **Shape:** `@MainActor @Observable final class`, so T10 binds to it directly (Observation is not SwiftUI, so the core stays UI-free). The slow work runs off the main thread inside the services. Observable properties: `state`, `selectedImage`, `selectedDrive` (both kept through the run and its result, so progress and done screens can name them) and `isCancelling` (show "Cancelling…" and disable the button).
- **Wiring:** `WriteCoordinator.live()` is the production setup (one `ProcessCommandRunner` shared by `SafetyGuard` and `DiskutilDiskManager`, plus `AuthopenOpener`). The designated init has **no defaults** for `safetyGuard`, `diskManager` or `opener`, so a test or Simulate setup can't reach diskutil or authopen by forgetting one. Engine, verifier, inspector and clock have defaults.
- **API and transitions** (an illegal call throws `WriteCoordinatorError.notAllowed(action, in: phase)` and changes nothing):
  - `selectImage(_:)` / `selectImage(at:) async throws` (inspects off main; throws `ImageInspectorError` and leaves the state alone): from idle, imageSelected or driveSelected. A drive already selected stays selected.
  - `selectDrive(_:filter:)`: from imageSelected or driveSelected. **Pass the same `DiskFilter` the list was built with**; it is stored and handed to `SafetyGuard.validate`.
  - `requestConfirmation()`: driveSelected → `awaitingConfirmation(image, disk)`.
  - `confirmAndStart()`: only from `awaitingConfirmation`. Returns the run's `Task` (`@discardableResult`); tests await it, the UI can ignore it.
  - `cancel()`: on the confirm screen it goes back to driveSelected. During preparing, writing or verifying it requests a stop; repeating it is a no-op. It throws while finishing (the drive is already verified) and in non-running states.
  - `reset()`: from any non-running state → idle, clearing the image, drive and filter.
- **Pipeline:** `preparing(.safetyCheck)` → `preparing(.unmount)` → `preparing(.open)` → `writing` → `verifying` → `finishing` → `finished`. `Task.checkCancellation()` runs after each preparing step. The **fresh** `DiskInfo` from `SafetyGuard` is what gets unmounted and opened. The device is closed explicitly before the eject, and a `defer` closes it on every other path. The eject uses `ejectAfterWrite`, and a failure only sets `WriteSummary.ejectWarning`.
- **Progress:** `.writing`/`.verifying` start at 0 bytes, then follow the engines' throttled updates. These hop to the main actor in their own tasks, so `apply` drops one from an older run (`runID`), from a pass that has ended, or one that is older than the current value. As T05 noted, the 100 % write update arrives **before** `fullSync()`. T10 should show "Finishing…" while `state` is `.writing` with `fractionComplete == 1`.
- **Cancel semantics:**
  - `.cancelled(stage)` tells T11 whether the drive was touched (`PipelineStage.mayHaveModifiedDrive`, true for `.write` and `.verify`).
  - Once a cancel was requested, **any** error that ends the run counts as `.cancelled` (logged under category `coordinator`). This covers authopen's `userCancelled` when the user clicked Cancel in the app and then dismissed the prompt.
  - A cancel that lands after the verifier compared its last chunk loses, and the run finishes. Every byte matched, so calling the drive undefined would be wrong (T06 left this to T09).
  - authopen ignores a cancel once its prompt is up. When the prompt returns an fd, the next check throws and the `defer` closes it (tested with `GatedOpener`).
- **For T11:** `.failed(WriteFailure)` carries `stage` and the original typed `error` (`SafetyGuardError`, `DiskManagerError`, `DeviceOpenError`, `WriteEngineError`, `VerifierError`, `ImageSourceError`, `CommandRunnerError`). `message` is just `localizedDescription`. T11 owns mapping these to user text and drive-state sentences. **Prompt cancel without an in-app cancel is currently `.failed(stage: .open, error: DeviceOpenError.userCancelled)`.** T11 step 3 should turn it into a return to the confirm step. The "image larger than drive" pre-check (T11 step 6) is not in the coordinator yet; the engine still catches it at the write stage.
- **Deviations:**
  1. `awaitingConfirmation` carries `(ImageInfo, DiskInfo)`, `preparing` carries a `PipelineStage` (safety check, unmount or admin prompt), and `cancelled` carries the stage it stopped in. The plan listed these without payloads.
  2. The plan's `Summary` is `WriteSummary`. It has image and drive names, BSD name, bytes, write/verify/total seconds, sync method and eject warning. "Average speed" is `averageWriteBytesPerSecond`: bytes over the write pass, flush included.
  3. Illegal calls throw rather than being ignored. `WriteFailure` is `Equatable` by stage plus `String(reflecting: error)`, so `WriteState` is `Equatable`.
  4. Added `selectImage(at:)`, `live()`, `isCancelling`, `selectedImage`/`selectedDrive`, `WriteState.phase`/`isRunning` and an internal `onTransition` test hook.

---

### T10 — SwiftUI shell and screens

**Goal:** the minimal GUI. One window, linear flow.

**Steps**
1. `App/` views bound to `WriteCoordinator` state:
   - **Image step:** "Select Image…" using `NSOpenPanel` (or `.fileImporter`) limited to `.iso`/`.img`; shows name and size; shows the non-boot warning if present.
   - **Drive step:** list of disks (name, size, BSD name); checkbox "Show all external disks"; refresh button and auto-refresh on disk changes (DiskArbitration notifications or a 2 s poll); empty state text ("Insert a USB drive").
   - **Confirm step:** "You are about to erase **<name>** (<size>, /dev/diskN). Mounted volumes: …. All data on this drive will be permanently lost." Buttons: Cancel, **Erase and Write** (destructive style). Add a line: "macOS will ask for an administrator password (the dialog says *authopen wants to make changes*)." T01 showed that the dialog names authopen, not the app, which could otherwise look suspicious.
   - **Progress step:** phase label (Writing / Verifying), progress bar, percent, speed (MB/s), ETA, Cancel button.
   - **Done step:** "Finished. You can remove the drive." with duration and average speed; "Write another" button.
   - **Error step:** plain-language message, what happened to the drive, "Try again".
2. Window sizing, no extras, no menu customization beyond defaults. Dark mode comes for free.
3. Keep views dumb: no disk or I/O logic in views.

**Acceptance criteria**
- `scripts/build.sh` succeeds.
- A SwiftUI preview or UI-less snapshot of each step compiles using a fake coordinator state (previews for every state).
- Walkthrough in the debug app with a fake pipeline (a `#if DEBUG` "Simulate" switch using `FakeDeviceOpener` and a temp file) shows every step including progress, done, and error. Record how to run the simulation in Handoff notes.

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 301 tests (37 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings, and the release flag check passes. The new suites were run 6 times with no flakes. Two mutations were caught: dropping the identity check when the list refreshes, and applying a stale drive-list refresh.
- **How to run the simulation:** `scripts/build.sh` (Debug), then `ISOSWORD_SIMULATE=1 build/IsoSword.app/Contents/MacOS/IsoSword`. A yellow banner says it is a simulation. Choose any `.img`/`.iso` of **at least 30 MB** (e.g. `mkfile -n 300m /tmp/sim.img`), then pick a drive. Each drive has a scripted outcome:
  - `disk90` works (about 40 MB/s write, 80 MB/s verify, 2 s "password prompt", 1 s flush).
  - `disk91` is pulled out mid-write (`ENXIO` on write call 6, about 21 MB in).
  - `disk92` returns bad data on read-back (mismatch at 8 MiB).
  - `disk93` fails as if the password dialog was cancelled.
  - `disk94` is 16 MB, so the image is too large.
  - `disk95` is a Thunderbolt SSD, shown only with "Show all external disks".
  - `disk0` is the simulated internal boot disk. It is listed by discovery and always filtered out.
  Nothing calls diskutil or authopen. Devices are sparse temp files, deleted when the run ends.
- **Walkthrough done by the agent** on the Simulate build, driven through System Events accessibility (screen capture isn't permitted in the agent's session, so the screens were checked through their accessibility text, not visually). Every step was reached: setup (image, drive, toggle), confirm (Cancel goes back), preparing (prompt text), writing with speed and ETA, "Finishing the write" during the flush, verifying, done (duration and average speed), failed (pulled out, verify mismatch, prompt cancelled, too large), and cancelled (during the prompt, the write and the verify). "Write Another" and "Try Again" return to the drive step with the image kept. The live Debug app was also opened read-only and showed "Insert a USB drive" under both settings. **Nick should still look at it once**, for layout and dark mode.
- **App files** (`App/`): `IsoSwordApp` (a single `Window`, not `WindowGroup`), `AppServices` (wires the coordinator and drive list, live or simulated), `ContentView` (switches on `coordinator.state` and forwards actions), `SetupView` + `ImageSection` + `DriveSection`, `ConfirmView`, `ProgressStepView`, `OutcomeView` (shared layout) + `DoneView`/`FailedView`/`CancelledView`, `ImageFileTypes`, `SimulationBanner` and `PreviewSamples` (both `#if DEBUG`). The step views take plain values and closures. Every state has a `#Preview` (in `#if DEBUG`), covering the 3 setup states, confirm, the 3 preparing stages, writing (speed unknown, normal, flushing), verifying, cancelling, ejecting, done (with and without an eject warning), failed (write, safety check) and cancelled (before and after the write).
- **Core additions** (`Sources/ImageWriterCore/`):
  - `DriveListModel` (`@MainActor @Observable`): `drives`, the `filter` they were built with, `showAllExternal`, `errorMessage`, `hasLoaded`, `refresh()`, `setShowAllExternal(_:)`, and `autoRefresh(every: 2 s)` for a view's `.task`, so polling stops off the setup screen. Only the newest refresh is applied. A failed refresh empties the list (fails closed). `onUpdate` is called after each applied refresh.
  - `WriteCoordinator.refreshSelectedDrive(from:filter:)`: on the drive step, a drive still listed with the same identity takes its fresh entry and the new list's filter. One that vanished or changed is deselected (back to `imageSelected`). `AppServices` connects it to `DriveListModel.onUpdate`, so the selection always matches the visible list and its filter. A test shows the safety check then uses the new filter.
  - `WriteCoordinator.reset(keepingImage:)`: `true` goes back to `imageSelected`, used by "Try Again", "Start Over" and "Write Another". The drive is always picked again.
  - `ProgressDisplay(state:isCancelling:)`: progress screen text. The 100 % write update reads "Finishing the write", the prompt stage names the authopen dialog, and the cancel button is disabled while finishing or once a cancel was requested.
  - `DisplayFormat`: sizes (decimal, as Finder shows them), speed, percent (never 100 % early), duration, time left, mount points. The output doesn't depend on the locale.
  - `PipelineStage.driveStateNote`: one sentence for the failed and cancelled screens.
  - `Fakes/StaticDiskDiscovery`, `Fakes/StaticBootDiskResolver` (not gated, like the other fakes).
  - `Simulation/` (every file is `#if DEBUG`): `SimulationMode` (env key, `makeLister()`, `makeCoordinator()`), `SimulatedDrive`, `SimulatedDevice` (throttled `FileBackedDevice`, optional corrupted read), `SimulatedOpener` (delay, then `FakeDeviceOpener`). `check-release-flags.sh` also checks `ISOSWORD_SIMULATE`, `SimulationMode` and `SimulatedDrive`, and `ReleaseFlagCheckTests` checks they match the code. The only related string left in the Release binary is the `isSimulation` property name, which is always false there.
- **For T11:**
  - The failed screen shows `failure.message` (the raw `localizedDescription`) and `stage.driveStateNote`. Seen in the walkthrough: the ENXIO text is technical ("write at offset … Device not configured (errno 6)"), and `imageTooLarge` says "may be partially written" although nothing was written (it fails in the pre-check, at stage `.write`). The error mapping should replace both.
  - A cancelled prompt currently shows the error screen ("The administrator password prompt was cancelled."), as T09 noted.
  - Closing the window during a write doesn't stop it, because `Window` doesn't quit on close. Quit is not guarded yet.
  - The drive list stops polling on the confirm screen, so a drive pulled out there is caught by the safety check, not the UI.
  - `ContentView.perform` shows a refused coordinator call in an alert. None appeared in the walkthrough.
- **Deviations:**
  1. The image and drive steps share one screen, as numbered sections, with the drive list disabled until an image is chosen. The coordinator already allows changing either one there.
  2. Added `DriveListModel`, `refreshSelectedDrive`, `reset(keepingImage:)`, `ProgressDisplay`, `DisplayFormat` and `driveStateNote` to the core, so the views hold no logic and the behavior is tested.
  3. Auto-refresh is a 2 s poll (the plan allows it), not DiskArbitration.
  4. Simulate is an environment variable (`ISOSWORD_SIMULATE=1`, matching `ISOSWORD_ALLOW_VIRTUAL_DISKS`), not an in-app switch. Its opener wraps `FakeDeviceOpener` with a delay, and each simulated drive scripts one outcome, so the error screens can be reached.
  5. "Write Another" keeps the image.

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

**Handoff notes:**
- **Done 2026-10-09.** `scripts/test.sh` passes 338 tests (37 new). `scripts/build.sh` and `--release` succeed for `x86_64 arm64` with no compiler warnings, and the release flag check passes. The suite was run 5 times with no flakes. Five mutations were caught: not ending the sleep activity, not returning to the confirm screen on a cancelled prompt, skipping the too-small check, and a `stopAndWait` that doesn't cancel or doesn't wait.
- **Core files** (`Sources/ImageWriterCore/`):
  - `FailureExplanation(_ failure:)`: `title`, `message`, `drive: DriveCondition` and optional `details` (the raw `localizedDescription`, only where it adds errno, diskutil output or authopen status). Every case of `SafetyGuardError`, `DiskManagerError`, `DeviceOpenError`, `WriteEngineError`, `VerifierError`, `ImageSourceError`, `DeviceIOError` and `CommandRunnerError` has its own wording; anything else falls back to the stage. A stage before the write always reports `.untouched`. A test checks that no title or message contains jargon (errno, exit status, authopen, posix).
  - `DriveCondition`: `.untouched`, `.partiallyWritten`, `.unverified` (written, read-back didn't finish), `.doesNotMatch` (mismatch, or the drive ended early), each with a `note`. `init(stoppedIn:)` is used by the cancelled screen and the quit alert. **Replaces `PipelineStage.driveStateNote`**, which is gone. A cancel during verify now says "unverified", not "partially written": the write and flush had finished.
  - Removal: `ENXIO`/`ENODEV` reads "The drive was disconnected"; `EIO` reads "The drive stopped responding" (removed or faulty). Both say the write was not retried. The coordinator never retried; a fault test now also checks that there is exactly one open, no flush, no verify, no eject, and that "Try Again" requires picking the drive again.
  - `DriveTooSmall` (from `ImageInfo.sizeBytes` vs `DiskInfo.sizeBytes`): `WriteCoordinator.driveTooSmall` is set on the drive step, and `requestConfirmation()` throws `WriteCoordinatorError.driveTooSmall(_)` (new case). The engine's own check stays as a backstop.
  - Prompt cancelled: `DeviceOpenError.userCancelled` at the open stage **without** an in-app cancel now returns to `.awaitingConfirmation`, with `WriteCoordinator.notice = .passwordPromptCancelled` (`WriteNotice`, cleared by the next state change). The drive is shown with no mount points, because the unmount before the prompt succeeded. With an in-app cancel first it is still `.cancelled(.open)`. The volumes are **not** remounted (see below).
  - `SleepPreventer` protocol, `ProcessInfoSleepPreventer` (`beginActivity([.userInitiated, .idleSystemSleepDisabled])`, display sleep still allowed) and `Fakes/FakeSleepPreventer`. The coordinator takes it as an init parameter (default: the real one) and holds one activity per run, from the safety check until the run ends, on every path. Visible as `PreventUserIdleSystemSleep named: "Writing <image> to diskN"` in `pmset -g assertions`.
  - `WriteCoordinator.stopAndWait()`: cancels a run that can still be cancelled, then waits for it to end; a run that is finishing (eject) is left to complete. `WriteState.cancellableStage` gives the stage a cancel would stop in (nil while finishing).
- **App files** (`App/`): `FailedView` shows the explanation (title, message, drive note, stage, selectable details). `ConfirmView` shows the notice. `SetupView` shows the too-small message and disables Continue; `DriveSection` marks rows "Too small for this image". New `AppDelegate` (via `@NSApplicationDelegateAdaptor`) and `WindowCloseGuard`. `AppServices.shared` is now the single instance used by the window and the delegate.
- **Quit and close:**
  - Close: while `state.isRunning`, `WindowCloseGuard` removes `.closable` from the window's style mask, so the close button is greyed out and ⌘W does nothing. It comes back when the run ends.
  - Quit (⌘Q, menu, logout): during preparing/writing/verifying an alert asks "Keep Writing" (default) or "Stop and Quit" (destructive), with the drive note for that stage. Stop and Quit cancels, replies `.terminateLater`, and quits once `stopAndWait()` returns, so the device is closed by the coordinator. During finishing it waits for the eject without asking. If the authopen dialog is up, the quit waits until the user answers it (authopen can't be interrupted); the alert says so.
  - New: closing the window when no run is in progress now quits the app (`applicationShouldTerminateAfterLastWindowClosed`). Before, the app kept running with no window.
- **Walkthrough by the agent** on the Simulate build, through System Events (accessibility text, not visually): the too-small message and disabled Continue (disk94), the prompt cancel back to the confirm screen with the notice and "Mounted volumes: none" (disk93), the close button disabled during the run and enabled after, ⌘W ignored mid-write, ⌘Q alert → Keep Writing (the run continued into verify) → ⌘Q → Stop and Quit (the app exited, no temp device files left), the removal failure screen (disk91), the sleep assertion present only during the run, and ⌘W quitting the idle app. **Simulate outcomes changed:** disk93 now returns to the confirm screen, and disk94 can't be confirmed, so the engine's "image too large" failure is no longer reachable from the UI.
- **For T12 / Nick:**
  - Check the quit alert and the greyed-out close button with a real write, and that the Mac doesn't idle-sleep during a long one.
  - The window opened on another Space when launched from a terminal while a full-screen app was in front. This is normal macOS behavior, not a T11 change.
- **Deviations:**
  1. Quit is confirmed with an alert (the plan allowed either); window close is disabled.
  2. Added `applicationShouldTerminateAfterLastWindowClosed` (single-window app).
  3. After a cancelled prompt the drive's volumes stay unmounted and the notice says so. Remounting would need a new `DiskManager.mount` call; left out as not needed for safety.
  4. Step 7 (app icon, About box) skipped, as the plan allows.

---

### T12 — 🧑 Hardware test checklist and README

**Goal:** document and execute the first real-world validation.

**Agent steps**
1. Write `docs/HARDWARE_TESTS.md` as a checklist with expected results, covering: RAM-disk dry run (debug flag), real USB stick with a hybrid Linux ISO (boots on a test machine), an `.img` write, an image bigger than the stick, ejecting the stick mid-write (use a spare stick), cancelling during write and during verify, cancelling the password prompt, boot disk and internal disks absent from both list modes, Apple Silicon and Intel runs if available. Also record whether the USB stick supports `F_FULLFSYNC` or the `fsync` fallback was used (needs a debug log line from T05/T02).
2. Finish `README.md`: what it is, requirements, build instructions, safety notes (what the app erases), known limitations (hybrid ISOs only, Windows ISOs unsupported), and the roadmap (SMAppService helper, signing and notarization).
3. Set status to `NEEDS_HUMAN` and stop.

**Human steps (Nick):** run the checklist, record pass/fail and notes in the file, file issues for failures.

**Acceptance criteria:** checklist completed by Nick; README accurate.

**Handoff notes:**
- **Agent prep done 2026-10-09, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 338 tests. `scripts/build.sh` and `--release` succeed for `x86_64 arm64`, and the release flag check passes. No code changed. The agent wrote to no disk; the only disk command run was a read-only `diskutil info -plist disk0`, to check the H14 snippet.
- **Nick: work through [`docs/HARDWARE_TESTS.md`](docs/HARDWARE_TESTS.md).** Fill in the environment table, each test's Result and Notes, the summary table and the flush-method line, and file issues for failures. Then tell the agent, who records the outcome here and marks T12 `DONE` if every test passed (or the failures are filed and accepted).
- **Checklist** (H1–H14): every item from agent step 1, plus the checks earlier tasks asked T12 for:
  - Layout and dark mode in Simulate (T10): H1.
  - Close button greyed out, quit alert and idle-sleep assertion during a real write (T11): H6 and H10.
  - What real USB, SD and Thunderbolt disks report (T03): H14, a read-only `diskutil info` snippet.
  - A drive-in-use test (H12), which is cheap and checks the busy wording and dissenter name from T07.
  - **`F_FULLFSYNC` vs fallback:** no new code was needed. `RawDevice` already logs `fullSync used F_FULLFSYNC` / `fullSync used fsync fallback` at info level under category `device` (T02). The checklist has Nick keep `log stream --predicate 'subsystem == "com.example.isosword"' --info` open. Info messages are not kept in the log store by default, so `log show` afterwards may miss them; it must be streamed live.
  - The RAM-disk run (H2) `chown`s the nodes to `root:operator`, as in T01 run 2, so the real password prompt appears.
- **README** rewritten: what it is, status, safety (what is erased and which checks prevent a wrong-disk write), requirements, build and run, the two debug-only modes, logs, how it works, known limitations, roadmap, layout. Limitations include the authopen-named dialog, one prompt per write, volumes left unmounted after a cancelled prompt (T11 deviation 3), and the quarantine workaround for the ad-hoc-signed app.
- **Deviations:** added H1 (Simulate look-through), H12 (drive in use) and H14 (disk reports) beyond the plan's list, so the requests from T03, T07, T10 and T11 have a place to be recorded.
- **2026-10-12: T13 runs before the remaining tests.** H1–H9 ran on the authopen-named-dialog build. Run H10, H11, H12 and H14 only after T13 is `DONE`, on the T13 build, and put the build's commit in each test's notes. See T13 "Order with T12".
- **2026-10-12: run them on the T14 build instead.** T14 renames the app to Red Delicious (`build/RedDelicious.app`, `REDDELICIOUS_*` env vars, subsystem `com.example.reddelicious`), and the checklist's unrun steps use the new names.
- **2026-10-13: and on the T23 build or later.** T23 renames the app to Raccoon Writer (`build/RaccoonWriter.app`, `RACCOONWRITER_*` env vars, subsystem `com.example.raccoonwriter`), and the checklist's steps use the new names.

---

### T13 — 🧑 Branded password prompt (`authopen -extauth`)

**Goal:** the admin dialog names ISO Sword instead of authopen. The app creates the authorization itself and hands it to authopen with `-extauth` (see `man authopen`). The fd passing, single open and the rest of the pipeline stay as they are. The app still never runs as root.

**Order with T12:** T13 runs before T12's remaining tests (H10, H11, H12, H14). H10 step 4 quits while the password dialog is up, which T13 changes, so H10 would need re-running after T13 anyway. H11 also exercises the new dialog on a real write. H12 stops before the prompt, and H14 only reads `diskutil`. The finished T12 results (H1–H9) stay valid; T13's human steps re-check the dialog text and cancel parts of H2, H5 and H6 on the new build.

**Agent steps**
1. Add a `DeviceAuthorizer` protocol to `ImageWriterCore`, with a production `SecurityAuthorizer` (Security.framework is a system framework, so there is still no dependency) and a `Fakes/FakeDeviceAuthorizer`. It takes a device path and returns a value that owns the `AuthorizationRef` and exposes its external form (`AuthorizationMakeExternalForm`, `kAuthorizationExternalFormLength` = 32 bytes).
   - Right: `sys.openfile.readwrite./dev/rdiskN`. It must match the path passed to authopen exactly. authopen asks for `readwrite` because of `-o 2`.
   - Flags: `kAuthorizationFlagInteractionAllowed | kAuthorizationFlagExtendRights | kAuthorizationFlagPreAuthorize`.
   - Environment: `kAuthorizationEnvironmentPrompt` with one plain sentence, for example "ISO Sword needs your password to erase and write the selected drive." The system's own "wants to make changes" line can't be removed.
   - Keep the `AuthorizationRef` alive until authopen has exited, because authopen resolves the external form while it runs. Free it on every path afterwards.
   - **Keep one prompt per write.** An in-process authorization may be reused within the right's `timeout` (300 s), unlike separate authopen runs (T01). Free with `kAuthorizationFlagDestroyRights` so the next write prompts again. Nick confirms this in human step 3.
   - Map `OSStatus`: `errAuthorizationCanceled` → `userCancelled`, `errAuthorizationDenied` → `permissionDenied`, anything else → a new `DeviceOpenError.authorizationFailed(status:)` whose description uses `SecCopyErrorMessageString`. Give the new case wording in `FailureExplanation`. The jargon test must still pass.
2. `AuthopenOpener` takes a `DeviceAuthorizer`. `init()` uses `SecurityAuthorizer`, and the internal `init(executable:authorizer:)` serves tests. In `obtainDescriptor`:
   - Authorize first, on the same GCD thread as now, because `AuthorizationCreate` blocks while the dialog is up. If it fails, authopen is never spawned.
   - Run `authopen -stdoutpipe -extauth -o 2 /dev/rdiskN` with stdin on a pipe instead of `/dev/null`. Write the 32 bytes, then close the write end, before `recvmsg`. 32 bytes is under `PIPE_BUF`, so the write can't block.
   - **Set `F_SETNOSIGPIPE` on the write end.** If authopen exits before reading stdin, a plain write raises `SIGPIPE` and kills the app. Treat `EPIPE` as "authopen exited early" and map the error from its exit status and stderr as usual.
   - Make the stdin pipe `FD_CLOEXEC`, like the other parent ends, and keep `POSIX_SPAWN_CLOEXEC_DEFAULT`.
   - Keep the stderr cancel mapping as a fallback: it covers a dialog from authopen itself (see human step 2).
3. Tests (none may call `AuthorizationCreate` or authopen):
   - The `OSStatus` mapping.
   - A failed or cancelled authorization never spawns the stand-in script.
   - The stand-in script receives `-extauth` in argv and exactly the fake's 32 bytes on stdin.
   - A stand-in that exits without reading stdin doesn't crash the test process and maps to an error.
   - The authorization value is freed on success, on failure and when no fd arrives.
4. Update user-facing text that quotes the old dialog: `ProgressDisplay.swift` (the "authopen wants to make changes" detail), `ConfirmView.swift`, `README.md` (the safety note, the limitation "The dialog names `authopen`", the roadmap item, how-it-works), and the `-extauth` bullet in section 4. In `docs/HARDWARE_TESTS.md`, update the steps and expected results of the tests not yet run (H10 step 4) and of H5 step 3, which quote the dialog. Leave T01's and T12's recorded results and notes as they are; they describe the old build.
5. `scripts/test.sh` and `scripts/build.sh --release` pass. Write exact instructions for Nick under Handoff notes, set `NEEDS_HUMAN`, and stop.

**Human steps (Nick)**
1. **RAM disk, Debug build**, with nodes chowned `root:operator` as in H2 (`docs/HARDWARE_TESTS.md`), so the real prompt appears. Write and verify `ram-test.img`. Record the exact dialog text and which icon it shows (the app has no icon yet, T11 step 7).
2. Confirm **exactly one** dialog appears. A second dialog naming authopen means the external authorization didn't satisfy authopen. If that happens, copy the log window's `authopen` lines.
3. Run a second write within 5 minutes. Record whether it prompts again. It should.
4. Cancel the dialog. The app returns to the confirm screen with the notice, as in H5.
5. Enter a wrong password until macOS gives up. Record the screen the app shows.
6. **Real USB stick, Release build:** one full write and verify, to confirm the dialog and the write on real hardware.

**Acceptance criteria**
- The dialog names ISO Sword, and only one dialog appears per write.
- Each write prompts once, including a second write within 5 minutes.
- A cancel returns to the confirm screen, as before. A wrong password gives a clear failure screen with no jargon.
- No test calls `AuthorizationCreate` or authopen. `scripts/test.sh` and `scripts/build.sh --release` pass.
- No user-facing text still quotes "authopen wants to make changes".

**Files:** `Sources/ImageWriterCore/` (`DeviceAuthorizer`, `SecurityAuthorizer`, `Fakes/FakeDeviceAuthorizer`, `AuthopenOpener`, `DeviceOpenError`, `FailureExplanation`, `ProgressDisplay`), `App/ConfirmView.swift`, `Tests/`, `README.md`, `docs/HARDWARE_TESTS.md`

**Handoff notes:**
- **Agent prep done 2026-10-12, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 353 tests (338 before). `scripts/build.sh` (Debug) and `scripts/build.sh --release` succeed for `x86_64 arm64` with no Swift warnings, and the release flag check passes. The agent wrote to no disk and never ran authopen or `AuthorizationCreate`.
- **What was built:**
  - `DeviceAuthorizer` (protocol), `DeviceAuthorization` (protocol: `externalForm` of 32 bytes and `release()`), production `SecurityAuthorizer` + `SecurityAuthorization`, and `Fakes/FakeDeviceAuthorizer` (+ `FakeDeviceAuthorization`, which counts releases).
  - `SecurityAuthorizer` requests `sys.openfile.readwrite./dev/rdiskN` with `interactionAllowed | extendRights | preAuthorize` and the prompt "ISO Sword needs your password to erase and write the selected drive." `SecurityAuthorization.release()` calls `AuthorizationFree(…, destroyRights)`, is idempotent, and also runs from `deinit` as a safety net.
  - `OSStatus` mapping: `errAuthorizationCanceled` → `userCancelled`, `errAuthorizationDenied` → `permissionDenied`, anything else → new `DeviceOpenError.authorizationFailed(status:)`, described with `SecCopyErrorMessageString`. `FailureExplanation` gives it "The password couldn’t be checked" with the system text in the details line.
  - `AuthopenOpener.obtainDescriptor` authorizes first (on the same GCD thread), then runs `authopen -stdoutpipe -extauth -o 2 /dev/rdiskN` with stdin on a pipe. The 32 bytes are written and the write end closed before `recvmsg`. The authorization is released by `defer` after authopen has exited, on every path. Authopen's stderr cancel mapping is kept as a fallback.
  - The stdin pipe is made by `makeInputPipe()`: both ends `FD_CLOEXEC`, write end `F_SETNOSIGPIPE`. A failed write (EPIPE) is logged and the error is then mapped from authopen's exit status and stderr as before. `POSIX_SPAWN_CLOEXEC_DEFAULT` is unchanged.
  - User-facing text: `ProgressDisplay` now says "Enter an administrator password in the dialog from ISO Sword." `ConfirmView` says "ISO Sword will ask for an administrator password." README safety note, how-it-works, limitations and roadmap updated. Section 4's `-extauth` bullet marked implemented. In `docs/HARDWARE_TESTS.md`, H5 step 3 and H10 step 4 no longer quote the authopen dialog.
- **Tests:** `OSStatus` mapping, right name, prompt text, error description, external form length (`SecurityAuthorizerTests`). In `AuthopenOpenerTests`: failed/cancelled/denied authorization never spawns the stand-in; the stand-in gets `-extauth` and exactly the fake's 32 bytes on stdin (read to EOF, so it also proves the write end is closed); a stand-in that closes stdin and exits is an error, not a crash (20 runs); a deterministic test writes to a pipe with no reader and gets `EPIPE`; the authorization is released exactly once on success, on authopen failure, on exit without an fd, on a signal and on a spawn failure, and is still alive while authopen runs; two opens authorize twice. "OSStatus" added to the jargon list in `FailureExplanationTests`. **Mutation-checked:** removing `F_SETNOSIGPIPE` kills the test process.
- **Deviations:**
  1. Release is an explicit `release()` on a `DeviceAuthorization` protocol, not only `deinit`, so tests can check it is freed on every path.
  2. `obtainDescriptor` has an internal `runner` parameter (default `run`). A shell stand-in can't send an fd over `SCM_RIGHTS`, so the success-path release test uses it.
  3. The app's text no longer quotes the dialog's headline; it says "the dialog from ISO Sword". The exact macOS headline is unknown until human step 1. If it's worth quoting, update `ProgressDisplay` and `ConfirmView` then.
  4. H2's expected line got a note that builds from T13 on name ISO Sword. H2's recorded result and notes are unchanged.
- **Nick: run these on the current commit**, with the log open in a second Terminal window:
  ```sh
  log stream --predicate 'subsystem == "com.example.isosword" OR process == "authopen"' --info
  ```
  1. **RAM disk, Debug build.** `scripts/build.sh`. Create the RAM disk and `chown` its nodes exactly as in H2 step 2 of `docs/HARDWARE_TESTS.md`. Then run `ISOSWORD_ALLOW_VIRTUAL_DISKS=1 build/IsoSword.app/Contents/MacOS/IsoSword`, write `~/iso-sword-test/ram-test.img` to the RAM disk and enter your password. **Record the exact dialog text** (headline and message) and **which icon it shows**. Expect the message "ISO Sword needs your password to erase and write the selected drive."
  2. **Count the dialogs.** Exactly one should appear. If a second one naming authopen appears, copy the log's `authopen` lines and tell the agent.
  3. **Second write within 5 minutes** of entering the password in step 1. The RAM disk is ejected after a successful write, so create a new one with the H2 step 2 snippet first. Record whether it prompts again. It should.
  4. **Cancel.** Start another write and click Cancel in the dialog. Expect the confirm screen with the notice, as in H5.
  5. **Wrong password.** Start another write and enter a wrong password until macOS stops asking. Record the screen the app shows. Expect "Permission was refused".
  6. **Real USB stick, Release build.** `scripts/build.sh --release`, then `open build/IsoSword.app`. One full write and verify to the test stick. Record the dialog text and icon, and whether the write and verify passed.
  7. Clean up any RAM disk still attached: `hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"`.
  
  Then tell the agent the results. If they meet the acceptance criteria, the agent records them here and marks T13 `DONE`. After that, run T12's H10, H11, H12 and H14 on the T13 build.
- **Human results, 2026-10-12, commit `0639200`** (Nick ran the steps in the order cancel, wrong password, write, second write, USB, so one pair of RAM disks covered steps 1–5):
  - **Step 1, dialog (Debug, RAM disk with `root:operator` nodes):** named ISO Sword, as expected. Nick didn't record the exact headline or the icon.
  - **Step 2:** exactly one dialog per write. No second authopen dialog. The log was as expected (`fullSync used fsync fallback`). So the external authorization satisfies authopen.
  - **Step 3:** a second write within 5 minutes prompted again. `destroyRights` works.
  - **Step 4:** Cancel returned to the confirm screen with the notice, as in H5.
  - **Step 5:** after 5 wrong passwords macOS was still asking. It never gives up: the agent read the rule (read-only `security authorizationdb read sys.openfile.`): `authenticate-user`, group `admin`, `timeout` 300, **`tries` 10000**. Only Cancel ends the dialog, and that is step 4's path.
  - **Step 6 (Release, real USB stick):** one dialog, then write and verify passed.
- **Acceptance:** every criterion is met except "a wrong password gives a clear failure screen", which can't be reached on a real Mac because of `tries` 10000. The code path is still covered: `errAuthorizationDenied` → `permissionDenied` → "Permission was refused" is unit-tested (`SecurityAuthorizerTests`, `FailureExplanationTests`). Marked `DONE` with this as a recorded deviation.

---

### T14 — Rename to Red Delicious Media Writer

**Goal:** the app is called **Red Delicious Media Writer**, or **Red Delicious** for short. Rename the display name and every internal identifier. `ImageWriterCore` keeps its name because it's generic. The GitHub repo and local folder stay `iso-sword` (see section 4).

**Name mapping**

| Old | New |
| --- | --- |
| "ISO Sword" | `AppInfo.displayName` = "Red Delicious Media Writer"; new `AppInfo.shortName` = "Red Delicious" |
| `IsoSword` (XcodeGen project, target, scheme, `PRODUCT_NAME`, `.app`, executable) | `RedDelicious` |
| `IsoSwordApp` / `App/IsoSwordApp.swift`, `App/IsoSword.entitlements` | `RedDeliciousApp` / `App/RedDeliciousApp.swift`, `App/RedDelicious.entitlements` |
| `com.example.isosword` (bundle ID and log subsystem) | `com.example.reddelicious` |
| `ISOSWORD_ALLOW_VIRTUAL_DISKS`, `ISOSWORD_SIMULATE` | `REDDELICIOUS_ALLOW_VIRTUAL_DISKS`, `REDDELICIOUS_SIMULATE` |
| `isosword-*` temp prefixes, `/nonexistent/isosword/…` test paths | `reddelicious-*`, `/nonexistent/reddelicious/…` |

**Where each name goes:** the full name in `CFBundleDisplayName` (Finder, Dock), the window title and the README heading. The short name in `CFBundleName` (menu bar, at most 15 characters) and in sentences, e.g. "Red Delicious needs your password…".

**Order with T12:** T12's remaining tests (H10, H11, H12, H14) run on the T14 build, so the checklist's `.app` path, env vars and log predicate match what Nick launches.

**Agent steps**
1. Core: `AppInfo` (`displayName`, new `shortName`, `bundleIdentifier`). `SecurityAuthorizer.prompt` and `ProgressDisplay` use `shortName`. New env keys in `DebugTestMode` and `SimulationMode`. Change the `FileBackedDevice` temp prefix. Update comments that name the app.
2. App and project: `git mv` the app struct file and entitlements, then rename the struct. `Info.plist` names. `ConfirmView` and `AppDelegate` interpolate `AppInfo.shortName`. Update `project.yml` (name, target, scheme, `PRODUCT_NAME`, bundle ID, entitlements and excludes), `scripts/build.sh` and `scripts/check-release-flags.sh`. Delete the stale generated `IsoSword.xcodeproj` and `build/IsoSword.app`.
3. Tests: `AppInfoTests` checks both names and that `shortName` fits `CFBundleName`'s 15 characters. Update the strings in `SecurityAuthorizerTests`, `ProgressDisplayTests`, `CoordinatorFaultTests`, `DebugTestModeTests`, `SimulationModeTests`, `ReleaseFlagCheckTests`, and every `isosword-` prefix and `/nonexistent/isosword/` path.
4. Docs: README (heading, prose, commands, log subsystem, quarantine command, a "formerly ISO Sword" line). In `docs/HARDWARE_TESTS.md`, update the intro, setup and steps of tests not yet run (H10, H11, H12, H14). Leave recorded results as they are, and add a line on pre-T14 names. Keep `~/iso-sword-test/`. Update the `AGENTS.md` title and this file's title, intro and section 1 rows. Leave earlier handoff notes and the change log as history.
5. `scripts/test.sh`, `scripts/build.sh` and `scripts/build.sh --release` pass. Fill in Handoff notes, mark `DONE` and commit.

**Acceptance criteria**
- `plutil -p build/RedDelicious.app/Contents/Info.plist` shows `CFBundleDisplayName` "Red Delicious Media Writer", `CFBundleName` "Red Delicious", `CFBundleIdentifier` `com.example.reddelicious` and `CFBundleExecutable` `RedDelicious`.
- `git grep -i -E "iso ?sword|isosword"` matches only history (this file's earlier tasks and change log, HARDWARE_TESTS recorded results and the pre-T14 note), the README "formerly" line and clone URL, and the repo mention in `AGENTS.md`.
- `scripts/test.sh` and `scripts/build.sh --release` pass, including the release flag check with the new markers.

**Files:** `Sources/ImageWriterCore/` (`AppInfo`, `SecurityAuthorizer`, `ProgressDisplay`, `DebugTestMode`, `Simulation/SimulationMode`, `Fakes/FileBackedDevice`, comments), `App/`, `project.yml`, `scripts/`, `Tests/`, `README.md`, `docs/HARDWARE_TESTS.md`, `AGENTS.md`, `PLAN.md`

**Handoff notes:**
- **Done 2026-10-12.** `scripts/test.sh` passes 355 tests (353 before; the 2 new ones are in `AppInfoTests`). `scripts/build.sh` and `scripts/build.sh --release` succeed for `x86_64 arm64` with no Swift warnings, and the release flag check passes with the `REDDELICIOUS_*` markers. `plutil -p build/RedDelicious.app/Contents/Info.plist` shows the four expected values. No disk was touched.
- **What changed:** everything in the name mapping above. `AppInfo.shortName` is new. `SecurityAuthorizer.prompt`, `ProgressDisplay`, `ConfirmView` and `AppDelegate` interpolate it instead of a literal, so the next rename only needs `AppInfo` and `Info.plist`. The window title still comes from `AppInfo.displayName`, so it shows the full name. The stale gitignored `IsoSword.xcodeproj` and `build/IsoSword.app` were deleted.
- **Left as history:** earlier tasks' handoff notes and the change log in this file. In `docs/HARDWARE_TESTS.md`, the recorded results (H3 part 1, the H6 flush log line, the H13 notes, the H14 SD-card entry) keep the old names, and the intro has a line explaining pre-T14 names. `~/iso-sword-test/` is unchanged because it's Nick's local folder. Remaining `git grep -i "iso ?sword|isosword"` matches are only these places, the README "formerly" line and `AGENTS.md`'s repo mention.
- **Side effects for Nick:**
  - The new bundle ID makes macOS treat this as a new app, so the removable-volume privacy prompt may appear again.
  - Log predicates must use `com.example.reddelicious`.
  - The env vars are now `REDDELICIOUS_SIMULATE` and `REDDELICIOUS_ALLOW_VIRTUAL_DISKS`.
  - `build/` currently holds the Release build. Run `scripts/build.sh` for Debug.
- **Deviation:** the plan said to update only the steps of unrun tests in `docs/HARDWARE_TESTS.md`. The commands in the steps of tests already run (H1, H2, H3, H13) also use the new names, so the steps work if someone re-runs them. Only results and notes keep the old names.

---

### T15 — App icon

**Goal:** the app has its red apple icon in Finder, the Dock and the app switcher. Nick supplied the artwork in `icons/`: a complete `AppIcon.appiconset`, loose PNGs (16–1024) and an `AppIcon.icns`.

**Agent steps**
1. Move `icons/AppIcon.appiconset` to `App/Assets.xcassets/` and add the catalog's `Contents.json`.
2. Set `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `project.yml`.
3. Delete `icons/`: the loose PNGs and the `.icns` duplicate the set.
4. `scripts/test.sh` and `scripts/build.sh --release` pass.

**Acceptance criteria**
- `build/RedDelicious.app/Contents/Resources/` contains `AppIcon.icns` and `Assets.car`, and `Info.plist` has `CFBundleIconName` = `AppIcon`.

**Files:** `App/Assets.xcassets/`, `project.yml`, `PLAN.md`

**Handoff notes:**
- **Done 2026-10-12.** `scripts/test.sh` passes 355 tests. `scripts/build.sh --release` succeeds for `x86_64 arm64` and the release flag check passes. The bundle has `CFBundleIconFile` and `CFBundleIconName` = `AppIcon`. `assetutil` shows all 10 renditions (16–1024 px) in `Assets.car`. actool puts only 16–256 px into the `.icns`, as a fallback.
- **Supplied files:** the set's `Contents.json` was already valid and every slot had the right pixel size, so it was used unchanged. The loose PNGs, the `.icns` and the `icons/` folder were deleted. They were never committed.
- **For Nick:** check whether the password dialog now shows the apple. If it does, remove "The password dialog has no custom icon yet" from the README's known limitations. Finder and the Dock may keep showing the old icon until the icon cache refreshes, for example after moving the app or logging out.

---

### T16 — 🧑 Password prompt before the safety check; size check after open

**Goal:** close a review finding. The pipeline ran safety check → unmount → password dialog → authopen, and wrote whatever authopen opened. The dialog can stay open indefinitely. If the stick is unplugged meanwhile and another disk attached, macOS usually gives the new disk the same `diskN`, and the authorization (`sys.openfile.readwrite./dev/rdiskN`) covers the path, not the medium. A backup drive that would never pass the filter could be written. Fix it in two parts:
1. Show the dialog first, then run the safety check, unmount and authopen back to back. authopen gets the authorization through `-extauth` (T13), so it doesn't prompt.
2. After the open, require the opened device's block size and block count × block size to match the disk the safety check returned.

This also removes the README limitation "after a cancelled password prompt the drive stays unmounted". Out of scope by Nick's decision: a stronger hardware identifier (such as the IOKit registry entry ID of the opened descriptor), so two identical sticks still look the same.

**Order with T12:** T12's remaining tests (H10, H11, H12, H14) run on the T16 build. H12's expected result changes: the dialog now appears before the unmount fails.

**Agent steps**
1. Split `DeviceOpener` into `authorize(bsdName:) -> DeviceGrant` (shows the dialog, opens nothing) and `DeviceGrant.open()` (no prompt) plus `release()`. `AuthopenOpener.authorize` runs `DeviceAuthorizer` off the cooperative pool; the new `AuthopenGrant` owns the authorization and runs authopen with it. `obtainDescriptor` no longer authorizes or frees.
2. Add `PipelineStage.authorize` before `.safetyCheck`. The coordinator authorizes first, then validates, unmounts, opens, releases the grant as soon as the descriptor arrives, then calls the new `SafetyGuard.checkOpened`. A `defer` releases the grant on every other path. Only a cancel of the app's own dialog (stage `.authorize`) returns to the confirm screen; the drive is untouched, so the `mountPoints = []` workaround goes.
3. Update the fakes (`FakeDeviceOpener` with `authorizeError:`/`openError:`, `FakeDeviceGrant` counting releases), Simulate mode, `ProgressDisplay`, `AppDelegate`, `WriteNotice`, previews, README and `docs/HARDWARE_TESTS.md` (H5 and H12 expectations, new H15).
4. Tests: a disk that takes the name during the dialog is refused before unmount and open; an opened device of another size or block size is never written; the grant is released exactly once on success, failure and cancel; a cancelled dialog unmounts nothing; a cancel reported by authopen itself fails plainly.
5. `scripts/test.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**
1. RAM disk, Debug build: one full write. Exactly one dialog appears, even though authopen now runs a moment after the dialog, once the unmount is done.
2. H15: swap RAM disks while the dialog is open. The write is refused.
3. Real USB stick, Release build: H5 (cancel the dialog). The volume stays mounted.
4. Real USB stick, Release build: one full write and verify. It passes, which confirms the size check matches what real hardware reports.

**Acceptance criteria**
- The dialog comes before the safety check and the unmount, and a disk swapped in during the dialog is refused (unit test and H15).
- An opened device whose size or block size differs from the checked disk is never written (unit tests).
- One dialog per write; a full write and verify to a real stick passes.
- A cancelled dialog leaves the drive mounted. The README no longer lists the unmounted-after-cancel limitation.
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `Sources/ImageWriterCore/` (`DeviceOpener`, new `DeviceGrant`, new `AuthopenGrant`, `AuthopenOpener`, `DeviceAuthorization`, `SecurityAuthorization`, `SafetyGuard`, `SafetyGuardError`, `PipelineStage`, `DriveCondition`, `ProgressDisplay`, `WriteCoordinator`, `WriteNotice`, `Fakes/FakeDeviceOpener`, `Simulation/`), `App/` (`AppDelegate`, `ConfirmView`, `PreviewSamples`, `ProgressStepView`), `Tests/`, `README.md`, `docs/HARDWARE_TESTS.md`

**Handoff notes:**
- **Agent prep done 2026-10-12, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 371 tests (355 before). `scripts/build.sh` and `scripts/build.sh --release` succeed with no Swift warnings, and the release flag check passes. The agent wrote to no disk and never ran authopen or `AuthorizationCreate`.
- **What was built:**
  - `DeviceOpener.authorize(bsdName:)` returns a `DeviceGrant` (`bsdName`, `open()`, `release()`, idempotent). `AuthopenGrant` holds the `DeviceAuthorization` and releases it once, also from `deinit`. `DeviceAuthorization` is now `Sendable`, and `SecurityAuthorization` guards its reference with a lock because it's released on a different thread from the one that created it.
  - `PipelineStage.authorize` ("Getting permission to write") is the first stage. `.open` is now "Opening the drive" with no dialog hint. `ProgressDisplay` and the quit alert key the dialog text off `.authorize`.
  - `SafetyGuard.checkOpened(_:matches:)` compares block size (when diskutil reported one) and then bytes, and throws the existing `SafetyGuardError.diskChanged`, so the failure screen says "A different drive is attached". The failure is in stage `.open`, so the drive is reported untouched. A disk with unknown size (discovery falls back to 0) fails closed.
  - `WriteNotice.passwordPromptCancelled` now says the drive was left as it was.
- **Mutation-checked:** with the old order (validate before authorize), the swap-during-dialog test writes the backup drive and fails. Without `checkOpened`, both opened-device tests write the wrong device and fail.
- **Deviations:**
  1. `userCancelled` during `.open` (authopen showing its own dialog, which T13 showed doesn't happen) is now a plain failure, not a return to the confirm screen, because by then the drive is unmounted.
  2. The coordinator test suites' disk fixture now has the size of their 32 KiB fake device (`DiskInfo.usbStick(sizeBytes:)`), since the open is checked against it.
- **Nick: run these on the T16 commit**, with the log open in a second Terminal window:
  ```sh
  log stream --predicate 'subsystem == "com.example.reddelicious" OR process == "authopen"' --info
  ```
  1. **RAM disk, Debug build.** `scripts/build.sh`, create the RAM disk exactly as in H2 step 2 of `docs/HARDWARE_TESTS.md`, then run `REDDELICIOUS_ALLOW_VIRTUAL_DISKS=1 build/RedDelicious.app/Contents/MacOS/RedDelicious`. Write `~/iso-sword-test/ram-test.img` to the RAM disk. **Count the dialogs: exactly one.** The progress screen should show "Getting permission to write" with the dialog, then "Checking the drive", "Unmounting the drive" and "Opening the drive" quickly after you enter the password. Write and verify should pass. If a second dialog naming authopen appears, or the log shows `Refused … after opening`, copy the log lines.
  2. **H15** in `docs/HARDWARE_TESTS.md`: swap RAM disks while the dialog is open. Record the result there.
  3. **Real USB stick, Release build.** `scripts/build.sh --release`, then `open build/RedDelicious.app`. Run **H5** (cancel the dialog) with a mounted volume on the stick. Expect the confirm screen with "…the drive was left as it was", and the volume still in Finder.
  4. **Same stick:** one full write and verify. Expect one dialog, then a pass. If it fails with "A different drive is attached", copy the `Refused` log line: it means the opened size differs from what diskutil reports on real hardware.
  5. Clean up any RAM disk still attached: `hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"`, and the same with `"$DISK2"` after H15.

  Then tell the agent the results. If they meet the acceptance criteria, the agent records them here and marks T16 `DONE`.
- **Human results, 2026-10-12, commit `e55abea`:**
  - **Step 1 (Debug, RAM disk):** exactly one dialog, then write and verify passed. So authopen accepts the external authorization when it runs after the unmount rather than straight after the dialog, and the size check matches on a RAM disk.
  - **Step 2 (H15):** the first attempt didn't test the takeover: leftover RAM disks (`disk10`, `disk11`) were attached, so A became `disk12` and B took the lowest free number, `disk8`. After detaching the leftovers, A and B were both `disk8`, and the app showed "A different drive is attached" (size changed) after the password. H15 step 2 now says to detach other RAM disks first.
  - **Step 3 (Release, real stick, H5):** the stick still held the FreeBSD image from H7, which macOS can't mount, so Nick erased it to ExFAT `TESTSTICK` with a test file first. Cancelling the dialog returned to the confirm screen with the new notice, and the volume stayed mounted.
  - **Step 4 (Release, real stick):** one dialog, then write and verify passed. The opened device's size and block size match what diskutil reports for the Cruzer Glide.
  - Side note: the first Debug launch didn't list the RAM disk because `build/` still held the agent's Release build; `scripts/build.sh` fixed it.
- **Acceptance:** every criterion is met. Marked `DONE`.

---

### T17 — 🧑 Layered app icon (Icon Composer) with dark variant

**Goal:** the icon follows the macOS 26 icon style (Default, Dark, Clear, Tinted) like Nick's other apps. Today it doesn't: the T15 PNGs have a cream rounded square painted in, so macOS 26 can't recolour them and shows the same cream tile in Dark mode. The fix is an Icon Composer `.icon` file, with the apple as a transparent foreground layer and the background as a fill that the system can swap. macOS 14 and 15 must still get a working icon.

**Artwork:** the `.icon` file needs the apple without the square and without its baked-in drop shadow, because Icon Composer adds its own shadow. If Nick has the original artwork, use it. Otherwise the agent cuts the apple out of `icon_512x512@2x.png` (1024 px) and Nick approves the result in step 1 below. Edges may need cleanup.

**Agent steps**
1. Get the foreground: Nick's original, or a cutout from the 1024 px PNG with transparent background, no square, no ground shadow. Keep the source PNG under `App/AppIcon.icon/Assets/`, not loose in the repo.
2. Draft `App/AppIcon.icon` (the `icon.json` and `Assets/` bundle Icon Composer writes): one layer with the apple and a background fill that matches the current cream tile, so the Default look is unchanged. If you can't produce a bundle that `actool` accepts, stop and ask Nick to create it in Icon Composer from the foreground PNG instead.
3. Wire it up in `project.yml`. The `.icon` file has to be a single file reference in the Resources phase, not a group, so check how XcodeGen 2.46 adds it and set its `type`/`buildPhase` explicitly if needed. Keep `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`, which now names the `.icon` file.
4. Pre-26 fallback: build, then inspect `Assets.car` (`assetutil --info`) and `AppIcon.icns`. If Xcode generates legacy renditions from the `.icon` file, delete `AppIcon.appiconset`. If not, keep the set as the macOS 14/15 icon, and make sure the two don't clash under the same name. Record which one applied in the Handoff notes.
5. `scripts/test.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**, on the T23 build or later. T23 replaced the apple with the raccoon from Nick's branding pack, so these steps check the raccoon.
1. Open `App/AppIcon.icon` in Icon Composer (`/Applications/Xcode.app/Contents/Applications/Icon Composer.app`). Check the cutout edges and preview Default, Dark, Clear and Tinted. Adjust if you like and save. If you change anything, tell the agent so it rebuilds.
2. `scripts/build.sh --release`, then copy `build/RaccoonWriter.app` somewhere new (for example `~/Applications`) and open it there. This avoids the stale icon cache. Under System Settings › Appearance, switch the icon style through Default, Dark, Clear and Tinted. Check that the Dock and Finder icon follows each one, and that in Dark it sits on the dark background like the other apps.
3. Optional, if you have a macOS 14 or 15 machine: check that the icon still shows there.
4. While the app is open, start a write to a RAM disk or the test stick and look at the password dialog. If it shows the raccoon, the README's "The password dialog has no custom icon yet" limitation can go (left over from T15). Cancel the dialog.

**Acceptance criteria**
- In Dark icon style on macOS 26 the icon has a dark background, and in Default it looks like the raccoon on the ivory tile from Nick's pack (`source/icon-master.png`; changed from "the T15 icon" by T23).
- Clear and Tinted show the raccoon shape, not a solid tile.
- The bundle still carries an icon that macOS 14/15 can use (`AppIcon.icns` or legacy renditions in `Assets.car`).
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `App/AppIcon.icon/`, `App/Assets.xcassets/AppIcon.appiconset/` (kept or removed per step 4), `project.yml`, `PLAN.md`

**Handoff notes:**
- **Agent prep done 2026-10-12, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 371 tests. `scripts/build.sh --release` succeeds for `x86_64 arm64` with no asset warnings, and the release flag check passes. `build/` holds the Release build.
- **Foreground:** Nick's original apple artwork (1024 px, transparent background, no ground shadow), so no cutout was needed. The background removal had left the body about 98% opaque (alpha 224–254 on ~570k pixels). Those pixels were un-premultiplied and set to fully opaque, so the fill can't show through. The anti-aliased edge is unchanged. Stored as `App/AppIcon.icon/Assets/apple.png`.
- **`icon.json`:** written by hand. Solid fill `srgb:0.976,0.957,0.910`, sampled from the T15 cream tile. One layer at scale 0.8, with `glass` off and group translucency off so the apple stays opaque, and a neutral shadow. There's no dark fill specialization: the Dark rendition gets a dark background automatically. `ictool` (inside Icon Composer.app) rendered Default, Dark, ClearLight, ClearDark, TintedLight and TintedDark for macOS, and all six look right: cream tile in Default, dark tile in Dark, apple shape in Clear and Tinted.
- **Project:** XcodeGen 2.46 adds `AppIcon.icon` as a single `wrapper.icon` file reference in Resources, so `project.yml` is unchanged. `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` now resolves to it.
- **Pre-26 fallback (step 4):** `actool` renders the legacy icons from the `.icon` file. With both sources present, the `.icns` (16–256 px) and the 7 flat `Assets.car` images (32–1024 px) were renders of the new icon, not the T15 PNGs. Removing the set left the `.icns` byte-identical and the same 7 images. Their digests changed, but they also change between two compiles of the same input, so the renders aren't byte-stable. The `.car` also has layered stacks for Aqua, DarkAqua and Tintable. So `App/Assets.xcassets` (it held only the icon) was deleted.
- **Deviation:** none from the steps. Step 3's `project.yml` edit turned out not to be needed.
- **Human results, 2026-10-13, on the T23 build or later (commit `162d647`):** Nick completed the human steps and reported that all passed. Icon Composer previews of the raccoon look right in Default, Dark, Clear and Tinted. No changes were saved, so no rebuild was needed. The installed copy's Dock and Finder icon follows each icon style, with a dark background in Dark. The README's "password dialog has no custom icon yet" limitation (step 4) is left as is until Nick confirms which icon the dialog showed.
- **Acceptance:** every criterion is met. `scripts/test.sh` passes 374 tests and `scripts/build.sh --release` succeeds for `x86_64 arm64` with the release flag check passing, re-run on `162d647`. Marked `DONE`.

---

### T18 — 🧑 Make the password-cancelled notice stand out

**Goal:** after the password dialog is cancelled, the app goes back to the confirm screen, which looks almost exactly as it did before. The only difference is the `WriteNotice` line ("The password dialog was cancelled, so nothing was written…"). It is easy to miss because `ConfirmView` shows it in `.secondary` grey (the icon too), with no background, under the much louder red "Erase this drive?" title. Make it a tinted callout box and move it to the top of the screen.

Out of scope (Nick chose only these two changes): new wording or a separate title for `WriteNotice`, animation, VoiceOver announcements, the grey dialog hint on the progress screen, and a shared message view for the other inline warnings and errors.

**Agent steps**
1. In `App/ConfirmView.swift`, show the notice as a callout:
   - The text uses the primary colour and `.font(.callout)`. Only the icon (`info.circle.fill`) is tinted blue.
   - The box has padding of about 10, full width with leading alignment, a `.blue.opacity(0.12)` fill and a `.blue.opacity(0.3)` border, both with corner radius 8.
   - `.fixedSize(horizontal: false, vertical: true)` stays, so long text wraps instead of truncating.
   - Put it in a small private view in the same file, like `StepHeader` in `SetupView.swift`.
2. Move the callout to the top of the `VStack`, above the "Erase this drive?" title. When there is no notice, the screen must look exactly as it does now.
3. `WriteNotice` and the coordinator don't change. The existing preview "Back after the password dialog was cancelled" shows the new layout.
4. `scripts/test.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**
1. Run `scripts/build.sh` (Debug), then `RACCOONWRITER_SIMULATE=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`.
2. Choose any `.iso` or `.img` image, select "Simulated USB Stick (password dialog cancelled)", then Continue… and Erase and Write. After the simulated dialog delay, the confirm screen comes back.
3. Check the callout catches your eye before the red title, and that it reads well in both Light and Dark appearance (System Settings › Appearance). Also check it at the narrowest window width.
4. Press Cancel, choose the same drive again and continue. The confirm screen should show no callout and look as it did before T18.

**Acceptance criteria**
- The notice is the first thing on the confirm screen. It shows in a tinted box with primary-colour text and a blue icon.
- It reads well in Light and Dark, and wraps rather than truncates at the minimum window width.
- Without a notice, the confirm screen is unchanged.
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `App/ConfirmView.swift`, `PLAN.md`

**Handoff notes:**
- **Agent prep done 2026-10-12, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 371 tests. `scripts/build.sh --release` succeeds for `x86_64 arm64` with no Swift warnings, and the release flag check passes. `build/` holds the Release build, so run `scripts/build.sh` first for the Debug-only Simulate mode.
- **What was built:** a private `NoticeCallout` view in `ConfirmView.swift`, as specified in step 1. It's the first item in the screen's `VStack`, above the title, and only appears when there's a notice, so the screen without one is unchanged. `WriteNotice` and the coordinator are untouched.
- **Rendering check:** the agent rendered the callout above the title with `ImageRenderer` at 540 pt wide (the minimum window width), in Light and Dark. In both, the text is easy to read, the box is clearly tinted, and the message wraps onto two lines. This was a standalone copy of the view, not the running app, so step 3 below is still needed.
- **Deviation:** none.
- **Nick: run these on the T23 build or later** (T23 renamed the app; the commands below use the new names).
  1. `scripts/build.sh`, then `RACCOONWRITER_SIMULATE=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`.
  2. Choose any `.iso` or `.img` file, for example `~/iso-sword-test/ram-test.img`. Select "Simulated USB Stick (password dialog cancelled)", then Continue… and Erase and Write. The progress screen waits a moment as if the dialog were up, then the confirm screen comes back with the blue box at the top.
  3. Check that the box catches your eye before the red title. Switch System Settings › Appearance between Light and Dark while the app is open, and drag the window to its narrowest width. The text should stay readable and wrap rather than be cut off.
  4. Press Cancel, choose the same drive again and Continue…. The confirm screen should have no box and look as it did before T18.

  Then tell the agent the results. If they meet the acceptance criteria, the agent records them here and marks T18 `DONE`.
- **Human results, 2026-10-13, on the T23 build or later (commit `162d647`):** Nick ran steps 1–4 and all passed. The callout catches the eye before the red title, reads well in Light and Dark, and wraps at the narrowest window width. After Cancel and choosing the drive again, the confirm screen has no callout.
- **Acceptance:** every criterion is met. `scripts/test.sh` passes 374 tests and `scripts/build.sh --release` succeeds for `x86_64 arm64` with the release flag check passing, re-run on `162d647`. Marked `DONE`.

---

### T19 — 🧑 Flush the drive cache with `DKIOCSYNCHRONIZE`

**Goal:** close a review finding. The final flush doesn't reach the drive on real hardware. `F_FULLFSYNC` goes to the vnode as an ioctl. A filesystem turns it into a drive cache flush, but on a raw disk node the disk driver doesn't recognise it and returns `ENOTTY`. That is why the T01 RAM disk and the H6 SanDisk Cruzer Glide both logged `fsync fallback`. And `fsync` on a character device (`/dev/rdiskN`) returns 0 without doing anything. So today the app never asks the drive to flush its write cache, and the README line "The final flush uses `F_FULLFSYNC`" is wrong. In practice the eject probably flushes the drive, which hides the problem, but a failed eject or a stick pulled straight after "Finished" isn't covered.

The fix is `DKIOCSYNCHRONIZE` from `<sys/disk.h>`, `_IOW('d', 22, dk_synchronize_t)`. The disk driver turns it into a SCSI SYNCHRONIZE CACHE, which USB mass storage uses. With a zeroed `dk_synchronize_t` (offset 0, length 0, no options) it flushes the whole device. Make it the first method and keep `F_FULLFSYNC` and `fsync` as fallbacks.

**Order:** `WriteEngine` already flushes after the last write and before the verify, so the order doesn't change. A flush makes the write durable before success is reported. It doesn't guarantee the verify reads from flash rather than the drive's cache, so don't claim that anywhere.

**Out of scope:** `DKIOCSYNCHRONIZECACHE` (`_IO('d', 22)`, the older form) as an extra fallback, unless step 1 or the hardware run shows `DKIOCSYNCHRONIZE` unsupported where the older one would work. Also `DK_SYNCHRONIZE_OPTION_BARRIER`: a barrier only orders writes and doesn't empty the cache.

**Agent steps**
1. Add `ioctlSynchronize` next to the two ioctl constants in `RawDevice`. Compute `_IOW('d', 22, dk_synchronize_t)` from the SDK header (expected `0x8018_6416`, since the struct is 24 bytes) and check it the way T01 checked the others, for example by compiling a small C file that prints the macro. Use Darwin's imported `dk_synchronize_t` if it's available in Swift; otherwise mirror it in a Swift struct and add a test that its size is 24. No device is needed for any of this.
2. Extend `SyncMethod` and `SyncMethod.perform`: `DKIOCSYNCHRONIZE` → `F_FULLFSYNC` → `fsync`. Each step moves on only when the previous one returns `ENOTTY` or `ENOTSUP`; any other error is a real sync failure and throws with the method's name; `EINTR` retries as now. Add a `.synchronize` case, and fix the doc comments: `.fullFsync` stays for regular files and the fakes, and `.fsyncFallback` must say it doesn't reach the drive on a raw node. Reaching `fsync` is still not an error, because RAM disks may support neither command and the eject flushes the drive anyway.
3. `RawDevice.fullSync()` passes the ioctl as the first closure (a small `PosixIO.ioctlStatus` helper, in the same shape as `fcntlStatus`). Log the method used as now (`fullSync used DKIOCSYNCHRONIZE` / `F_FULLFSYNC` / `fsync fallback`). When a method is skipped, also log which one and its errno at info level, so the hardware run shows why.
4. `FileBackedDevice`: a regular file returns `ENOTTY` for the ioctl, so by default it lands on `F_FULLFSYNC`. Add a fault that makes the synchronize step succeed (so the coordinator tests can cover `.synchronize`) and keep `fullFsyncUnsupported`. Update `SimulatedDevice` and `PreviewSamples` if they name a method.
5. Tests: each fallback step with `ENOTTY` and `ENOTSUP`; any other errno from each step is fatal and later steps aren't called; `EINTR` retries; `RawDevice` on a temp file returns `.fullFsync` (the ioctl falls through); the engine reports whatever method the device used.
6. Docs: `README.md` line 70 (the flush asks the drive to empty its write cache with `DKIOCSYNCHRONIZE`, falling back to `F_FULLFSYNC` and then `fsync` where it isn't supported); section 1 "Cache and sync" note in this file; in `docs/HARDWARE_TESTS.md`, H2's and H6's expected flush method and the "Flush method on the USB stick" line. Leave the 2026-10-09 notes as they are, since they record what happened, and add a line pointing to T19.
7. `scripts/test.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**, with `log stream --predicate 'subsystem == "com.example.raccoonwriter"' --info` open in a second Terminal window:
1. RAM disk, Debug build: one full write and verify. Record the flush method and any skipped-method errno from the log.
2. Real USB stick (the Cruzer Glide), Release build: one full write and verify. It passes. Record the flush method; `DKIOCSYNCHRONIZE` is the expected result. If it falls back, copy the log lines with the errno.

**Acceptance criteria**
- `fullSync()` tries `DKIOCSYNCHRONIZE` first and falls back to `F_FULLFSYNC` and then `fsync` only on `ENOTTY`/`ENOTSUP`. Any other error fails the write (unit tests).
- The ioctl constant is checked against the SDK header, and the struct is 24 bytes.
- On the Cruzer Glide, write and verify pass and the log shows which method ran. If it isn't `DKIOCSYNCHRONIZE`, the errno is recorded here and the README says what the app actually does.
- The README and `docs/HARDWARE_TESTS.md` no longer claim the flush uses `F_FULLFSYNC` on raw devices.
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `Sources/ImageWriterCore/` (`RawDevice`, `SyncMethod`, `PosixIO`, `Fakes/FileBackedDevice`, `Simulation/SimulatedDevice`), `App/PreviewSamples.swift`, `Tests/` (`SyncMethodTests`, `RawDeviceTests`, `FileBackedDeviceTests`, coordinator and engine tests as needed), `README.md`, `docs/HARDWARE_TESTS.md`, `PLAN.md`

**Handoff notes:**
- **Agent prep done 2026-10-13, now `NEEDS_HUMAN`.** `scripts/test.sh` passes 374 tests. `scripts/build.sh --release` succeeds with no Swift warnings, and the release flag check passes. The agent wrote to no disk and never ran authopen.
- **Step 1 (constant):** a C file compiled for arm64 and x86_64 printed `DKIOCSYNCHRONIZE=0x80186416` and `sizeof(dk_synchronize_t)=24` on both (and the T01 values for the geometry ioctls). Darwin imports `dk_synchronize_t` into Swift, so there is no mirror struct. `RawDeviceTests.synchronizeIoctlMatchesTheHeader` checks the size is 24 and rebuilds `_IOW('d', 22, …)` from the `<sys/ioccom.h>` formula.
- **What was built:**
  - `SyncMethod.synchronize` is the new first case. `SyncMethod.perform(synchronize:fullFsync:fsync:onSkip:)` runs the three in order, moves on only on `ENOTTY`/`ENOTSUP`, retries `EINTR` at every step, and throws `DeviceIOError.posix` with the call's name (`ioctl(DKIOCSYNCHRONIZE)`, `F_FULLFSYNC`, `fsync`) for any other errno. Any error from `fsync`, `ENOTTY` included, is still fatal, as before.
  - `RawDevice.fullSync()` sends a zeroed `dk_synchronize_t` through the new `PosixIO.ioctlStatus`. It logs `fullSync skipped <call>: errno N (<text>)` at info level for each skipped call, then `fullSync used DKIOCSYNCHRONIZE` / `F_FULLFSYNC` / `fsync fallback`.
  - `FileBackedDevice.Faults.synchronizeSupported` (default false) makes the synchronize step succeed. When it's off the step returns `ENOTTY` without calling the ioctl, so the fake stays deterministic. `syncError` now applies to every step the device supports, so existing tests keep their `F_FULLFSYNC` error. `SimulatedDevice` names no method and is unchanged; `PreviewSamples` now shows `.synchronize`.
  - Tests: every fallback step with `ENOTTY` and `ENOTSUP`, other errnos fatal at each step with later steps not called, `EINTR` at each step, `RawDevice` on a temp file landing on `.fullFsync`, and the engine and coordinator reporting all three methods.
- **Deviations:** none. The sync method still isn't shown in the UI, only in the log and `WriteSummary`.
- **Nick: run these on the T19 commit**, with this log open in a second Terminal window:
  ```sh
  log stream --predicate 'subsystem == "com.example.raccoonwriter"' --info
  ```
  1. **RAM disk, Debug build.** Run `scripts/build.sh`, create the RAM disk exactly as in H2 step 2 of `docs/HARDWARE_TESTS.md`, then run `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`. Write `~/iso-sword-test/ram-test.img` to the RAM disk. Write and verify should pass. **Copy the `fullSync used …` line and any `fullSync skipped …` lines.** Either `DKIOCSYNCHRONIZE` or `fsync fallback` is acceptable on a RAM disk. Then clean up: `hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"`
  2. **Real USB stick (the Cruzer Glide), Release build.** Run `scripts/build.sh --release`, then `open build/RaccoonWriter.app`. Write any image to the stick, for example the Fedora ISO from H6, and let it verify. It should pass. **Copy the `fullSync used …` line.** The expected result is `DKIOCSYNCHRONIZE`. If it says `F_FULLFSYNC` or `fsync fallback`, also copy the `fullSync skipped …` lines, because they give the errno.

  Then tell the agent the results. If the stick used `DKIOCSYNCHRONIZE`, the agent records the results here and in `docs/HARDWARE_TESTS.md` and marks T19 `DONE`. If not, the agent updates the README to say what the app actually does and decides with Nick whether the older `DKIOCSYNCHRONIZECACHE` is worth trying.
- **Human results, 2026-10-13, commit `169b386`:**
  - **Step 1 (Debug, RAM disk):** write and verify passed, and the RAM disk was ejected. Log: `20:32:18.191924 … RaccoonWriter: (RaccoonWriter.debug.dylib) [com.example.raccoonwriter:device] fullSync used DKIOCSYNCHRONIZE`, with no `skipped` lines. So the RAM disk driver supports `DKIOCSYNCHRONIZE`, though it returned `ENOTTY` for `F_FULLFSYNC` in T01.
  - **Step 2 (Release, the Cruzer Glide):** `ram-test.img` written; write and verify passed, and the stick was ejected. Log: `20:35:54.857664 … RaccoonWriter: [com.example.raccoonwriter:device] fullSync used DKIOCSYNCHRONIZE`, with no `skipped` lines. The stick now gets a real cache flush before success is reported.
  - The verify passing is inferred from the eject: the coordinator ejects only after `Verifier` succeeds.
- **Acceptance:** every criterion is met. `DKIOCSYNCHRONIZECACHE` isn't needed. Marked `DONE`.

---

### T20 — 🧑 Warn for drives over 500 GB; README says USB hard drives are listed

**Goal:** close a review finding. The default drive list includes USB hard drives and SSDs, not just sticks. `DiskFilter.rejection(for:bootDisks:)` accepts a USB disk when `isRemovable || isEjectable`. USB hard drive and SSD enclosures usually report `Ejectable = true` (even the Thunderbolt T7 in `PreviewSamples` does), so a USB Time Machine or backup drive appears by default. The README says "only external, removable USB drives are listed", which is wrong. The filter stays as it is: hiding ejectable-only disks would also hide some sticks and card readers, and the user may really want to write to a USB SSD. Instead, fix the README and warn when a drive is large. balenaEtcher does the same above 128 GB; Nick chose 500 GB, because 128 and 256 GB sticks are common.

**Threshold:** the drive's listed `sizeBytes` is strictly greater than 500,000,000,000 bytes. That is decimal, as `DisplayFormat` and Finder use. A "500 GB" SSD (for example 500,107,862,016 bytes, which shows as "500 GB") is therefore warned about, which is what we want. The warning doesn't depend on the bus, removable flags, or the "Show all external disks" setting.

**Out of scope:** changing what `DiskFilter` accepts; blocking the write or adding an extra confirmation step (the warning is advisory, like `BootWarning`); a setting for the threshold; showing USB hard drives only when the toggle is on.

**Agent steps**
1. Add `LargeDriveWarning` to `Sources/ImageWriterCore/`, in the same shape as `DriveTooSmall`: a stored `driveBytes`, `static let thresholdBytes: UInt64 = 500_000_000_000`, `init?(drive: DiskInfo)` that returns nil at or below the threshold, and a `message`. Use the drive's size in the message, not the threshold, so a 500.1 GB drive doesn't read "larger than 500 GB" next to "500 GB". Suggested wording: "This is a large drive (1 TB). USB sticks are rarely this big, so make sure it isn't a backup or external hard drive you want to keep."
2. Drive list (`App/DriveSection.swift`, `DriveRow`): a second caption line "Large drive" in orange, under the details and alongside "Too small for this image" if both apply. Compute it in `DriveSection` and pass a Bool in, the way `isTooSmall` is passed.
3. Confirm screen (`App/ConfirmView.swift`): when the warning applies, show its message as an orange `exclamationmark.triangle.fill` label between the "You are about to erase…" line and the details grid, with `.fixedSize(horizontal: false, vertical: true)` so it wraps. It must not push the T18 notice callout off the top, and the screen without a warning must look exactly as it does now.
4. Simulate mode: add `SimulatedDrive.usbHardDrive`, named "Simulated USB Hard Drive (1 TB)": 1,000,204,886,016 bytes, bus `USB`, `isRemovable: false`, `isEjectable: true`, mounted at `/Volumes/SIM96` (bsdName `disk96`), with the same scripted outcome as `.working`. It must appear in the default list, which also covers the finding itself. Update any simulation test that counts or lists the cases. Add a large USB drive to `PreviewSamples`, plus previews for the drive list and confirm screen with that drive.
5. Tests (`LargeDriveWarningTests`): nil at 0, at a typical stick size and at exactly 500,000,000,000; non-nil at 500,000,000,001 and at 500,107,862,016; the message contains the drive's `DisplayFormat.size`. Add a `DiskFilterTests` case recording the current behaviour: a USB disk with `isRemovable: false, isEjectable: true` is listed by default. A later change to the filter then has to be deliberate.
6. Docs:
   - `README.md` line 13: by default the list shows external USB drives that macOS reports as removable or ejectable. That covers USB sticks and card readers, but also most USB hard drives and SSDs, so a backup or Time Machine drive can appear. Drives over 500 GB are marked "Large drive" and the confirm screen warns about them. Add a matching item under the limitations (near the SD card line).
   - This file, section 1 "Drive filter" row: "removable or ejectable", and mention the large-drive warning.
   - `docs/HARDWARE_TESTS.md`: add a step to H1 for the simulated USB hard drive.
7. `scripts/test.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**
1. Run `scripts/build.sh` (Debug), then `RACCOONWRITER_SIMULATE=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`.
2. Choose any image. "Simulated USB Hard Drive (1 TB)" is listed with "Show all external disks" off and shows "Large drive". The simulated 16 GB sticks don't.
3. Select it and press Continue…. The confirm screen shows the large-drive warning, and it reads well in Light and Dark and at the narrowest window width. Cancel, choose "Simulated USB Stick (works)" and continue: no warning.
4. Choose "Simulated USB Stick (password dialog cancelled)" and run it through the cancelled dialog, to check the T18 callout still sits above the title.
5. Optional, if a USB hard drive or SSD over 500 GB is to hand: plug it in with a Release build and check it is listed with "Large drive". Don't select Erase and Write.

**Acceptance criteria**
- Drives over 500,000,000,000 bytes show "Large drive" in the list and a warning on the confirm screen. Drives at or below that show neither, and nothing else on those screens changes.
- The warning never blocks the write.
- The README no longer says only removable USB drives are listed, and it explains the large-drive warning. The section 1 table matches.
- `DiskFilter` behaviour is unchanged, and a test records that ejectable-only USB disks are listed by default.
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `Sources/ImageWriterCore/LargeDriveWarning.swift`, `Sources/ImageWriterCore/Simulation/SimulatedDrive.swift`, `App/DriveSection.swift`, `App/ConfirmView.swift`, `App/PreviewSamples.swift`, `Tests/ImageWriterCoreTests/` (`LargeDriveWarningTests`, `DiskFilterTests`, `SimulationModeTests` as needed), `README.md`, `docs/HARDWARE_TESTS.md`, `PLAN.md`

**Handoff notes:**
- _(none yet)_

---

### T21 — Hardening: close-on-exec device descriptor, partial-block I/O, image identity, diskutil kill

**Goal:** close four review findings. None is known to have happened, but each is cheap to fix, and one (D) can leave the app unable to quit. All four can be tested with temp files, fakes and stand-in scripts, so there is no human step.

- **A. Device descriptor inherits into children.** `DescriptorReceiver.receive` returns the descriptor from authopen without `FD_CLOEXEC`. Descriptor flags don't travel with `SCM_RIGHTS`, and macOS `recvmsg` has no `MSG_CMSG_CLOEXEC`, so it arrives without the flag. Nothing spawns a process while the device is open today, but a child that inherited it would have write access to the raw disk and would keep it open after the app closes it, so a later eject could fail as busy. `AuthopenOpener.run` already sets the flag on every other descriptor for this reason.
- **B. Partial-block retry is misaligned.** `WriteEngine.writeFully` and `Verifier.readFully` retry the remainder after a short transfer. If the count isn't a whole number of blocks, the retry has an unaligned offset and buffer, which `/dev/rdiskN` rejects with `EINVAL`, reported as a baffling "write at offset N: Invalid argument". Short transfers of whole blocks stay supported, as now.
- **C. Image identity isn't checked.** `ImageSource` compares only the type and size with what `ImageInspector` saw, so a different file of the same size at the same path is written, and verify passes because it reads the same path. Its doc comment claims a replaced file fails, which is untrue today. A file changed in place during the run isn't caught either.
- **D. Timeout path can hang.** In `ProcessCommandRunner.runBlocking`, a command that ignores SIGTERM makes `exited.wait()` after `terminate()` block forever. `readers.wait()` is also unbounded, so a grandchild that keeps stdout or stderr open blocks it even after the command exits. Neither wait observes task cancellation. A hang in the safety check or unmount leaves the run at "Cancelling" and blocks Quit (`stopAndWait`). A hang in eject sticks in finishing, which can't be cancelled. A hang in a drive list refresh stops polling silently.

**Out of scope:** blocking mounts on the target with DiskArbitration (the fifth finding); it waits for a hardware check of whether anything mounts between close and eject. Also making `CommandRunner` calls cancellable (D makes them finite, which is enough); killing the command's whole process group; using `ctime` for identity (Finder and Spotlight change it by adding extended attributes, which would cause false "changed" errors).

**Agent steps**
1. **A.** In `DescriptorReceiver.receive`, set `FD_CLOEXEC` on the received descriptor before returning it. If `fcntl` fails, close the descriptor and throw `DeviceOpenError.posix(operation: "fcntl(FD_CLOEXEC)", …)`, the way `makeInputPipe` fails closed on `F_SETNOSIGPIPE`. Test in `DescriptorReceiverTests`: the received descriptor has `FD_CLOEXEC` set (`fcntl(fd, F_GETFD)`). Check the test fails without the fix.
2. **B.**
   - In `WriteEngine.writeFully`, after the `count > 0` guard, require `count` to be a multiple of `device.blockSize`. Otherwise throw a new `WriteEngineError.partialBlock(atOffset:byteCount:)` with no retry. The description and `FailureExplanation` say in plain words that the drive wrote part of a block and the write was stopped. Drive state is `.partiallyWritten`, like `.stalled`.
   - Do the same in `Verifier.readFully` with `VerifierError.partialBlock(atOffset:byteCount:)` and the matching explanation, using the drive state the verify stage's other device errors use.
   - `FileBackedDevice.Faults`: add `partialBlockWriteOnCall` and `partialBlockReadOnCall` (1-based, like `shortWriteOnCall`) that transfer a count that isn't a block multiple, for example `length - blockSize / 2` for a request longer than one block.
   - Tests: each fault throws the new error with the right offset and byte count, and the device sees no further call after it. The existing whole-block short write and read tests still pass. `FailureExplanationTests` cover both new cases.
3. **C.**
   - Add `FileIdentity` (`Sources/ImageWriterCore/FileIdentity.swift`): `device`, `inode`, `sizeBytes` and the modification time in seconds and nanoseconds (`st_mtimespec`), built from a `stat`. Equatable and Sendable.
   - `ImageInspector` records it from the `fstat` it already does. `ImageInfo` stores it as a **non-optional** field, so production code has no way to skip the check. Update the 10 places that construct `ImageInfo`. For tests, add a helper that builds an `ImageInfo` from a real temp file's `stat`. `PreviewSamples` may use a made-up value, since previews never write.
   - `ImageSource.init` compares the `fstat` of its open descriptor with the recorded identity and throws `ImageSourceError.changed` on any difference, which replaces the size comparison. Add `ImageSource.checkUnchanged()`, which runs `fstat` on the same descriptor and compares again. `Verifier` calls it after its last comparison and before returning, so a file changed in place during the write or verify fails the run instead of reporting a verified drive. The existing `changed` explanation ("Choose the image again") covers both.
   - Fix the `ImageSource` doc comment so it matches.
   - Tests in `ImageSourceTests`, each failing before the fix: a same-size file renamed over the path is `changed` at init. The file rewritten in place with the same size but a different modification time is `changed` at init. A file modified after `ImageSource` opened it fails `checkUnchanged()`. An untouched file passes both. Set modification times explicitly with `futimes`, so the tests don't depend on timestamp resolution.
4. **D.**
   - In `ProcessCommandRunner.runBlocking`, after a timeout: `terminate()`, wait up to `killGrace`, then `kill(process.processIdentifier, SIGKILL)` if it is still running, then wait up to `killGrace` again. If it still hasn't exited, log it and throw `timedOut` without waiting further.
   - After the command exits, normally or not, wait at most `killGrace` for the two output readers. If they don't finish, a grandchild is holding a pipe: throw `outputUnreadable` with a message saying the output stayed open after the command exited, and leave the readers to finish on their own. Don't close their handles from this thread; a descriptor closed under a blocked read could be reused for another file.
   - `killGrace` defaults to 2 seconds. Add it as an internal init parameter so tests can shorten it. Worst case is now `timeout` + 3 × `killGrace` instead of forever. Update the type's doc comment.
   - Tests in `ProcessCommandRunnerTests`, with `/bin/sh -c` stand-ins and sleeps of at most 5 seconds, so a failed run doesn't leave long-lived processes. Check each test hangs or fails without the fix:
     - `trap '' TERM; exec /bin/sleep 5` with a short timeout and grace: throws `timedOut` well before 5 seconds. `sleep` inherits the ignored SIGTERM, so only the SIGKILL ends it.
     - `/bin/sleep 5 & echo done`: the shell exits at once, the background `sleep` holds stdout, and the runner throws `outputUnreadable` within about `killGrace`.
     - The existing timeout, signal and large-output tests still pass.
5. Note in this task's Handoff notes which of the new tests failed without its fix. `scripts/test.sh` and `scripts/build.sh --release` pass. Mark `DONE`.

**Acceptance criteria**
- The descriptor from authopen has `FD_CLOEXEC` set before `receive` returns it (unit test).
- A transfer that isn't a whole number of blocks stops the write or verify with a clear typed error and no further I/O. Whole-block short transfers are still retried (unit tests).
- A same-size replacement, an in-place change before the run, and a change during the run all fail with `ImageSourceError.changed`. `ImageInfo` can't be made without a `FileIdentity` (unit tests).
- `ProcessCommandRunner` returns or throws within `timeout` + 3 × `killGrace`, even for a command that ignores SIGTERM or leaves a pipe open (unit tests).
- `scripts/test.sh` and `scripts/build.sh --release` pass.

**Files:** `Sources/ImageWriterCore/` (`DescriptorReceiver`, `WriteEngine`, `WriteEngineError`, `Verifier`, `VerifierError`, `FailureExplanation`, `FileIdentity` (new), `ImageInfo`, `ImageInspector`, `ImageSource`, `ProcessCommandRunner`, `Fakes/FileBackedDevice`), `App/PreviewSamples.swift`, `Tests/ImageWriterCoreTests/` (`DescriptorReceiverTests`, `WriteEngineTests`, `VerifierTests`, `FailureExplanationTests`, `ImageSourceTests`, `ImageInspectorTests`, `ProcessCommandRunnerTests`, `TestSupport`, and the tests that construct `ImageInfo`), `PLAN.md`

**Handoff notes:**
- _(none yet)_

---

### T22 — 🧑 Volume names on screen, debug-only fakes, Info.plist keys, Hardened Runtime

**Goal:** close four review findings. Each is a small change; D needs a hardware run, which makes this a human checkpoint.

- **A. Volume names aren't shown.** `DiskInfo.volumeNames` is filled in by `DiskutilDiscovery` and never displayed. The drive list shows the media name, size, `/dev/diskN` and bus, so two identical sticks look the same, and users recognise "STICK" or "Backup" more readily than a disk number. Picking the wrong drive is the main way this app destroys data. The confirm screen shows mount paths, which contain the name only while a volume is mounted. (The review also said the confirm screen shows "Mounted volumes: none" after a cancelled prompt. That was true at T11, when the unmount came before the prompt; since T16 nothing is unmounted before the prompt, so check it rather than assume it.)
- **B. Test fakes ship in Release.** All eight files in `Sources/ImageWriterCore/Fakes/` are public and compiled into the Release binary. T02 deviation 3 left them unwrapped because T10's Simulate mode needed them. Simulate mode is now entirely `#if DEBUG`, so that reason no longer holds. Nothing in Release creates them, but `FakeDeviceOpener` approves every request, and a Release compile error is the right outcome if future code ever wires one in.
- **C. Info.plist is missing three keys.** `NSHumanReadableCopyright` (shown in the About window and Get Info), `LSApplicationCategoryType`, and `NSRemovableVolumesUsageDescription`. The removable-volume privacy prompt has appeared before (section 5, T14 handoff notes) and currently uses macOS's generic wording.
- **D. Hardened Runtime is off** (`ENABLE_HARDENED_RUNTIME: NO`). Notarization requires it. Notarization is still out of scope, but turning it on now surfaces any problem while the change is one line, not later during a release.

**Out of scope:** DiskArbitration notifications in place of the 2 s poll (the review's fifth item; low benefit for about 200 lines of new code); Developer ID signing and notarization; renaming "Mounted volumes"; showing volume names on the progress, done or failed screens.

**Agent steps**
1. **A. Volume names.**
   - Add `DisplayFormat.volumeNames(of:) -> String?`: the names joined with ", " in their existing order, or nil when there are none. It sits next to `mountPoints(of:)`.
   - `DriveRow` (`App/DriveSection.swift`): put the volume names first on the details line, for example "STICK · 16 GB · /dev/disk4 · USB". Leave the line unchanged when there are none. Keep `lineLimit(1)` and truncate in the middle so the device path doesn't disappear behind a long name list.
   - `ConfirmView`: add a "Volume names:" grid row above "Mounted volumes:", shown only when there are names. The names come from the drive and are user-controlled, so pass them as a `String` value, never a string literal, so SwiftUI doesn't treat them as Markdown or a localization key (the same reason the title line is built from pieces).
   - Check which fixtures under `Tests/ImageWriterCoreTests/Fixtures/` include an **unmounted** partition with a `VolumeName`. If one does, add a `DiskutilDiscoveryTests` assertion that its name is in `volumeNames` while `mountPoints` doesn't include it. If none does, say so in the Handoff notes and leave it to human step 2.
   - `PreviewSamples`: one drive with two volume names, one with none. Update the drive list and confirm screen previews.
   - Tests in `DisplayFormatTests`: several names, one name, none (nil), and a name containing `*` or `[` comes back unchanged.
   - In the Simulate build, run disk93 through the cancelled prompt and record what "Mounted volumes:" shows on the confirm screen afterwards. Since T16 it should show `/Volumes/SIM93`. If it shows "none", find out why before going on.
2. **B. Debug-only fakes.**
   - Wrap each of the eight files in `Sources/ImageWriterCore/Fakes/` (`FakeCommandRunner`, `FakeDeviceAuthorizer`, `FakeDeviceOpener`, `FakeDiskManager`, `FakeSleepPreventer`, `FileBackedDevice`, `StaticBootDiskResolver`, `StaticDiskDiscovery`) in a whole-file `#if DEBUG` / `#endif`, the way `Simulation/` is done.
   - Fix any Release compile error by gating the caller, not by un-gating the fake. If a production path needs one, stop and set `BLOCKED`.
   - `swift test` builds Debug, so the test target is unaffected. `swift test -c release` stops compiling; note that in the Handoff notes, and note in T02's deviation 3 that T22 supersedes it.
   - Add `FakeDeviceOpener`, `FileBackedDevice` and `StaticBootDiskResolver` to the strings `scripts/check-release-flags.sh` fails on, and to `ReleaseFlagCheckTests.markers`. In `scriptChecksEveryMarkerTheCodeUses`, add `String(describing:)` checks for the three types inside the existing `#if DEBUG` block.
   - After `scripts/build.sh --release`, also run `strings` on the binary and grep it for all eight type names. Record that none are found.
3. **C. Info.plist** (`App/Info.plist`):
   - `NSHumanReadableCopyright`: "Copyright © 2026 Nicholas Thorp." Nick confirms the holder in human step 1.
   - `LSApplicationCategoryType`: `public.app-category.utilities`.
   - `NSRemovableVolumesUsageDescription`: "Raccoon Writer reads the disk image you choose when it is stored on a USB drive or other removable volume."
   - Add a test that reads `App/Info.plist` from the source tree (found from `#filePath`, as `ReleaseFlagCheckTests` finds the script) and checks the three keys are present and non-empty, with the expected category value.
   - Check the built app with `plutil -p build/RaccoonWriter.app/Contents/Info.plist`.
4. **D. Hardened Runtime.**
   - `project.yml`: `ENABLE_HARDENED_RUNTIME: YES` for all configurations.
   - No new entitlements are expected. The app starts `authopen` and `diskutil` as separate processes, which the runtime allows. It loads only system frameworks and the statically linked `ImageWriterCore`, and it uses no JIT. Xcode still adds `get-task-allow` to Debug builds, so debugging works.
   - `scripts/build.sh`: after the copy, fail if `codesign -dv build/RaccoonWriter.app` doesn't report the `runtime` flag (for example `flags=0x10002(adhoc,runtime)`). It should fail closed if `codesign` itself fails. Also run `codesign --verify --strict` on the bundle.
   - Debug build: launch `RACCOONWRITER_SIMULATE=1` and run disk90 (works) through to Done. Simulate mode touches no disks. If the app fails to start because the Xcode 16 `.debug.dylib` is refused, set `ENABLE_DEBUG_DYLIB: NO` for Debug in `project.yml`; that only affects previews. Never add `com.apple.security.cs.disable-library-validation`. If neither approach works, set `BLOCKED` and record the crash report.
   - README: under Limitations, the "Not signed or notarized" item says the Hardened Runtime is on, so notarization only needs a Developer ID signature.
5. `scripts/test.sh`, `scripts/build.sh` and `scripts/build.sh --release` pass. Write instructions for Nick, set `NEEDS_HUMAN`, stop.

**Human steps (Nick)**, with `log stream --predicate 'subsystem == "com.example.raccoonwriter"' --info` open in a second Terminal window:
1. Confirm or correct the copyright holder in `App/Info.plist`. Open the Release app's About window and check the copyright line.
2. **Volume names, Release build, real stick:** plug in the Cruzer Glide with a named volume. The drive list shows the volume name on its row. Press Continue…: the confirm screen shows "Volume names:" and "Mounted volumes:". Cancel the password dialog: both rows still appear above the T18 notice callout. Then eject the volume in Finder (not the drive), press Refresh, and record whether the name is still listed while unmounted.
3. **Hardened Runtime, Release build, real stick:** one full write and verify. The password dialog appears with the app's name (T13 `-extauth`), the write and verify pass, and the drive ejects. Record anything unusual in the log.
4. **Hardened Runtime, Debug build, RAM disk:** with `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1` and a RAM disk from `hdiutil attach -nomount ram://65536`, one full write and verify passes.
5. **Optional, privacy prompt:** with the image stored on a second USB volume (not the target), choose it in the app. Record whether the removable-volume prompt appears, and if it does, that it shows the new text. If no prompt appears, try `tccutil reset SystemPolicyRemovableVolumes com.example.raccoonwriter` and run the step again.

**Acceptance criteria**
- Drive rows and the confirm screen show volume names when a drive has any. Nothing changes for a drive without them (unit tests and Nick's check).
- After a cancelled password prompt, the confirm screen shows the drive's mount paths, not "none".
- No type from `Fakes/` is in the Release binary. The release check fails a bundle that contains one of the new markers (unit tests and `strings`).
- `Info.plist` has the three keys (unit test, `plutil`).
- Debug and Release builds are signed with the Hardened Runtime, and `scripts/build.sh` fails if the flag is missing. A real-stick write and verify (Release) and a RAM-disk write and verify (Debug) pass with it on.
- `scripts/test.sh`, `scripts/build.sh` and `scripts/build.sh --release` pass.

**Files:** `Sources/ImageWriterCore/` (`DisplayFormat`, every file in `Fakes/`), `App/` (`DriveSection.swift`, `ConfirmView.swift`, `PreviewSamples.swift`, `Info.plist`), `project.yml`, `scripts/build.sh`, `scripts/check-release-flags.sh`, `Tests/ImageWriterCoreTests/` (`DisplayFormatTests`, `DiskutilDiscoveryTests`, `ReleaseFlagCheckTests`, a new Info.plist test), `README.md`, `docs/HARDWARE_TESTS.md` (record the results), `PLAN.md`

**Handoff notes:**
- _(none yet)_

---

### T23 — Rename to Raccoon Writer, with the raccoon icon

**Goal:** the app is called **Raccoon Writer**. The name is short enough to be both the full and the short name. Rename the display name and every internal identifier, the same way T14 did. `ImageWriterCore` keeps its name. The GitHub repo and local folder stay `iso-sword` (see section 4).

**Priority:** T23 goes ahead of T19–T22, so its tracker row sits above theirs and it depends only on T16. T19–T22 are then done on the renamed app.

**Name mapping**

| Old | New |
| --- | --- |
| `AppInfo.displayName` "Red Delicious Media Writer", `AppInfo.shortName` "Red Delicious" | both "Raccoon Writer" (14 characters, fits `CFBundleName`) |
| `RedDelicious` (XcodeGen project, target, scheme, `PRODUCT_NAME`, `.app`, executable) | `RaccoonWriter` |
| `RedDeliciousApp` / `App/RedDeliciousApp.swift`, `App/RedDelicious.entitlements` | `RaccoonWriterApp` / `App/RaccoonWriterApp.swift`, `App/RaccoonWriter.entitlements` |
| `com.example.reddelicious` (bundle ID and log subsystem) | `com.example.raccoonwriter` |
| `REDDELICIOUS_ALLOW_VIRTUAL_DISKS`, `REDDELICIOUS_SIMULATE` | `RACCOONWRITER_ALLOW_VIRTUAL_DISKS`, `RACCOONWRITER_SIMULATE` |
| `reddelicious-*` temp prefixes, `/nonexistent/reddelicious/…` test paths | `raccoonwriter-*`, `/nonexistent/raccoonwriter/…` |

Keep `AppInfo.shortName` even though it now equals `displayName`, so code that uses it doesn't change and a later rename can split them again.

**Icon:** the red apple is replaced by the raccoon from Nick's pack in `raccoon-writer-branding/` (untracked). The app's only icon is `App/AppIcon.icon` (T17): an Icon Composer bundle with one transparent foreground layer (`Assets/apple.png`) on a cream fill, from which `actool` also renders the macOS 14/15 `.icns` and legacy renditions. So the swap is a new foreground layer, not a new PNG set. What the pack holds and what it's used for:

| Pack file | Use |
| --- | --- |
| `Raccoon Writer logo with transparent background.png` (1254 px, full raccoon holding a USB stick, no tile) | The new foreground layer, `App/AppIcon.icon/Assets/raccoon.png` |
| `source/icon-master.png` (1024 px, raccoon on the ivory rounded tile) | Reference only: the Default render should look like it, and its tile colour is the fill |
| `macos/icon_*.png`, `source/icon-small-master.png` (tiles baked in; 16–64 px use a simplified face) | Not used. Baked-in tiles are what T17 removed, and T17 found `actool` ignores an `.appiconset` next to the `.icon`. The `.icon` is rendered at every size from the one layer |
| `Raccoon Writer icon with transparent background.png` (head only), `web/`, `preview.png`, `README.md`, `verification.json` | Not used; the app has no web or in-app logo |

**Out of scope:** an in-app logo, per-size small artwork, and renaming the repo and folder.

**Agent steps**
1. Core: `AppInfo` (both names and `bundleIdentifier`). New env keys in `DebugTestMode` and `SimulationMode`. The `FileBackedDevice` temp prefix. Update comments that name the app (`AuthopenOpener`, `DeviceAuthorizer`, `DiskFilter`, `ImageKind` and any others `git grep` finds).
2. App and project: `git mv` the app struct file and entitlements, then rename the struct. `Info.plist` names. `AppServices.swift`. Update `project.yml` (name, target, scheme, `PRODUCT_NAME`, bundle ID, entitlements and excludes), `scripts/build.sh` and `scripts/check-release-flags.sh`. Delete the stale generated `RedDelicious.xcodeproj` and `build/RedDelicious.app`.
3. Tests: `AppInfoTests` checks both names and that `shortName` fits 15 characters. Update the strings in `SecurityAuthorizerTests`, `ProgressDisplayTests`, `CoordinatorFaultTests`, `DebugTestModeTests`, `SimulationModeTests`, `ReleaseFlagCheckTests`, `AuthopenOpenerTests`, and every `reddelicious-` prefix and `/nonexistent/reddelicious/` path.
4. Docs: README (heading, prose, commands, log subsystem, quarantine command; the "formerly" line becomes "formerly Red Delicious Media Writer and before that ISO Sword"). In `docs/HARDWARE_TESTS.md`, update the intro, setup and steps; leave recorded results as they are and extend the pre-T14 names line to cover pre-T23 names. Update the `AGENTS.md` title and this file's title and section 1 rows (app name, bundle ID).
5. In this file, update the commands in the human steps of the tasks that aren't `DONE` yet (T12, T17, T18) and in T19–T22's steps, so Nick and the next agent run the new names. Leave `DONE` tasks' text, all handoff notes and the change log as history.
6. Icon:
   - Copy the transparent logo PNG to `App/AppIcon.icon/Assets/raccoon.png` and `git rm` `apple.png`. Check it the way T17 checked the apple: body pixels should be fully opaque (un-premultiply and set alpha to 255 if the background removal left them slightly transparent), and there should be no baked-in ground shadow, since Icon Composer adds its own. Leave anti-aliased edges alone.
   - In `icon.json`, point the layer at `raccoon.png` and rename it `raccoon`. Set the solid fill to the ivory sampled from `source/icon-master.png`'s tile. Adjust the layer `scale` (and `translation-in-points` if needed) so the raccoon's framing matches `icon-master.png`. Keep `glass` off, translucency off and the neutral shadow.
   - Render Default, Dark, ClearLight, ClearDark, TintedLight and TintedDark with `ictool` (inside Icon Composer.app), as T17 did, and look at each one. Also look at the 16 and 32 px renditions in the built `AppIcon.icns`: if the full raccoon is unreadable there, say so in the Handoff notes rather than adding per-size art.
   - Update T17 so its human check covers the raccoon: its Default acceptance criterion becomes "looks like `source/icon-master.png` from the pack" instead of "looks like the T15 icon", and its human steps say "raccoon" instead of "apple". T17 stays `NEEDS_HUMAN`.
   - `git grep -i apple -- App README.md` should find no leftover apple icon references.
7. `scripts/test.sh`, `scripts/build.sh` and `scripts/build.sh --release` pass.
8. Once step 7 passes, delete `raccoon-writer-branding/`. It's untracked, so git can't bring it back: everything the app uses from it is now under `App/AppIcon.icon/`, and Nick keeps the originals. Don't commit any of it. Fill in Handoff notes, mark `DONE` and commit.

**Acceptance criteria**
- `plutil -p build/RaccoonWriter.app/Contents/Info.plist` shows `CFBundleDisplayName` and `CFBundleName` "Raccoon Writer", `CFBundleIdentifier` `com.example.raccoonwriter` and `CFBundleExecutable` `RaccoonWriter`.
- The window title, the password dialog text and the menu bar say "Raccoon Writer".
- `git grep -i -E "red ?delicious|reddelicious"` matches only history (this file's `DONE` tasks, handoff notes and change log, HARDWARE_TESTS recorded results and the pre-T23 note) and the README "formerly" line.
- `scripts/test.sh` and `scripts/build.sh --release` pass, including the release flag check with the `RACCOONWRITER_*` markers.
- `App/AppIcon.icon/` holds `raccoon.png` and no `apple.png`. The `ictool` Default render shows the raccoon on an ivory tile, Dark shows it on a dark tile, and Clear and Tinted show the raccoon shape, not a solid tile.
- The built app's `AppIcon.icns` and `Assets.car` contain the raccoon.
- `raccoon-writer-branding/` no longer exists and was never committed.

**Files:** `Sources/ImageWriterCore/` (`AppInfo`, `DebugTestMode`, `Simulation/SimulationMode`, `Fakes/FileBackedDevice`, comments), `App/` (including `AppIcon.icon/`), `project.yml`, `scripts/`, `Tests/`, `README.md`, `docs/HARDWARE_TESTS.md`, `AGENTS.md`, `PLAN.md`; `raccoon-writer-branding/` deleted

**Handoff notes:**
- **Done 2026-10-13.** `scripts/test.sh` passes 371 tests. `scripts/build.sh` and `scripts/build.sh --release` succeed for `x86_64 arm64`. The Release log has no Swift or asset warnings (only the usual AppIntents metadata note), and the release flag check passes with the `RACCOONWRITER_*` markers. `plutil -p build/RaccoonWriter.app/Contents/Info.plist` shows `CFBundleDisplayName` and `CFBundleName` "Raccoon Writer", `CFBundleIdentifier` `com.example.raccoonwriter` and `CFBundleExecutable` `RaccoonWriter`. `build/` holds the Release build. No disk was touched.
- **Rename:** everything in the name mapping. `AppInfo.shortName` now equals `displayName`, with a comment saying why it's kept. The window title, the password dialog text (`SecurityAuthorizer.prompt`) and the menu bar all come from `AppInfo` and `Info.plist`, so they say "Raccoon Writer". The stale gitignored `RedDelicious.xcodeproj` and `build/RedDelicious.app` were deleted. Remaining `git grep -i -E "red ?delicious|reddelicious"` matches are only history (section 1's "Was" notes, `DONE` tasks, handoff notes, change log), T23's own mapping, and the "formerly" lines in the README and the `docs/HARDWARE_TESTS.md` intro.
- **Icon layer:** `App/AppIcon.icon/Assets/raccoon.png` is the pack's transparent logo at its native 1254 px. As with the apple, the background removal had left the body slightly transparent (alpha 252–253 on ~900k pixels). Pixels at alpha 250–254 were set to 255; the PNG stores straight (un-premultiplied) colour, so no colour changed. The anti-aliased edge (alpha below 250) is unchanged. 333 stray specks outside the raccoon (890 pixels, alpha at most 3, invisible) were cleared. There was no baked-in ground shadow.
- **`icon.json`:** layer renamed `raccoon`, scale 0.75 (the apple was 0.8), no translation. Scales 0.6–0.8 were rendered next to `icon-master.png`; 0.75 matches its framing, and 0.8 pushes the tail against the tile edge. Solid fill `srgb:0.992,0.957,0.894` (253, 244, 228), sampled mid-tile from `icon-master.png`. The pack's tile has a slight top-to-bottom gradient, from (253, 251, 244) to (249, 236, 211). A solid fill was used, as the task said, since Icon Composer adds its own lighting. `glass`, translucency and the neutral shadow are unchanged. `ictool` renders of Default, Dark, ClearLight, ClearDark, TintedLight and TintedDark all look right: ivory tile in Default, dark tile in Dark, raccoon shape in Clear and Tinted.
- **Built icon:** `AppIcon.icns` (16, 32, 128 and 256 px) and `Assets.car` (layered stacks for Aqua, DarkAqua and Tintable, plus flat 32–1024 px images) are all the raccoon. **Small sizes:** at 32 px the full raccoon still reads as a raccoon holding a blue stick, but at 16 px it's a brown blob with a blue spot. The pack's simplified-face art for 16–64 px is clearer, but a `.icon` file has one layer for all sizes, so it wasn't used (see the icon table above). If the 16 px icon (Finder list view, some menus) bothers Nick, that's a separate task.
- **Plan updates:** title, section 1 rows, a T12 note about the T23 names, T17's human steps and acceptance criteria (raccoon instead of apple; still `NEEDS_HUMAN`), T18's human steps and its instructions for Nick, and T19–T22's steps now use the new names.
- **Branding folder:** `raccoon-writer-branding/` was deleted after the builds passed. It was never committed, so the only copy of its other files is Nick's own.
- **Deviation:** T18's handoff said to run its checks "on the T18 commit". That now says "on the T23 build or later", with the new names, since those are the builds Nick will run. Otherwise the handoff notes are unchanged.
- **For Nick:** the new bundle ID makes macOS treat this as a new app, so the removable-volume privacy prompt may appear again. Log predicates use `com.example.raccoonwriter`. The env vars are `RACCOONWRITER_SIMULATE` and `RACCOONWRITER_ALLOW_VIRTUAL_DISKS`. Finder and the Dock may show the apple until the icon cache refreshes; T17's step 2 (copy the app somewhere new) avoids that.

---

## 4. Future work (not in scope)

- Rename the GitHub repo and local folder from `iso-sword` to match the app (T14 left them as they are).
- ~~`authopen -extauth` for a dialog naming ISO Sword~~: implemented in T13.
- `HelperOpener` using an SMAppService-registered privileged XPC helper (removes per-write password prompt). Requires Developer ID signing; design must re-validate targets inside the helper.
- Developer ID signing, notarization, DMG packaging.
- Compressed image support, SHA-256 display, drag-and-drop, localization.

## 5. Open risks

| Risk | Mitigation |
| --- | --- |
| authopen behavior differs from assumptions (flags, read-back on same fd) | T01 spike first; T02, T05 and T06 are amended from its findings |
| Wrong disk written | Layered defenses: filtered list, explicit confirm screen, `SafetyGuard` re-check after the password dialog (T16), size check of the opened device (T16), fail-closed discovery, tests for boot disk and internal exclusion. Identical drives swapped during the dialog are not told apart |
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
| 2026-10-07 | T01 DONE after Nick's runs; T02, T05, T10 and T12 amended from the findings | Claude |
| 2026-10-07 | Agents may mark 🧑 tasks DONE once all agent and human steps are complete (section 0, AGENTS.md) | Claude |
| 2026-10-07 | T02 DONE: DeviceOpener/OpenedDevice, AuthopenOpener, RawDevice, fakes | Claude |
| 2026-10-07 | T03 DONE: DiskInfo, DiskutilDiscovery, BootDiskResolver, DiskFilter, TargetDiskLister, CommandRunner | Claude |
| 2026-10-09 | T04 DONE: ImageInspector, ImageInfo, ImageKind, BootWarning, ImageSignatures | Claude |
| 2026-10-09 | T05 DONE: WriteEngine, TransferProgress, SpeedEstimator, ProgressMeter, ImageSource | Claude |
| 2026-10-09 | T06 DONE: Verifier, VerifierError, VerifyResult; FileBackedDevice short-read fault | Claude |
| 2026-10-09 | T07 DONE: DiskManager, DiskutilDiskManager, DiskManagerError, EjectWarning, FakeDiskManager | Claude |
| 2026-10-09 | T08 DONE: SafetyGuard, SafetyGuardError, DiskIdentityField, DebugTestMode, check-release-flags.sh | Claude |
| 2026-10-09 | T09 DONE: WriteCoordinator, WriteState, PipelineStage, WriteFailure, WriteSummary, WriteCoordinatorError | Claude |
| 2026-10-09 | T10 DONE: SwiftUI screens, DriveListModel, ProgressDisplay, DisplayFormat, debug Simulate mode | Claude |
| 2026-10-09 | T11 DONE: FailureExplanation, DriveCondition, DriveTooSmall, prompt cancel to confirm, sleep prevention, quit and close guards | Claude |
| 2026-10-09 | T12 prep: docs/HARDWARE_TESTS.md checklist (H1–H14) and README; NEEDS_HUMAN for the hardware run | Claude |
| 2026-10-12 | T13 added: branded password prompt via `authopen -extauth`, after T12 | Claude |
| 2026-10-12 | T13 moved ahead of T12's remaining tests (H10, H11, H12, H14): now depends on T11 | Claude |
| 2026-10-12 | T13 prep: DeviceAuthorizer, SecurityAuthorizer, FakeDeviceAuthorizer, `authopen -extauth` in AuthopenOpener; NEEDS_HUMAN for the dialog checks | Claude |
| 2026-10-12 | T13 DONE after Nick's dialog checks; macOS retries wrong passwords indefinitely (`tries` 10000) | Claude |
| 2026-10-12 | T14 added: rename to Red Delicious Media Writer; T12's remaining tests run on the T14 build | Claude |
| 2026-10-12 | T14 DONE: app renamed to Red Delicious Media Writer (`RedDelicious`, `com.example.reddelicious`, `REDDELICIOUS_*`) | Claude |
| 2026-10-12 | T15 DONE: app icon from Nick's artwork in `App/Assets.xcassets` | Claude |
| 2026-10-12 | T16 added from a review finding (disk swapped during the password dialog) and prepped: prompt before the safety check, size check after open; NEEDS_HUMAN. T12's remaining tests run on the T16 build | Claude |
| 2026-10-12 | T16 DONE after Nick's runs: one dialog per write, H15 swap refused, H5 leaves the drive mounted, real-stick write and verify pass | Claude |
| 2026-10-12 | T17 added: layered Icon Composer icon so the app follows the macOS 26 Dark, Clear and Tinted icon styles | Claude |
| 2026-10-12 | T17 prep: `App/AppIcon.icon` from Nick's apple artwork replaces the T15 PNG set; NEEDS_HUMAN for the Dock and Finder check | Claude |
| 2026-10-12 | T19 added from a review finding: the final flush never reaches the drive on raw devices (`F_FULLFSYNC` returns `ENOTTY`, `fsync` does nothing), so flush with `DKIOCSYNCHRONIZE` | Claude |
| 2026-10-12 | T20 added from a review finding: USB hard drives and SSDs report ejectable, so the default list shows them; fix the README and warn for drives over 500 GB | Claude |
| 2026-10-12 | T21 added from four review findings: the device descriptor isn't close-on-exec, a partial-block write or read retries misaligned, a same-size replaced image isn't caught, and a diskutil that ignores SIGTERM hangs the timeout path | Claude |
| 2026-10-12 | T22 added from four review findings: volume names aren't shown, test fakes ship in Release, Info.plist lacks copyright, category and removable-volume usage text, and the Hardened Runtime is off. DiskArbitration (the fifth) left out | Claude |
| 2026-10-13 | T23 added: rename to Raccoon Writer (`RaccoonWriter`, `com.example.raccoonwriter`, `RACCOONWRITER_*`) and the raccoon icon from Nick's `raccoon-writer-branding/` pack, deleted afterwards; listed above T19 so it is done before T19–T22 | Claude |
| 2026-10-13 | T23 DONE: app renamed to Raccoon Writer (`RaccoonWriter`, `com.example.raccoonwriter`, `RACCOONWRITER_*`); raccoon layer in `App/AppIcon.icon`; branding folder deleted | Claude |
| 2026-10-13 | T19 prep: `DKIOCSYNCHRONIZE` is the first flush method, then `F_FULLFSYNC`, then `fsync`; skipped methods logged with their errno; NEEDS_HUMAN for the RAM-disk and Cruzer Glide runs | Claude |
| 2026-10-13 | T19 DONE after Nick's runs: both the RAM disk and the Cruzer Glide flush with `DKIOCSYNCHRONIZE` | Claude |
| 2026-10-13 | T18 DONE after Nick's check: the callout stands out in Light and Dark, wraps at minimum width, and is absent without a notice | Claude |
| 2026-10-13 | T17 DONE after Nick's check: the raccoon icon follows the Default, Dark, Clear and Tinted icon styles | Claude |
