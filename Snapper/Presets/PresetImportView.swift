import SwiftUI

/// Preview first; importing creates a new preset and never overwrites another.
struct PresetImportView: View {
    let file: PresetFile
    let store: PresetStore
    let looks: LookLibrary
    let hasPremium: Bool
    var onUpgrade: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var before: UIImage?
    @State private var after: UIImage?
    @State private var error: String?
    @State private var previewFailed = false
    private let renderer = PhotoRenderer()

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview on a Sample Photo") {
                    if let before, let after {
                        BeforeAfterView(before: before, after: after, autoSweep: false)
                            .frame(height: 260).clipped()
                    } else if previewFailed {
                        Text("Sample preview unavailable. Your preset settings are shown below.")
                    } else { ProgressView("Preparing preview…") }
                }
                Section("Preset") {
                    TextField("Name", text: $name)
                    LabeledContent("Look", value: looks.look(id: file.lookID)?.name ?? file.lookID)
                    LabeledContent("Strength", value: "\(Int(file.strength * 100))%")
                    ForEach(PhotoAdjustments.Kind.allCases) { kind in
                        LabeledContent(kind.rawValue.capitalized, value: "\(Int((file.adjustments[kind] * 100).rounded()))")
                    }
                    Text("Only the color style is imported. Your photos, crops, frames and dates stay as they are.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if looks.look(id: file.lookID)?.isPremium == true && !hasPremium {
                        Text("This uses a Premium look. You can preview it, but saving photos with it requires Premium.")
                    }
                }
                Section {
                    Button("Import Preset") {
                        guard hasPremium || store.presets.isEmpty else { onUpgrade(); dismiss(); return }
                        do {
                            try store.save(name: name, recipe: file.recipe, hasPremium: hasPremium)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.loadFailed)
                    if !hasPremium && !store.presets.isEmpty {
                        Text("Your free preset slot is in use. Premium adds unlimited presets; you can also cancel and delete a preset first.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Import Preset")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                name = file.name
                guard let url = DemoScene.url, let look = looks.look(id: file.lookID) else { previewFailed = true; return }
                let id = UUID()
                before = await renderer.original(id: id, sourceURL: url, maxPixelSize: 800)
                after = await renderer.preview(id: id, sourceURL: url, look: look, recipe: file.recipe, maxPixelSize: 800)
                previewFailed = before == nil || after == nil
            }
            .alert("Couldn't Import Preset", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }
}
