import SwiftUI

/// The versions of one photo: its original, how it was shot, and every named
/// edit kept with it. Tapping one shows it in the editor; nothing is lost by
/// switching, and Undo goes back.
struct VersionsView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    /// The name prompt: a new version, or renaming one.
    private enum Naming: Identifiable {
        /// Keep the edit showing (not yet a version) as one.
        case keepCurrent
        /// A new version starting from this recipe.
        case new(PhotoRecipe)
        case rename(PhotoVersion)

        var id: String {
            switch self {
            case .keepCurrent: "keep"
            case .new: "new"
            case .rename(let version): version.id.uuidString
            }
        }
    }

    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleteTarget: PhotoVersion?
    @State private var skippedLocked = 0

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if model.activeVersion == nil {
                        Button {
                            name = model.suggestedVersionName()
                            naming = .keepCurrent
                        } label: {
                            Label("Save Current Edit as Version", systemImage: "plus.square.on.square")
                        }
                        .disabled(!model.hasUnkeptEdit || isFull)
                    } else {
                        // A copy of the version showing, to take in another direction.
                        Button {
                            name = model.suggestedVersionName()
                            naming = .new(model.recipe)
                        } label: {
                            Label("Duplicate This Version", systemImage: "plus.square.on.square")
                        }
                        .disabled(isFull)
                    }
                    Button {
                        name = model.suggestedVersionName(for: model.originalRecipe)
                        naming = .new(model.originalRecipe)
                    } label: {
                        Label("New Version from Original", systemImage: "photo.badge.plus")
                    }
                    .disabled(isFull)
                } footer: {
                    if isFull {
                        Text("This photo has \(PhotoVersion.maxCount) versions, the most it can keep. Delete one to make another.")
                    } else {
                        Text("Keep different edits of this photo together, like Warm and Black & White. The version showing keeps every change, so switching never loses an edit.")
                    }
                }

                Section("This Photo") {
                    builtInRow(title: Text("Original"), detail: Text("No look or edits"),
                               image: model.originalThumbnail, recipe: model.originalRecipe)
                    if let asShot = model.asShotRecipe {
                        builtInRow(title: Text("As Shot"),
                                   detail: Text(model.looks.look(id: asShot.lookID)?.name ?? ""),
                                   image: model.asShotThumbnail, recipe: asShot)
                    }
                    if model.hasUnkeptEdit {
                        row(title: Text("Current Edit"), detail: Text("Not kept as a version yet"),
                            image: model.preview, isShowing: true, isSaving: false)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isSelected)
                    }
                }

                if !model.versions.isEmpty {
                    Section {
                        ForEach(model.versions) { version in
                            versionRow(version)
                        }
                    } header: {
                        Text("Versions")
                    } footer: {
                        if skippedLocked > 0 {
                            Text("\(skippedLocked) versions use Premium looks or tools and weren't saved.")
                        }
                    }

                    if model.versions.count > 1 {
                        Section {
                            Button {
                                skippedLocked = model.saveAllVersionsToPhotos()
                            } label: {
                                Label("Save All Versions to Photos", systemImage: "square.and.arrow.down.on.square")
                            }
                            .disabled(!model.savingVersionIDs.isEmpty)
                        }
                    }
                }
            }
            .navigationTitle("Versions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(namingTitle, isPresented: namingBinding, presenting: naming) { target in
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.words)
                Button("Save") {
                    switch target {
                    case .keepCurrent: model.saveVersion(named: name)
                    case .new(let recipe):
                        model.createVersion(named: name, from: recipe)
                        dismiss()
                    case .rename(let version): model.renameVersion(version, to: name)
                    }
                }
                .disabled(PhotoVersion.validName(name) == nil)
                Button("Cancel", role: .cancel) {}
            } message: { target in
                switch target {
                case .keepCurrent: Text("The current look and every edit are kept under this name.")
                case .new: Text("The new version opens in the editor; the others stay as they are.")
                case .rename: Text("")
                }
            }
            .confirmationDialog(Text("Delete “\(deleteTarget?.name ?? "")”?"), isPresented: deleteBinding,
                                titleVisibility: .visible, presenting: deleteTarget) { version in
                Button("Delete Version", role: .destructive) { model.deleteVersion(version) }
            } message: { _ in
                Text("The photo and its other versions stay. Copies already saved to Photos aren't affected.")
            }
            .task { await model.loadVersionThumbnails() }
            .sensoryFeedback(.success, trigger: model.versions.count) { old, new in new > old }
        }
    }

    // MARK: - Rows

    private var isFull: Bool { model.versions.count >= PhotoVersion.maxCount }

    private func builtInRow(title: Text, detail: Text, image: UIImage?, recipe: PhotoRecipe) -> some View {
        let isShowing = model.activeVersion == nil && model.recipe == recipe
        return Button {
            model.switchTo(recipe, version: nil)
            dismiss()
        } label: {
            row(title: title, detail: detail, image: image, isShowing: isShowing, isSaving: false)
        }
        .accessibilityAddTraits(isShowing ? .isSelected : [])
    }

    private func versionRow(_ version: PhotoVersion) -> some View {
        let isShowing = model.activeVersion?.id == version.id
        let look = model.looks.look(id: version.recipe.lookID) ?? .original
        let detail = Text("\(look.name) · \(version.createdAt.formatted(date: .abbreviated, time: .omitted))")
        return Button {
            model.switchTo(version.recipe, version: version)
            dismiss()
        } label: {
            row(title: Text(version.name), detail: detail, image: model.versionThumbnails[version.id],
                isShowing: isShowing, isSaving: model.savingVersionIDs.contains(version.id),
                isLocked: model.needsPremium(version.recipe))
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = version } label: { Label("Delete", systemImage: "trash") }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") {
                name = version.name
                naming = .rename(version)
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                name = model.suggestedVersionName(for: version.recipe)
                naming = .new(version.recipe)
            }
            .disabled(isFull)
            Button("Save to Photos", systemImage: "square.and.arrow.down") {
                model.saveVersionToPhotos(version)
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { deleteTarget = version }
        }
        .accessibilityAddTraits(isShowing ? .isSelected : [])
        .accessibilityHint(Text("Shows this version. Touch and hold for more options."))
    }

    private func row(title: Text, detail: Text, image: UIImage?, isShowing: Bool, isSaving: Bool,
                     isLocked: Bool = false) -> some View {
        HStack(spacing: 12) {
            Color.white.opacity(0.08)
                .frame(width: 52, height: 52)
                .overlay {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    title.font(.body.weight(.semibold)).foregroundStyle(.primary)
                    if isLocked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.accent)
                            .accessibilityLabel(Text("Premium"))
                    }
                }
                detail.font(.caption).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            if isSaving {
                ProgressView()
            } else if isShowing {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel(Text("Showing"))
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Bindings

    private var namingTitle: Text {
        switch naming {
        case .rename: Text("Rename Version")
        case .new: Text("New Version")
        default: Text("Name This Version")
        }
    }

    private var namingBinding: Binding<Bool> {
        Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }
}
