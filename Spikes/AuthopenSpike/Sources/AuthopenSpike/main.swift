import Foundation

// T01 spike: obtain a writable fd for a raw disk through authopen, write and
// read back 1 MiB at offset 0. See README.md before running. DESTROYS DATA.

let usage = """
usage: AuthopenSpike /dev/rdiskN --i-know-this-is-a-test-disk [options]

  --dry-run             Run the target checks only, then exit. Nothing is unmounted, opened or written.
  --allow-physical-usb  Accept an external USB whole disk instead of a RAM disk. Erases its first 1 MiB.
  --open-flags N        Decimal flags passed to authopen -o (default \(O_RDWR) = O_RDWR).
  --no-eject            Leave the disk attached afterwards (RAM disks vanish when ejected).
"""

struct Options {
    var rawPath = ""
    var acknowledged = false
    var dryRun = false
    var mode = TargetMode.ramDiskOnly
    var openFlags = O_RDWR
    var eject = true
}

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
        case "--i-know-this-is-a-test-disk": options.acknowledged = true
        case "--dry-run": options.dryRun = true
        case "--allow-physical-usb": options.mode = .physicalUSB
        case "--no-eject": options.eject = false
        case "--open-flags":
            guard let value = iterator.next(), let flags = Int32(value) else {
                throw SpikeError.usage("--open-flags needs a decimal number\n\n\(usage)")
            }
            options.openFlags = flags
        case "-h", "--help": throw SpikeError.usage(usage)
        default:
            guard options.rawPath.isEmpty, !argument.hasPrefix("-") else {
                throw SpikeError.usage("unexpected argument \(argument)\n\n\(usage)")
            }
            options.rawPath = argument
        }
    }
    guard !options.rawPath.isEmpty else { throw SpikeError.usage(usage) }
    guard options.acknowledged else {
        throw SpikeError.usage("refusing without --i-know-this-is-a-test-disk\n\n\(usage)")
    }
    return options
}

var findings: [String] = []
/// Set just before the first side effect; only then is ejecting appropriate.
var touchedDisk = false

func note(_ line: String) {
    findings.append(line)
    print("  • \(line)")
}

func step(_ title: String) {
    print("\n== \(title)")
}

