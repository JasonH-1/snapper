import AVFoundation
import CoreImage
import OSLog
import SwiftUI

/// View model for the camera screen: permission state, the selected look,
/// swipe-to-change, flash, zoom, focus and the shutter.
@MainActor
@Observable
final class CameraModel {
    enum Status: Equatable {
        case starting
        case running
        case needsPermission
        case denied
        case interrupted(CameraInterruption)
        /// No camera hardware (Simulator): a demo image stands in for the feed.
        case noCamera
        case failed(String)
    }

    private(set) var status: Status = .starting
    private(set) var capabilities = CameraCapabilities()
    private(set) var looks: [Look]
    private(set) var lookIndex = 0
    private(set) var activePreset: SavedPreset?
    var captureStyle: PhotoRecipe {
        activePreset?.applying(to: PhotoRecipe(lookID: currentLook.id)) ?? PhotoRecipe(lookID: currentLook.id)
    }
    /// Bumped whenever the look changes, to show the look's name briefly.
    private(set) var lookChangeCount = 0
    private(set) var zoom: CGFloat = 1
    /// Where the focus reticle is drawn, in preview coordinates.
    private(set) var focusPoint: CGPoint?
    private(set) var focusCount = 0
    private(set) var shutterCount = 0
    private(set) var isCapturing = false
    var flashMode: FlashMode = .off
    /// Exposure compensation in stops (the brightness slider).
    private(set) var exposureBias: Float = 0
    /// Focus and exposure held at the last point (AE/AF lock).
    private(set) var isFocusLocked = false
    /// Seconds left on the self-timer, while it runs.
    private(set) var countdown: Int?
    private(set) var whiteBalance: WhiteBalancePreset = .auto
    private(set) var isChangingWhiteBalance = false
    private(set) var whiteBalanceError: String?
    /// Manual lens position (0 near … 1 far); nil = auto focus.
    private(set) var lensPosition: Float?
    /// Manual ISO and shutter speed; nil = auto exposure.
    private(set) var manualExposure: ManualExposure? {
        didSet { if (manualExposure == nil) != (oldValue == nil) { syncCameraControlExposure() } }
    }
    /// Camera Control's overlay is up: on-screen controls step aside.
    private(set) var isCameraControlFullscreen = false

    struct ManualExposure: Equatable, Sendable {
        var iso: Float
        /// Seconds.
        var shutter: Double
    }

    /// The slider's range: ±2 stops, within what the device supports.
    var exposureRange: ClosedRange<Float> {
        let lower = max(-2, capabilities.minExposureBias)
        let upper = min(2, capabilities.maxExposureBias)
        return lower <= upper ? lower...upper : 0...0
    }

    var canCapture: Bool {
        !isChangingWhiteBalance && isPreviewVisible && isAppActive && (status == .running || status == .noCamera)
    }

    var currentLook: Look { looks.indices.contains(lookIndex) ? looks[lookIndex] : .original }
    var collectionName: String? { library.collection(for: currentLook)?.name }

    /// Flash, exposure and camera, to remember between launches.
    var preferences: CameraPreferences {
        CameraPreferences(flash: flashMode, exposureBias: exposureBias, position: preferredPosition)
    }

    /// Camera Control's look picker: every look in swipe order, and the current one.
    var cameraControlLooks: CameraControlUpdate {
        .looks(titles: looks.map(\.name), selected: lookIndex)
    }

    /// Camera Control's exposure slider, which only works with auto exposure.
    var cameraControlExposure: CameraControlUpdate {
        .exposure(range: exposureRange, value: exposureBias, isEnabled: manualExposure == nil)
    }

    @ObservationIgnored let renderer: PreviewRenderer
    @ObservationIgnored let library: LookLibrary
    @ObservationIgnored private let captureService: CaptureService
    @ObservationIgnored private let lutStore: LUTStore
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var zoomTask: Task<Void, Never>?
    @ObservationIgnored private var pendingZoom: (value: CGFloat, animated: Bool)?
    @ObservationIgnored private var exposureTask: Task<Void, Never>?
    @ObservationIgnored private var pendingExposure: Float?
    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var manualExposureTask: Task<Void, Never>?
    @ObservationIgnored private var pendingManualExposure: ManualExposure?
    /// The last metering point, in device coordinates (centre until a tap).
    @ObservationIgnored private var meteringPoint = CGPoint(x: 0.5, y: 0.5)
    @ObservationIgnored private var swipeTarget: Int?
    private var isPreviewVisible = true
    private var isAppActive = true
    @ObservationIgnored private var hasStarted = false
    /// The camera to open: the one last used (see `restore(_:)`).
    @ObservationIgnored private var preferredPosition: CameraPosition = .back
    @ObservationIgnored private var cameraControlUpdates: [CameraControlUpdate] = []
    @ObservationIgnored private var cameraControlTask: Task<Void, Never>?

