# Red Delicious Media Writer (repo: iso-sword) — Implementation Plan

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
| App name / folder | **Red Delicious Media Writer**, short name "Red Delicious", target `RedDelicious`. Folder and repo stay `iso-sword`. Was "ISO Sword" / `IsoSword` until T14 |
| Bundle ID | `com.example.reddelicious` (placeholder; change before any public release). Was `com.example.isosword` until T14 |
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
- **Cache and sync:** set `F_NOCACHE` on the fd; call `fcntl(fd, F_FULLFSYNC)` after the last write, falling back to `fsync()` if it fails with `ENOTTY`/`ENOTSUP` (T01: RAM disks return `ENOTTY`).
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
| T16 | 🧑 Password prompt before the safety check; size check after open | T15 | NEEDS_HUMAN | | Claude (prep) / Nick (run) |

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
  - `WriteCoordinator.reset(keepingImage:)`: `true` goes back to `imageSelected`, used by "Try Again", "Start Again" and "Write Another". The drive is always picked again.
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
