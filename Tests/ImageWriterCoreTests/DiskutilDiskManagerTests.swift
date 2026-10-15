import Foundation
import Testing
@testable import ImageWriterCore

/// Outputs below were captured from `diskutil` on macOS 26.3.1 against a scratch `.dmg`.
struct DiskutilDiskManagerTests {
    static let diskutil = "/usr/sbin/diskutil"
    static let unmount4 = [diskutil, "unmountDisk", "/dev/disk4"]
    static let mount4 = [diskutil, "mountDisk", "/dev/disk4"]
    static let eject4 = [diskutil, "eject", "/dev/disk4"]

    static let unmounted = CommandResult(status: 0, stdout: Data("Unmount of all volumes on disk4 was successful\n".utf8))
    static let ejected = CommandResult(status: 0, stdout: Data("Disk /dev/disk4 ejected\n".utf8))
    static let busy = CommandResult(status: 1, stderr: Data("""
        Unmount of disk4 failed: at least one volume could not be unmounted
        Unmount was dissented by PID 57474 (/bin/sleep)
        Dissenter parent PPID 57440 (/bin/zsh)

        """.utf8))
    static let unmountMissing = CommandResult(status: 1, stderr: Data("Unmount failed for /dev/disk4\n".utf8))
    static let ejectMissing = CommandResult(status: 1, stderr: Data("Failed to find disk /dev/disk4\n".utf8))

    func manager(_ responses: [[String]: CommandResult]) -> (DiskutilDiskManager, FakeCommandRunner) {
        let runner = FakeCommandRunner(responses: responses)
        return (DiskutilDiskManager(runner: runner), runner)
    }

    // MARK: unmount

    @Test func unmountRunsDiskutilOnTheWholeDiskNode() async throws {
        let (manager, runner) = manager([Self.unmount4: Self.unmounted])
        try await manager.unmountWholeDisk(bsdName: "disk4")
        #expect(runner.invocations == [Self.unmount4])
    }

    @Test func unmountIsIdempotent() async throws {
        // diskutil answers an already-unmounted disk with the same success line and exit 0.
        let (manager, runner) = manager([Self.unmount4: Self.unmounted])
        try await manager.unmountWholeDisk(bsdName: "disk4")
        try await manager.unmountWholeDisk(bsdName: "disk4")
        #expect(runner.invocations == [Self.unmount4, Self.unmount4])
    }