    /// Called with each new photo and the look it was taken with.
    @ObservationIgnored var onCapture: ((CapturedPhoto, Look) -> Void)?
    /// Called when the selected look changes (swipe or picker).
    @ObservationIgnored var onLookChange: ((Look) -> Void)?
    /// Called when the person changes flash, exposure or camera.
    @ObservationIgnored var onPreferencesChange: ((CameraPreferences) -> Void)?

    /// The id the next photo will get. The preview renders random effects
    /// with its seed, and each shot advances it, like winding on a roll.
    @ObservationIgnored private var nextFrameID = UUID()

    init(library: LookLibrary, lutStore: LUTStore = .shared) {
        let renderer = PreviewRenderer()
        self.renderer = renderer
        self.library = library
        self.lutStore = lutStore
        self.looks = library.looks
        self.captureService = CaptureService(renderer: renderer)
        renderer.show(lookState(for: currentLook))
        renderer.setSeed(nextFrameID.effectsSeed)
        preloadLooks()
        listenForEvents()
    }

    // MARK: - Session

    /// Starts as the camera was left: flash, exposure and front or back
    /// camera. Call before `start()`.
    func restore(_ preferences: CameraPreferences) {
        flashMode = preferences.flash
        preferredPosition = preferences.position
        exposureBias = min(max(preferences.exposureBias, exposureRange.lowerBound), exposureRange.upperBound)
        if status == .noCamera { updateDemo() }
    }

    /// Takes on flash, exposure and camera chosen elsewhere (the Lock Screen
    /// camera), switching cameras if this one is already running.
    func adopt(_ preferences: CameraPreferences) {
        flashMode = preferences.flash
        applyExposureBias(preferences.exposureBias)
        syncCameraControlExposure()
        if hasStarted, capabilities.position != preferences.position, capabilities.canSwitchCamera {
            switchCamera()
        } else {
            preferredPosition = preferences.position
        }
        onPreferencesChange?(self.preferences)
    }

    /// Starts the camera if permission allows. Safe to call repeatedly.
    func start() async {
        guard CaptureService.isCameraAvailable else {
            status = .noCamera
            startDemo()
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            await startSession()
        case .notDetermined:
            status = .needsPermission
        default:
            status = .denied
        }
    }

