import SwiftUI

@main
struct SnapperApp: App {
    @State private var app = AppModel(store: StoreKitPurchaseService())

    init() {
        #if DEBUG
        TouchIndicators.installIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
