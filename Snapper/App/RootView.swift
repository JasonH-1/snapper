import SwiftUI

/// Hosts the camera and everything presented over it.
struct RootView: View {
    @Bindable var app: AppModel
    @Environment(\.openURL) private var openURL
    @Namespace private var libraryZoom
    @State private var incomingPreset: PresetFile?
    @State private var importError: String?
    @State private var pendingPreset: PresetFile?
    @State private var pendingImportError: String?
    @State private var waitingForDismissals: Set<String> = []
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
            app.isImportingPreset = false
            app.updateCameraVisibility()
            presentationDismissed("import")
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
            app.synchronizeCameraPreset()
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
            libraryZoom: libraryZoom,
            onShowPaywall: { app.presentPaywall(.upgrade) },
            onOpenSettings: { app.openSettings() },
            onOpenLookPicker: { app.openLookPicker() },
            onOpenPresets: { app.openCameraPresets() }
        )
        .onAppear { app.synchronizeCameraPreset() }
        .onChange(of: app.hasPremium) { _, _ in app.synchronizeCameraPreset() }
        .onChange(of: app.settings.presets.presets) { _, _ in app.synchronizeCameraPreset() }
        .sheet(isPresented: $app.isShowingCameraPresets, onDismiss: {
            app.cameraPresetsDismissed()
            presentationDismissed("presets")
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
        .fullScreenCover(item: $app.libraryScreen, onDismiss: { app.libraryDismissed(); presentationDismissed("library") }) { library in
            LibraryView(model: library,
                        onClose: { app.libraryScreen = nil },
                        onShowPaywall: { app.presentPaywall(.upgrade) },
                        onShootPreset: { app.shootWithPreset($0) })
                .paywallHost(app, as: .library, onDismiss: { presentationDismissed("paywall") })
                .zoomTransition(from: AppModel.libraryZoomID, in: libraryZoom)
        }
        .paywallHost(app, as: .root, onDismiss: { presentationDismissed("paywall") })
        .sheet(isPresented: $app.isShowingSettings, onDismiss: { app.settingsDismissed(); presentationDismissed("settings") }) {
            SettingsView(app: app, onClose: { app.isShowingSettings = false })
                .paywallHost(app, as: .settings, onDismiss: { presentationDismissed("paywall") })
        }
        .sheet(isPresented: $app.isShowingLookPicker, onDismiss: { app.lookPickerDismissed(); presentationDismissed("looks") }) {
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
        pendingPreset = nil
        pendingImportError = nil
        do {
            guard url.isFileURL else { throw PresetFile.FileError.invalid }
            pendingPreset = try PresetFile.read(url, looks: app.library)
        } catch { pendingImportError = error.localizedDescription }
        app.camera.cancelCountdown()
        app.upgradeAfterCameraPresets = false
        upgradeAfterImport = false
        presentPendingImport()
    }

    private func presentationDismissed(_ name: String) {
        waitingForDismissals.remove(name)
        presentPendingImport()
    }

    private func presentPendingImport() {
        guard pendingPreset != nil || pendingImportError != nil, waitingForDismissals.isEmpty else { return }
        // Dismiss the topmost surface first, then wait for its callback before
        // dismissing its parent. Never race a guessed animation duration.
        if incomingPreset != nil {
            waitingForDismissals.insert("import")
            incomingPreset = nil
            return
        }
        if app.paywall != nil {
            waitingForDismissals.insert("paywall")
            app.paywall = nil
            return
        }
        if app.isShowingCameraPresets {
            waitingForDismissals.insert("presets")
            app.isShowingCameraPresets = false
            return
        }
        if app.isShowingSettings {
            waitingForDismissals.insert("settings")
            app.isShowingSettings = false
            return
        }
        if app.isShowingLookPicker {
            waitingForDismissals.insert("looks")
            app.isShowingLookPicker = false
            return
        }
        if app.libraryScreen != nil {
            waitingForDismissals.insert("library")
            app.libraryScreen?.editor?.finish()
            app.libraryScreen = nil
            return
        }
        if let file = pendingPreset {
            pendingPreset = nil
            app.isImportingPreset = true
            app.updateCameraVisibility()
            incomingPreset = file
        } else if let error = pendingImportError {
            pendingImportError = nil
            importError = error
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
    func paywallHost(_ app: AppModel, as host: AppModel.PaywallHost, onDismiss: @escaping () -> Void = {}) -> some View {
        fullScreenCover(item: app.paywallBinding(for: host), onDismiss: { app.paywallDismissed(); onDismiss() }) { paywall in
            PaywallView(model: paywall, onClose: { app.paywall = nil })
        }
    }
}
