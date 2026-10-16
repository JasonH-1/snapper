import SwiftUI

/// Hosts the camera and everything presented over it.
struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if app.needsOnboarding {
                OnboardingView(library: app.library, renderer: app.renderer) {
                    withAnimation(.easeInOut(duration: 0.35)) { app.finishOnboarding() }
                }
                .transition(.opacity)
            } else {
                camera
                    .transition(.opacity)
            }
        }
        .task {
            app.store.start()
            await app.captures.load()
        }
    }

    private var camera: some View {
        CameraView(
            model: app.camera,
            settings: app.settings,
            hasPremium: app.hasPremium,
            lastCapture: app.captures.latestThumbnail,
            isProcessingCapture: app.captures.isProcessingCapture,
            onOpenLibrary: { app.openLibrary() },
            onShowPaywall: { app.presentPaywall(.upgrade) },
            onOpenSettings: { app.openSettings() },
            onOpenLookPicker: { app.openLookPicker() }
        )
        .overlay(alignment: .top) {
            if let toast = app.toast {
                ToastView(toast: toast, onAction: { handle($0) }, onDismiss: { app.dismissToast() })
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .fullScreenCover(item: $app.libraryScreen, onDismiss: { app.libraryDismissed() }) { library in
            LibraryView(model: library,
                        onClose: { app.libraryScreen = nil },
                        onShowPaywall: { app.presentPaywall(.upgrade) })
                .paywallHost(app, as: .library)
        }
        .paywallHost(app, as: .root)
        .sheet(isPresented: $app.isShowingSettings, onDismiss: { app.settingsDismissed() }) {
            SettingsView(app: app, onClose: { app.isShowingSettings = false })
                .paywallHost(app, as: .settings)
        }
        .sheet(isPresented: $app.isShowingLookPicker, onDismiss: { app.lookPickerDismissed() }) {
            LookPickerView(library: app.library,
                           selectedID: app.camera.currentLook.id,
                           hasPremium: app.hasPremium,
                           settings: app.settings,
                           thumbnails: app.lookThumbnails) { look in
                app.selectLook(look)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func handle(_ action: Toast.Action) {
        app.dismissToast()
        switch action {
        case .showPaywall:
            app.presentPaywall(.upgrade)
        case .openSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
    }
}

extension View {
    /// Presents the paywall from this screen when it is the top-most one.
    func paywallHost(_ app: AppModel, as host: AppModel.PaywallHost) -> some View {
        fullScreenCover(item: app.paywallBinding(for: host), onDismiss: { app.paywallDismissed() }) { paywall in
            PaywallView(model: paywall, onClose: { app.paywall = nil })
        }
    }
}
