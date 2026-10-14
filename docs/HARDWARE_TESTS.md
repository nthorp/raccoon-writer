# Hardware test checklist (T12)

The first real-world check of Raccoon Writer. Builds before T14 were called ISO Sword (`build/IsoSword.app`, env vars `ISOSWORD_*`, log subsystem `com.example.isosword`), and builds from T14 until T23 were called Red Delicious Media Writer (`build/RedDelicious.app`, env vars `REDDELICIOUS_*`, log subsystem `com.example.reddelicious`); the recorded results below keep the names of the build they ran on. Every test here is run by a person (Nick), never by an agent. Agents must not write to real disks.

**Most of these tests erase a USB stick.** Use sticks that hold nothing you need. H11 pulls a stick out mid-write. That is almost always harmless, but use a spare stick you don't mind losing.

## How to record results

For each test, fill in the **Result** line (`PASS` or `FAIL`) and add notes: what you saw, anything unexpected, and any lines from the log window that matter. Copy the outcome into the summary table. For each failure, file an issue and put its link in the notes.

A test passes only if every **Expected** item happened. If one item differs but the rest is fine, mark it `FAIL` and explain in the notes. The difference is still worth an issue.

## Setup

### What you need

- A Mac with Apple Silicon. An Intel Mac too if you have one (H13).
- One or two USB sticks you can erase, at least 8 GB. One of them is the spare for H11.
- A PC (or Intel Mac) that can boot from USB, for H6 and H7.
- Images. Keep them in `~/iso-sword-test/`:
  - **A hybrid Linux ISO**, for example Fedora Workstation Live or Ubuntu Desktop (both are hybrid). At least 2 GB, so that H8 and H9 have time to click Cancel.
  - **An uncompressed `.img`**, for example a FreeBSD `memstick.img`, or a Raspberry Pi OS image unpacked with `xz -dk`. Raccoon Writer can't read `.xz`, `.gz` or `.zip`.
  - **An image bigger than your stick.** A sparse file is enough. For a 16 GB stick: `mkfile -n 20g ~/iso-sword-test/too-big.img` (use a size larger than your stick).
  - **Random test data for the RAM disk:** `head -c 200000000 /dev/urandom > ~/iso-sword-test/ram-test.img` (200 MB).

### Builds

Both builds go to `build/RaccoonWriter.app`, so rebuild when a test needs the other one.

- Debug, needed for H1, H2 and part of H3: `scripts/build.sh`
- Release, used for every real-stick test (H3–H13): `scripts/build.sh --release`

Record the commit you tested: `git rev-parse --short HEAD`.

### Log window

Keep this running in a second Terminal window during every test. It shows which flush method was used (H6), authopen's error text, and why disks were filtered out:

```sh
log stream --predicate 'subsystem == "com.example.raccoonwriter"' --info
```

### Identifying the stick

Before each write, find the stick's disk number yourself and compare it with what the app shows:

```sh
diskutil list external physical
```

Run it before and after inserting the stick. The new entry (for example `/dev/disk4`) is the stick. **On the confirm screen, check that the name, size and `/dev/diskN` match. If they don't, click Cancel and stop.**

## Test environment

| | Run A | Run B (optional) |
| --- | --- | --- |
| Date | 2026-10-09 | |
| Mac model and chip | MacBook Pro (Mac15,10), Apple M3 Max, 36 GB | |
| macOS version | 26.3.1 (25D2128) | |
| Xcode version | 26.6 (17F113) | |
| Commit tested | 2df5b29 (app code unchanged since T11, 57fc215) | |
| USB stick 1 (make, model, size, USB 2/3) | SanDisk Cruzer Glide, 31.4 GB, USB 2.0 link (480 Mb/s) through a GenesysLogic USB 2.1 hub | |
| USB stick 2 / spare (make, model, size) | | |
| Boot test machine | 2017 Intel Mac | |

## Summary

**Wait for T13 before running H10, H11, H12 and H14.** T13 (in `PLAN.md`) changes the password dialog, so these run on the T13 build. Put the build's commit (`git log --oneline -1`) in each test's notes.

**From T16 on, the password dialog comes first**, before the safety check and the unmount. A cancelled dialog leaves the drive mounted (H5), and the dialog appears even when the drive turns out to be in use (H12). H15 is new in T16.