func runSpike(_ options: Options) throws {
    let bsd = try bsdName(fromRawPath: options.rawPath)

    step("Checking target \(options.rawPath)")
    let facts = try vetTarget(bsd: bsd, mode: options.mode)
    print(facts.summary)
    note("target \(bsd): \(facts.mediaName), \(facts.sizeBytes) bytes, block \(facts.blockSize), bus \(facts.busProtocol), mode \(options.mode)")
    // authopen skips the password prompt when the caller can already open the
    // node, which is the case for disk images the user attached themselves.
    var node = stat()
    if stat(options.rawPath, &node) == 0 {
        let mode = String(node.st_mode & 0o777, radix: 8)
        note("device node owner uid \(node.st_uid), gid \(node.st_gid), mode \(mode); you are uid \(getuid())")
    }

    if options.dryRun {
        print("\nDry run: target accepted. Nothing was unmounted, opened or written.")
        return
    }

    print("\nThis will OVERWRITE the first 1 MiB of /dev/\(bsd) (\(facts.mediaName)).")
    print("Type \(bsd) to continue: ", terminator: "")
    guard readLine()?.trimmingCharacters(in: .whitespaces) == bsd else {
        throw SpikeError.refused("confirmation did not match; nothing was changed")
    }

    step("Unmounting /dev/\(bsd)")
    touchedDisk = true
    let unmount = try runChecked(diskutil, ["unmountDisk", "/dev/\(bsd)"])
    note("unmountDisk: \(unmount.combinedText.trimmingCharacters(in: .whitespacesAndNewlines))")

    step("authopen (expect an admin password prompt)")
    let opened = try authopen(path: options.rawPath, openFlags: options.openFlags)
    let fd = opened.fd
    defer {
        close(fd)
        print("  closed fd \(fd)")
    }
    note("authopen -stdoutpipe -o \(options.openFlags): fd \(fd) received, exit status \(opened.exitStatus), \(String(format: "%.1f", opened.secondsWaiting)) s including prompt")
    note("data bytes sent alongside the fd: \(opened.payload.count) \(opened.payload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))")

    var info = stat()
    if fstat(fd, &info) == 0 {
        let isCharDevice = (info.st_mode & S_IFMT) == S_IFCHR
        note("fstat: character device = \(isCharDevice)")
    }
    let flags = fcntl(fd, F_GETFL)
    let accessMode = flags & O_ACCMODE
    let accessName = accessMode == O_RDWR ? "O_RDWR" : accessMode == O_WRONLY ? "O_WRONLY" : "O_RDONLY"
    note("F_GETFL: \(String(format: "0x%x", flags)) (\(accessName))")

    step("Geometry")
    let geometry = try deviceGeometry(fd: fd)
    note("DKIOCGETBLOCKSIZE \(geometry.blockSize), DKIOCGETBLOCKCOUNT \(geometry.blockCount), bytes \(geometry.byteCount) (diskutil said \(facts.sizeBytes))")

    let length = 1024 * 1024
    let blockSize = Int(geometry.blockSize)
    guard blockSize > 0, length % blockSize == 0, UInt64(length) <= geometry.byteCount else {
        throw SpikeError.refused("unexpected geometry for a 1 MiB test")
    }

    let nocache = fcntl(fd, F_NOCACHE, 1)
    note("F_NOCACHE: \(nocache == 0 ? "ok" : "failed errno \(errno)")")

    step("Unaligned read probes (read-only)")
    note(probeUnalignedRead(fd: fd, length: 100, offset: 0, alignedMemory: true))
    note(probeUnalignedRead(fd: fd, length: blockSize, offset: 1, alignedMemory: true))
    note(probeUnalignedRead(fd: fd, length: blockSize, offset: 0, alignedMemory: false))

    step("Writing 1 MiB pattern at offset 0")
    let alignment = max(Int(getpagesize()), blockSize)
    let pattern = try AlignedBuffer(count: length, alignment: alignment)
    fillPattern(pattern)
    let writeStart = Date()
    let shortWrites = try writeFully(fd: fd, from: pattern, offset: 0)
    note("write: \(length) bytes in \(String(format: "%.3f", Date().timeIntervalSince(writeStart))) s, short writes \(shortWrites)")

    let sync = fcntl(fd, F_FULLFSYNC)
    let syncErrno = errno
    note("F_FULLFSYNC: \(sync == 0 ? "ok" : "failed errno \(syncErrno) (\(String(cString: strerror(syncErrno))))")")

    step("Reading back through the same fd")
    let readBack = try AlignedBuffer(count: length, alignment: alignment)
    memset(readBack.pointer, 0, length)
    let shortReads = try readFully(fd: fd, into: readBack, offset: 0)
    if memcmp(pattern.pointer, readBack.pointer, length) != 0 {
        let a = pattern.pointer.assumingMemoryBound(to: UInt8.self)
        let b = readBack.pointer.assumingMemoryBound(to: UInt8.self)
        let offset = (0..<length).first { a[$0] != b[$0] } ?? -1
        note("read-back: MISMATCH at offset \(offset)")
        throw SpikeError.mismatch(offset: offset)
    }
    note("read-back on same fd: matches (\(length) bytes, short reads \(shortReads))")
}

func ejectIfRequested(_ options: Options) {
    guard options.eject, let bsd = try? bsdName(fromRawPath: options.rawPath) else { return }
    step("Ejecting /dev/\(bsd)")
    do {
        let result = try runChecked(diskutil, ["eject", "/dev/\(bsd)"])
        note("eject: \(result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines))")
    } catch {
        note("eject failed: \(error)")
    }
}

func printFindings() {
    print("\n== Findings (paste into PLAN.md T01 handoff notes)")
    print("  host: \(ProcessInfo.processInfo.operatingSystemVersionString), arch \(machineArchitecture())")
    findings.forEach { print("  - \($0)") }
}

func machineArchitecture() -> String {
    var info = utsname()
    uname(&info)
    var machine = info.machine
    let capacity = MemoryLayout.size(ofValue: machine)
    return withUnsafePointer(to: &machine) {
        $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
    }
}

let options: Options
do {
    options = try parseOptions(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write("\(error)\n".data(using: .utf8) ?? Data())
    exit(2)
}

var exitCode: Int32 = 0
do {
    try runSpike(options)
} catch {
    print("\nERROR: \(error)")
    note("error: \(error)")
    exitCode = 1
}
if touchedDisk {
    ejectIfRequested(options)
}
printFindings()
exit(exitCode)
