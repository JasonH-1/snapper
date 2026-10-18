import SwiftUI
import UniformTypeIdentifiers

/// Shared browser for single-photo editing and batch styling.
struct PresetsView: View {
    @Bindable var store: PresetStore
    let looks: LookLibrary
    let hasPremium: Bool
    var currentRecipe: PhotoRecipe?
    var onApply: (SavedPreset) -> Bool
    var onUpgrade: () -> Void
    var onShoot: ((SavedPreset) -> Bool)?
    var samplePhotoURL: URL?
    @State private var isImporting = false
    @State private var incoming: PresetFile?
    @State private var shareItems: LibraryModel.ShareItems?
    @State private var sharedDirectory: URL?
    @State private var upgradeAfterImport = false
    @State private var isPreparingShare = false

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var renaming: SavedPreset?
    @State private var renameText = ""
    @State private var deleting: SavedPreset?
    @State private var message: String?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Presets keep the look, strength, color and film adjustments. Each photo keeps its own crop, frame, date and selective edits.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if !hasPremium {
                        Text("One personal preset is included free. Premium unlocks unlimited presets and batch styling.")
                            .font(.footnote)
                    }
                    if store.loadFailed {
                        Text(PresetStore.StoreError.unavailable.localizedDescription).foregroundStyle(.red)
                    }
                }
                if currentRecipe != nil {
                    Section("Save This Style") {
                        TextField("Preset name", text: $name)
                            .textInputAutocapitalization(.words)
                        Button("Save Preset", systemImage: "plus.circle") {
                            guard hasPremium || store.presets.isEmpty else { upgrade(); return }
                            perform {
                                guard let currentRecipe else { return }
                                try store.save(name: name, recipe: currentRecipe, hasPremium: hasPremium)
                                name = ""
                                message = String(localized: "Preset saved")
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.loadFailed)
                    }
                }
                Section {
                    Button("Import Preset File", systemImage: "square.and.arrow.down") { isImporting = true }
                        .disabled(store.loadFailed)
                    Text("Open a .snapperpreset file shared by a friend. You can preview it before importing.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Your Presets") {
                    if store.presets.isEmpty {
                        Text("Edit a photo, then open Presets to save your first style.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(store.presets) { preset in
                        HStack {
                            Button {
                                guard store.canUse(preset, hasPremium: hasPremium) else { upgrade(); return }
                                if onApply(preset) { dismiss() }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(preset.name).font(.headline)
                                        if !store.canUse(preset, hasPremium: hasPremium) {
                                            Image(systemName: "lock.fill").font(.caption)
                                        }
                                    }
                                    Text(looks.look(id: preset.lookID)?.name ?? String(localized: "Unavailable look"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(looks.look(id: preset.lookID) == nil)
                            Menu {
                                if let onShoot {
                                    Button("Shoot with This Preset", systemImage: "camera") {
                                        guard store.canUse(preset, hasPremium: hasPremium) else { upgrade(); return }
                                        if onShoot(preset) { dismiss() }
                                    }
                                    .disabled(looks.look(id: preset.lookID) == nil)
                                }
                                Button("Share Preset File", systemImage: "square.and.arrow.up") { share(preset, card: false) }
                                    .disabled(isPreparingShare)
                                Button("Share Style Card", systemImage: "photo") {
                                    guard store.canUse(preset, hasPremium: hasPremium),
                                          hasPremium || (looks.look(id: preset.lookID)?.isPremium == false && currentRecipe?.requiresPremium != true) else { upgrade(); return }
                                    share(preset, card: true)
                                }
                                .disabled(isPreparingShare || looks.look(id: preset.lookID) == nil)
                                Button("Rename", systemImage: "pencil") { renameText = preset.name; renaming = preset }
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    guard hasPremium || store.presets.isEmpty else { upgrade(); return }
                                    perform { try store.duplicate(preset, hasPremium: hasPremium) }
                                }
                                if !hasPremium && store.presets.first?.id != preset.id {
                                    Button("Use as My Free Preset", systemImage: "checkmark.circle") {
                                        perform { try store.makeFreePreset(preset) }
                                    }
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) { deleting = preset }
                            } label: {
                                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(Text("Manage \(preset.name)"))
                        }
                        .padding(.vertical, 4)
                    }
                }
                if isPreparingShare { ProgressView("Preparing style to share…") }
                if let message { Text(message).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            }
            .fileImporter(isPresented: $isImporting, allowedContentTypes: [.snapperPreset, .json]) { result in
                perform { incoming = try PresetFile.read(result.get(), looks: looks) }
            }
            .sheet(item: $incoming, onDismiss: {
                if upgradeAfterImport { upgradeAfterImport = false; upgrade() }
            }) { file in
                PresetImportView(file: file, store: store, looks: looks, hasPremium: hasPremium,
                                 onUpgrade: { upgradeAfterImport = true })
            }
            .sheet(item: $shareItems, onDismiss: cleanupShare) { items in
                ShareSheet(items: items.urls)
            }
            .navigationTitle("Personal Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(isPreparingShare) } }
            .interactiveDismissDisabled(isPreparingShare)
            .alert("Rename Preset", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Save") {
                    if let renaming { perform { try store.rename(renaming, to: renameText) } }
                    renaming = nil
                }
            }
            .confirmationDialog("Delete preset?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let deleting { perform { try store.delete(deleting) } }
                    deleting = nil
                }
            } message: { Text("Photos already edited with this preset keep their edits.") }
            .alert("Couldn't Complete Preset Action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func cleanupShare() {
        if let sharedDirectory { try? FileManager.default.removeItem(at: sharedDirectory) }
        sharedDirectory = nil
    }

    private func share(_ preset: SavedPreset, card: Bool) {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task { @MainActor in
            defer { isPreparingShare = false }
            do {
                cleanupShare()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                sharedDirectory = directory
                let file = directory.appendingPathComponent("Snapper-Preset.snapperpreset")
                try PresetDocument(preset).data.write(to: file, options: .atomic)
                var urls = [file]
                if card {
                    guard let source = samplePhotoURL ?? DemoScene.url, let look = looks.look(id: preset.lookID),
                          let photo = await PhotoRenderer().preview(id: UUID(), sourceURL: source, look: look,
                                                                   recipe: preset.applying(to: currentRecipe ?? .untouched), maxPixelSize: 1200),
                          let data = StyleCard.image(photo: photo, preset: preset, lookName: look.name,
                                                     isSample: samplePhotoURL == nil).jpegData(compressionQuality: 0.92) else {
                        throw PhotoRenderer.RenderError.unreadableImage
                    }
                    let image = directory.appendingPathComponent("Snapper-Style.jpg")
                    try data.write(to: image, options: .atomic)
                    urls.insert(image, at: 0)
                }
                shareItems = LibraryModel.ShareItems(urls: urls)
            } catch { cleanupShare(); self.error = error.localizedDescription }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    private func upgrade() { onUpgrade(); dismiss() }
}