| ID | Test | Build | Result | Notes / issue |
| --- | --- | --- | --- | --- |
| H1 | Simulate mode: layout and dark mode | Debug | PASS | |
| H2 | RAM-disk dry run with password prompt | Debug | PASS | Prompt shown; `fsync fallback` as expected for a RAM disk |
| H3 | Boot and internal disks never listed | Debug + Release | PASS | Debug: only `disk7` and `disk9`; Release: only `disk7`; hot-plug and deselect work; built-in SD slot reports internal, so hidden |
| H4 | Image bigger than the stick | Release | PASS | 40 GB image vs 31.4 GB stick |
| H5 | Cancel the password prompt | Release | PASS | Back to confirm screen; volume and file intact after replug. Re-run on T16: volume stays mounted |
| H6 | Hybrid Linux ISO, boots on test machine; flush method | Release | PASS | Fedora 44 Live booted on a 2017 Intel Mac; `fsync fallback`; 4.7 MB/s, 11 min 30 s |
| H7 | `.img` write | Release | PASS | FreeBSD `.img` booted on a 2017 Intel Mac |
| H8 | Cancel during write | Release | PASS | |
| H9 | Cancel during verify | Release | PASS | |
| H10 | Quit and close during a write | Release | | |
| H11 | Pull the stick out mid-write | Release | | |
| H12 | Drive in use (unmount refused) | Release | | |
| H13 | Intel Mac run | Release | Not possible | Intel Mac runs macOS 13.7.8; app needs 14+ |
| H14 | What real disks report (read-only) | none | | |
| H15 | Drive swapped during the password dialog | Debug | PASS | Both RAM disks were `disk8`; refused with "A different drive is attached" |

**Flush method on the USB stick (from H6):** `fsync fallback` (SanDisk Cruzer Glide, 2026-10-09). That build never tried `DKIOCSYNCHRONIZE`. **From T19 on: `DKIOCSYNCHRONIZE`** (Cruzer Glide, Release build, 2026-10-13, commit `169b386`; details under T19 in `PLAN.md`).

---

## Tests

### H1 — Simulate mode: layout and dark mode

Nothing touches a disk. This is a visual check of every screen, which agents couldn't do (they read the screens as accessibility text only).

**Steps**
1. `scripts/build.sh`, then `mkfile -n 300m /tmp/sim.img`.
2. `RACCOONWRITER_SIMULATE=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`
3. Choose `/tmp/sim.img`. Write to `disk90` (success), `disk91` (pulled out mid-write) and `disk92` (verify mismatch). Try `disk93` (cancelled password prompt) and `disk94` (too small).
4. Switch to Dark Mode (System Settings → Appearance) and look at the setup, progress and done screens again.
5. (Added in T20.) With "Show all external disks" off, check that `disk96`, "Simulated USB Hard Drive (1 TB)", is listed with "Large drive" under it, and the 16 GB sticks aren't. Select it and press Continue…: the confirm screen shows an orange large-drive warning under the "You are about to erase…" line. A write to it succeeds like `disk90`.

**Expected**
- A yellow banner says it's a simulation.
- Text is readable and nothing is clipped or overlapping, in Light and Dark Mode.
- The window is a sensible size, and resizing it doesn't break the layout.

**Result:** PASS
**Notes:** 2026-10-09, Debug build. Nick reports every expected result, in Light and Dark Mode.

### H2 — RAM-disk dry run (debug flag)

A full write, verify and eject against a RAM disk, with the real password prompt. No USB stick is involved.

**Steps**
1. `scripts/build.sh` (Debug).
2. Create a 512 MiB RAM disk and make its nodes root-owned like a real disk. Without the `chown`, authopen doesn't ask for a password (T01). The `sudo` password here is for Terminal, not the prompt being tested.
   ```sh
   DISK=$(hdiutil attach -nomount ram://1048576 | awk '{print $1}')
   RAW="/dev/r${DISK#/dev/}"
   sudo chown root:operator "$DISK" "$RAW"
   echo "$DISK"
   ```
3. `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`
4. Choose `~/iso-sword-test/ram-test.img`. Pick the RAM disk (its `diskN` is the one echoed above, named "Disk Image"). Click Continue, then **Erase and Write**.
5. Enter your password in the macOS dialog.
6. Afterwards, clean up if the disk is still attached ("no such disk" is fine): `hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"`

