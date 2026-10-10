#if DEBUG
import Foundation
import Testing
@testable import ImageWriterCore

/// The debug Simulate mode: its drive list goes through the real filter, and each
/// simulated drive reaches the outcome it is named for, using temp files only.
@MainActor
@Suite(.timeLimit(.minutes(1)))
final class SimulationModeTests {
    /// Over six 4 MiB chunks, so the pulled-out drive fails mid-write.
    static let imageBytes: UInt64 = 26_000_000

    let dir: URL

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("isosword-simulate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit {
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func enabledOnlyByExactlyOne() {
        #expect(SimulationMode.isEnabled(environment: ["ISOSWORD_SIMULATE": "1"]))
        #expect(!SimulationMode.isEnabled(environment: ["ISOSWORD_SIMULATE": "true"]))
        #expect(!SimulationMode.isEnabled(environment: [:]))
    }

    @Test func driveListGoesThroughTheRealFilter() async throws {
        let lister = SimulationMode.makeLister()

        let usb = try await lister.targets(filter: DiskFilter(showAllExternal: false)).map(\.bsdName)
        let all = try await lister.targets(filter: DiskFilter(showAllExternal: true)).map(\.bsdName)

        #expect(usb == ["disk90", "disk91", "disk92", "disk93", "disk94"])
        #expect(all == usb + ["disk95"])
        #expect(!all.contains(SimulatedDrive.internalDisk.bsdName))
    }

    func run(on drive: SimulatedDrive) async throws -> WriteState {
        let url = dir.appendingPathComponent("sim.img")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: Self.imageBytes)
        try handle.close()

        let coordinator = SimulationMode.makeCoordinator(promptDelay: .zero, directory: dir)
        try await coordinator.selectImage(at: url)
        try coordinator.selectDrive(drive.disk, filter: DiskFilter(showAllExternal: drive == .thunderbolt))
        try coordinator.requestConfirmation()
        try await coordinator.confirmAndStart().value
        return coordinator.state
    }

    func failure(_ state: WriteState) -> WriteFailure? {
        if case .failed(let failure) = state { return failure }
        return nil
    }

    @Test func workingDriveFinishes() async throws {
        let state = try await run(on: .working)
        guard case .finished(let summary) = state else {
            Issue.record("Expected finished, got \(state)")
            return
        }
        #expect(summary.bytes == Self.imageBytes)
        #expect(summary.bsdName == "disk90")
    }

    @Test func pulledOutDriveFailsMidWrite() async throws {
        let failure = try #require(failure(try await run(on: .removedMidWrite)))
        #expect(failure.stage == .write)
        guard case WriteEngineError.write(DeviceIOError.posix(_, let code)) = failure.error else {
            Issue.record("Unexpected error \(failure.error)")
            return
        }
        #expect(code == ENXIO)
    }

    @Test func badReadBackFailsVerification() async throws {
        let failure = try #require(failure(try await run(on: .verifyMismatch)))
        #expect(failure.stage == .verify)
        #expect(failure.error as? VerifierError == .verificationFailed(atOffset: 8 * 1024 * 1024))
    }

    @Test func cancelledPromptReturnsToTheConfirmScreen() async throws {
        let state = try await run(on: .promptCancelled)
        #expect(state.phase == .awaitingConfirmation)
    }

    @Test func smallDriveCannotBeConfirmed() async throws {
        await #expect(throws: WriteCoordinatorError.self) { try await self.run(on: .tooSmall) }
    }

    @Test func leavesNoDeviceFilesBehind() async throws {
        _ = try await run(on: .working)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("isosword-fake-") }
        #expect(leftovers.isEmpty)
    }
}
#endif
