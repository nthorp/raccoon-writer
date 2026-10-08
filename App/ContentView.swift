import SwiftUI
import ImageWriterCore

struct ContentView: View {
    var body: some View {
        Text("iso-sword")
            .font(.largeTitle)
            .frame(minWidth: 480, minHeight: 320)
            .navigationTitle(AppInfo.displayName)
    }
}

#Preview {
    ContentView()
}