**Expected**
- The confirm screen shows the RAM disk's name, 537 MB and `/dev/diskN`.
- The dialog says "authopen wants to make changes" (builds before T13; from T13 on it names the app, see T13).
- The progress screen goes through writing, "Finishing the write" and verifying, then shows "Finished. You can remove the drive." with the size, total time and average write speed.
- The log shows `fullSync used …`. From T19 on this is `DKIOCSYNCHRONIZE` if the RAM disk supports it; otherwise `fsync fallback`, with a `fullSync skipped …` line and its errno for each method that was skipped. Before T19 it was always `fsync fallback` (RAM disks don't support `F_FULLFSYNC`, see T01).
- Either the RAM disk was ejected, or the done screen says "Finished, but the drive is still attached". Note which one.

**Result:** PASS
**Notes:** 2026-10-09, Debug build, 512 MiB RAM disk with `root:operator` nodes. Nick reports every expected result, including the authopen password dialog and the `fullSync used fsync fallback` log line. Afterwards the agent checked `hdiutil info`: the 512 MiB RAM disk was no longer attached. The agent also found that `log show` afterwards returned no lines from the app, because info-level lines aren't stored, so the flush method can only be seen live with `log stream`.
- T19 adds `DKIOCSYNCHRONIZE` as the first flush method and re-runs this test; see T19 in `PLAN.md`.
- T19 re-run, 2026-10-13, Debug build, commit `169b386`: write and verify passed, the RAM disk was ejected, and the log showed `fullSync used DKIOCSYNCHRONIZE` with no skipped methods.

### H3 — Boot and internal disks never listed

**Steps**
1. Run `diskutil list` and note every internal disk and the boot disk's APFS container (for example `disk0` and `disk3`). Mount any `.dmg` you have (or leave one mounted).
2. **Release build**, with a USB stick inserted: look at the drive list with "Show all external disks" off, then on.
3. Insert and remove the stick while the drive list is showing. Do the same while the stick is selected.
4. **Debug build** with `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1`: repeat step 2.
5. If you have an SD card slot, a card reader or a Thunderbolt/USB-C SSD, attach it and repeat step 2 with the Release build.

**Expected**
- Internal disks, the boot disk and its container never appear, in either mode or either build.
- With the toggle off, only the USB stick is listed. With it on, other external, non-internal disks (Thunderbolt SSD, external SD reader) may also appear.
- A mounted `.dmg` never appears, not even with the debug flag (the flag accepts only unmounted disk images).
- The stick appears or disappears within about 2 seconds. When the selected stick is removed, it is deselected.
- Note what an SD card in a built-in slot does. It may report itself as internal, in which case it is hidden by design.

**Result:** PASS
**Notes:**
- **Part 1, 2026-10-09, Debug build with `ISOSWORD_ALLOW_VIRTUAL_DISKS=1`.** `diskutil list` showed: `disk0` internal SSD; `disk3` boot APFS container (synthesized, store `disk0s2`); `disk5` iOS 26.5 Simulator image, mounted through its APFS container `disk6`; `disk7` USB stick (SanDisk Cruzer Glide, 31.4 GB); `disk8` mounted `TestDMG` `.dmg`; `disk9` unmounted 33.6 MB RAM disk (the control). The app listed **only `disk7` and `disk9`**, as expected: the internal disk, the boot container, both mounted disk images and the simulator's container were hidden, and the RAM disk showing confirms the debug flag was active.
- **Part 2, 2026-10-09, Release build, no debug flag.** Only the USB stick (`disk7`) was listed, with "Show all external disks" both off and on: no internal disk, boot container, simulator image or other disk image. Unplugging the stick removed it from the list, and plugging it back in brought it back. Unplugging it while it was selected removed it, cleared the selection and disabled Continue.
- **Step 5:** an SD card in the MacBook Pro's built-in slot (`disk4`) mounted in Finder but was **not listed** in either toggle position. The slot reports `Internal = true` (details in H14), so it is hidden by design. This confirms the T03 guess. Write SD cards through a USB card reader instead (now in the README's known limitations).

### H4 — Image bigger than the stick

**Steps**
1. Choose `~/iso-sword-test/too-big.img`, then look at the stick in the drive list.

