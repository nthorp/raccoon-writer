import Foundation
import Testing
@testable import ImageWriterCore

struct DiskutilDiscoveryTests {
    typealias F = DiskutilFixtures

    func disks(overriding overrides: [[String]: CommandResult] = [:]) async throws -> [String: DiskInfo] {
        let disks = try await DiskutilDiscovery(runner: try F.runner(overriding: overrides)).listDisks()
        return Dictionary(uniqueKeysWithValues: disks.map { ($0.bsdName, $0) })
    }

    @Test func listsEveryWholeDiskInDiskutilOrder() async throws {
        let disks = try await DiskutilDiscovery(runner: try F.runner()).listDisks()
        #expect(disks.map(\.bsdName) == F.wholeDisks)
    }

    @Test func usbStickFields() async throws {
        let stick = try #require(try await disks()["disk4"])
        #expect(stick.mediaName == "SanDisk Ultra")
        #expect(stick.sizeBytes == 30_752_636_928)
        #expect(stick.blockSize == 512)
        #expect(stick.busProtocol == "USB")
        #expect(!stick.isInternal && stick.isRemovable && stick.isEjectable)
        #expect(!stick.isVirtual && stick.isWholeDisk && !stick.isAPFSContainer)
        #expect(stick.mountPoints == ["/Volumes/STICK", "/Volumes/DATA"])
        #expect(stick.volumeNames == ["STICK", "DATA"])
        #expect(stick.devicePath == "/dev/disk4")
        #expect(stick.rawDevicePath == "/dev/rdisk4")
    }

    @Test func containerVolumesAreCreditedToThePhysicalDisk() async throws {
        let disks = try await disks()
        let ssd = try #require(disks["disk5"])
        #expect(ssd.mountPoints == ["/Volumes/Backup"])
        #expect(ssd.volumeNames == ["EFI", "Backup"])
        #expect(!ssd.isAPFSContainer && !ssd.isVirtual)

        let container = try #require(disks["disk6"])
        #expect(container.isAPFSContainer && container.isVirtual)
        #expect(container.mountPoints == ["/Volumes/Backup"])
    }

    /// disk5s1 (EFI) has a `VolumeName` and no mount point; the name is still listed.
    @Test func unmountedVolumeNameIsListed() async throws {
        let ssd = try #require(try await disks()["disk5"])
        #expect(ssd.volumeNames.contains("EFI"))
        #expect(!ssd.mountPoints.contains { $0.hasSuffix("/EFI") })
    }

    @Test func realInternalCaptures() async throws {
        let disks = try await disks()
        let builtIn = try #require(disks["disk0"])
        #expect(builtIn.isInternal && builtIn.isWholeDisk)
        // T01: internal disks report VirtualOrPhysical = Unknown.
        #expect(!builtIn.isVirtual)
        #expect(builtIn.busProtocol == "Apple Fabric")
        #expect(builtIn.mountPoints.contains("/"))

        let container = try #require(disks["disk3"])
        #expect(container.isInternal && container.isAPFSContainer && container.isVirtual)
        #expect(container.mountPoints.contains("/"))
        #expect(container.mountPoints.contains("/System/Volumes/Data"))
    }

    @Test func diskImageIsVirtual() async throws {
        let image = try #require(try await disks()["disk8"])
        #expect(image.isVirtual && !image.isInternal && image.isRemovable)
        #expect(image.busProtocol == "Disk Image")
        #expect(image.mountPoints == ["/Volumes/Installer"])
    }

    @Test func vanishedDiskIsLeftOut() async throws {
        let disks = try await disks(overriding: [F.info("disk7"): try F.notFound()])
        #expect(disks["disk7"] == nil)
        #expect(disks.count == F.wholeDisks.count - 1)
    }

    @Test func mismatchedDescriptionIsLeftOut() async throws {
        let disks = try await disks(overriding: [F.info("disk4"): try F.ok("info-disk5")])
        #expect(disks["disk4"] == nil)
        #expect(disks["disk5"] != nil)
    }

    @Test func malformedInfoIsLeftOut() async throws {
        var info = try F.dictionary("info-disk4")
        info["Internal"] = "no"
        let disks = try await disks(overriding: [F.info("disk4"): try F.plist(info)])
        #expect(disks["disk4"] == nil)
    }

    @Test func missingSafetyKeysTakeRestrictiveValues() async throws {
        let bare = try F.plist(["DeviceIdentifier": "disk4", "Size": 1_000_000])
        let disk = try #require(try await disks(overriding: [F.info("disk4"): bare])["disk4"])
        #expect(disk.isInternal)
        #expect(!disk.isWholeDisk)
        #expect(!disk.isRemovable && !disk.isEjectable)
    }

    @Test func invalidNamesNeverReachDiskutil() async throws {
        var list = try F.dictionary("list")
        list["WholeDisks"] = ["disk4", "disk4;rm -rf ~", "../disk1", "disk4s1", "rdisk5"]
        let runner = try F.runner(overriding: [F.list: try F.plist(list)])
        let disks = try await DiskutilDiscovery(runner: runner).listDisks()
        #expect(disks.map(\.bsdName) == ["disk4"])
        #expect(runner.invocations.sorted { $0.joined() < $1.joined() } == [F.info("disk4"), F.list])
    }

    @Test func listFailureThrows() async throws {
        let runner = try F.runner(overriding: [F.list: CommandResult(status: 1, stderr: Data("boom\n".utf8))])
        await #expect(throws: DiskDiscoveryError.commandFailed(command: "diskutil list -plist", status: 1, message: "boom")) {
            _ = try await DiskutilDiscovery(runner: runner).listDisks()
        }
    }

    @Test func malformedListThrows() async throws {
        let runner = try F.runner(overriding: [F.list: CommandResult(status: 0, stdout: Data("not a plist".utf8))])
        do {
            _ = try await DiskutilDiscovery(runner: runner).listDisks()
            Issue.record("expected malformed output")
        } catch DiskDiscoveryError.malformedOutput(let command, _) {
            #expect(command == "diskutil list -plist")
        }
    }

    @Test func runnerFailurePropagates() async throws {
        let responses = try F.responses()
        let runner = FakeCommandRunner { executable, arguments in
            if arguments == ["info", "-plist", "disk5"] {
                throw CommandRunnerError.timedOut(executable: executable, seconds: 30)
            }
            return responses[[executable] + arguments] ?? CommandResult(status: 1)
        }
        await #expect(throws: CommandRunnerError.timedOut(executable: F.diskutil, seconds: 30)) {
            _ = try await DiskutilDiscovery(runner: runner).listDisks()
        }
    }

    @Test func diskutilErrorReplyIsCommandFailure() async throws {
        await #expect(throws: DiskDiscoveryError.commandFailed(command: "diskutil info -plist disk9", status: 1, message: "Could not find disk: disk99")) {
            _ = try await Diskutil(runner: FakeCommandRunner(responses: [F.info("disk9"): try F.notFound()])).info("disk9")
        }
    }

    @Test func diskutilRejectsInvalidTargetsWithoutRunning() async throws {
        let runner = FakeCommandRunner(responses: [:])
        for target in ["", "/dev/disk4", "disk4;ls", "-plist", "/Volumes/STICK", "disk4s"] {
            await #expect(throws: DiskDiscoveryError.invalidIdentifier(target)) {
                _ = try await Diskutil(runner: runner).info(target)
            }
        }
        #expect(runner.invocations.isEmpty)
    }
}
