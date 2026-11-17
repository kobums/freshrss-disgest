import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        @Bindable var app = app

        Group {
            if app.needsConnection {
                ConnectView()
            } else {
                NavigationStack(path: $app.path) {
                    TimelineScreen()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await app.didBecomeActive() }
            case .background: app.didEnterBackground()
            default: break
            }
        }
    }
}
