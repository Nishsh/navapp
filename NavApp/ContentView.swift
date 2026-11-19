import SwiftUI

struct ContentView: View {
    @StateObject private var bridge = LocationBridge()

    var body: some View {
        WebView(bridge: bridge)
            .ignoresSafeArea()
            .preferredColorScheme(.light)
            .onAppear { bridge.requestAuthorization() }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
