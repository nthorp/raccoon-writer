import ImageWriterCore

/// The coordinator and drive list the window binds to, wired together. Debug builds
/// started with `REDDELICIOUS_SIMULATE=1` get the fake pipeline instead of diskutil and authopen.
@MainActor
struct AppServices {
    static let windowTitle = AppInfo.displayName
    /// One instance for the window and the app delegate's quit guard.
    static let shared = make()

    let coordinator: WriteCoordinator
    let driveList: DriveListModel
    let isSimulation: Bool

    static func make() -> AppServices {
#if DEBUG
        if SimulationMode.isEnabled() {
            return wired(coordinator: SimulationMode.makeCoordinator(), lister: SimulationMode.makeLister(), isSimulation: true)
        }
#endif
        return wired(coordinator: .live(), lister: TargetDiskLister(), isSimulation: false)
    }

    private static func wired(coordinator: WriteCoordinator, lister: TargetDiskLister, isSimulation: Bool) -> AppServices {
        let driveList = DriveListModel(lister: lister)
        // A drive that vanished or changed is deselected, and the selection always
        // carries the filter of the list it is shown in.
        driveList.onUpdate = { [weak coordinator] drives, filter in
            coordinator?.refreshSelectedDrive(from: drives, filter: filter)
        }
        return AppServices(coordinator: coordinator, driveList: driveList, isSimulation: isSimulation)
    }
}
