#if DEBUG
import SwiftUI

/// Debug Simulate mode only: makes it obvious that nothing real is being written.
struct SimulationBanner: View {
    var body: some View {
        Label("Simulation: fake drives, nothing real is read or written", systemImage: "testtube.2")
            .font(.callout.bold())
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(.yellow)
    }
}
#endif
