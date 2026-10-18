import SwiftUI

/// Portrait camera controls stay aligned with their labels and hit targets.
/// Captured-photo orientation is handled separately by CaptureService.
struct CameraView: View {
    @Bindable var model: CameraModel
    /// Camera preferences: grid, level, timer, aspect ratio and more.
    @Bindable var settings: AppSettings
    /// Whether the person has Snapper Premium (premium looks unlocked).
    var hasPremium: Bool
    var lastCapture: UIImage?
    var isProcessingCapture: Bool
    var onOpenLibrary: () -> Void = {}
    /// The Library grows out of its button and shrinks back into it.
    var libraryZoom: Namespace.ID?
    var onShowPaywall: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onOpenLookPicker: () -> Void = {}
    var onOpenPresets: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var showBanner = false
    @State private var bannerTask: Task<Void, Never>?
    @State private var zoomAtGestureStart: CGFloat?
    @State private var shutterBlink = false
    @State private var showOptions = false
    @State private var optionsTab: CameraOptionsPanel.Tab = .exposure
    @State private var level = LevelObserver()

    /// Any option changed from its default, to tint the options button.
    private var optionsActive: Bool {
        model.exposureBias != 0 || model.isFocusLocked || model.whiteBalance != .auto
            || model.lensPosition != nil || model.manualExposure != nil
            || settings.showGrid || settings.showLevel || settings.selfTimer != .off
            || settings.aspectRatio != .fourThree
    }

    private var canShoot: Bool { model.canCapture }

    private var isLocked: Bool {
        (model.currentLook.isPremium || model.activePreset?.adjustments.requiresPremium == true) && !hasPremium
    }

    private static let topBarHeight: CGFloat = 52
    /// Approximate height of the look caption + shutter row.
    private static let controlsHeight: CGFloat = 186

