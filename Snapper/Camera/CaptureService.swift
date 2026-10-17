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
    /// Exposure compensation in stops, kept across camera switches.
    private var exposureBias: Float = 0
    /// While locked, focus and exposure stay put when the scene changes.
    private var isFocusLocked = false
    /// Manual ISO and shutter speed are set; taps then only move focus.
    private var isManualExposure = false
    /// A manual lens position is set; taps return focus to auto.
    private var isManualFocus = false

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
            isFocusLocked = false
            isManualExposure = false
            isManualFocus = false
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            device.setExposureTargetBias(Self.clamp(exposureBias, for: device), completionHandler: nil)
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
        isFocusLocked = false
        meter(at: devicePoint)
    }

    /// Focuses and meters at a point, then holds both (AE/AF lock) until the
    /// next tap, reset or camera switch, even if the scene changes.
    func lockFocusAndExposure(at devicePoint: CGPoint) {
        isFocusLocked = true
        meter(at: devicePoint)
        if let device = deviceInput?.device, (try? device.lockForConfiguration()) != nil {
            device.isSubjectAreaChangeMonitoringEnabled = false
            device.unlockForConfiguration()
        }
    }

    /// Sets exposure compensation in stops. Returns the value applied after
    /// clamping to what the device supports.
    @discardableResult
    func setExposureBias(_ bias: Float) -> Float {
        exposureBias = bias
        guard let device = deviceInput?.device else { return bias }
        let clamped = Self.clamp(bias, for: device)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.setExposureTargetBias(clamped, completionHandler: nil)
        } catch {
            Logger.camera.error("Exposure bias failed: \(error.localizedDescription, privacy: .public)")
        }
        return clamped
    }

    /// Uses temperature/tint on iOS 26, including virtual multi-lens cameras.
    /// Older systems may only use custom gains when the device explicitly supports them.
    func setWhiteBalance(_ preset: WhiteBalancePreset) {
        guard let device = deviceInput?.device else { return }
        let route = WhiteBalanceControl.route(
            preset: preset,
            supportsLocked: device.isWhiteBalanceModeSupported(.locked),
            supportsCustomGains: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsTemperature: Self.supportsTemperatureWhiteBalance)
        guard route != .unsupported else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            switch route {
            case .automatic:
                guard device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { return }
                device.whiteBalanceMode = .continuousAutoWhiteBalance
            case .temperature:
                guard #available(iOS 26.0, *), let kelvin = preset.temperature else { return }
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                device.setWhiteBalanceModeLocked(whiteBalanceTemperatureAndTintValues: values, handler: nil)
            case .deviceGains:
                guard let kelvin = preset.temperature else { return }
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: kelvin, tint: 0)
                let proposed = device.deviceWhiteBalanceGains(for: values)
                guard let gains = WhiteBalanceControl.validatedGains(proposed, maximum: device.maxWhiteBalanceGain) else { return }
                device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
            case .unsupported:
                return
            }
            eventContinuation.yield(.whiteBalanceChanged(preset))
        } catch {
            Logger.camera.error("White balance failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static var supportsTemperatureWhiteBalance: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// Holds the lens at `position` (0 = nearest, 1 = farthest), or returns
    /// to continuous auto focus when `position` is nil.
    func setLensPosition(_ position: Float?) {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let position, device.isLockingFocusWithCustomLensPositionSupported {
                isManualFocus = true
                device.setFocusModeLocked(lensPosition: min(max(position, 0), 1), completionHandler: nil)
            } else {
                isManualFocus = false
                if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            }
        } catch {
            Logger.camera.error("Lens position failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sets ISO and shutter speed (seconds) by hand, clamped to the device's
    /// range, or returns to auto exposure when `manual` is nil.
    func setManualExposure(_ manual: (iso: Float, shutter: Double)?) {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if let manual, device.isExposureModeSupported(.custom) {
                isManualExposure = true
                let format = device.activeFormat
                let iso = min(max(manual.iso, format.minISO), format.maxISO)
                let shortest = format.minExposureDuration.seconds, longest = format.maxExposureDuration.seconds
                let shutter = min(max(manual.shutter, shortest), longest)
                device.setExposureModeCustom(duration: CMTime(seconds: shutter, preferredTimescale: 1_000_000),
                                             iso: iso, completionHandler: nil)
            } else {
                isManualExposure = false
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
                device.setExposureTargetBias(Self.clamp(exposureBias, for: device), completionHandler: nil)
            }
        } catch {
            Logger.camera.error("Manual exposure failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// What auto exposure has chosen right now, as a starting point for manual.
    func currentExposure() -> (iso: Float, shutter: Double)? {
        guard let device = deviceInput?.device else { return nil }
        return (device.iso, device.exposureDuration.seconds)
    }

    /// The Photo Size setting, in megapixels.
    func setMaxMegapixels(_ megapixels: Int) {
        photoCapture.maxMegapixels = megapixels
        if let device = deviceInput?.device {
            photoCapture.configure(for: device)
        }
    }

    private static func clamp(_ bias: Float, for device: AVCaptureDevice) -> Float {
        min(max(bias, device.minExposureTargetBias), device.maxExposureTargetBias)
    }

    private func meter(at devicePoint: CGPoint) {
        guard let device = deviceInput?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if !isManualExposure, device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            isManualFocus = false
            device.isSubjectAreaChangeMonitoringEnabled = !isFocusLocked
        } catch {
            Logger.camera.error("Focus failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns to continuous auto focus and exposure at the centre.
    func resetFocus() {
        isFocusLocked = false
        guard let device = deviceInput?.device else { return }
        let center = CGPoint(x: 0.5, y: 0.5)
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = center }
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if !isManualExposure {
                if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = center }
                if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
            }
            isManualFocus = false
            device.isSubjectAreaChangeMonitoringEnabled = true
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
    func capturePhoto(flash: FlashMode, mirrorFront: Bool = true,
                      onShutter: @escaping @Sendable () -> Void) async throws -> CapturedPhoto {
        guard isConfigured, session.isRunning else { throw CameraError.notRunning }
        let isFront = position == .front
        var captureID: Int64 = 0
        defer { photoCapture.release(captureID) }
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            captureID = photoCapture.capture(flash: flash, mirrored: isFront && mirrorFront, onShutter: onShutter) { result in
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
        caps.minExposureBias = device.minExposureTargetBias
        caps.maxExposureBias = device.maxExposureTargetBias
        caps.supportsManualExposure = device.isExposureModeSupported(.custom)
        caps.minISO = device.activeFormat.minISO
        caps.maxISO = device.activeFormat.maxISO
        caps.minShutter = device.activeFormat.minExposureDuration.seconds
        // Long exposures blur hand-held shots; cap the slider at half a second.
        caps.maxShutter = min(device.activeFormat.maxExposureDuration.seconds, 0.5)
        caps.supportsManualFocus = device.isLockingFocusWithCustomLensPositionSupported
        caps.supportsWhiteBalance = WhiteBalanceControl.route(
            preset: .daylight, supportsLocked: device.isWhiteBalanceModeSupported(.locked),
            supportsCustomGains: device.isLockingWhiteBalanceWithCustomDeviceGainsSupported,
            supportsTemperature: Self.supportsTemperatureWhiteBalance) != .unsupported
        caps.photoMegapixels = PhotoCapture.megapixelOptions(for: device)
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
        guard !isFocusLocked, !isManualFocus else { return }
        resetFocus()
        eventContinuation.yield(.subjectAreaChanged)
    }
}
