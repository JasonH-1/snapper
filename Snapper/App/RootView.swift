import SwiftUI

/// Hosts the camera and everything presented over it.
struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openURL) private var openURL
    @Namespace private var libraryZoom
    @State private var incomingPreset: PresetFile?
    @State private var importError: String?
    @State private var importTask: Task<Void, Never>?
    @State private var upgradeAfterImport = false

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
        .onOpenURL { receivePreset($0) }
        .sheet(item: $incomingPreset, onDismiss: {
            if upgradeAfterImport { upgradeAfterImport = false; app.presentPaywall(.upgrade) }
        }) { file in
            PresetImportView(file: file, store: app.settings.presets, looks: app.library, hasPremium: app.hasPremium,
                             onUpgrade: { upgradeAfterImport = true })
        }
        .alert("Couldn't Open Preset", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(importError ?? "") }
        .task {
            app.store.start()
            await app.captures.load()
            app.synchronizeCameraPreset()
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
            libraryZoom: libraryZoom,
            onShowPaywall: { app.presentPaywall(.upgrade) },
            onOpenSettings: { app.openSettings() },
            onOpenLookPicker: { app.openLookPicker() },
            onOpenPresets: { app.isShowingCameraPresets = true }
        )
        .onChange(of: app.hasPremium) { _, _ in app.synchronizeCameraPreset() }
        .onChange(of: app.settings.presets.presets) { _, _ in app.synchronizeCameraPreset() }
        .sheet(isPresented: $app.isShowingCameraPresets, onDismiss: {
            if app.upgradeAfterCameraPresets {
                app.upgradeAfterCameraPresets = false
                app.presentPaywall(.upgrade)
            }
        }) {
            PresetsView(store: app.settings.presets, looks: app.library, hasPremium: app.hasPremium,
                        currentRecipe: app.camera.captureStyle,
                        onApply: { app.shootWithPreset($0) },
                        onUpgrade: { app.upgradeAfterCameraPresets = true })
        }
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
                        onShowPaywall: { app.presentPaywall(.upgrade) },
                        onShootPreset: { app.shootWithPreset($0) })
                .paywallHost(app, as: .library)
                .zoomTransition(from: AppModel.libraryZoomID, in: libraryZoom)
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

    private func receivePreset(_ url: URL) {
        importTask?.cancel()
        do {
            guard url.isFileURL else { throw PresetFile.FileError.invalid }
            let file = try PresetFile.read(url, looks: app.library)
            app.camera.cancelCountdown()
            app.libraryScreen?.editor?.finish()
            app.libraryScreen = nil
            app.isShowingSettings = false
            app.isShowingLookPicker = false
            app.isShowingCameraPresets = false
            app.paywall = nil
            incomingPreset = nil
            importTask = Task { @MainActor in
                // Allow any presented screen to finish dismissing before import.
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                incomingPreset = file
            }
        } catch { importError = error.localizedDescription }
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
