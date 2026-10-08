# AuthopenSpike (T01)

Throwaway experiment. It proves that `authopen` can hand a writable raw-disk file descriptor to an unprivileged Swift process. It also records how that descriptor behaves. This is not part of the app or the main package.

**It overwrites the first 1 MiB of the target disk.** By default it only accepts a RAM disk created with `hdiutil attach ram://…`. Before doing anything, it checks the target and refuses the boot disk, internal disks, partitions, other disk images, and disks it cannot identify. You must also type the disk name to confirm.

## What it does

1. Validates the target: `/dev/rdiskN` form; `diskutil info` says whole disk, not internal, not the boot disk; and `hdiutil info` shows a `ram://` image. With `--allow-physical-usb`, it requires an external USB whole disk instead.
2. Asks you to type the disk name (for example `disk7`).
3. `diskutil unmountDisk /dev/diskN`
4. Spawns `/usr/libexec/authopen -stdoutpipe -o 2 /dev/rdiskN` (`2` = `O_RDWR`) with stdout on a Unix socketpair, and receives the fd via `recvmsg` / `SCM_RIGHTS`. **The macOS admin password prompt appears here.**
5. Reports the fd's flags and the `DKIOCGETBLOCKSIZE` / `DKIOCGETBLOCKCOUNT` geometry, sets `F_NOCACHE`, and runs three read-only probes with unaligned requests.
6. Writes a 1 MiB pattern at offset 0 from a `posix_memalign` buffer, calls `F_FULLFSYNC`, reads it back through the same fd, and compares.
7. Closes the fd, runs `diskutil eject /dev/diskN` (a RAM disk is freed by this), and prints a **Findings** block.

## Run it (Nick)

From the repo root:

```sh
cd Spikes/AuthopenSpike
swift build

# 1. Create a 32 MiB RAM disk (65536 × 512-byte sectors). Note the /dev/diskN it prints.
hdiutil attach -nomount ram://65536
#    → /dev/disk7   (your number may differ; use it below, as rdiskN)

# 2. Optional: check the target without touching it.
.build/debug/AuthopenSpike /dev/rdisk7 --i-know-this-is-a-test-disk --dry-run

# 3. The real run. Type the disk name when asked, then enter your admin password.
.build/debug/AuthopenSpike /dev/rdisk7 --i-know-this-is-a-test-disk

# 4. Clean up if the disk is still attached (for example after an error or --no-eject).
hdiutil detach /dev/disk7
```

Also try these and note what happens:

- **Cancel the password prompt.** Create a new RAM disk and run step 3 again, but click Cancel. Record the `authopen exited with status N` line. T02 maps this status to `userCancelled`.
- **Wrong password three times**, if you're patient. Record the status.

### Optional: a real USB stick

Use only a stick whose contents you don't need. Its partition table is destroyed.

```sh
diskutil list external physical          # find the stick, e.g. /dev/disk8
.build/debug/AuthopenSpike /dev/rdisk8 --i-know-this-is-a-test-disk --allow-physical-usb --dry-run
.build/debug/AuthopenSpike /dev/rdisk8 --i-know-this-is-a-test-disk --allow-physical-usb
```

Afterwards the stick is ejected. To reuse it, reformat it in Disk Utility.

### Options

| Flag | Meaning |
| --- | --- |
| `--dry-run` | Run the checks only. Nothing is unmounted, opened or written. |
| `--allow-physical-usb` | Accept an external USB whole disk instead of a RAM disk. |
| `--open-flags N` | Decimal `open(2)` flags for `authopen -o` (default `2` = `O_RDWR`; `34` = `O_RDWR\|O_EXLOCK`). |
| `--no-eject` | Leave the disk attached so you can re-run with other flags. |

## What to record in PLAN.md (T01 Handoff notes)

Paste the **Findings** block the spike prints, and answer:

1. Did the password prompt appear? What did it say (app name shown, wording)?
2. Did `-stdoutpipe -o 2` work as is? If not, which flags did?
3. Did the read-back on the same fd match?
4. Results of the three unaligned-read probes (lines starting `pread(`).
5. Did `F_FULLFSYNC` succeed? (A RAM disk may not support it. Note the errno if not.)
6. Any TCC / "Operation not permitted" / removable-volume access prompts? From Terminal, or only from a built app?
7. Exit status when the prompt is cancelled.
8. Apple Silicon vs Intel differences, if you tried both.
