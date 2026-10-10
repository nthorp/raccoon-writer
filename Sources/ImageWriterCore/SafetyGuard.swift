import Foundation
import os

/// The last check before the privileged open. Re-resolves the boot disks, re-lists the
/// disks, and requires the confirmed disk to still be present, to still be the same
/// medium, and to still pass the filter the user chose it under. Fails closed: any
/// query error refuses the write.
public struct SafetyGuard: Sendable {
    private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "safety")

    private let discovery: any DiskDiscovery
    private let bootResolver: any BootDiskResolving

    public init(discovery: any DiskDiscovery, bootResolver: any BootDiskResolving) {
        self.discovery = discovery
        self.bootResolver = bootResolver
    }

    /// Production wiring through diskutil.
    public init(runner: any CommandRunner = ProcessCommandRunner()) {
        self.init(discovery: DiskutilDiscovery(runner: runner), bootResolver: BootDiskResolver(runner: runner))
    }

    /// Returns the freshly queried disk. `filter` must be the one the drive list used,
    /// so a disk shown only under "Show all external disks" is not accepted otherwise.
    @discardableResult
    public func validate(confirmed: DiskInfo, filter: DiskFilter) async throws -> DiskInfo {
        do {
            return try await check(confirmed: confirmed, filter: filter)
        } catch let error as SafetyGuardError {
            Self.log.error("Refused \(confirmed.bsdName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func check(confirmed: DiskInfo, filter: DiskFilter) async throws -> DiskInfo {
        let name = confirmed.bsdName
        guard BSDName.isWholeDisk(name) else {
            throw SafetyGuardError.forbiddenTarget(bsdName: name, reason: .invalidName)
        }

        let bootDisks: BootDiskSet
        let disks: [DiskInfo]
        do {
            // Boot disks first, as in TargetDiskLister: without them nothing is safe.
            bootDisks = try await bootResolver.resolveBootDisks()
            disks = try await discovery.listDisks()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SafetyGuardError.queryFailed(reason: error.localizedDescription)
        }

        let matches = disks.filter { $0.bsdName == name }
        guard matches.count <= 1 else {
            throw SafetyGuardError.queryFailed(reason: "\(name) was listed more than once")
        }
        guard let current = matches.first else {
            throw SafetyGuardError.diskMissing(bsdName: name)
        }
        if let field = current.identityDifference(from: confirmed) {
            throw SafetyGuardError.diskChanged(bsdName: name, field: field)
        }
        if let reason = filter.rejection(for: current, bootDisks: bootDisks) {
            throw SafetyGuardError.forbiddenTarget(bsdName: name, reason: reason)
        }
        return current
    }
}
