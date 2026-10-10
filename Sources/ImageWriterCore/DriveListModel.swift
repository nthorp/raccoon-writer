import Foundation
import Observation
import os

/// The drive picker's list: refreshes `TargetDiskLister` on demand and on a timer, and
/// remembers which filter the shown list was built with, because the drive the user
/// picks must be selected and safety-checked under that same filter.
@MainActor
@Observable
public final class DriveListModel {
    @ObservationIgnored private static let log = Logger(subsystem: AppInfo.bundleIdentifier, category: "drivelist")

    public private(set) var drives: [DiskInfo] = []
    /// The filter `drives` was built with. Pass it to `WriteCoordinator.selectDrive`.
    public private(set) var filter: DiskFilter
    /// The "Show all external disks" setting. It takes effect with the next refresh.
    public private(set) var showAllExternal: Bool
    /// Set when the last refresh failed. `drives` is then empty: the list fails closed.
    public private(set) var errorMessage: String?
    /// False until the first refresh has finished, so the view can say it is looking.
    public private(set) var hasLoaded = false

    /// Called on the main actor after every applied refresh, failed ones included.
    @ObservationIgnored public var onUpdate: (@MainActor (_ drives: [DiskInfo], _ filter: DiskFilter) -> Void)?

    @ObservationIgnored private let lister: TargetDiskLister
    @ObservationIgnored private let makeFilter: @Sendable (Bool) -> DiskFilter
    /// Only the newest refresh is applied, so a slow query under the old setting can't
    /// overwrite the list built after the user flipped the toggle.
    @ObservationIgnored private var generation: UInt64 = 0

    /// `makeFilter` defaults to `DiskFilter.configured`, so Debug builds honor the
    /// virtual-disk test mode.
    public init(
        lister: TargetDiskLister,
        showAllExternal: Bool = false,
        makeFilter: @escaping @Sendable (Bool) -> DiskFilter = { DiskFilter.configured(showAllExternal: $0) }
    ) {
        self.lister = lister
        self.makeFilter = makeFilter
        self.showAllExternal = showAllExternal
        self.filter = makeFilter(showAllExternal)
    }

    public func setShowAllExternal(_ value: Bool) async {
        guard value != showAllExternal else { return }
        showAllExternal = value
        await refresh()
    }

    public func refresh() async {
        generation &+= 1
        let id = generation
        let filter = makeFilter(showAllExternal)
        let result: Result<[DiskInfo], any Error>
        do {
            result = .success(try await lister.targets(filter: filter))
        } catch is CancellationError {
            return
        } catch {
            result = .failure(error)
        }
        guard id == generation else { return }

        self.filter = filter
        hasLoaded = true
        switch result {
        case .success(let fresh):
            errorMessage = nil
            if fresh != drives { drives = fresh }
        case .failure(let error):
            Self.log.error("Drive list refresh failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            if !drives.isEmpty { drives = [] }
        }
        onUpdate?(drives, filter)
    }

    /// Refreshes now and then every `interval` until the calling task is cancelled.
    /// Meant for a view's `.task`, so polling stops when the drive step goes away.
    public func autoRefresh(every interval: Duration = .seconds(2)) async {
        while !Task.isCancelled {
            await refresh()
            do {
                try await Task.sleep(for: interval)
            } catch {
                return
            }
        }
    }
}
