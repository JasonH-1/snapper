import SwiftUI

struct BatchFinishView: View {
    @Bindable var model: LibraryModel
    let records: [CaptureRecord]
    var onUpgrade: () -> Void
    var onShareAfterDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var options = BatchFinish()
    private let columns = [GridItem(.adaptive(minimum: 130))]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Finish \(records.count) photos together")
                        .font(.title3.weight(.semibold))
                    Text("Preview first. Each photo keeps its own crop, color edits and date stamp. Unchecked options keep existing finishing.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Toggle("Use the Same Frame", isOn: $options.replaceFrame)
                    if options.replaceFrame {
                        Picker("Frame", selection: $options.frame) {
                            ForEach(PhotoFinish.Frame.allCases) { Text($0.title).tag($0) }
                        }
                        if options.frame != .none {
                            LabeledContent("Border", value: "\(Int((options.border * 100).rounded()))%")
                            Slider(value: $options.border, in: 0.01...0.16, step: 0.01)
                                .accessibilityLabel("Border width")
                        }
                    }
                    Toggle("Use the Same Layout", isOn: $options.replaceLayout)
                    if options.replaceLayout {
                        Picker("Layout", selection: $options.layout) {
                            ForEach(PhotoFinish.Layout.allCases) { Text($0.title).tag($0) }
                        }
                    }
                    Text("Full photos fit inside each layout; nothing extra is cropped.")
                        .font(.footnote).foregroundStyle(.secondary)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(records) { record in
                            BatchFinishPreview(record: record, options: options, captures: model.captures)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Finish Photo Set")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    if !model.hasPremiumNow {
                        Text("Preview free · Batch finishing requires Premium").font(.footnote)
                    }
                    HStack {
                        Button("Apply") { apply(share: false) }.buttonStyle(.bordered)
                        Button("Apply & Share") { apply(share: true) }.buttonStyle(.borderedProminent)
                    }
                    .disabled(!options.hasChanges || records.isEmpty || model.isWorking)
                }
                .padding().frame(maxWidth: .infinity).background(.bar)
            }
        }
    }

    private func apply(share: Bool) {
        guard model.hasPremiumNow else { onUpgrade(); dismiss(); return }
        if model.applyFinishing(options, to: records) {
            if share { onShareAfterDismiss() }
            dismiss()
        }
    }
}

private struct BatchFinishPreview: View {
    let record: CaptureRecord
    let options: BatchFinish
    let captures: CaptureLibrary
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Color.gray.opacity(0.1)
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if failed {
                    Label("Preview unavailable", systemImage: "exclamationmark.triangle").font(.caption)
                } else { ProgressView() }
            }
            .frame(height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(record.recipe.finish.dateStamp ?? String(localized: "No date stamp"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task(id: options) {
            image = nil
            failed = false
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            guard !Task.isCancelled else { return }
            let rendered = await captures.renderer.thumbnail(sourceURL: captures.url(for: record),
                                                              look: captures.look(for: record),
                                                              recipe: options.applying(to: record.recipe),
                                                              seed: record.id.effectsSeed, maxPixelSize: 500)
            guard !Task.isCancelled else { return }
            image = rendered
            failed = rendered == nil
        }
    }
}
