# Hardware test checklist (T12)

The first real-world check of ISO Sword. Every test here is run by a person (Nick), never by an agent. Agents must not write to real disks.

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
  - **An uncompressed `.img`**, for example a FreeBSD `memstick.img`, or a Raspberry Pi OS image unpacked with `xz -dk`. ISO Sword can't read `.xz`, `.gz` or `.zip`.
  - **An image bigger than your stick.** A sparse file is enough. For a 16 GB stick: `mkfile -n 20g ~/iso-sword-test/too-big.img` (use a size larger than your stick).
  - **Random test data for the RAM disk:** `head -c 200000000 /dev/urandom > ~/iso-sword-test/ram-test.img` (200 MB).

### Builds

Both builds go to `build/IsoSword.app`, so rebuild when a test needs the other one.

- Debug, needed for H1, H2 and part of H3: `scripts/build.sh`
- Release, used for every real-stick test (H3–H13): `scripts/build.sh --release`

Record the commit you tested: `git rev-parse --short HEAD`.

### Log window

Keep this running in a second Terminal window during every test. It shows which flush method was used (H6), authopen's error text, and why disks were filtered out:

```sh
log stream --predicate 'subsystem == "com.example.isosword"' --info
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
| Date | | |
| Mac model and chip | | |
| macOS version | | |
| Xcode version | | |
| Commit tested | | |
| USB stick 1 (make, model, size, USB 2/3) | | |
| USB stick 2 / spare (make, model, size) | | |
| Boot test machine | | |

## Summary

| ID | Test | Build | Result | Notes / issue |
| --- | --- | --- | --- | --- |
| H1 | Simulate mode: layout and dark mode | Debug | | |
| H2 | RAM-disk dry run with password prompt | Debug | | |
| H3 | Boot and internal disks never listed | Debug + Release | | |
| H4 | Image bigger than the stick | Release | | |
| H5 | Cancel the password prompt | Release | | |
| H6 | Hybrid Linux ISO, boots on test machine; flush method | Release | | |
| H7 | `.img` write | Release | | |
| H8 | Cancel during write | Release | | |
| H9 | Cancel during verify | Release | | |
| H10 | Quit and close during a write | Release | | |
| H11 | Pull the stick out mid-write | Release | | |
| H12 | Drive in use (unmount refused) | Release | | |
| H13 | Intel Mac run | Release | | |
| H14 | What real disks report (read-only) | none | | |

**Flush method on the USB stick (from H6):** `F_FULLFSYNC` / `fsync fallback` (circle one)

---

## Tests

### H1 — Simulate mode: layout and dark mode

Nothing touches a disk. This is a visual check of every screen, which agents couldn't do (they read the screens as accessibility text only).

**Steps**
1. `scripts/build.sh`, then `mkfile -n 300m /tmp/sim.img`.
2. `ISOSWORD_SIMULATE=1 build/IsoSword.app/Contents/MacOS/IsoSword`
3. Choose `/tmp/sim.img`. Write to `disk90` (success), `disk91` (pulled out mid-write) and `disk92` (verify mismatch). Try `disk93` (cancelled password prompt) and `disk94` (too small).
4. Switch to Dark Mode (System Settings → Appearance) and look at the setup, progress and done screens again.

**Expected**
- A yellow banner says it's a simulation.
- Text is readable and nothing is clipped or overlapping, in Light and Dark Mode.
- The window is a sensible size, and resizing it doesn't break the layout.

**Result:**
**Notes:**

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
3. `ISOSWORD_ALLOW_VIRTUAL_DISKS=1 build/IsoSword.app/Contents/MacOS/IsoSword`
4. Choose `~/iso-sword-test/ram-test.img`. Pick the RAM disk (its `diskN` is the one echoed above, named "Disk Image"). Click Continue, then **Erase and Write**.
5. Enter your password in the macOS dialog.
6. Afterwards, clean up if the disk is still attached ("no such disk" is fine): `hdiutil detach "$DISK" || sudo hdiutil detach "$DISK"`

**Expected**
- The confirm screen shows the RAM disk's name, 537 MB and `/dev/diskN`.
- The dialog says "authopen wants to make changes".
- The progress screen goes through writing, "Finishing the write" and verifying, then shows "Finished. You can remove the drive." with the size, total time and average write speed.
- The log shows `fullSync used fsync fallback` (RAM disks don't support `F_FULLFSYNC`, see T01).
- Either the RAM disk was ejected, or the done screen says "Finished, but the drive is still attached". Note which one.

**Result:**
**Notes:**

### H3 — Boot and internal disks never listed

**Steps**
1. Run `diskutil list` and note every internal disk and the boot disk's APFS container (for example `disk0` and `disk3`). Mount any `.dmg` you have (or leave one mounted).
2. **Release build**, with a USB stick inserted: look at the drive list with "Show all external disks" off, then on.
3. Insert and remove the stick while the drive list is showing. Do the same while the stick is selected.
4. **Debug build** with `ISOSWORD_ALLOW_VIRTUAL_DISKS=1`: repeat step 2.
5. If you have an SD card slot, a card reader or a Thunderbolt/USB-C SSD, attach it and repeat step 2 with the Release build.

**Expected**
- Internal disks, the boot disk and its container never appear, in either mode or either build.
- With the toggle off, only the USB stick is listed. With it on, other external, non-internal disks (Thunderbolt SSD, external SD reader) may also appear.
- A mounted `.dmg` never appears, not even with the debug flag (the flag accepts only unmounted disk images).
- The stick appears or disappears within about 2 seconds. When the selected stick is removed, it is deselected.
- Note what an SD card in a built-in slot does. It may report itself as internal, in which case it is hidden by design.

**Result:**
**Notes:**

### H4 — Image bigger than the stick

**Steps**
1. Choose `~/iso-sword-test/too-big.img`, then look at the stick in the drive list.

**Expected**
- The stick's row says "Too small for this image".
- A message says the image is larger than the drive and how big a drive is needed.
- Continue is disabled. Nothing was unmounted (the stick's volumes are still in Finder).

**Result:**
**Notes:**

### H5 — Cancel the password prompt

**Steps**
1. Make sure the stick has a mounted volume (format it in Disk Utility first if needed).
2. Choose any image and the stick, click Continue, then **Erase and Write**.
3. In the "authopen wants to make changes" dialog, click **Cancel**.

**Expected**
- The app returns to the confirm screen, not an error screen, with the notice: "The password dialog was cancelled, so nothing was written. The drive's volumes have been unmounted; reinsert the drive to get them back."
- "Mounted volumes" now reads none, and the volume has left Finder.
- After the stick is reinserted, its volume and files are intact.

**Result:**
**Notes:**

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
- **Record** the flush method (`F_FULLFSYNC` or `fsync fallback`), the average write speed and the total time.

**Result:**
**Notes:**

### H7 — `.img` write

**Steps**
1. Write the uncompressed `.img` to the stick as in H6.
2. Boot from it, or for a Raspberry Pi image, check that the stick's boot partition mounts on the Mac after reinserting it.

**Expected**
- No boot warning for the `.img`.
- The write and verify finish, and the stick ejects.
- The stick boots, or its partitions mount and look right.

**Result:**
**Notes:**

### H8 — Cancel during write

**Steps**
1. Start writing the large hybrid ISO. At about 20–50 %, click **Cancel**.

**Expected**
- The button changes to "Cancelling…" and is disabled. Within a second or two the screen shows "Cancelled", "Stopped while: writing." and "The drive may be partially written and is not bootable…".
- The log shows no `fullSync used` line for this run.
- **Start Again** returns to the setup screen with the image kept, and the drive must be picked again.
- Writing again to the same stick then succeeds (it can be combined with H9).

**Result:**
**Notes:**

### H9 — Cancel during verify

**Steps**
1. Write the large hybrid ISO. When the screen switches to verifying, click **Cancel**.

**Expected**
- "Cancelled", "Stopped while: verifying." and "The image was written but could not be checked, so the drive may not boot…".
- If the cancel lands just after the last chunk was compared, the run may finish as a success instead. That is correct: every byte matched. Note it if it happens.

**Result:**
**Notes:**

### H10 — Quit and close during a write

**Steps**
1. Start a write. While it is writing, press ⌘Q.
2. Click **Keep Writing**. Check that the write continues.
3. Press ⌘Q again and click **Stop and Quit**.
4. Start another write, and during the password dialog press ⌘Q, then **Stop and Quit**, then answer the dialog (either button).

**Expected**
- The alert says "Stop writing and quit?" with the drive note. "Keep Writing" is the default button.
- Keep Writing: the run continues normally.
- Stop and Quit: the app quits within a few seconds. `ps aux | grep -i IsoSword` shows nothing left running.
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
- First attempt: "The drive is in use", naming the process that is holding it, with "Nothing was written to the drive." No password dialog appears.
- Second attempt: works normally.

**Result:**
**Notes:**

### H13 — Intel Mac run (if available)

**Steps**
1. Copy `build/IsoSword.app` (Release) to the Intel Mac. If it was copied by AirDrop or downloaded, clear the quarantine flag first: `xattr -dr com.apple.quarantine IsoSword.app`. The app is only ad-hoc signed.
2. Repeat H3 and H6 there.

**Expected**
- The app launches, and H3 and H6 give the same results as on Apple Silicon. Record the flush method there too.

**Result:**
**Notes:**

### H14 — What real disks report (read-only)

The disk list's filter rules were partly written from hand-made fixtures (T03). This records what real hardware reports. The command only reads.

**Steps:** for each disk you have (USB stick, SD card in a built-in slot, SD card in a USB reader, Thunderbolt/USB-C SSD), find its `diskN` with `diskutil list` and run:

```sh
D=disk4
for k in MediaName BusProtocol Internal Removable RemovableMedia Ejectable VirtualOrPhysical DeviceBlockSize TotalSize; do printf '%s: ' "$k"; diskutil info -plist "$D" | plutil -extract "$k" raw -o - - 2>/dev/null || echo absent; done
```

Change `disk4` to the disk's number first. Paste each output below, and note whether the disk appeared in ISO Sword with the toggle off and on.

**Result:**
**Notes:**