    var body: some View {
        GeometryReader { geometry in
            let previewSize = CGSize(width: geometry.size.width, height: geometry.size.width * 4 / 3)
            // On shorter iPhones the controls overlap the bottom of the preview.
            let overlap = max(0, Self.topBarHeight + previewSize.height + Self.controlsHeight - geometry.size.height)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .frame(height: Self.topBarHeight)
                    preview(size: previewSize, bottomInset: overlap)
                        .frame(width: previewSize.width, height: previewSize.height)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bottomControls
                }
            }
        }
        .statusBarHidden()
        // The camera is always dark; scoped to this screen so sheets and the
        // review screen still follow the system appearance.
        .environment(\.colorScheme, .dark)
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .onChange(of: model.lookChangeCount) { _, _ in
            flashBanner()
        }
        .sensoryFeedback(.selection, trigger: model.lookChangeCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.shutterCount)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: model.focusCount)
        .sensoryFeedback(.impact(weight: .light), trigger: model.countdown)
        .onChange(of: model.shutterCount) { _, _ in blinkShutter() }
        .task(id: settings.photoMegapixels) { model.setPhotoMegapixels(settings.photoMegapixels) }
        .task(id: settings.showLevel) {
            if settings.showLevel { level.start() } else { level.stop() }
        }
        .volumeButtonShutter(enabled: settings.volumeButtonShutter && canShoot) {
            model.shutterPressed(options: settings.captureOptions)
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        ZStack {
            HStack(spacing: 10) {
                if model.capabilities.hasFlash {
                    Button {
                        model.cycleFlash()
                    } label: {
                        Image(systemName: model.flashMode.symbolName)
                            .foregroundStyle(model.flashMode == .off ? Color.white : Theme.accent)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(CameraIconButtonStyle(size: 44))
                    .accessibilityLabel(Text(model.flashMode.accessibilityLabel))
                }

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showOptions.toggle() }
                } label: {
                    Image(systemName: showOptions ? "chevron.up" : "slider.horizontal.3")
                        .foregroundStyle(optionsActive || showOptions ? Theme.accent : .white)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(showOptions ? Text("Hide camera options") : Text("Camera options"))

                Spacer()

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape.fill")
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text("Settings"))
            }

            if isLocked {
                Button(action: onShowPaywall) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("Premium")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.accent, in: Capsule())
                    .minimumTapTarget()
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityHint(Text("Shows Snapper Premium. Without it, photos save without the Premium look or tools."))
            }
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isLocked)
    }

    // MARK: - Preview

    private func preview(size: CGSize, bottomInset: CGFloat) -> some View {
        ZStack {
            CameraPreviewView(renderer: model.renderer)

            AspectRatioMask(aspect: settings.aspectRatio)

            if settings.showGrid {
                let crop = settings.aspectRatio.crop(CGRect(origin: .zero, size: size))
                CameraGrid()
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
            }

            if settings.showLevel {
                LevelIndicator(observer: level)
            }

            if let point = model.focusPoint {
                FocusReticle()
                    .id(model.focusCount)
                    .position(point)
            }

            if showBanner {
                LookBanner(look: model.currentLook, collectionName: model.collectionName, isLocked: isLocked)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            VStack(spacing: 8) {
                if model.status == .noCamera {
                    Text("Simulator — demo image")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassSurface(in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                }
                if model.isFocusLocked {
                    Text("AE/AF LOCK")
                        .font(.caption.weight(.bold))
                        .tracking(0.5)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(.black)
                        .transition(.opacity)
                }
                Spacer()
            }
            .padding(.top, 12)
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: model.isFocusLocked)

            if let countdown = model.countdown, countdown > 0 {
                Text("\(countdown)")
                    .font(.system(size: 96, weight: .thin).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.5), radius: 12)
                    .contentTransition(.numericText(countsDown: true))
                    .allowsHitTesting(false)
                    .accessibilityLabel(Text("Taking photo in \(countdown) seconds"))
            }

            VStack(spacing: 12) {
                Spacer()
                if showOptions {
                    CameraOptionsPanel(model: model, settings: settings, tab: $optionsTab)
                        .padding(.horizontal, 12)
                        .padding(.bottom, model.capabilities.zoomPresets.count > 1 ? 0 : 14 + bottomInset)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                if model.capabilities.zoomPresets.count > 1 {
                    ZoomControl(presets: model.capabilities.zoomPresets, zoom: model.zoom) { preset in
                        model.setZoom(preset, animated: true)
                    }
                    .padding(.bottom, 14 + bottomInset)
                }
            }

            Color.black
                .opacity(shutterBlink ? 0.85 : 0)
                .allowsHitTesting(false)

            CameraStatusOverlay(status: model.status) {
                Task { await model.requestPermission() }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.previewCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .gesture(swipeGesture(width: size.width))
        .simultaneousGesture(zoomGesture)
        .onTapGesture(count: 1, coordinateSpace: .local) { location in
            model.focus(at: location, in: size)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Camera preview"))
        .accessibilityAction(named: Text("Next look")) {
            model.select(model.looks[(model.lookIndex + 1) % model.looks.count])
        }
        .accessibilityAction(named: Text("Previous look")) {
            model.select(model.looks[(model.lookIndex - 1 + model.looks.count) % model.looks.count])
        }
    }

    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                // Two-finger pinches also move a drag; never treat them as swipes.
                guard zoomAtGestureStart == nil,
                      abs(value.translation.width) > abs(value.translation.height) * 0.6 else { return }
                model.swipeChanged(translation: value.translation.width, width: width)
            }
            .onEnded { value in
                model.swipeEnded(translation: value.translation.width,
                                 predictedTranslation: value.predictedEndTranslation.width,
                                 width: width)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomAtGestureStart ?? model.zoom
                if zoomAtGestureStart == nil {
                    zoomAtGestureStart = start
                    model.cancelSwipe()
                }
                model.setZoom(start * value.magnification)
            }
            .onEnded { _ in
                zoomAtGestureStart = nil
            }
    }

    private func flashBanner() {
        bannerTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { showBanner = true }
        bannerTask = Task {
            try? await Task.sleep(for: .seconds(1.1))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.35)) { showBanner = false }
        }
    }

    // MARK: - Bottom controls

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Button(action: onOpenLookPicker) {
                    HStack(spacing: 10) {
                        Image(systemName: "camera.filters").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("LOOKS").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                            Text(model.currentLook.name).font(Theme.lookName(.headline)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                    }
                    .padding(12).frame(maxWidth: .infinity, minHeight: 58)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Browse looks. Current look: \(model.currentLook.name)")
                Button(action: onOpenPresets) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("MY STYLES", systemImage: "square.stack").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        Text(model.activePreset?.name ?? String(localized: "Presets"))
                            .font(.subheadline.weight(.semibold)).lineLimit(1)
                            .foregroundStyle(model.activePreset == nil ? Color.white : Theme.accent)
                    }
                    .padding(12).frame(minHeight: 58)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .contentShape(Rectangle())
                }
                .accessibilityHint("Choose or save a personal style")
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.horizontal, 16)
            HStack {
                libraryButton
                Spacer()
                ShutterButton(isBusy: model.isCapturing, isCountingDown: model.countdown != nil) {
                    model.shutterPressed(options: settings.captureOptions)
                }
                .disabled(!canShoot)
                Spacer()
                Button {
                    model.switchCamera()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 52, height: 52)
                            .glassSurface(in: Circle(), interactive: true)
                        Text("Flip").font(.caption.weight(.semibold))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.capabilities.canSwitchCamera)
                .opacity(model.capabilities.canSwitchCamera ? 1 : 0.35)
                .accessibilityLabel(Text("Switch camera"))
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(alignment: .bottom) {
            Color.black.opacity(0.7)
                .ignoresSafeArea()
        }
    }

    /// The newest photo with a grid badge: opens the Library.
    private var libraryButton: some View {
        Button(action: onOpenLibrary) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.1))
                    if let lastCapture {
                        Image(uiImage: lastCapture)
                            .resizable()
                            .scaledToFill()
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .id(lastCapture)
                    } else {
                        Image(systemName: "photo.on.rectangle")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if isProcessingCapture {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .zoomSource(id: AppModel.libraryZoomID, in: libraryZoom)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 24, height: 24)
                        .background(Theme.accent, in: Circle())
                        .overlay(Circle().strokeBorder(.black, lineWidth: 2))
                        .offset(x: 6, y: 6)
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: lastCapture)

                Text("Library")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Library"))
        .accessibilityHint(Text("Your photos, to edit, share or import more"))
    }

    private func blinkShutter() {
        shutterBlink = true
        withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
            shutterBlink = false
        }
    }
}
