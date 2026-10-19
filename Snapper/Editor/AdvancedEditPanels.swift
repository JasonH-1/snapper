import SwiftUI

/// The Color tab: the colour mixer, or split toning, with their resets in
/// one menu (like Curves).
struct ColorPanel: View {
    @Bindable var model: EditorModel
    @State private var showsSplitToning = false
    @State private var band = ColorBand.red

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Picker("Color tool", selection: $showsSplitToning) {
                    Text("Color Mixer").tag(false)
                    Text("Split Toning").tag(true)
                }
                .pickerStyle(.segmented)
                resetMenu
            }
            .padding(.horizontal, 16)
            if !model.hasPremiumNow {
                PremiumPreviewNote(text: showsSplitToning ? "Premium split toning · preview free" : "Premium color mixer · preview free")
            }
            FitOrScroll {
                Group {
                    if showsSplitToning {
                        SplitToningPanel(model: model)
                    } else {
                        ColorMixerPanel(model: model, band: $band)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: 260)
        .onAppear { showsSplitToning = model.recipe.adjustments.splitToning.isActive && !model.recipe.adjustments.colorMixer.isActive }
    }

    private var resetMenu: some View {
        Menu {
            if showsSplitToning {
                Button("Reset Split Toning", systemImage: "arrow.counterclockwise", role: .destructive) { model.resetSplitToning() }
                    .disabled(model.splitToning == .none)
            } else {
                Button("Reset \(band.title)", systemImage: "arrow.counterclockwise") { model.setColorMix(ColorMix(), for: band) }
                    .disabled(!model.recipe.adjustments.colorMixer[band].isActive)
                Button("Reset All Colors", systemImage: "arrow.counterclockwise.circle", role: .destructive) { model.resetColorMix() }
                    .disabled(!model.recipe.adjustments.colorMixer.isActive)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .minimumTapTarget()
        }
        .accessibilityLabel(Text("Color options"))
    }
}

/// Hue, saturation and luminance for one colour at a time, chosen from a
/// row of swatches.
struct ColorMixerPanel: View {
    @Bindable var model: EditorModel
    @Binding var band: ColorBand

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                ForEach(ColorBand.allCases) { swatch($0) }
            }
            .padding(.horizontal, 4)
            .background(.white.opacity(0.05), in: Capsule())
            .sensoryFeedback(.selection, trigger: band)
            ProSlider(title: String(localized: "Hue"), value: binding(\.hue), gradient: band.hueTrack,
                      onEditingChanged: { model.interaction(began: $0) })
            ProSlider(title: String(localized: "Saturation"), value: binding(\.saturation), gradient: band.saturationTrack,
                      onEditingChanged: { model.interaction(began: $0) })
            ProSlider(title: String(localized: "Luminance"), value: binding(\.luminance), gradient: band.luminanceTrack,
                      onEditingChanged: { model.interaction(began: $0) })
        }
    }

    /// A colour, and nothing else: a ring marks the one being edited, a dot
    /// under it the ones already changed.
    private func swatch(_ option: ColorBand) -> some View {
        let isSelected = option == band
        let isChanged = model.recipe.adjustments.colorMixer[option].isActive
        return Button {
            band = option
        } label: {
            ColorSwatch(color: option.color, isChanged: isChanged, isSelected: isSelected)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(option.title))
        .accessibilityValue(isChanged ? Text("Changed") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func binding(_ key: WritableKeyPath<ColorMix, Double>) -> Binding<Double> {
        Binding(get: { model.recipe.adjustments.colorMixer[band][keyPath: key] }, set: { value in
            var mix = model.recipe.adjustments.colorMixer[band]
            mix[keyPath: key] = value
            model.setColorMix(mix, for: band)
        })
    }
}

/// One colour in the mixer: a flat disc.
private struct ColorSwatch: View {
    let color: Color
    let isChanged: Bool
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 26, height: 26)
            .padding(4)
            .overlay(Circle().strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2))
            .overlay(alignment: .bottom) {
                Circle()
                    .fill(isChanged ? Color.white : .clear)
                    .frame(width: 4, height: 4)
                    .offset(y: 8)
            }
            .scaleEffect(isSelected ? 1.08 : 1)
            .animation(.snapper(Motion.quick, reduceMotion: reduceMotion), value: isSelected)
    }
}

