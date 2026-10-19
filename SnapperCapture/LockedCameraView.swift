import SwiftUI

/// The Lock Screen camera's screen: the live preview through the current
/// look, swipe to change looks, and the shutter. Everything else (editing,
/// presets, settings) waits for Snapper, a tap on the photo button away.
struct LockedCameraView: View {
    @Bindable var model: LockedCameraModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showBanner = false
    @State private var bannerTask: Task<Void, Never>?
    @State private var zoomAtGestureStart: CGFloat?
    @State private var shutterBlink = false

    private var camera: CameraModel { model.camera }
    private var hidesChrome: Bool { camera.isCameraControlFullscreen }

    private static let topBarHeight: CGFloat = 52
    private static let controlsHeight: CGFloat = 186

    var body: some View {
        GeometryReader { geometry in
            let previewSize = CGSize(width: geometry.size.width, height: geometry.size.width * 4 / 3)
            let overlap = max(0, Self.topBarHeight + previewSize.height + Self.controlsHeight - geometry.size.height)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                VStack(spacing: 0) {
                    topBar
                        .frame(height: Self.topBarHeight)
                        .hiddenForCameraControl(hidesChrome)
                    preview(size: previewSize, bottomInset: overlap)
                        .frame(width: previewSize.width, height: previewSize.height)
                    Spacer(minLength: 0)
                }

                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    bottomControls
                        .hiddenForCameraControl(hidesChrome)
                }
            }
        }
        .statusBarHidden()
        .environment(\.colorScheme, .dark)
        .task {
            await model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            camera.scenePhaseChanged(phase)
        }
        .onChange(of: camera.lookChangeCount) { _, _ in
            flashBanner()
        }
        .sensoryFeedback(.selection, trigger: camera.lookChangeCount)
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.shutterCount)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.5), trigger: camera.focusCount)
        .sensoryFeedback(.impact(weight: .light), trigger: camera.countdown)
        .onChange(of: camera.shutterCount) { _, _ in blinkShutter() }
        .volumeButtonShutter(enabled: model.settings.hardwareShutter && camera.canCapture) {
            model.shutterPressed()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            if camera.capabilities.hasFlash {
                Button {
                    camera.cycleFlash()
                } label: {
                    Image(systemName: camera.flashMode.symbolName)
                        .foregroundStyle(camera.flashMode == .off ? Color.white : Theme.accent)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(CameraIconButtonStyle(size: 44))
                .accessibilityLabel(Text(camera.flashMode.accessibilityLabel))
            }
            Spacer()
            // Set in Snapper; shown so a delayed or brighter shot isn't a surprise.
            let timer = model.settings.captureOptions.timer
            if timer != .off {
                Label(timer.label, systemImage: "timer")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassSurface(in: Capsule())
                    .accessibilityLabel(Text("Self-timer \(timer.label)"))
            }
            if camera.exposureBias != 0 {
                Label(Self.exposureText(camera.exposureBias), systemImage: "plusminus.circle")
                    .font(.footnote.weight(.semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .glassSurface(in: Capsule())
                    .accessibilityLabel(Text("Exposure \(Self.exposureText(camera.exposureBias))"))
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Preview

    private func preview(size: CGSize, bottomInset: CGFloat) -> some View {
        let aspect = model.settings.captureOptions.aspect
        return ZStack {
            CameraPreviewView(renderer: camera.renderer)

            AspectRatioMask(aspect: aspect)

            if model.settings.showGrid {
                let crop = aspect.crop(CGRect(origin: .zero, size: size))
                CameraGrid()
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
            }

            if let point = camera.focusPoint {
                FocusReticle()
                    .id(camera.focusCount)
                    .position(point)
            }

            if showBanner {
                LookBanner(look: camera.currentLook, collectionName: camera.collectionName, isLocked: model.isLocked)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .allowsHitTesting(false)
            }

            if let countdown = camera.countdown, countdown > 0 {
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
                if camera.capabilities.zoomPresets.count > 1 {
                    ZoomControl(presets: camera.capabilities.zoomPresets, zoom: camera.zoom) { preset in
                        camera.setZoom(preset, animated: true)
                    }
                    .padding(.bottom, 14 + bottomInset)
                }
            }
            .hiddenForCameraControl(hidesChrome)

            Color.black
                .opacity(shutterBlink ? 0.85 : 0)
                .allowsHitTesting(false)

            statusOverlay
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.previewCornerRadius, style: .continuous))
        .contentShape(Rectangle())
        .gesture(swipeGesture(width: size.width))
        .simultaneousGesture(zoomGesture)
        .onTapGesture(count: 1, coordinateSpace: .local) { location in
            camera.focus(at: location, in: size)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Camera preview"))
        .accessibilityAction(named: Text("Next look")) {
            camera.select(camera.looks[(camera.lookIndex + 1) % camera.looks.count])
        }
        .accessibilityAction(named: Text("Previous look")) {
            camera.select(camera.looks[(camera.lookIndex - 1 + camera.looks.count) % camera.looks.count])
        }
    }

    /// Camera access can only be given in Snapper itself, after unlocking.
    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .needsPermission, .denied:
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Camera access")
                    .font(.title3.weight(.semibold))
                Text("Open Snapper once to let it use the camera. Then it opens straight from the Lock Screen.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Snapper") { model.openSnapper(.camera) }
                    .buttonStyle(PrimaryButtonStyle())
                    .frame(maxWidth: 260)
                    .padding(.top, 6)
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.72))
        default:
            CameraStatusOverlay(status: camera.status) {}
        }
    }

    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                guard zoomAtGestureStart == nil,
                      abs(value.translation.width) > abs(value.translation.height) * 0.6 else { return }
                camera.swipeChanged(translation: value.translation.width, width: width)
            }
            .onEnded { value in
                camera.swipeEnded(translation: value.translation.width,
                                  predictedTranslation: value.predictedEndTranslation.width,
                                  width: width)
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = zoomAtGestureStart ?? camera.zoom
                if zoomAtGestureStart == nil {
                    zoomAtGestureStart = start
                    camera.cancelSwipe()
                }
                camera.setZoom(start * value.magnification)
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
        VStack(spacing: 14) {
            if let error = model.saveError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            } else {
                LookCaption(look: camera.currentLook, collectionName: camera.collectionName, isLocked: model.isLocked)
            }
            HStack {
                photosButton
                Spacer()
                ShutterButton(isBusy: camera.isCapturing, isCountingDown: camera.countdown != nil) {
                    model.shutterPressed()
                }
                .disabled(!camera.canCapture)
                Spacer()
                Button {
                    camera.switchCamera()
                } label: {
                    VStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 52, height: 52)
                            .glassSurface(in: Circle(), interactive: true)
                        Text("Flip").font(.caption.weight(.semibold))
                    }
                    .frame(width: 64)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!camera.capabilities.canSwitchCamera)
                .opacity(camera.capabilities.canSwitchCamera ? 1 : 0.35)
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

    /// This session's newest photo. Opens Snapper's Library after unlocking,
    /// where the photos arrive (and are saved to Photos, if that's on).
    private var photosButton: some View {
        Button {
            model.openSnapper(.library)
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.1))
                    if let image = model.lastCapture {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                            .id(image)
                    } else {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    if camera.isCapturing {
                        ProgressView()
                            .tint(.white)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 1))
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: model.lastCapture)

                Text("Snapper")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 64)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Open Snapper"))
        .accessibilityValue(model.photoCount == 0 ? Text("") : Text("\(model.photoCount) photos taken"))
        .accessibilityHint(Text("Unlock to see your photos in the Library"))
    }

    /// "+0.7", "−1.3", like the app's exposure slider.
    private static func exposureText(_ stops: Float) -> String {
        let rounded = (stops * 10).rounded() / 10
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f", abs(rounded))
    }

    private func blinkShutter() {
        shutterBlink = true
        withAnimation(.easeOut(duration: 0.25).delay(0.05)) {
            shutterBlink = false
        }
    }
}
