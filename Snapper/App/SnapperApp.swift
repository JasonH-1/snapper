import SwiftUI

@main
struct SnapperApp: App {
    @State private var app = AppModel(store: FreeTierPurchaseService())

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
