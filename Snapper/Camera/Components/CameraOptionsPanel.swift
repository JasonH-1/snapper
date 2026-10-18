import SwiftUI

/// Camera options over the bottom of the preview, on glass: a tab per
/// control (exposure, focus, white balance, ISO & shutter, aspect ratio) and
/// quick toggles for grid, level and self-timer.
struct CameraOptionsPanel: View {
    enum Tab: String, CaseIterable, Identifiable {
        case exposure, focus, whiteBalance, pro, ratio

        var id: String { rawValue }

        var symbolName: String {
            switch self {
            case .exposure: "plusminus.circle"
            case .focus: "scope"
            case .whiteBalance: "thermometer.sun"
            case .pro: "camera.aperture"
            case .ratio: "aspectratio"
            }
        }

        var title: String {
            switch self {
            case .exposure: String(localized: "Exposure")
            case .focus: String(localized: "Focus")
            case .whiteBalance: String(localized: "White Balance")
            case .pro: String(localized: "ISO & Shutter")
            case .ratio: String(localized: "Aspect Ratio")
            }
        }
    }

    @Bindable var model: CameraModel
    @Bindable var settings: AppSettings
    @Binding var tab: Tab

    /// Exposure moves in ⅓-stop steps, like the iPhone camera.
    nonisolated private static let step: Float = 1 / 3

