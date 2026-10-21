import SwiftUI

struct ContentView: View {
    @StateObject private var app = AppState()

    var body: some View {
        HomeView()
            .environmentObject(app)
            .onAppear {
                app.startObserving()
            }
    }
}
