import SwiftUI

@main
struct IsoSwordApp: App {
    @State private var services = AppServices.make()

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