    /// Shows the system camera prompt, then starts if allowed.
    func requestPermission() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        if granted {
            await startSession()
        } else {
            status = .denied
        }
    }

    private func startSession() async {
        guard isPreviewVisible, isAppActive else { return }
        if status != .running { status = .starting }
        do {
            try await captureService.start(position: preferredPosition, exposureBias: exposureBias)
            hasStarted = true
        } catch CameraError.noCamera {
            status = .noCamera
            startDemo()
        } catch {
            Logger.camera.error("Camera start failed: \(error.localizedDescription, privacy: .public)")
            status = .failed(error.localizedDescription)
        }
    }

    private func startDemo() {
        if let url = DemoScene.url {
            renderer.startDemo(imageURL: url)
        }
        var demo = CameraCapabilities(position: .back, hasFlash: false, canSwitchCamera: false,
                                      zoomPresets: [1], minZoom: 1, maxZoom: 1, zoom: 1)
        demo.supportsManualExposure = true
        demo.supportsManualFocus = true
        demo.supportsWhiteBalance = true
        demo.photoMegapixels = [12, 24, 48]
        capabilities = demo
        updateDemo()
    }

    /// Pause the camera while another full-screen view covers it.
    func setPreviewVisible(_ visible: Bool) {
        isPreviewVisible = visible
        if !visible { cancelCountdown() }
        updateRunningState()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        isAppActive = phase == .active
        if !isAppActive { cancelCountdown() }
        // Coming back from the Settings app: camera access may have changed.
        if phase == .active, status == .denied || status == .needsPermission {
            renderer.setEnabled(isPreviewVisible)
            Task { await start() }
            return
        }
        updateRunningState()
    }

    private func updateRunningState() {
        let shouldRun = isPreviewVisible && isAppActive
        renderer.setEnabled(shouldRun)
        guard status != .noCamera else { return }
        if shouldRun {
            if hasStarted || status == .running || status == .starting {
                Task { await startSession() }
            }
        } else {
            Task { await captureService.stop() }
        }
    }

    private func listenForEvents() {
        let events = captureService.events
        eventTask = Task { [weak self] in
            for await event in events {
                self?.handle(event)
            }
        }
    }

    private func handle(_ event: CaptureEvent) {
        switch event {
        case .configured(let caps):
            capabilities = caps
            zoom = caps.zoom
            if !caps.hasFlash { flashMode = .off }
            // A new device starts automatic; the bias carries over, clamped.
            isFocusLocked = false
            whiteBalance = .auto
            lensPosition = nil
            manualExposure = nil
            exposureBias = min(max(exposureBias, exposureRange.lowerBound), exposureRange.upperBound)
            sendCameraControl(cameraControlLooks)
            sendCameraControl(cameraControlExposure)
        case .whiteBalanceChanged(let preset):
            whiteBalance = preset
        case .running(let running):
            if running {
                status = .running
            } else if case .running = status, isPreviewVisible, isAppActive {
                status = .starting
            }
        case .interrupted(let reason):
            if let reason {
                status = .interrupted(reason)
            } else if hasStarted {
                status = .running
            }
        case .failed(let message):
            status = .failed(message)
        case .captureOrientation:
            break
        case .subjectAreaChanged:
            if !isFocusLocked { focusPoint = nil }
        case .cameraControlLook(let index):
            cameraControlSelectedLook(at: index)
        case .cameraControlExposure(let stops):
            cameraControlChangedExposure(to: stops)
        case .cameraControlFullscreen(let fullscreen):
            isCameraControlFullscreen = fullscreen
        }
    }

    // MARK: - Looks

    func lookState(for look: Look) -> PreviewRenderer.LookState {
        PreviewRenderer.LookState(id: look.id, lut: lutStore.lut(for: look), effects: look.effects)
    }

    /// Jumps straight to a look (from the look picker).
    func select(_ look: Look) {
        select(look, fromCameraControl: false)
    }

    private func select(_ look: Look, fromCameraControl: Bool) {
        guard let index = looks.firstIndex(of: look) else { return }
        activePreset = nil
        swipeTarget = nil
        lookIndex = index
        renderer.show(lookState(for: look))
        lookChangeCount += 1
        lookSelectionChanged(fromCameraControl: fromCameraControl)
        onLookChange?(look)
    }

    func selectPreset(_ preset: SavedPreset) {
        guard let look = library.look(id: preset.lookID), let index = looks.firstIndex(of: look) else { return }
        activePreset = preset
        swipeTarget = nil
        lookIndex = index
        var state = lookState(for: look)
        state.strength = preset.strength
        state.adjustments = preset.adjustments
        renderer.show(state)
        lookChangeCount += 1
        lookSelectionChanged(fromCameraControl: false)
        onLookChange?(look)
    }

    /// Reorders the swipe sequence (e.g. favourites first) and keeps the current look.
    func setLookOrder(_ ordered: [Look]) {
        let current = currentLook
        looks = ordered.isEmpty ? [.original] : ordered
        if let index = looks.firstIndex(of: current) {
            lookIndex = index
            lookSelectionChanged(fromCameraControl: false)
        } else {
            activePreset = nil
            swipeTarget = nil
            lookIndex = 0
            renderer.show(lookState(for: currentLook))
            lookSelectionChanged(fromCameraControl: false)
            onLookChange?(currentLook)
        }
    }

    /// Camera Control's look picker moved: its indexes follow the swipe order.
    func cameraControlSelectedLook(at index: Int) {
        guard looks.indices.contains(index), index != lookIndex else { return }
        cancelSwipe()
        select(looks[index], fromCameraControl: true)
    }

    /// Keeps the nearby looks ready and Camera Control's picker in step. A
    /// change that came from the picker isn't sent back, so a fast scroll
    /// on Camera Control is never pulled back to an older look.
    private func lookSelectionChanged(fromCameraControl: Bool) {
        preloadLooks()
        if !fromCameraControl { sendCameraControl(cameraControlLooks) }
    }

    private func wrapped(_ index: Int) -> Int {
        let count = looks.count
        return ((index % count) + count) % count
    }

    func swipeChanged(translation: CGFloat, width: CGFloat) {
        guard looks.count > 1, width > 0, translation != 0 else { return }
        let edge: PreviewRenderer.SwipeEdge = translation < 0 ? .trailing : .leading
        let target = wrapped(lookIndex + (edge == .trailing ? 1 : -1))
        swipeTarget = target
        renderer.updateSwipe(incoming: lookState(for: looks[target]), edge: edge, progress: abs(translation) / width)
    }

    func swipeEnded(translation: CGFloat, predictedTranslation: CGFloat, width: CGFloat) {
        guard let target = swipeTarget, width > 0 else { return }
        swipeTarget = nil
        let progress = abs(translation) / width
        let flick = abs(predictedTranslation) > width * 0.6 && predictedTranslation.sign == translation.sign
        let commit = progress > 0.33 || flick
        renderer.finishSwipe(commit: commit)
        if commit {
            activePreset = nil
            lookIndex = target
            lookChangeCount += 1
            lookSelectionChanged(fromCameraControl: false)
            onLookChange?(currentLook)
        }
    }

    /// Abandons an in-progress swipe (e.g. when a pinch starts).
    func cancelSwipe() {
        guard swipeTarget != nil else { return }
        swipeTarget = nil
        renderer.finishSwipe(commit: false)
    }

    /// Loads the looks either side of the current one, so a swipe never waits
    /// on disk. Any other look loads when it's picked (see `LUTStore`), and
    /// only the most recent few stay in memory.
    private func preloadLooks() {
        guard !self.looks.isEmpty else { return }
        let looks = [-1, 0, 1].map { self.looks[wrapped(lookIndex + $0)] }
        let store = lutStore
        Task.detached(priority: .utility) {
            store.preload(looks)
        }
    }

    // MARK: - Controls

    func cycleFlash() {
        guard capabilities.hasFlash else { return }
        flashMode = flashMode.next
        onPreferencesChange?(preferences)
    }

    func switchCamera() {
        guard capabilities.canSwitchCamera, !isChangingWhiteBalance, !isCapturing else { return }
        focusPoint = nil
        Task {
            do {
                preferredPosition = try await captureService.switchCamera()
                onPreferencesChange?(preferences)
            } catch {
                Logger.camera.error("Switching camera failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Focus and exposure at a tap (and release an AE/AF lock). `point` is in
    /// the preview's coordinates.
    func focus(at point: CGPoint, in size: CGSize) {
        guard !isChangingWhiteBalance else { return }
        guard status == .running || status == .noCamera, size.width > 0, size.height > 0 else { return }
        let x = min(max(point.x / size.width, 0), 1)
        let y = min(max(point.y / size.height, 0), 1)
        // Preview frames are rotated to portrait (and mirrored for the front
        // camera); device points of interest use the unrotated sensor frame.
        let devicePoint = capabilities.position == .front ? CGPoint(x: y, y: x) : CGPoint(x: y, y: 1 - x)
        meteringPoint = devicePoint
        focusPoint = point
        focusCount += 1
        isFocusLocked = false
        if lensPosition != nil {
            lensPosition = nil
            updateDemo()
        }
        guard status == .running else { return }
        Task { await captureService.focus(at: devicePoint) }
    }

    /// Locks focus and exposure at the last tapped point (or the centre), or
    /// releases the lock.
    func toggleFocusLock() {
        guard status == .running || status == .noCamera else { return }
        isFocusLocked.toggle()
        focusCount += 1
        guard status == .running else { return }
        let point = meteringPoint
        if isFocusLocked {
            Task { await captureService.lockFocusAndExposure(at: point) }
        } else {
            focusPoint = nil
            Task { await captureService.resetFocus() }
        }
    }

    /// Exposure compensation in stops, clamped to `exposureRange`.
    func setExposureBias(_ stops: Float) {
        guard applyExposureBias(stops) else { return }
        syncCameraControlExposure()
    }

    /// Camera Control's exposure slider moved. The slider already shows the
    /// value, so it's only sent back when the camera couldn't take it.
    func cameraControlChangedExposure(to stops: Float) {
        guard manualExposure == nil, !isChangingWhiteBalance else {
            syncCameraControlExposure()
            return
        }
        applyExposureBias(stops)
    }

    /// Returns whether the bias changed.
    @discardableResult
    private func applyExposureBias(_ stops: Float) -> Bool {
        guard !isChangingWhiteBalance else { return false }
        let clamped = min(max(stops, exposureRange.lowerBound), exposureRange.upperBound)
        guard clamped != exposureBias else { return false }
        exposureBias = clamped
        onPreferencesChange?(preferences)
        if status == .noCamera {
            updateDemo()
            return true
        }
        pendingExposure = clamped
        guard exposureTask == nil else { return true }
        exposureTask = Task {
            while let next = pendingExposure {
                pendingExposure = nil
                await captureService.setExposureBias(next)
            }
            exposureTask = nil
        }
        return true
    }

    // MARK: - Camera Control

    private func syncCameraControlExposure() {
        sendCameraControl(cameraControlExposure)
    }

    /// Sends Camera Control updates to the capture service in order; a newer
    /// update of the same kind replaces one still waiting.
    private func sendCameraControl(_ update: CameraControlUpdate) {
        guard status != .noCamera else { return }
        cameraControlUpdates.removeAll { update.replaces($0) }
        cameraControlUpdates.append(update)
        guard cameraControlTask == nil else { return }
        cameraControlTask = Task {
            while !cameraControlUpdates.isEmpty {
                let next = cameraControlUpdates.removeFirst()
                await captureService.updateCameraControl(next)
            }
            cameraControlTask = nil
        }
    }

    func setZoom(_ value: CGFloat, animated: Bool = false) {
        guard !isChangingWhiteBalance else { return }
        let clamped = min(max(value, capabilities.minZoom), capabilities.maxZoom)
        zoom = clamped
        pendingZoom = (clamped, animated)
        guard zoomTask == nil else { return }
        zoomTask = Task {
            while let next = pendingZoom {
                pendingZoom = nil
                _ = await captureService.setZoom(next.value, animated: next.animated)
            }
            zoomTask = nil
        }
    }

    func setWhiteBalance(_ preset: WhiteBalancePreset) {
        guard !isChangingWhiteBalance, !isCapturing,
              preset == .auto || capabilities.supportsWhiteBalance else { return }
        whiteBalanceError = nil
        if status == .noCamera {
            whiteBalance = preset
            return updateDemo()
        }
        cancelCountdown()
        focusPoint = nil
        isChangingWhiteBalance = true
        Task {
            defer { isChangingWhiteBalance = false }
            // Drain pending controls before replacing the capture device.
            await zoomTask?.value
            await exposureTask?.value
            await manualExposureTask?.value
            do {
                try await captureService.setWhiteBalance(preset)
            } catch {
                whiteBalanceError = String(localized: "Could not change white balance. Please try again.")
                Logger.camera.error("White balance failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Switches between auto focus and a manual lens position.
    func setManualFocus(_ manual: Bool) {
        guard !isChangingWhiteBalance else { return }
        guard manual != (lensPosition != nil) else { return }
        if manual {
            focusPoint = nil
            isFocusLocked = false
            setLensPosition(1)
        } else {
            lensPosition = nil
            if status == .noCamera { return updateDemo() }
            Task { await captureService.setLensPosition(nil) }
        }
    }

    /// Lens position, 0 (nearest) … 1 (farthest).
    func setLensPosition(_ position: Float) {
        guard !isChangingWhiteBalance else { return }
        let clamped = min(max(position, 0), 1)
        lensPosition = clamped
        if status == .noCamera { return updateDemo() }
        Task { await captureService.setLensPosition(clamped) }
    }

    /// Switches between auto exposure and manual ISO and shutter speed,
    /// starting from whatever auto exposure had chosen.
    func setManualExposure(_ manual: Bool) {
        guard !isChangingWhiteBalance else { return }
        guard manual != (manualExposure != nil) else { return }
        guard manual else {
            manualExposure = nil
            if status == .noCamera { return updateDemo() }
            Task { await captureService.setManualExposure(nil) }
            return
        }
        isFocusLocked = false
        if status == .noCamera {
            manualExposure = Self.demoAutoExposure
            return updateDemo()
        }
        Task {
            let current = await captureService.currentExposure()
            let start = current.map { ManualExposure(iso: $0.iso, shutter: $0.shutter) } ?? Self.demoAutoExposure
            applyManualExposure(start)
        }
    }

    func setISO(_ iso: Float) {
        guard var manual = manualExposure else { return }
        manual.iso = min(max(iso, capabilities.minISO), capabilities.maxISO)
        applyManualExposure(manual)
    }

    func setShutter(_ seconds: Double) {
        guard var manual = manualExposure else { return }
        manual.shutter = min(max(seconds, capabilities.minShutter), capabilities.maxShutter)
        applyManualExposure(manual)
    }

    private func applyManualExposure(_ manual: ManualExposure) {
        guard !isChangingWhiteBalance else { return }
        manualExposure = manual
        if status == .noCamera { return updateDemo() }
        pendingManualExposure = manual
        guard manualExposureTask == nil else { return }
        manualExposureTask = Task {
            while let next = pendingManualExposure {
                pendingManualExposure = nil
                await captureService.setManualExposure((next.iso, next.shutter))
            }
            manualExposureTask = nil
        }
    }

    /// The Photo Size setting.
    func setPhotoMegapixels(_ megapixels: Int) {
        Task { await captureService.setMaxMegapixels(megapixels) }
    }

    // MARK: - Simulator stand-in

    /// What auto exposure "picks" for the demo scene.
    private static let demoAutoExposure = ManualExposure(iso: 200, shutter: 1.0 / 60)

    /// The demo feed's look under the current settings.
    private var demoAdjustments: DemoAdjustments {
        var adjustments = DemoAdjustments()
        if let manual = manualExposure {
            let auto = Self.demoAutoExposure
            adjustments.exposure = Float(log2(Double(manual.iso / auto.iso)) + log2(manual.shutter / auto.shutter))
        } else {
            adjustments.exposure = exposureBias
        }
        adjustments.temperature = whiteBalance.temperature
        // The demo scene is far away: sharp at the far end of the lens.
        adjustments.defocus = lensPosition.map { max(0, 0.9 - $0) / 0.9 } ?? 0
        return adjustments
    }

    private func updateDemo() {
        renderer.setDemoAdjustments(demoAdjustments)
    }

    // MARK: - Capture

    /// The shutter button: shoots now, starts the self-timer, or cancels a
    /// running countdown.
    func shutterPressed(options: CaptureOptions) {
        guard canCapture else { cancelCountdown(); return }
        if countdown != nil {
            cancelCountdown()
            return
        }
        guard options.timer != .off, status == .running || status == .noCamera else {
            capture(options: options)
            return
        }
        countdown = options.timer.rawValue
        countdownTask = Task {
            while let left = countdown, left > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                countdown = left - 1
            }
            countdown = nil
            countdownTask = nil
            capture(options: options)
        }
    }

    func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    func capture(options: CaptureOptions = CaptureOptions()) {
        guard canCapture, !isCapturing else { return }
        let look = currentLook
        let style = captureStyle
        shutterCount += 1
        if status == .noCamera {
            captureDemoPhoto(look: look, id: advanceFrame(), aspect: options.aspect, style: style)
            return
        }
        guard status == .running else { return }
        let frameID = advanceFrame()
        isCapturing = true
        let flash = capabilities.hasFlash ? flashMode : .off
        Task {
            defer { isCapturing = false }
            do {
                var photo = try await captureService.capturePhoto(flash: flash, mirrorFront: options.mirrorFrontCamera,
                                                                  onShutter: {})
                photo.id = frameID
                photo.aspect = options.aspect
                photo.style = style
                onCapture?(photo, look)
            } catch {
                Logger.camera.error("Capture failed: \(error.localizedDescription, privacy: .public)")
                status = .failed(error.localizedDescription)
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    if case .failed = status { status = .running }
                }
            }
        }
    }

    /// In the Simulator the shutter "captures" the demo image so the rest of
    /// the app (review, saving, paywall) can be exercised without a camera.
    private func captureDemoPhoto(look: Look, id: UUID, aspect: AspectRatio, style: PhotoRecipe) {
        guard let url = DemoScene.url, var data = try? Data(contentsOf: url) else { return }
        // Bake the simulated settings in, as the camera would have.
        let adjustments = demoAdjustments
        if adjustments != DemoAdjustments(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]),
           let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
           let adjusted = CIContext().jpegRepresentation(of: adjustments.apply(to: image), colorSpace: sRGB, options: [:]) {
            data = adjusted
        }
        onCapture?(CapturedPhoto(data: data, isFrontCamera: false, aspect: aspect, id: id, style: style), look)
    }

    /// Returns the frame the preview is showing and moves on to a fresh one.
    private func advanceFrame() -> UUID {
        let frameID = nextFrameID
        nextFrameID = UUID()
        renderer.setSeed(nextFrameID.effectsSeed)
        return frameID
    }
}