extension ColorBand {
    /// The colour this band picks out of the photo.
    var color: Color { Self.color(hue: center) }

    /// The hue shift runs up to 30° either way (see ColorMixRendering).
    var hueTrack: [Color] { stride(from: -30.0, through: 30, by: 10).map { Self.color(hue: center + $0) } }
    var saturationTrack: [Color] {
        [Color(white: 0.55), Self.color(hue: center, saturation: 0.45), Self.color(hue: center)]
    }
    var luminanceTrack: [Color] {
        [Self.color(hue: center, brightness: 0.3), Self.color(hue: center), Self.color(hue: center, saturation: 0.3, brightness: 1)]
    }

    private static func color(hue: Double, saturation: Double = 0.85, brightness: Double = 0.95) -> Color {
        let wrapped = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return Color(hue: wrapped / 360, saturation: saturation, brightness: brightness)
    }
}

/// Small yellow line at the top of a Premium tool: what it is, and that
/// trying it is free.
struct PremiumPreviewNote: View {
    let text: LocalizedStringKey

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
    }
}

/// Edits for the subject and the background separately, and a brush to
/// refine which is which.
struct SelectiveEditPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 6) {
            if !model.hasPremiumNow {
                PremiumPreviewNote(text: "Premium selective edits · preview free")
            }
            FitOrScroll {
                VStack(alignment: .leading, spacing: 8) {
                    if model.isDetectingSubject {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Finding the subject…")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    } else if model.subjectDetectionFailed && model.recipe.selective.usesSubjectDetection {
                        noSubjectFound
                    } else if model.canEditSelection {
                        HStack(spacing: 8) {
                            Picker("Tool", selection: tool) {
                                Text("Adjust").tag(Tool.adjust)
                                Text("Paint").tag(Tool.paint)
                                Text("Erase").tag(Tool.erase)
                            }
                            .pickerStyle(.segmented)
                            resetMenu
                        }
                        switch model.selectiveMode {
                        case .adjust: adjustControls
                        case .refine: brushControls
                        }
                    } else {
                        startChoices
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxHeight: 280)
        .task(id: DetectionKey(crop: model.recipe.crop, usesDetection: model.recipe.selective.usesSubjectDetection)) {
            await model.prepareSelective()
        }
    }

    /// What the selection starts from. Reset and Undo can switch subject
    /// detection back on without the crop changing, so both count.
    private struct DetectionKey: Equatable {
        let crop: PhotoCrop
        let usesDetection: Bool
    }

    /// One control for what a finger does: adjust the sliders, or paint or
    /// erase the selection.
    private enum Tool: Hashable { case adjust, paint, erase }

    private var tool: Binding<Tool> {
        Binding(get: {
            guard model.selectiveMode == .refine else { return .adjust }
            return model.brushMode == .paint ? .paint : .erase
        }, set: { tool in
            switch tool {
            case .adjust: model.selectiveMode = .adjust
            case .paint: model.brushMode = .paint; model.selectiveMode = .refine
            case .erase: model.brushMode = .erase; model.selectiveMode = .refine
            }
        })
    }

    /// Before a selection exists: the two ways to make one.
    private var startChoices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Edit the subject and background separately: find the subject, or paint the area yourself.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                actionButton(String(localized: "Find Subject"), systemImage: "person.crop.rectangle") { model.useSubjectDetection() }
                actionButton(String(localized: "Paint Area"), systemImage: "paintbrush.pointed") { model.paintSelectionManually() }
            }
        }
    }

    /// When detection finds nobody: say so, and offer both ways on.
    private var noSubjectFound: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("No clear subject found")
                    .font(.subheadline.weight(.semibold))
                Text("Paint over the part you want to edit, or try finding the subject again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                actionButton(String(localized: "Paint Area"), systemImage: "paintbrush.pointed") { model.paintSelectionManually() }
                actionButton(String(localized: "Try Again"), systemImage: "arrow.clockwise") {
                    Task { await model.prepareSelective(retry: true) }
                }
            }
        }
    }

    private var resetMenu: some View {
        Menu {
            Button("Reset Selective Edits", systemImage: "arrow.counterclockwise", role: .destructive) { model.resetSelective() }
                .disabled(model.recipe.selective == SelectiveEdits())
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.body.weight(.semibold))
                .minimumTapTarget()
        }
        .accessibilityLabel(Text("Selective edit options"))
    }

    // MARK: - Adjust

    @ViewBuilder
    private var adjustControls: some View {
        HStack(spacing: 8) {
            Picker("Area", selection: $model.editsBackground) {
                Text("Subject").tag(false)
                Text("Background").tag(true)
            }
            .pickerStyle(.segmented)
            // Shows the selection in red over the photo.
            Button {
                model.showsMaskWhileAdjusting.toggle()
            } label: {
                Image(systemName: model.showsMaskWhileAdjusting ? "eye.fill" : "eye")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(model.showsMaskWhileAdjusting ? Theme.accent : .white)
                    .contentTransition(.symbolEffect(.replace))
                    .minimumTapTarget()
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(Text("Show Selection"))
            .accessibilityAddTraits(model.showsMaskWhileAdjusting ? .isSelected : [])
        }
        if model.showsMaskWhileAdjusting {
            Text("Red marks the \(model.editsBackground ? "background" : "subject"). Pinch the photo to check edges and hair.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        control(String(localized: "Brightness"), key: \.brightness, gradient: [Color(white: 0.12), Color(white: 0.92)])
        control(String(localized: "Saturation"), key: \.saturation,
                gradient: [Color(white: 0.55), Color(hue: 0.95, saturation: 0.75, brightness: 0.95), Color(hue: 0.08, saturation: 0.9, brightness: 1)])
        control(String(localized: "Warmth"), key: \.warmth,
                gradient: [Color(red: 0.35, green: 0.6, blue: 1), Color(white: 0.85), Color(red: 1, green: 0.7, blue: 0.25)])
    }

    private func control(_ title: String, key: WritableKeyPath<SelectiveAdjustment, Double>, gradient: [Color]) -> some View {
        let background = model.editsBackground
        return ProSlider(title: title, value: Binding(get: {
            (background ? model.recipe.selective.background : model.recipe.selective.subject)[keyPath: key]
        }, set: { model.setSelective($0, key: key, background: background) }), gradient: gradient,
                         onEditingChanged: { model.interaction(began: $0) })
    }

    // MARK: - Refine

    @ViewBuilder
    private var brushControls: some View {
        Text(brushHint)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ProSlider(title: String(localized: "Size"), value: $model.brushSize, range: EditorModel.brushSizeRange,
                  defaultValue: EditorModel.defaultBrushSize, format: { "\(Int($0.rounded())) pt" })
        ProSlider(title: String(localized: "Softness"), value: $model.brushSoftness, range: 0...1,
                  defaultValue: EditorModel.defaultBrushSoftness, format: ProSlider.percent)
        HStack(spacing: 10) {
            actionButton(String(localized: "Clear Strokes"), systemImage: "trash") { model.clearBrushStrokes() }
                .disabled(!model.hasBrushStrokes)
            if model.recipe.selective.usesSubjectDetection {
                actionButton(String(localized: "Paint Manually"), systemImage: "paintbrush.pointed") { model.paintSelectionManually() }
            } else {
                actionButton(String(localized: "Find Subject"), systemImage: "person.crop.rectangle") { model.useSubjectDetection() }
            }
        }
    }

    private var brushHint: LocalizedStringKey {
        switch (model.brushMode, model.recipe.selective.usesSubjectDetection) {
        case (.paint, true): "Paint to add to the subject. Two fingers zoom and move."
        case (.paint, false): "Paint over the part to edit. Two fingers zoom and move."
        case (.erase, _): "Paint over what shouldn't be edited. Two fingers zoom and move."
        }
    }

    /// One of a pair of equal, full-width secondary actions.
    private func actionButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 44)
                .hairlineControl(cornerRadius: 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}
