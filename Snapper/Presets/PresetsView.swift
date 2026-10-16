import SwiftUI

/// Shared browser for single-photo editing and batch styling.
struct PresetsView: View {
    @Bindable var store: PresetStore
    let looks: LookLibrary
    let hasPremium: Bool
    var currentRecipe: PhotoRecipe?
    var onApply: (SavedPreset) -> Bool
    var onUpgrade: () -> Void

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
                    Text("Presets keep the look, strength and light adjustments. Each photo keeps its own crop, frame and date.")
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
                if let message { Text(message).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently) }
            }
            .navigationTitle("Personal Presets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
            .alert("Couldn't Save Preset", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(error ?? "") }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do { try operation() } catch { self.error = error.localizedDescription }
    }
    private func upgrade() { onUpgrade(); dismiss() }
}