**Expected**
- The stick's row says "Too small for this image".
- A message says the image is larger than the drive and how big a drive is needed.
- Continue is disabled. Nothing was unmounted (the stick's volumes are still in Finder).

**Result:** PASS
**Notes:** 2026-10-09, Release build. The first attempt used a 20 GB file, which fits on the 31.4 GB stick, so the app correctly allowed it. That was a test-setup mistake, not a bug. With a 40 GB sparse `too-big.img`, the stick's row showed "Too small for this image".

### H5 — Cancel the password prompt

**Steps**
1. Make sure the stick has a mounted volume (format it in Disk Utility first if needed).
2. Choose any image and the stick, click Continue, then **Erase and Write**.
3. In the password dialog, click **Cancel**. From T13 on the dialog names the app; earlier builds showed "authopen wants to make changes".

**Expected** (from T16 on; earlier builds unmounted the drive before the dialog, which is what the result below recorded)
- The app returns to the confirm screen, not an error screen, with the notice: "The password dialog was cancelled, so nothing was written and the drive was left as it was."
- "Mounted volumes" still lists the volume, and it is still in Finder with its files intact.

**Result:** PASS
**Notes:** 2026-10-09, Release build, stick formatted ExFAT/GPT as `TESTSTICK` with one test file. Clicking Cancel in the authopen dialog returned the app to the confirm screen with the notice, not an error screen. "Mounted volumes" read none and `TESTSTICK` left Finder. After a replug, `TESTSTICK` remounted. The agent checked read-only afterwards: `disk7` still had its GPT layout (EFI + `TESTSTICK`) and the test file was intact.
**Re-run on T16, 2026-10-12, Release build, commit `e55abea`:** stick erased to ExFAT `TESTSTICK` with a test file. Cancel returned to the confirm screen with "…nothing was written and the drive was left as it was", and the volume stayed mounted. A full write and verify on the same stick then passed.

### H6 — Hybrid Linux ISO, boots on a test machine

The main end-to-end test. Also records the flush method on a real stick.

**Steps**
1. Note the stick's `diskN` (see "Identifying the stick").
2. Choose the hybrid ISO. There should be **no** "may not boot from a USB drive" warning.
3. Pick the stick, click Continue, check that the confirm screen matches, then **Erase and Write** and enter your password.
4. While it writes:
   - Check that the window's close button is greyed out and ⌘W does nothing.
   - Run `pmset -g assertions | grep -i writing`. It should show `PreventUserIdleSystemSleep` named "Writing <image> to diskN".
5. When it finishes, look for the `fullSync used …` line in the log window. Run `pmset -g assertions | grep -i writing` again.
6. Remove the stick and boot the test machine from it.

**Expected**
- The progress screen shows percent, a speed in MB/s (a dash for the first second) and the time left, then "Finishing the write", then verifying.
- "Finished. You can remove the drive." The stick has disappeared from `diskutil list` (ejected).
- The sleep assertion is present during the run and gone afterwards. The close button works again.
- The test machine boots to the distro's boot menu or live desktop.
- **Record** the flush method (`DKIOCSYNCHRONIZE` is expected from T19 on; otherwise `F_FULLFSYNC` or `fsync fallback`, plus the `fullSync skipped …` lines with their errno), the average write speed and the total time.

**Result:** PASS
**Notes:**
- 2026-10-09, Release build, `Fedora-Workstation-Live-44-1.7.x86_64.iso` to the SanDisk Cruzer Glide (`disk7`, USB 2.0). Nick reports every expected result for steps 2–4: no boot warning; the confirm screen matched; the close button was greyed out and ⌘W ignored during the write; the sleep assertion was present during the run and gone after; progress went through writing, "Finishing the write" and verifying; "Finished. You can remove the drive." and the stick ejected.
- **Flush method: `fsync fallback`.** Log: `2026-10-09 22:04:46.084688-0500 … IsoSword: [com.example.isosword:device] fullSync used fsync fallback`. This stick does not support `F_FULLFSYNC` (open question from T01). The write still verified. The cache is bypassed (`F_NOCACHE`), and the eject that follows has macOS flush the drive.
- **Average write speed 4.7 MB/s, total time 11 min 30 s** (write, flush, verify and eject). This is slow but in line with this stick, a USB 2.0 Cruzer Glide on a 480 Mb/s link through a hub. Writing is the stick's bottleneck.
- **Boot test PASS:** the stick booted Fedora 44 Live on a 2017 Intel Mac.
- T19: `F_FULLFSYNC` returns `ENOTTY` on any raw disk node, not only this stick, and `fsync` there doesn't reach the drive, so this build never flushed the stick's cache; the eject did. T19 flushes with `DKIOCSYNCHRONIZE` and re-runs the write on this stick; see T19 in `PLAN.md`.
- T19 re-run, 2026-10-13, Release build, commit `169b386`, `ram-test.img` to the Cruzer Glide: write and verify passed, the stick was ejected, and the log showed `fullSync used DKIOCSYNCHRONIZE` with no skipped methods.

### H7 — `.img` write

**Steps**
1. Write the uncompressed `.img` to the stick as in H6.
2. Boot from it, or for a Raspberry Pi image, check that the stick's boot partition mounts on the Mac after reinserting it.

**Expected**
- No boot warning for the `.img`.
- The write and verify finish, and the stick ejects.
- The stick boots, or its partitions mount and look right.

**Result:** PASS
**Notes:** 2026-10-09, Release build. A FreeBSD `.img` was written to the SanDisk Cruzer Glide; the write and verify finished and the stick ejected. It booted the 2017 Intel Mac.

### H8 — Cancel during write

**Steps**
1. Start writing the large hybrid ISO. At about 20–50 %, click **Cancel**.

**Expected**
- The button changes to "Cancelling…" and is disabled. Within a second or two the screen shows "Cancelled", "Stopped while: writing." and "The drive may be partially written and is not bootable…".
- The log shows no `fullSync used` line for this run.
- **Start Over** returns to the setup screen with the image kept, and the drive must be picked again.
- Writing again to the same stick then succeeds (it can be combined with H9).

**Result:** PASS
**Notes:** 2026-10-09, Release build, Fedora 44 ISO, cancelled partway through the write. Nick reports every expected result. Writing to the same stick again afterwards worked (H9).

### H9 — Cancel during verify

**Steps**
1. Write the large hybrid ISO. When the screen switches to verifying, click **Cancel**.

**Expected**
- "Cancelled", "Stopped while: verifying." and "The image was written but could not be checked, so the drive may not boot…".
- If the cancel lands just after the last chunk was compared, the run may finish as a success instead. That is correct: every byte matched. Note it if it happens.

**Result:** PASS
**Notes:** 2026-10-09, Release build, FreeBSD `.img`, cancelled during the verify. Nick reports every expected result.

### H10 — Quit and close during a write

**Steps**
1. Start a write. While it is writing, press ⌘Q.
2. Click **Keep Writing**. Check that the write continues.
3. Press ⌘Q again and click **Stop and Quit**.
4. Start another write, and while the Raccoon Writer password dialog is up press ⌘Q, then **Stop and Quit**, then answer the dialog (either button). Note which button you used.

**Expected**
- The alert says "Stop writing and quit?" with the drive note. "Keep Writing" is the default button.
- Keep Writing: the run continues normally.
- Stop and Quit: the app quits within a few seconds. `ps aux | grep -i RaccoonWriter` shows nothing left running.
- During the password dialog the alert says "Cancel and quit?" and that the app quits once you answer the dialog, which it does.

**Result:**
**Notes:**

### H11 — Pull the stick out mid-write (spare stick)

**Steps**
1. Start writing the large ISO to the **spare** stick. At about 30 %, pull it out.

**Expected**
- Within a few seconds the app shows "The drive was disconnected" or "The drive stopped responding" (note which), with "Writing stopped and was not retried" and the partially-written drive note. The app does not hang.
- **Try Again** goes back to the setup screen and requires picking a drive. Nothing is retried on another disk.
- The log shows the I/O error (note the errno if you can see it).
- After reinserting it, the stick can be written again successfully.

**Result:**
**Notes:**

### H12 — Drive in use (unmount refused)

**Steps**
1. Mount a volume on the stick and keep a file on it open in Terminal, for example: `tail -f "/Volumes/<name>/some-file"` (or `cd` into the volume).
2. Try to write to the stick.
3. Stop the `tail` (or `cd` away) and try again.

**Expected**
- First attempt: the password dialog appears (from T16 on it comes before the unmount). After you enter the password: "The drive is in use", naming the process that is holding it, with "Nothing was written to the drive."
- Second attempt: works normally.

**Result:**
**Notes:**

### H13 — Intel Mac run (if available)

**Steps**
1. Copy `build/RaccoonWriter.app` (Release) to the Intel Mac. If it was copied by AirDrop or downloaded, clear the quarantine flag first: `xattr -dr com.apple.quarantine RaccoonWriter.app`. The app is only ad-hoc signed.
2. Repeat H3 and H6 there.

**Expected**
- The app launches, and H3 and H6 give the same results as on Apple Silicon. Record the flush method there too.

**Result:** Not possible on Intel hardware
**Notes:** The only Intel Mac available (2017) runs macOS Ventura 13.7.8, and ISO Sword requires macOS 14 or later (it uses the Observation framework), so the app can't run there. The 2017 Intel Mac was still used as the boot machine for H6 and H7.

### H14 — What real disks report (read-only)

The disk list's filter rules were partly written from hand-made fixtures (T03). This records what real hardware reports. The command only reads.

**Steps:** for each disk you have (USB stick, SD card in a built-in slot, SD card in a USB reader, Thunderbolt/USB-C SSD), find its `diskN` with `diskutil list` and run:

```sh
D=disk4
for k in MediaName BusProtocol Internal Removable RemovableMedia Ejectable VirtualOrPhysical DeviceBlockSize TotalSize; do printf '%s: ' "$k"; diskutil info -plist "$D" | plutil -extract "$k" raw -o - - 2>/dev/null || echo absent; done
```

Change `disk4` to the disk's number first. Paste each output below, and note whether the disk appeared in Raccoon Writer with the toggle off and on.

**Result:**
**Notes:**
- **USB stick 1, `disk7` on 2026-10-09** (read by the agent): MediaName `Cruzer Glide`, BusProtocol `USB`, Internal `false`, Removable `true`, RemovableMedia `true`, Ejectable `true`, VirtualOrPhysical `Physical`, DeviceBlockSize `512`, TotalSize `31406948352`. This matches the hand-written USB fixture's rules (T03): shown in the default list.
- **SD card in the built-in SDXC slot, `disk4` on 2026-10-09** (read by the agent): MediaName `Built In SDXC Reader`, BusProtocol `Secure Digital`, Internal **`true`**, Removable `true`, RemovableMedia `true`, Ejectable `true`, VirtualOrPhysical `Physical`, DeviceBlockSize `512`, TotalSize `64021856256`. Hidden under both settings because it reports internal. The T03 fixture `info-disk7` guessed `Internal = false` for an SD card; a real built-in slot says `true`. Not seen in ISO Sword with the toggle off or on.

### H15 — Drive swapped during the password dialog (RAM disks, debug flag)

Checks that a disk which takes over the drive's `/dev/diskN` name while the password dialog is open is refused. RAM disks stand in for the stick and the other disk, so nothing real is at risk. Added in T16.

**Steps**
1. `scripts/build.sh` (Debug).
2. Detach any RAM disks left from earlier tests (`hdiutil info` lists them with image path `ram://…`). Otherwise A may not get the lowest free number, and B won't reuse A's name. Then create RAM disk **A** (512 MiB) with root-owned nodes, as in H2 step 2:
   ```sh
   DISK=$(hdiutil attach -nomount ram://1048576 | awk '{print $1}')
   RAW="/dev/r${DISK#/dev/}"
   sudo chown root:operator "$DISK" "$RAW"
   echo "$DISK"
   ```
3. `RACCOONWRITER_ALLOW_VIRTUAL_DISKS=1 build/RaccoonWriter.app/Contents/MacOS/RaccoonWriter`
4. Choose `~/iso-sword-test/ram-test.img`, pick RAM disk A, click Continue, then **Erase and Write**. **Leave the password dialog open.**
5. In Terminal, detach A and attach RAM disk **B**, which is half the size:
   ```sh
   hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"
   DISK2=$(hdiutil attach -nomount ram://524288 | awk '{print $1}')
   RAW2="/dev/r${DISK2#/dev/}"
   sudo chown root:operator "$DISK2" "$RAW2"
   echo "$DISK $DISK2"
   ```
   The two names should be the same, because macOS reuses the lowest free number. If they differ, note it, detach B and start again from step 2.
6. Enter your password in the dialog.
7. Clean up: `hdiutil detach "$DISK2" || sudo hdiutil detach "$DISK2"`

**Expected**
- After the password, the app shows "A different drive is attached", saying the drive's size changed, with "Nothing was written to the drive."
- The log shows `Refused diskN` from the `safety` category, and no unmount or authopen lines for that run.

**Result:** PASS
**Notes:** 2026-10-12, Debug build, commit `e55abea`. First attempt: leftover RAM disks `disk10` and `disk11` were attached, so A became `disk12` and B took `disk8`; the names differed, so it was redone. After detaching the leftovers, A and B were both `disk8`, and after the password the app showed "A different drive is attached" (size changed).
