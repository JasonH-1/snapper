import SwiftUI

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
    @State private var background = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(model.hasPremiumNow ? "Edits stay with this photo." : "Premium selective edits · preview free")
                    .font(.caption).foregroundStyle(Theme.accent)
                if model.isDetectingSubject { ProgressView("Finding the subject on your iPhone…") }
                else if model.subjectDetectionFailed {
                    Text("No usable subject mask was found. Try a photo with a clear foreground subject.").font(.caption)
                    Button("Retry detection") { Task { await model.prepareSelective(retry: true) } }.frame(minHeight: 44)
                } else if let mask = model.subjectMaskPreview {
                    HStack {
                        Image(uiImage: mask).resizable().scaledToFit().frame(width: 70, height: 70)
                            .accessibilityLabel("Detected subject mask")
                        Text("White marks the subject; black marks the background. Check the edges before editing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Picker("Area", selection: $background) {
                        Text("Subject").tag(false)
                        Text("Background").tag(true)
                    }.pickerStyle(.segmented)
                    control("Brightness", key: \.brightness)
                    control("Saturation", key: \.saturation)
                    control("Warmth", key: \.warmth)
                }
                Button("Reset selective edits") { model.resetSelective() }
                    .frame(minHeight: 44).disabled(!model.recipe.selective.isActive)
            }.padding(.horizontal, 16)
        }
        .frame(maxHeight: 280)
        .task(id: model.recipe.crop) { await model.prepareSelective() }
    }
    private func control(_ title: String, key: WritableKeyPath<SelectiveAdjustment, Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption)
            Slider(value: Binding(get: {
                (background ? model.recipe.selective.background : model.recipe.selective.subject)[keyPath: key]
            }, set: { model.setSelective($0, key: key, background: background) }), in: -1...1,
                   onEditingChanged: { model.interaction(began: $0) })
                .tint(Theme.accent).accessibilityLabel("\(background ? "Background" : "Subject") \(title)")
        }
    }
}
