import SwiftUI

/// Export settings for the photo being edited, with the real size of the
/// file they make: Snapper writes it in the background, and Save or Share
/// then use that same file.
struct ExportOptionsView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    estimateRow
                }

                Section {
                    Picker("Format", selection: binding(\.format)) {
                        Text("HEIF").tag(PhotoRenderer.ExportFormat.heic)
                        Text("JPEG").tag(PhotoRenderer.ExportFormat.jpeg)
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Format")
                } footer: {
                    Text(model.exportOptions.format == .heic
                         ? "HEIF files are about half the size of JPEG at the same quality."
                         : "JPEG opens in every app and on every website.")
                }

                Section("Size") {
                    Picker("Size", selection: binding(\.size)) {
                        ForEach(ExportOptions.Size.allCases) { size in
                            sizeLabel(size).tag(size)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Quality")
                            Spacer()
                            Text(model.exportOptions.quality, format: .percent.precision(.fractionLength(0)))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: binding(\.quality), in: ExportOptions.qualityRange, step: 0.05)
                            .tint(Theme.accent)
                            .accessibilityLabel(Text("Quality"))
                            .accessibilityValue(Text(model.exportOptions.quality, format: .percent.precision(.fractionLength(0))))
                    }
                } footer: {
                    Text("Higher quality keeps more fine detail and makes larger files. 90% is hard to tell from 100%.")
                }

                Section {
                    Toggle("Include Location", isOn: binding(\.includesLocation))
                } footer: {
                    if model.photoHasLocation {
                        Text(model.exportOptions.includesLocation
                             ? "This photo records where it was taken, and the place stays in saved and shared copies."
                             : "Saved and shared copies leave out where this photo was taken. The photo in Snapper keeps it.")
                    } else {
                        Text("This photo doesn't record where it was taken. The setting applies to photos that do.")
                    }
                }

                Section {
                    Button {
                        model.save()
                        dismiss()
                    } label: {
                        Label(model.isImported ? "Save Copy to Photos" : "Save to Photos", systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.isSaving)
                    Button {
                        model.share()
                    } label: {
                        HStack {
                            Label("Share", systemImage: "square.and.arrow.up")
                            if model.isPreparingShare {
                                Spacer()
                                ProgressView()
                            }
                        }
                    }
                    .disabled(model.isPreparingShare)
                } footer: {
                    Text("These settings are kept for every photo you save or share, and can also be changed in Settings.")
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $model.shareItem) { item in
                ShareSheet(items: [item.url])
                    .presentationDetents([.medium, .large])
                    .ignoresSafeArea()
            }
        }
        .onAppear { model.exportOptionsAppeared() }
        .onDisappear { model.exportOptionsDisappeared() }
    }

    // MARK: - Rows

    private var estimateRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("File Size")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Group {
                    if let prepared = model.preparedExport, !model.isMeasuringExport {
                        Text(prepared.byteCount, format: .byteCount(style: .file))
                    } else if model.exportMeasureFailed {
                        Text("Couldn't measure")
                    } else {
                        Text("Measuring…")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.title3.weight(.semibold).monospacedDigit())
                .contentTransition(.numericText())
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Text("Dimensions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(dimensionsText)
                    .font(.title3.weight(.semibold).monospacedDigit())
            }
        }
        .animation(.default, value: model.preparedExport?.byteCount)
        .accessibilityElement(children: .combine)
        .overlay(alignment: .bottom) {
            if model.isMeasuringExport {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Theme.accent)
                    .offset(y: 10)
            }
        }
    }

    private var dimensionsText: String {
        if let prepared = model.preparedExport, prepared.options == model.exportOptions {
            return Self.dimensions(prepared.pixelSize)
        }
        guard let full = model.fullExportSize else { return "—" }
        return Self.dimensions(model.exportOptions.outputSize(for: full))
    }

    private func sizeLabel(_ size: ExportOptions.Size) -> some View {
        var options = model.exportOptions
        options.size = size
        let detail: String
        if let full = model.fullExportSize {
            let output = options.outputSize(for: full)
            // A photo smaller than this size is never scaled up.
            let isSameAsFull = size != .full && output == ExportOptions(size: .full).outputSize(for: full)
            detail = isSameAsFull ? String(localized: "Same as Full · \(Self.dimensions(output))") : Self.dimensions(output)
        } else {
            detail = size.longEdge.map { String(localized: "Up to \($0) px") } ?? String(localized: "Original resolution")
        }
        return VStack(alignment: .leading, spacing: 2) {
            Text(size.title)
            Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    static func dimensions(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    private func binding<Value>(_ key: WritableKeyPath<ExportOptions, Value>) -> Binding<Value> {
        Binding(get: { model.exportOptions[keyPath: key] }, set: { value in
            var options = model.exportOptions
            options[keyPath: key] = value
            model.exportOptions = options
        })
    }
}

extension ExportOptions.Size {
    var title: LocalizedStringResource {
        switch self {
        case .full: "Full Resolution"
        case .large: "Large · 4K"
        case .medium: "Medium"
        case .small: "Small · for social"
        }
    }
}