    @Test func unmountBusyNamesTheDissenter() async {
        let (manager, _) = manager([Self.unmount4: Self.busy])
        await #expect(throws: DiskManagerError.busy(dissenter: "/bin/sleep")) {
            try await manager.unmountWholeDisk(bsdName: "disk4")
        }
    }

    @Test func unmountBusyWithoutDissenterLine() async {
        let result = CommandResult(status: 1, stderr: Data("Unmount of disk4 failed: at least one volume could not be unmounted\n".utf8))
        let (manager, _) = manager([Self.unmount4: result])
        await #expect(throws: DiskManagerError.busy(dissenter: nil)) {
            try await manager.unmountWholeDisk(bsdName: "disk4")
        }
    }

    @Test func unmountResourceBusyWording() async {
        let result = CommandResult(status: 1, stdout: Data("Unmount failed for /Volumes/STICK: Resource busy\n".utf8))
        let (manager, _) = manager([Self.unmount4: result])
        await #expect(throws: DiskManagerError.busy(dissenter: nil)) {
            try await manager.unmountWholeDisk(bsdName: "disk4")
        }
    }

    @Test func unmountMissingDiskIsNotFound() async {
        let (manager, _) = manager([Self.unmount4: Self.unmountMissing])
        await #expect(throws: DiskManagerError.notFound(bsdName: "disk4")) {
            try await manager.unmountWholeDisk(bsdName: "disk4")
        }
    }

    @Test func unmountUnrecognizedFailureKeepsTheOutput() async {
        let result = CommandResult(status: 5, stdout: Data("partial\n".utf8), stderr: Data("Something odd\n".utf8))
        let (manager, _) = manager([Self.unmount4: result])
        await #expect(throws: DiskManagerError.commandFailed(
            command: "diskutil unmountDisk /dev/disk4", status: 5, output: "partial\nSomething odd")) {
            try await manager.unmountWholeDisk(bsdName: "disk4")
        }
    }

    // MARK: mount

    @Test func mountRunsDiskutilOnTheWholeDiskNode() async throws {
        // Success text not captured from a real run; only the exit status matters.
        let mounted = CommandResult(status: 0, stdout: Data("Volume(s) mounted successfully\n".utf8))
        let (manager, runner) = manager([Self.mount4: mounted])
        try await manager.mountWholeDisk(bsdName: "disk4")
        #expect(runner.invocations == [Self.mount4])
    }

    @Test func mountFailureKeepsTheOutput() async {
        let result = CommandResult(status: 1, stderr: Data("Volume(s) failed to mount\n".utf8))
        let (manager, _) = manager([Self.mount4: result])
        await #expect(throws: DiskManagerError.commandFailed(
            command: "diskutil mountDisk /dev/disk4", status: 1, output: "Volume(s) failed to mount")) {
            try await manager.mountWholeDisk(bsdName: "disk4")
        }
    }

    // MARK: eject

    @Test func ejectRunsDiskutilOnTheWholeDiskNode() async throws {
        let (manager, runner) = manager([Self.eject4: Self.ejected])
        try await manager.eject(bsdName: "disk4")
        #expect(runner.invocations == [Self.eject4])
    }

    @Test func ejectBusy() async {
        let (manager, _) = manager([Self.eject4: Self.busy])
        await #expect(throws: DiskManagerError.busy(dissenter: "/bin/sleep")) {
            try await manager.eject(bsdName: "disk4")
        }
    }

    @Test func ejectMissingDiskIsNotFound() async {
        let (manager, _) = manager([Self.eject4: Self.ejectMissing])
        await #expect(throws: DiskManagerError.notFound(bsdName: "disk4")) {
            try await manager.eject(bsdName: "disk4")
        }
    }

    @Test func ejectFailureAfterWriteIsAWarning() async {
        let (manager, _) = manager([Self.eject4: Self.busy])
        let warning = await manager.ejectAfterWrite(bsdName: "disk4")
        #expect(warning?.bsdName == "disk4")
        #expect(warning?.reason == DiskManagerError.busy(dissenter: "/bin/sleep").localizedDescription)
        #expect(warning?.message.isEmpty == false)
    }

    @Test func ejectSuccessAfterWriteHasNoWarning() async {
        let (manager, _) = manager([Self.eject4: Self.ejected])
        #expect(await manager.ejectAfterWrite(bsdName: "disk4") == nil)
    }

    @Test func runnerFailureDuringEjectAfterWriteIsAWarning() async {
        let runner = FakeCommandRunner { executable, _ in
            throw CommandRunnerError.timedOut(executable: executable, seconds: 30)
        }
        let warning = await DiskutilDiskManager(runner: runner).ejectAfterWrite(bsdName: "disk4")
        #expect(warning != nil)
    }

    // MARK: validation and plumbing

    static let badNames = [
        "", "disk", "disk4s1", "/dev/disk4", "rdisk4", "disk4 ", " disk4", "disk4; rm -rf ~",
        "disk-1", "disk4\n", "DISK4", "disk\u{0664}", "disk12345678901234567890",
    ]

    @Test(arguments: badNames)
    func invalidNamesThrowBeforeRunningAnything(name: String) async {
        let (manager, runner) = manager([:])
        await #expect(throws: DiskManagerError.invalidDiskName(name)) {
            try await manager.unmountWholeDisk(bsdName: name)
        }
        await #expect(throws: DiskManagerError.invalidDiskName(name)) {
            try await manager.mountWholeDisk(bsdName: name)
        }
        await #expect(throws: DiskManagerError.invalidDiskName(name)) {
            try await manager.eject(bsdName: name)
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func runnerErrorsPropagate() async {
        let runner = FakeCommandRunner { executable, _ in
            throw CommandRunnerError.launchFailed(executable: executable, message: "nope")
        }
        await #expect(throws: CommandRunnerError.launchFailed(executable: Self.diskutil, message: "nope")) {
            try await DiskutilDiskManager(runner: runner).unmountWholeDisk(bsdName: "disk4")
        }
    }

    @Test func notFoundLineForAnotherDiskIsNotMistakenForThisOne() {
        let error = DiskutilDiskManager.failure(command: "c", status: 1, output: "Unmount failed for /dev/disk40", bsdName: "disk4")
        #expect(error == .commandFailed(command: "c", status: 1, output: "Unmount failed for /dev/disk40"))
    }

    @Test(arguments: [
        ("Unmount was dissented by PID 1 (/Applications/My App (beta).app/Contents/MacOS/My App)",
         "/Applications/My App (beta).app/Contents/MacOS/My App"),
        ("Volume STICK on disk4s1 failed to unmount: dissented by PID 0 (kernel_task)", "kernel_task"),
        ("Unmount was dissented by PID 42", nil),
        ("Unmount was dissented by PID 42 ()", nil),
    ] as [(String, String?)])
    func dissenterParsing(line: String, expected: String?) {
        #expect(DiskutilDiskManager.dissenter(in: line) == expected)
    }

    @Test func everyErrorHasADescription() {
        let errors: [DiskManagerError] = [
            .invalidDiskName("x"), .busy(dissenter: "/bin/sleep"), .busy(dissenter: nil),
            .notFound(bsdName: "disk4"), .commandFailed(command: "c", status: 1, output: ""),
        ]
        for error in errors {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(DiskManagerError.busy(dissenter: "/bin/sleep").localizedDescription.contains("sleep"))
    }
}

struct FakeDiskManagerTests {
    @Test func recordsCallsAndInjectsFailures() async throws {
        let fake = FakeDiskManager(ejectError: DiskManagerError.busy(dissenter: nil))
        try await fake.unmountWholeDisk(bsdName: "disk4")
        await #expect(throws: DiskManagerError.busy(dissenter: nil)) {
            try await fake.eject(bsdName: "disk4")
        }
        #expect(fake.calls == [.unmount("disk4"), .eject("disk4")])

        fake.ejectError = nil
        fake.unmountError = DiskManagerError.notFound(bsdName: "disk4")
        try await fake.eject(bsdName: "disk4")
        await #expect(throws: DiskManagerError.notFound(bsdName: "disk4")) {
            try await fake.unmountWholeDisk(bsdName: "disk4")
        }

        try await fake.mountWholeDisk(bsdName: "disk4")
        fake.mountError = DiskManagerError.notFound(bsdName: "disk4")
        await #expect(throws: DiskManagerError.notFound(bsdName: "disk4")) {
            try await fake.mountWholeDisk(bsdName: "disk4")
        }
        #expect(fake.calls.suffix(2) == [.mount("disk4"), .mount("disk4")])
    }

    @Test func validatesNamesLikeProduction() async {
        let fake = FakeDiskManager()
        await #expect(throws: DiskManagerError.invalidDiskName("disk4s1")) {
            try await fake.unmountWholeDisk(bsdName: "disk4s1")
        }
        #expect(fake.calls.isEmpty)
    }
}