    private var tabs: [Tab] {
        Tab.allCases.filter { tab in
            switch tab {
            case .focus: model.capabilities.supportsManualFocus
            case .whiteBalance: model.capabilities.supportsWhiteBalance
            case .pro: model.capabilities.supportsManualExposure
            case .exposure, .ratio: true
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            Text(tab.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
                .textCase(.uppercase)
            content
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            HStack(spacing: 8) {
                chip(symbol: "grid", title: Text("Grid"), isOn: settings.showGrid) { settings.showGrid.toggle() }
                chip(symbol: "level", title: Text("Level"), isOn: settings.showLevel) { settings.showLevel.toggle() }
                chip(symbol: "timer", title: Text("Timer \(settings.selfTimer.label)"), isOn: settings.selfTimer != .off) {
                    settings.selfTimer = settings.selfTimer.next
                }
            }
        }
        .padding(14)
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear {
            if !tabs.contains(tab) { tab = .exposure }
        }
        .onChange(of: tabs) { _, available in
            if !available.contains(tab) { tab = .exposure }
        }
    }

    // MARK: - Tabs

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { item in
                let isSelected = item == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { tab = item }
                } label: {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(isSelected ? .black : (isActive(item) ? Theme.accent : .white))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .glassSurface(in: Capsule(), tint: isSelected ? Theme.accent : nil, interactive: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(item.title))
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: tab)
    }

    /// A control changed from its default, to mark its tab.
    private func isActive(_ item: Tab) -> Bool {
        switch item {
        case .exposure: model.exposureBias != 0 || model.isFocusLocked
        case .focus: model.lensPosition != nil
        case .whiteBalance: model.whiteBalance != .auto
        case .pro: model.manualExposure != nil
        case .ratio: settings.aspectRatio != .fourThree
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .exposure: exposureControls
        case .focus: focusControls
        case .whiteBalance: whiteBalanceControls
        case .pro: proControls
        case .ratio: ratioControls
        }
    }

    // MARK: - Controls

    @ViewBuilder
    private var exposureControls: some View {
        if model.manualExposure != nil {
            HStack {
                Text("Set by ISO & Shutter")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                chip(symbol: "a.circle", title: Text("Use Auto"), isOn: false) { model.setManualExposure(false) }
                    .fixedSize()
            }
        } else {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    icon("sun.min", size: 14, opacity: 0.7)
                    Slider(value: Binding(get: { model.exposureBias },
                                          set: { model.setExposureBias(Self.snapped($0)) }),
                           in: model.exposureRange, step: Self.step)
                        .tint(Theme.accent)
                        .accessibilityLabel(Text("Exposure"))
                        .accessibilityValue(Text(Self.format(model.exposureBias)))
                    icon("sun.max.fill", size: 16, opacity: 0.85)
                    valueButton(Self.format(model.exposureBias), isChanged: model.exposureBias != 0) {
                        model.setExposureBias(0)
                    }
                    .accessibilityLabel(Text("Reset exposure"))
                }
                .sensoryFeedback(.selection, trigger: model.exposureBias)
                chip(symbol: model.isFocusLocked ? "lock.fill" : "lock.open", title: Text("AE/AF Lock"),
                     isOn: model.isFocusLocked) { model.toggleFocusLock() }
                    .accessibilityHint(Text("Holds focus and exposure where you last tapped"))
            }
        }
    }

    private var focusControls: some View {
        VStack(spacing: 10) {
            segmented(isManual: model.lensPosition != nil) { model.setManualFocus($0) }
            if let lens = model.lensPosition {
                HStack(spacing: 10) {
                    icon("camera.macro", size: 15, opacity: 0.8)
                    Slider(value: Binding(get: { lens }, set: { model.setLensPosition($0) }), in: 0...1)
                        .tint(Theme.accent)
                        .accessibilityLabel(Text("Focus distance"))
                        .accessibilityValue(Text(lens < 0.5 ? "Near" : "Far"))
                    icon("mountain.2", size: 15, opacity: 0.8)
                }
            }
        }
    }

    /// Two rows that fit the panel: Auto plus four presets.
    private var whiteBalanceControls: some View {
        let presets = WhiteBalancePreset.allCases.filter { $0 != .auto }
        return VStack(spacing: 8) {
            chip(symbol: WhiteBalancePreset.auto.symbolName, title: Text(WhiteBalancePreset.auto.label),
                 isOn: model.whiteBalance == .auto) { model.setWhiteBalance(.auto) }
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        model.setWhiteBalance(preset)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: preset.symbolName)
                                .font(.system(size: 15, weight: .semibold))
                            Text(preset.label)
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .foregroundStyle(model.whiteBalance == preset ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 46)
                        .glassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous),
                                      tint: model.whiteBalance == preset ? Theme.accent : nil, interactive: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(preset.label))
                    .accessibilityAddTraits(model.whiteBalance == preset ? .isSelected : [])
                }
            }
            if model.isChangingWhiteBalance {
                ProgressView("Switching camera…")
                    .font(.caption)
                    .tint(.white)
            } else if let message = model.whiteBalanceError {
                Text(message).font(.caption).foregroundStyle(.white)
            } else if model.capabilities.whiteBalanceRequiresMainCamera {
                Text(model.capabilities.whiteBalanceUsesMainCamera
                     ? "Main lens only. Zoom is digital; choose Auto to use 0.5× and other lenses."
                     : "Presets use the 1× main lens. Focus and exposure reset when switching lenses.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .disabled(model.isChangingWhiteBalance || model.isCapturing)
    }

    private var proControls: some View {
        VStack(spacing: 10) {
            segmented(isManual: model.manualExposure != nil) { model.setManualExposure($0) }
            if let manual = model.manualExposure {
                let caps = model.capabilities
                HStack(spacing: 10) {
                    Text("ISO").font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.8)).frame(width: 34, alignment: .leading)
                    Slider(value: Binding(get: { Self.position(of: Double(manual.iso), in: Double(caps.minISO)...Double(caps.maxISO)) },
                                          set: { model.setISO(Float(Self.value(at: $0, in: Double(caps.minISO)...Double(caps.maxISO)))) }))
                        .tint(Theme.accent)
                        .accessibilityLabel(Text("ISO"))
                        .accessibilityValue(Text("\(Int(manual.iso.rounded()))"))
                    valueText("\(Int(manual.iso.rounded()))")
                }
                HStack(spacing: 10) {
                    icon("timer", size: 14, opacity: 0.8).frame(width: 34, alignment: .leading)
                    Slider(value: Binding(get: { Self.position(of: manual.shutter, in: caps.minShutter...caps.maxShutter) },
                                          set: { model.setShutter(Self.value(at: $0, in: caps.minShutter...caps.maxShutter)) }))
                        .tint(Theme.accent)
                        .accessibilityLabel(Text("Shutter speed"))
                        .accessibilityValue(Text(Self.formatShutter(manual.shutter)))
                    valueText(Self.formatShutter(manual.shutter))
                }
            }
        }
    }

    private var ratioControls: some View {
        HStack(spacing: 8) {
            ForEach(AspectRatio.allCases, id: \.self) { ratio in
                chip(symbol: nil, title: Text(ratio.rawValue), isOn: settings.aspectRatio == ratio) {
                    settings.aspectRatio = ratio
                }
            }
        }
    }

    // MARK: - Pieces

    private func segmented(isManual: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 8) {
            chip(symbol: "a.circle", title: Text("Auto"), isOn: !isManual) { set(false) }
            chip(symbol: "hand.point.up.left", title: Text("Manual"), isOn: isManual) { set(true) }
        }
    }

    private func icon(_ name: String, size: CGFloat, opacity: Double) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white.opacity(opacity))
    }

    private func valueText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .semibold).monospacedDigit())
            .foregroundStyle(Theme.accent)
            .frame(width: 52)
    }

    private func valueButton(_ text: String, isChanged: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(isChanged ? Theme.accent : .white)
                .frame(width: 46, height: 30)
                .glassSurface(in: Capsule(), interactive: true)
        }
        .buttonStyle(.plain)
    }

    private func chip(symbol: String?, title: Text, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                }
                title
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(isOn ? .black : .white)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .glassSurface(in: Capsule(), tint: isOn ? Theme.accent : nil, interactive: true)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    // MARK: - Values

    nonisolated static func snapped(_ value: Float) -> Float {
        (value / step).rounded() * step
    }

    /// "+0.7", "0.0", "−1.3".
    nonisolated static func format(_ stops: Float) -> String {
        let rounded = (stops * 10).rounded() / 10
        if rounded == 0 { return "0.0" }
        return (rounded > 0 ? "+" : "−") + String(format: "%.1f", abs(rounded))
    }

    /// "1/250", "1/2", "0.5s" style shutter speeds.
    nonisolated static func formatShutter(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds >= 1 { return String(format: "%.1fs", seconds) }
        let denominator = 1 / seconds
        let rounded = denominator >= 10 ? (denominator / 5).rounded() * 5 : denominator.rounded()
        return "1/\(Int(max(rounded, 1)))"
    }

    /// Slider position 0…1 for `value` on a logarithmic scale (ISO and shutter
    /// speed work in doublings), and back.
    nonisolated static func position(of value: Double, in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return 0 }
        return min(max(log(value / range.lowerBound) / log(range.upperBound / range.lowerBound), 0), 1)
    }

    nonisolated static func value(at position: Double, in range: ClosedRange<Double>) -> Double {
        guard range.lowerBound > 0, range.upperBound > range.lowerBound else { return range.lowerBound }
        return range.lowerBound * pow(range.upperBound / range.lowerBound, min(max(position, 0), 1))
    }
}

/// Rule-of-thirds lines.
struct CameraGrid: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let w = geometry.size.width, h = geometry.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3, y = h * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h))
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(.white.opacity(0.35), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Darkens the parts of the preview outside the chosen aspect ratio.
struct AspectRatioMask: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geometry in
            let frame = CGRect(origin: .zero, size: geometry.size)
            let crop = aspect.crop(frame)
            Path { path in
                path.addRect(frame)
                path.addRect(crop)
            }
            .fill(.black.opacity(0.8), style: FillStyle(eoFill: true))
            .animation(.snappy(duration: 0.25), value: aspect)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
