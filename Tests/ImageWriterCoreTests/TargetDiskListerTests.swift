import Foundation
import Testing
@testable import ImageWriterCore

/// The T03 acceptance criteria, end to end over the fixture machine.
struct TargetDiskListerTests {
    typealias F = DiskutilFixtures

    func targets(showAllExternal: Bool, overriding overrides: [[String]: CommandResult] = [:]) async throws -> [String] {
        try await TargetDiskLister(runner: try F.runner(overriding: overrides))
            .targets(showAllExternal: showAllExternal)
            .map(\.bsdName)
    }

    /// T29: the built-in SD card is listed with the toggle off, although it reports internal.
    @Test func defaultListShowsUSBDrivesAndTheBuiltInSDCard() async throws {
        #expect(try await targets(showAllExternal: false) == ["disk4", "disk7", "disk9"])
    }

    @Test func toggleAddsTheThunderboltSSD() async throws {
        #expect(try await targets(showAllExternal: true) == ["disk4", "disk5", "disk7", "disk9"])
    }

    @Test(arguments: CardReaderNearMiss.allCases, [false, true])
    func builtInSDNearMissIsNeverShown(_ miss: CardReaderNearMiss, showAllExternal: Bool) async throws {
        let shown = try await targets(showAllExternal: showAllExternal, overriding: try miss.override())
        #expect(!shown.contains("disk7"))
        #expect(shown.contains("disk4"))
    }

    @Test(arguments: [false, true])
    func bootInternalContainersAndImagesNeverAppear(showAllExternal: Bool) async throws {
        let shown = try await targets(showAllExternal: showAllExternal)
        for hidden in ["disk0", "disk3", "disk6", "disk8"] {
            #expect(!shown.contains(hidden))
        }
    }

    @Test func eachFixtureDiskIsRejectedForTheExpectedReason() async throws {
        let disks = try await DiskutilDiscovery(runner: try F.runner()).listDisks()
        let reasons = Dictionary(uniqueKeysWithValues: disks.map {
            ($0.bsdName, DiskFilter(showAllExternal: true).rejection(for: $0, bootDisks: .fixture))
        })
        #expect(reasons["disk0"] == .internalDisk)
        #expect(reasons["disk3"] == .internalDisk)
        #expect(reasons["disk6"] == .apfsContainer)
        #expect(reasons["disk8"] == .virtualDisk)
    }

    @Test(arguments: [false, true])
    func failsClosedWhenTheBootDiskCannotBeResolved(showAllExternal: Bool) async throws {
        let runner = try F.runner(overriding: [F.info("/"): try F.notFound()])
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await TargetDiskLister(runner: runner).targets(showAllExternal: showAllExternal)
        }
        #expect(!runner.invocations.contains(F.list))
    }

    @Test func failsClosedWhenTheAPFSStoreCannotBeResolved() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await targets(showAllExternal: true, overriding: [F.info("disk0s2"): try F.notFound()])
        }
    }

    @Test func failsClosedWhenTheResolverThrows() async throws {
        let lister = TargetDiskLister(discovery: StubDiscovery(disks: [.usbStick()]), bootResolver: FailingResolver())
        await #expect(throws: DiskDiscoveryError.bootDiskUnresolved(reason: "stub")) {
            _ = try await lister.targets(showAllExternal: false)
        }
    }

    @Test func discoveryFailureThrows() async throws {
        await #expect(throws: DiskDiscoveryError.self) {
            _ = try await targets(showAllExternal: false, overriding: [F.list: CommandResult(status: 1)])
        }
    }
}

/// The fixture's built-in SD card (`disk7`) with one of the four card-reader keys wrong
/// or missing. `Removable` stays true throughout, so `RemovableMedia` must be read on its own.
enum CardReaderNearMiss: CaseIterable, Sendable, CustomTestStringConvertible {
    case removableMediaFalse
    case removableMediaMissing
    case virtual
    case unknownVirtualOrPhysical
    case virtualOrPhysicalMissing
    case busProtocolMissing
    case busProtocolLowercase
    case busProtocolUSB
    case notWholeDisk
    case wholeDiskMissing

    func override() throws -> [[String]: CommandResult] {
        typealias F = DiskutilFixtures
        switch self {
        case .removableMediaFalse: return try F.infoVariant("disk7", setting: ["RemovableMedia": false])
        case .removableMediaMissing: return try F.infoVariant("disk7", removing: ["RemovableMedia"])
        case .virtual: return try F.infoVariant("disk7", setting: ["VirtualOrPhysical": "Virtual"])
        case .unknownVirtualOrPhysical: return try F.infoVariant("disk7", setting: ["VirtualOrPhysical": "Unknown"])
        case .virtualOrPhysicalMissing: return try F.infoVariant("disk7", removing: ["VirtualOrPhysical"])
        case .busProtocolMissing: return try F.infoVariant("disk7", removing: ["BusProtocol"])
        case .busProtocolLowercase: return try F.infoVariant("disk7", setting: ["BusProtocol": "secure digital"])
        // An internal reader on an internal USB bus stays hidden (out of scope in T29).
        case .busProtocolUSB: return try F.infoVariant("disk7", setting: ["BusProtocol": "USB"])
        case .notWholeDisk: return try F.infoVariant("disk7", setting: ["WholeDisk": false])
        case .wholeDiskMissing: return try F.infoVariant("disk7", removing: ["WholeDisk"])
        }
    }

    var testDescription: String { "\(self)" }
}

private struct StubDiscovery: DiskDiscovery {
    let disks: [DiskInfo]
    func listDisks() async throws -> [DiskInfo] { disks }
}

private struct FailingResolver: BootDiskResolving {
    func resolveBootDisks() async throws -> BootDiskSet {
        throw DiskDiscoveryError.bootDiskUnresolved(reason: "stub")
    }
}
