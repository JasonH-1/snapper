import SwiftUI

/// The camera screen: live filtered preview, swipe to change looks, shutter.
struct CameraView: View {
    @Bindable var model: CameraModel
    /// Whether the person has Snapper Premium (premium looks unlocked).
    var hasPremium: Bool
    var lastCapture: UIImage?
    var isProcessingCapture: Bool
    var onOpenLastCapture: () -> Void = {}
    var onShowPaywall: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onOpenLookPicker: () -> Void = {}

    @Environment(\.scenePhase) private var scenePhase
    @State private var orientation = DeviceOrientationObserver()
    @State private var showBanner = false
    @State private var bannerTask: Task<Void, Never>?
    @State private var zoomAtGestureStart: CGFloat?
    @State private var shutterBlink = false

    private var isLocked: Bool { model.currentLook.isPremium && !hasPremium }

    var body: some View {
        GeometryReader { geometry in
            let previewSize = CGSize(width: geometry.size.width, height: geometry.size.width * 4 / 3)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .frame(height: 52)
                    preview(size: previewSize)
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
        .preferredColorScheme(.dark)
        .task {
            orientation.start()
            await model.start()
        }
        .onDisappear { orientation.stop() }
        .onChange(of: scenePhase) { _, phase in
            model.scenePhaseChanged(phase)
        }
        .onChange(of: model.lookChangeCount) { _, _ in
            flashBanner()
        }
        .sensoryFeedback(.selection, trigger: model.lookChangeCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: model.shutterCount)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: model.focusCount)
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            if model.capabilities.hasFlash {
                Button {
                    model.cycleFlash()
                } label: {
                    Image(systemName: model.flashMode.symbolName)
                        .foregroundStyle(model.flashMode == .off ? Color.white : Color.yellow)
                        .contentTransition(.symbolEffect(.replace))
                        .rotationEffect(orientation.iconRotation)
                }
                .buttonStyle(CameraIconButtonStyle(size: 40))
                .accessibilityLabel(Text(model.flashMode.accessibilityLabel))
            } else {
                Color.clear.frame(width: 40, height: 40)
            }

            Spacer()

            if isLocked {
                Button(action: onShowPaywall) {
                    HStack(spacing: 6) {
                        Image(systemName: "lock.fill")
                        Text("Premium look")
                    }
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Theme.premiumGradient, in: Capsule())
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
                .accessibilityHint(Text("Shows Snapper Premium"))
            }

            Spacer()

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape.fill")
                    .rotationEffect(orientation.iconRotation)
            }
            .buttonStyle(CameraIconButtonStyle(size: 40))
            .accessibilityLabel(Text("Settings"))
        }
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isLocked)
        .animation(.spring(response: 0.35, dampingFraction: 0.75), value: orientation.iconRotation)
    }

    // MARK: - Preview

    private func preview(size: CGSize) -> some View {
        ZStack {
            CameraPreviewView(renderer: model.renderer)

            if let point = model.focusPoint {
                FocusReticle()
                    .id(model.focusCount)
                    .position(point)
            }

            if showBanner {
                LookBanner(look: model.currentLook, collectionName: model.collectionName, isLocked: isLocked)
                    .rotationEffect(orientation.iconRotation)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            if model.status == .noCamera {
                VStack {
                    Text("Simulator — demo image")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.5), in: Capsule())
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.top, 12)
                    Spacer()
                }
                .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                if model.capabilities.zoomPresets.count > 1 {
                    ZoomControl(presets: model.capabilities.zoomPresets,
                                zoom: model.zoom,
                                iconRotation: orientation.iconRotation) { preset in
                        model.setZoom(preset, animated: true)
                    }
                    .padding(.bottom, 14)
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
                guard abs(value.translation.width) > abs(value.translation.height) * 0.6 else { return }
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
                if zoomAtGestureStart == nil { zoomAtGestureStart = start }
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
        VStack(spacing: 18) {
            Button(action: onOpenLookPicker) {
                LookCaption(look: model.currentLook, collectionName: model.collectionName, isLocked: isLocked)
                    .animation(.easeInOut(duration: 0.2), value: model.currentLook)
            }
            .buttonStyle(.plain)

            HStack {
                thumbnail
                Spacer()
                ShutterButton(isBusy: model.isCapturing) {
                    blinkShutter()
                    model.capture()
                }
                .disabled(!(model.status == .running || model.status == .noCamera))
                Spacer()
                Button {
                    model.switchCamera()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .rotationEffect(orientation.iconRotation)
                }
                .buttonStyle(CameraIconButtonStyle(size: 52))
                .disabled(!model.capabilities.canSwitchCamera)
                .opacity(model.capabilities.canSwitchCamera ? 1 : 0.35)
                .accessibilityLabel(Text("Switch camera"))
            }
            .padding(.horizontal, 28)
        }
        .padding(.top, 16)
        .padding(.bottom, 12)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.65), .black],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
        }
    }

    private var thumbnail: some View {
        Button(action: onOpenLastCapture) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(0.1))
                if let lastCapture {
                    Image(uiImage: lastCapture)
                        .resizable()
                        .scaledToFill()
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                        .id(lastCapture)
                }
                if isProcessingCapture {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .rotationEffect(orientation.iconRotation)
            .animation(.spring(response: 0.35, dampingFraction: 0.75), value: lastCapture)
        }
        .buttonStyle(.plain)
        .disabled(lastCapture == nil)
        .accessibilityLabel(Text("Last photo"))
    }

    private func blinkShutter() {
        shutterBlink = true
        withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
            shutterBlink = false
        }
    }
}
