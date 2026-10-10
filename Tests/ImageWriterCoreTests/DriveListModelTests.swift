import Foundation
import Testing
@testable import ImageWriterCore

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DriveListModelTests {
    static var thunderbolt: DiskInfo {
        var disk = DiskInfo.usbStick("disk5")
        disk.mediaName = "Thunderbolt SSD"
        disk.busProtocol = "PCI-Express"
        return disk
    }

    func model(_ discovery: any DiskDiscovery, resolver: any BootDiskResolving = StaticBootDiskResolver(wholeDisks: ["disk0"])) -> DriveListModel {
        DriveListModel(lister: TargetDiskLister(discovery: discovery, bootResolver: resolver)) {
            DiskFilter(showAllExternal: $0)
        }
    }

    @Test func refreshListsTheFilteredDrivesAndReportsTheFilter() async {
        let model = model(StaticDiskDiscovery(disks: [.usbStick(), Self.thunderbolt]))
        var updates: [([DiskInfo], Bool)] = []
        model.onUpdate = { updates.append(($0, $1.showAllExternal)) }
        #expect(!model.hasLoaded)

        await model.refresh()

        #expect(model.hasLoaded)
        #expect(model.drives == [.usbStick()])
        #expect(model.filter.showAllExternal == false)
        #expect(updates.count == 1 && updates.first?.0 == [.usbStick()])
    }

    @Test func showAllExternalRebuildsTheListUnderTheNewFilter() async {
        let model = model(StaticDiskDiscovery(disks: [.usbStick(), Self.thunderbolt]))
        await model.refresh()

        await model.setShowAllExternal(true)

        #expect(model.showAllExternal)
        #expect(model.filter.showAllExternal)
        #expect(model.drives == [.usbStick(), Self.thunderbolt])
    }

    @Test func aFailedRefreshEmptiesTheListAndSaysWhy() async {
        let discovery = MutableDiscovery(disks: [.usbStick()])
        let model = model(discovery)
        var lastUpdate: [DiskInfo]?
        model.onUpdate = { drives, _ in lastUpdate = drives }
        await model.refresh()
        #expect(model.drives.count == 1)

        discovery.error = DiskDiscoveryError.bootDiskUnresolved(reason: "stub")
        await model.refresh()

        #expect(model.drives.isEmpty)
        #expect(model.errorMessage != nil)
        #expect(lastUpdate == [])

        discovery.error = nil
        await model.refresh()
        #expect(model.errorMessage == nil)
        #expect(model.drives == [.usbStick()])
    }

    @Test func anUnresolvableBootDiskFailsClosed() async {
        let model = model(StaticDiskDiscovery(disks: [.usbStick()]), resolver: StaticBootDiskResolver(wholeDisks: []))

        await model.refresh()

        #expect(model.drives.isEmpty)
        #expect(model.errorMessage != nil)
    }

    @Test func aSlowerOlderRefreshIsDropped() async throws {
        let discovery = GatedDiscovery(disks: [.usbStick(), Self.thunderbolt])
        let model = model(discovery)

        // The first query hangs under the default setting; the toggle's query finishes first.
        let slow = Task { await model.refresh() }
        await discovery.gate.waitForArrival()
        await model.setShowAllExternal(true)
        discovery.gate.release()
        await slow.value

        #expect(model.filter.showAllExternal)
        #expect(model.drives == [.usbStick(), Self.thunderbolt])
    }

    @Test func autoRefreshPicksUpChangesAndStopsWhenCancelled() async throws {
        let discovery = MutableDiscovery(disks: [])
        let model = model(discovery)
        let polling = Task { await model.autoRefresh(every: .milliseconds(10)) }

        try await waitUntil { model.hasLoaded }
        discovery.disks = [.usbStick()]
        try await waitUntil { model.drives == [.usbStick()] }

        polling.cancel()
        await polling.value
        let calls = discovery.calls
        try await Task.sleep(for: .milliseconds(50))
        #expect(discovery.calls == calls)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("Condition not met in time")
    }
}

private final class MutableDiscovery: DiskDiscovery, @unchecked Sendable {
    private let lock = NSLock()
    private var current: [DiskInfo]
    private var failure: (any Error)?
    private var count = 0

    init(disks: [DiskInfo]) {
        current = disks
    }

    var disks: [DiskInfo] {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }

    var error: (any Error)? {
        get { lock.withLock { failure } }
        set { lock.withLock { failure = newValue } }
    }

    var calls: Int { lock.withLock { count } }

    func listDisks() async throws -> [DiskInfo] {
        let (disks, error) = lock.withLock { () -> ([DiskInfo], (any Error)?) in
            count += 1
            return (current, failure)
        }
        if let error { throw error }
        return disks
    }
}

/// Holds its first query at `gate`; later ones answer at once.
private final class GatedDiscovery: DiskDiscovery, @unchecked Sendable {
    let gate = Gate()
    let disks: [DiskInfo]
    private let lock = NSLock()
    private var count = 0

    init(disks: [DiskInfo]) {
        self.disks = disks
    }

    func listDisks() async throws -> [DiskInfo] {
        let call = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if call == 1 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    self.gate.pass()
                    continuation.resume()
                }
            }
        }
        return disks
    }
}
