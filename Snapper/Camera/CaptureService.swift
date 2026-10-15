import AVFoundation
import OSLog

/// Owns the AVCaptureSession and everything that touches it.
///
/// The actor runs on a private serial queue (its executor), so session
/// configuration, start/stop and device changes never block the main thread.
/// Video frames go straight from AVFoundation to the preview renderer on the
/// renderer's own queue; the UI only hears about state through `events`.
actor CaptureService {
    private let sessionQueue = DispatchSerialQueue(label: "app.snapper.capture.session", qos: .userInitiated)

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        sessionQueue.asUnownedSerialExecutor()
    }

    nonisolated let events: AsyncStream<CaptureEvent>
    private let eventContinuation: AsyncStream<CaptureEvent>.Continuation

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoCapture = PhotoCapture()
    private let renderer: PreviewRenderer

    private var deviceInput: AVCaptureDeviceInput?
    private var position: CameraPosition = .back
    private var isConfigured = false
    private var wantsRunning = false
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var sessionObservers: [NSObjectProtocol] = []
    private var deviceObservers: [NSObjectProtocol] = []

    /// Multiplier from the device's zoom factor to the factor shown to people.
    /// On devices with an ultra-wide lens the device's 1.0 is shown as 0.5×.
    private var displayZoomMultiplier: CGFloat = 1

    init(renderer: PreviewRenderer) {
        self.renderer = renderer
        (events, eventContinuation) = AsyncStream.makeStream(of: CaptureEvent.self, bufferingPolicy: .bufferingNewest(32))
    }

    deinit {
        eventContinuation.finish()
    }

    /// Whether this device has any camera (false in the Simulator).
    nonisolated static var isCameraAvailable: Bool {
        device(for: .back) != nil || device(for: .front) != nil
    }

    // MARK: - Lifecycle

    /// Configures the session on first use and starts it.
    func start() throws {
        wantsRunning = true
        if !isConfigured {
            try configureSession()
        }
        if !session.isRunning {
            session.startRunning()
        }
        eventContinuation.yield(.running(session.isRunning))
    }

    func stop() {
        wantsRunning = false
        if session.isRunning {
            session.stopRunning()
        }
        eventContinuation.yield(.running(false))
    }

    // MARK: - Configuration

    private func configureSession() throws {
        let startPosition: CameraPosition = Self.device(for: .back) != nil ? .back : .front
        guard let device = Self.device(for: startPosition) else { throw CameraError.noCamera }
        let input = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        session.sessionPreset = .photo
        // Colour is managed explicitly (sRGB end to end, see `configure(device:)`).
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }
        session.addInput(input)
        deviceInput = input
        position = startPosition

        videoOutput.alwaysDiscardsLateVideoFrames = true
        let preferredFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let pixelFormat = videoOutput.availableVideoPixelFormatTypes.contains(preferredFormat)
            ? preferredFormat
            : kCVPixelFormatType_32BGRA
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
        videoOutput.setSampleBufferDelegate(renderer, queue: renderer.renderQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }
        session.addOutput(videoOutput)

        guard photoCapture.attach(to: session) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed
        }
        configureVideoConnection()
        session.commitConfiguration()

        configure(device: device)
        photoCapture.configure(for: device)
        observeSession()
        observe(device: device)
        isConfigured = true
        eventContinuation.yield(.configured(capabilities(for: device)))
    }

    /// Frames reach the renderer upright (portrait UI) and mirrored for the
    /// front camera, exactly as the photo will be.
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = position == .front
        }
    }

    private func configure(device: AVCaptureDevice) {
        displayZoomMultiplier = Self.displayZoomMultiplier(for: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
                device.activeColorSpace = .sRGB
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isLowLightBoostSupported {
                device.automaticallyEnablesLowLightBoostWhenAvailable = true
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            // Start on the main (1×) lens of multi-lens cameras.
            let standard = 1 / displayZoomMultiplier
            device.videoZoomFactor = min(max(standard, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
        } catch {
            Logger.camera.error("Could not configure device: \(error.localizedDescription, privacy: .public)")
        }

        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        photoCapture.rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.initial, .new]) { @Sendable [weak self] _, change in
            guard let self, let angle = change.newValue else { return }
            Task { await self.report(.captureOrientation(angle)) }
        }
    }

    private func report(_ event: CaptureEvent) {
        eventContinuation.yield(event)
    }

    // MARK: - Camera switching

    func switchCamera() throws {
        guard isConfigured else { throw CameraError.notRunning }
        let newPosition = position.toggled
        guard let device = Self.device(for: newPosition) else { throw CameraError.noCamera }
        let newInput = try AVCaptureDeviceInput(device: device)

        session.beginConfiguration()
        let oldInput = deviceInput
        if let oldInput { session.removeInput(oldInput) }
        if session.canAddInput(newInput) {
            session.addInput(newInput)
            deviceInput = newInput
            position = newPosition
        } else if let oldInput {
            session.addInput(oldInput)
        }
        configureVideoConnection()
        session.commitConfiguration()

        guard let active = deviceInput?.device else { throw CameraError.configurationFailed }
        configure(device: active)
        photoCapture.configure(for: active)
        observe(device: active)
        eventContinuation.yield(.configured(capabilities(for: active)))
    }

    // MARK: - Focus, exposure, zoom

    /// Focuses and meters at a point in device coordinates (0…1, landscape
    /// sensor orientation), the convention AVFoundation uses.
    func focus(at devicePoint: CGPoint) {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
        } catch {
            Logger.camera.error("Focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns to continuous auto focus and exposure at the centre.
    func resetFocus() {
        guard let device = deviceInput?.device else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
            if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        } catch {
            Logger.camera.error("Focus reset failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sets the zoom, in display units (1 = main lens). Returns the applied value.
    @discardableResult
    func setZoom(_ displayFactor: CGFloat, animated: Bool) -> CGFloat {
        guard let device = deviceInput?.device else { return displayFactor }
        let maxFactor = min(device.maxAvailableVideoZoomFactor, Self.maxDisplayZoom(for: device) / displayZoomMultiplier)
        let factor = min(max(displayFactor / displayZoomMultiplier, device.minAvailableVideoZoomFactor), maxFactor)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if animated {
                device.ramp(toVideoZoomFactor: factor, withRate: 8)
            } else {
                if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
                device.videoZoomFactor = factor
            }
        } catch {
            Logger.camera.error("Zoom failed: \(error.localizedDescription, privacy: .public)")
        }
        return factor * displayZoomMultiplier
    }

    // MARK: - Photo capture

    /// Takes a full-resolution photo. The returned data is the camera's
    /// HEIF/JPEG file with orientation (and front-camera mirroring) recorded in
    /// its metadata, matching how the live preview is shown.
    func capturePhoto(flash: FlashMode, onShutter: @escaping @Sendable () -> Void) async throws -> CapturedPhoto {
        guard isConfigured, session.isRunning else { throw CameraError.notRunning }
        let isFront = position == .front
        var captureID: Int64 = 0
        defer { photoCapture.release(captureID) }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            captureID = photoCapture.capture(flash: flash, mirrored: isFront, onShutter: onShutter) { result in
                continuation.resume(with: result)
            }
        }
        return CapturedPhoto(data: data, isFrontCamera: isFront)
    }

    // MARK: - Capabilities

    private func capabilities(for device: AVCaptureDevice) -> CameraCapabilities {
        let multiplier = displayZoomMultiplier
        var caps = CameraCapabilities()
        caps.position = position
        caps.hasFlash = device.hasFlash && photoCapture.supportsFlash
        caps.canSwitchCamera = Self.device(for: position.toggled) != nil
        caps.minZoom = device.minAvailableVideoZoomFactor * multiplier
        caps.maxZoom = min(device.maxAvailableVideoZoomFactor * multiplier, Self.maxDisplayZoom(for: device))
        caps.zoom = device.videoZoomFactor * multiplier
        caps.zoomPresets = Self.zoomPresets(for: device, multiplier: multiplier, maxZoom: caps.maxZoom)
        return caps
    }

    private static func hasUltraWide(_ device: AVCaptureDevice) -> Bool {
        device.deviceType == .builtInTripleCamera || device.deviceType == .builtInDualWideCamera
    }

    private static func displayZoomMultiplier(for device: AVCaptureDevice) -> CGFloat {
        guard hasUltraWide(device), let first = device.virtualDeviceSwitchOverVideoZoomFactors.first else { return 1 }
        let switchOver = CGFloat(truncating: first)
        return switchOver > 0 ? 1 / switchOver : 1
    }

    private static func maxDisplayZoom(for device: AVCaptureDevice) -> CGFloat {
        let multiplier = displayZoomMultiplier(for: device)
        let tele = device.virtualDeviceSwitchOverVideoZoomFactors.last.map { CGFloat(truncating: $0) * multiplier } ?? 1
        return max(10, tele * 3)
    }

    private static func zoomPresets(for device: AVCaptureDevice, multiplier: CGFloat, maxZoom: CGFloat) -> [CGFloat] {
        var presets: [CGFloat] = []
        if hasUltraWide(device) { presets.append(device.minAvailableVideoZoomFactor * multiplier) }
        presets.append(1)
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) * multiplier }
        for factor in switchOvers where factor > 1.01 {
            presets.append(factor)
        }
        if !presets.contains(where: { $0 > 1.01 }), maxZoom >= 2 {
            presets.append(2)
        }
        return presets.map { ($0 * 10).rounded() / 10 }.reduce(into: []) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    nonisolated static func device(for position: CameraPosition) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position.avPosition)
        for type in types {
            if let device = discovery.devices.first(where: { $0.deviceType == type }) {
                return device
            }
        }
        return nil
    }

    // MARK: - Notifications

    private func observeSession() {
        let center = NotificationCenter.default
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { @Sendable [weak self] note in
            guard let self else { return }
            let reason = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            Task { await self.handleInterruption(reason: reason) }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { @Sendable [weak self] _ in
            guard let self else { return }
            Task { await self.report(.interrupted(nil)) }
        })
        sessionObservers.append(center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { @Sendable [weak self] note in
            guard let self else { return }
            let code = (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code
            Task { await self.handleRuntimeError(code: code) }
        })
    }

    private func observe(device: AVCaptureDevice) {
        let center = NotificationCenter.default
        for observer in deviceObservers {
            center.removeObserver(observer)
        }
        deviceObservers = [
            center.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: device, queue: nil) { @Sendable [weak self] _ in
                guard let self else { return }
                Task { await self.handleSubjectAreaChange() }
            },
        ]
    }

    private func handleInterruption(reason: Int?) {
        let mapped: CameraInterruption
        switch reason.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:)) {
        case .videoDeviceInUseByAnotherClient, .audioDeviceInUseByAnotherClient:
            mapped = .inUseByAnotherApp
        case .videoDeviceNotAvailableDueToSystemPressure:
            mapped = .systemPressure
        case .videoDeviceNotAvailableInBackground:
            mapped = .background
        default:
            mapped = .other
        }
        eventContinuation.yield(.interrupted(mapped))
    }

    private func handleRuntimeError(code: Int?) {
        Logger.camera.error("Capture session runtime error \(code ?? -1)")
        if code == AVError.Code.mediaServicesWereReset.rawValue, wantsRunning {
            session.startRunning()
            eventContinuation.yield(.running(session.isRunning))
        } else if wantsRunning, !session.isRunning {
            eventContinuation.yield(.failed(String(localized: "The camera stopped unexpectedly.")))
        }
    }

    private func handleSubjectAreaChange() {
        resetFocus()
        eventContinuation.yield(.subjectAreaChanged)
    }
}
