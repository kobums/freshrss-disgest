import SwiftUI

@main
struct DigestApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .task { await app.launch() }
        }
    }
}
