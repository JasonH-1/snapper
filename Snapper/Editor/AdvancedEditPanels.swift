import SwiftUI

/// The Color tab: the colour mixer, or split toning.
struct ColorPanel: View {
    @Bindable var model: EditorModel
    @State private var showsSplitToning = false

    var body: some View {
        VStack(spacing: 8) {
            Picker("Color tool", selection: $showsSplitToning) {
                Text("Color Mixer").tag(false)
                Text("Split Toning").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            if showsSplitToning {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !model.hasPremiumNow {
                            Text("Premium split toning · preview free").font(.caption).foregroundStyle(Theme.accent)
                        }
                        SplitToningPanel(model: model)
                    }
                    .padding(.horizontal, 16)
                }
                .frame(maxHeight: 250)
            } else {
                ColorMixerPanel(model: model)
            }
        }
        .onAppear { showsSplitToning = model.recipe.adjustments.splitToning.isActive && !model.recipe.adjustments.colorMixer.isActive }
    }
}

struct ColorMixerPanel: View {
    @Bindable var model: EditorModel
    @State private var band = ColorBand.red
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !model.hasPremiumNow { Text("Premium color mixer · preview free").font(.caption).foregroundStyle(Theme.accent) }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(ColorBand.allCases) { option in
                            Button(option.title) { band = option }
                                .buttonStyle(.bordered).tint(option == band ? Theme.accent : .secondary)
                                .frame(minHeight: 44)
                                .accessibilityAddTraits(option == band ? .isSelected : [])
                        }
                    }
                }
                control("Hue", key: \.hue)
                control("Saturation", key: \.saturation)
                control("Luminance", key: \.luminance)
                Button("Reset color mixer") { model.resetColorMix() }.frame(minHeight: 44)
            }.padding(.horizontal, 16)
        }.frame(maxHeight: 250)
    }
    private func control(_ title: String, key: WritableKeyPath<ColorMix, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Slider(value: Binding(get: { model.recipe.adjustments.colorMixer[band][keyPath: key] }, set: { value in
                var mix = model.recipe.adjustments.colorMixer[band]
                mix[keyPath: key] = value
                model.setColorMix(mix, for: band)
            }), in: -1...1, onEditingChanged: { model.interaction(began: $0) })
                .tint(Theme.accent).accessibilityLabel("\(band.title) \(title)")
        }
    }
}

struct SelectiveEditPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.hasPremiumNow ? "Edits stay with this photo." : "Premium selective edits · preview free")
                    .font(.caption).foregroundStyle(Theme.accent)
                if model.isDetectingSubject {
                    ProgressView("Finding the subject on your iPhone…")
                } else if model.subjectDetectionFailed && model.recipe.selective.usesSubjectDetection {
                    Text("No clear subject was found. Paint the area you want to edit instead, or try detection again.")
                        .font(.caption)
                    HStack {
                        Button("Paint the Area") { model.paintSelectionManually() }
                            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                        Button("Retry Detection") { Task { await model.prepareSelective(retry: true) } }
                    }
                    .frame(minHeight: 44)
                } else if model.canEditSelection {
                    Picker("Mode", selection: $model.selectiveMode) {
                        Text("Adjust").tag(EditorModel.SelectiveMode.adjust)
                        Text("Refine Selection").tag(EditorModel.SelectiveMode.refine)
                    }
                    .pickerStyle(.segmented)
                    switch model.selectiveMode {
                    case .adjust: adjustControls
                    case .refine: brushControls
                    }
                }
                Button("Reset Selective Edits") { model.resetSelective() }
                    .frame(minHeight: 44)
                    .disabled(model.recipe.selective == SelectiveEdits())
            }
            .padding(.horizontal, 16)
        }
        .frame(maxHeight: 280)
        .task(id: model.recipe.crop) { await model.prepareSelective() }
    }

    // MARK: - Adjust

    @ViewBuilder
    private var adjustControls: some View {
        Picker("Area", selection: $model.editsBackground) {
            Text("Subject").tag(false)
            Text("Background").tag(true)
        }
        .pickerStyle(.segmented)
        Toggle(isOn: $model.showsMaskWhileAdjusting) {
            Label("Show Selection", systemImage: "circle.lefthalf.filled.righthalf.striped.horizontal")
        }
        .font(.subheadline)
        if model.showsMaskWhileAdjusting {
            Text("Red marks the \(model.editsBackground ? "background" : "subject"). Pinch the photo to check edges and hair.")
                .font(.caption).foregroundStyle(.secondary)
        }
        control("Brightness", key: \.brightness)
        control("Saturation", key: \.saturation)
        control("Warmth", key: \.warmth)
    }

    private func control(_ title: String, key: WritableKeyPath<SelectiveAdjustment, Double>) -> some View {
        let background = model.editsBackground
        return VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Slider(value: Binding(get: {
                (background ? model.recipe.selective.background : model.recipe.selective.subject)[keyPath: key]
            }, set: { model.setSelective($0, key: key, background: background) }), in: -1...1,
                   onEditingChanged: { model.interaction(began: $0) })
                .tint(Theme.accent).accessibilityLabel("\(background ? "Background" : "Subject") \(title)")
        }
    }

    // MARK: - Refine

    @ViewBuilder
    private var brushControls: some View {
        Picker("Brush", selection: $model.brushMode) {
            Label("Paint", systemImage: "paintbrush.pointed").tag(MaskStroke.Mode.paint)
            Label("Erase", systemImage: "eraser").tag(MaskStroke.Mode.erase)
        }
        .pickerStyle(.segmented)
        .accessibilityHint(Text("Paint adds to the subject; erase takes away from it."))
        Text(model.recipe.selective.usesSubjectDetection
             ? "Paint adds to the subject; erase takes it away. One finger paints, two fingers zoom and move."
             : "Paint the area to edit. One finger paints, two fingers zoom and move.")
            .font(.caption).foregroundStyle(.secondary)
        sliderRow(title: "Size", value: $model.brushSize, range: EditorModel.brushSizeRange,
                  display: "\(Int(model.brushSize.rounded())) pt")
        sliderRow(title: "Softness", value: $model.brushSoftness, range: 0...1,
                  display: "\(Int((model.brushSoftness * 100).rounded()))%")
        HStack(spacing: 16) {
            Button("Clear Brush Edits", systemImage: "trash") { model.clearBrushStrokes() }
                .disabled(!model.hasBrushStrokes)
            Spacer()
            if model.recipe.selective.usesSubjectDetection {
                Button("Paint from Scratch") { model.paintSelectionManually() }
            } else {
                Button("Detect Subject") { model.useSubjectDetection() }
            }
        }
        .font(.subheadline)
        .frame(minHeight: 44)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .tint(Theme.accent)
                .accessibilityLabel(Text("Brush \(title)"))
                .accessibilityValue(Text(display))
        }
    }
}
