import SwiftUI

@main
struct RedDeliciousApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let services = AppServices.shared

    var body: some Scene {
        // A single window: two windows driving one coordinator would only confuse.
        Window(AppServices.windowTitle, id: "main") {
            ContentView(
                coordinator: services.coordinator,
                driveList: services.driveList,
                isSimulation: services.isSimulation
            )
        }
        .windowResizability(.contentSize)
    }
}
