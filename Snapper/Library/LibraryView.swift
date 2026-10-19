import PhotosUI
import SwiftUI

/// The Library: every photo taken with Snapper or imported, by day. Filter
/// chips at the top, + to import, Select for batch actions; tap a photo to
/// edit it.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    var onClose: () -> Void
    var onShowPaywall: () -> Void
    var onShootPreset: ((SavedPreset) -> Bool)?

    @Environment(\.openURL) private var openURL
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var upgradeAfterPresets = false
    @State private var finishing: FinishSelection?
    @State private var upgradeAfterFinish = false
    @State private var shareAfterFinish = false

    private struct FinishSelection: Identifiable {
        let id = UUID()
        let records: [CaptureRecord]
    }
    /// Photos waiting on the delete confirmation: the selection, or the one
    /// photo whose context menu was used (kept apart from the selection).
    @State private var deleteTarget: Set<UUID>?
    /// Photos grow into the editor from their grid cell and shrink back.
    @Namespace private var photoZoom

    private var animation: Animation? { .snapper(Motion.standard, reduceMotion: reduceMotion) }
    /// Slides in and out from the bottom, or just fades with Reduce Motion.
    private var bottomTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            content
                .background(Theme.canvas.ignoresSafeArea())
                .navigationTitle(model.isSelecting ? selectionTitle : "")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .navigationDestination(item: $model.editor) { editor in
                    EditorView(model: editor, onShowPaywall: onShowPaywall, onShootPreset: onShootPreset)
                        .zoomTransition(from: editor.id, in: photoZoom)
                }
        }
        // While editing, a downward drag belongs to the editor, not to closing the Library.
        .interactiveDismissDisabled(model.editor != nil)
        .sheet(item: $model.shareItems) { items in
            ShareSheet(items: items.urls)
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .sheet(isPresented: $model.isChoosingLook) {
            LookPickerView(library: model.looks, selectedID: "", hasPremium: model.hasPremiumNow, settings: model.settings,
                           thumbnails: model.lookThumbnails, title: String(localized: "Apply a Look")) { look in
                model.applyLookToSelection(look)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $model.isChoosingPreset, onDismiss: {
            if upgradeAfterPresets { upgradeAfterPresets = false; onShowPaywall() }
        }) {
            PresetsView(store: model.settings.presets, looks: model.looks, hasPremium: model.hasPremiumNow,
                        onApply: { model.applyPresetToSelection($0) },
                        onUpgrade: { upgradeAfterPresets = true })
        }
        .sheet(item: $finishing, onDismiss: {
            if upgradeAfterFinish { upgradeAfterFinish = false; onShowPaywall() }
            else if shareAfterFinish { shareAfterFinish = false; model.shareSelected() }
        }) { selected in
            BatchFinishView(model: model, records: selected.records,
                            onUpgrade: { upgradeAfterFinish = true },
                            onShareAfterDismiss: { shareAfterFinish = true })
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible, presenting: deleteTarget) { ids in
            Button("Delete", role: .destructive) {
                withAnimation(animation) { model.delete(ids) }
            }
        } message: { ids in
            Text(ids.count == 1
                 ? "It will be removed from Snapper. Copies already saved to your photo library are not affected."
                 : "They will be removed from Snapper. Copies already saved to your photo library are not affected.")
        }
        .confirmationDialog(lockedExportTitle, isPresented: lockedExportBinding, titleVisibility: .visible,
                            presenting: model.lockedExport) { pending in
            Button(pending.action == .save ? "Save Without Premium Looks & Tools" : "Share Without Premium Looks & Tools") {
                model.exportWithoutPremium(pending)
            }
            Button("Unlock Premium") { model.unlock(pending) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Free to save: crops and free edits stay. The full edits stay in Snapper, ready if you unlock Premium.")
        }
        .alert(alertTitle, isPresented: alertBinding, presenting: model.alert) { alert in
            switch alert {
            case .photosAccessDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            case .error:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .photosAccessDenied:
                Text("Allow Snapper to add photos in Settings to save your shots to your library.")
            case .error(let message):
                Text(message)
            }
        }
    }

    private var selectionTitle: String {
        model.selection.isEmpty ? String(localized: "Select Photos") : String(localized: "\(model.selection.count) Selected")
    }

    private var deleteTitle: Text {
        Text("Delete \(LibraryModel.photoCount(deleteTarget?.count ?? 0))?")
    }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var lockedExportTitle: Text {
        let count = model.lockedExport?.lockedCount ?? 0
        return count == 1 ? Text("1 photo uses a Premium look or tools") : Text("\(count) photos use Premium looks or tools")
    }

    private var lockedExportBinding: Binding<Bool> {
        Binding(get: { model.lockedExport != nil }, set: { if !$0 { model.lockedExport = nil } })
    }

    private var alertTitle: Text {
        switch model.alert {
        case .photosAccessDenied: Text("Photo access needed")
        case .error: Text("Couldn't finish")
        case nil: Text("")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if model.isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    withAnimation(animation) { model.isSelecting = false }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(model.allVisibleSelected ? "Deselect All" : "Select All") {
                    model.toggleSelectAll()
                }
                .disabled(model.visibleRecords.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .fontWeight(.semibold)
                        Text("Camera")
                    }
                }
                .accessibilityLabel(Text("Back to camera"))
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") {
                    withAnimation(animation) { model.isSelecting = true }
                }
                .disabled(model.records.isEmpty)
            }
            // Its own glass capsule, apart from Select.
            if #available(iOS 26, *) {
                ToolbarSpacer(.fixed, placement: .topBarTrailing)
            }
            ToolbarItem(placement: .topBarTrailing) {
                importButton
            }
        }
    }

    private var importButton: some View {
        PhotosPicker(selection: $model.pickerItems, maxSelectionCount: 50, selectionBehavior: .ordered,
                     matching: .images, preferredItemEncoding: .current) {
            // The same icon as the badge on imported photos.
            Label("Import", systemImage: "square.and.arrow.down")
                .fontWeight(.semibold)
                .foregroundStyle(.black)
        }
        .buttonStyle(.borderedProminent)
        .tint(Theme.accent)
        .disabled(model.importProgress != nil)
        .accessibilityLabel(Text("Import photos"))
    }

    // MARK: - Grid

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !model.isSelecting { studioHeader }
                if model.isSelecting {
                    Text(model.selection.isEmpty ? "Choose photos to style, frame, or share together." : "Your set is ready. Choose Style to apply a look or add frames.")
                        .font(.subheadline).foregroundStyle(.secondary).padding(.horizontal, 16)
                }
                if let style = model.copiedStyle {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.clipboard").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Style copied: \(style.name)").font(.subheadline.weight(.semibold))
                            Text("Paste from a photo’s menu, or select a set.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if model.isSelecting {
                            Button("Paste") { model.pasteStyle(to: model.selection) }
                                .disabled(model.selection.isEmpty || model.isWorking)
                        }
                    }
                    .padding(14).background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 16)
                }
                filterChips
                if model.sections.isEmpty {
                    emptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.sections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: columns, spacing: 2) {
                                    ForEach(section.records) { record in
                                        cell(record)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 24)
            .animation(animation, value: model.filter)
        }
    }

    private var studioHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Make it yours.").font(Theme.lookName(.title))
                Text(model.summary).font(.subheadline).foregroundStyle(.secondary)
            }
            if let latest = model.records.first {
                Button { model.open(latest) } label: {
                    HStack(spacing: 14) {
                        Color.white.opacity(0.08).frame(width: 64, height: 64)
                            .overlay {
                                if let image = model.thumbnail(for: latest) {
                                    Image(uiImage: image).resizable().scaledToFill()
                                }
                            }.clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Latest photo").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(model.captures.look(for: latest).name).font(Theme.lookName(.title3))
                            Text("Edit, add a frame, and get it ready to share.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 18))
                }
                .buttonStyle(PressableButtonStyle())
                .onAppear { model.cellAppeared(latest) }
                .accessibilityLabel("Edit latest photo in \(model.captures.look(for: latest).name)")
            }
            HStack(spacing: 10) {
                Button {
                    withAnimation(animation) { model.isSelecting = true }
                } label: {
                    Label("Style a Set", systemImage: "square.stack")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .hairlineControl()
                }
                .disabled(model.records.isEmpty)
                if let latest = model.records.first {
                    Button {
                        model.copyStyle(from: latest)
                    } label: {
                        Label("Copy Latest Style", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .hairlineControl()
                    }
                    .accessibilityHint("Copies the look and edits of your latest photo to paste onto others")
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(.white)
            .buttonStyle(PressableButtonStyle())
        }.padding(.horizontal, 16)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { filter in
                    let isActive = model.filter == filter
                    Button {
                        model.filter = filter
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .chip(isSelected: isActive, horizontalPadding: 14)
                            .minimumTapTarget()
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(isActive ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
        }
        .sensoryFeedback(.selection, trigger: model.filter)
    }

    private func cell(_ record: CaptureRecord) -> some View {
        let isSelected = model.selection.contains(record.id)
        return Button {
            model.tapped(record)
        } label: {
            Color.white.opacity(0.06)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image = model.thumbnail(for: record) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .opacity(isSelected ? 0.7 : 1)
                    }
                }
                .clipped()
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    if record.isImported && !model.isSelecting {
                        CellBadge(systemImage: "square.and.arrow.down")
                            .padding(6)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if !record.versions.isEmpty && !model.isSelecting {
                        VersionsBadge(count: record.versions.count)
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    // Edited since it arrived; the yellow dot means that edit
                    // isn't in Photos yet.
                    if record.isEdited && !model.isSelecting {
                        CellBadge(systemImage: "slider.horizontal.3", showsDot: !record.isSavedWithCurrentRecipe)
                            .padding(6)
                    }
                }
                .overlay {
                    if isSelected {
                        Rectangle().strokeBorder(Theme.accent, lineWidth: 3)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if model.isSelecting {
                        SelectionMark(isSelected: isSelected)
                            .padding(7)
                    }
                }
                .zoomSource(id: record.id, in: photoZoom)
        }
        .buttonStyle(PressableButtonStyle())
        .onAppear { model.cellAppeared(record) }
        .contextMenu {
            if !model.isSelecting {
                Button {
                    model.open(record)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                Button("Copy Style", systemImage: "doc.on.doc") { model.copyStyle(from: record) }
                if model.copiedStyle != nil {
                    Button("Paste Style", systemImage: "doc.on.clipboard") { model.pasteStyle(to: [record.id]) }
                }
                Button(role: .destructive) {
                    deleteTarget = [record.id]
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .accessibilityLabel(Text(accessibilityLabel(for: record)))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(model.isSelecting ? Text("Selects the photo") : Text("Opens the photo to edit"))
    }

    private func accessibilityLabel(for record: CaptureRecord) -> String {
        var parts = [model.captures.look(for: record).isOriginal
                     ? String(localized: "Photo, no look")
                     : String(localized: "Photo in \(model.captures.look(for: record).name)")]
        if record.isImported { parts.append(String(localized: "imported")) }
        if record.isEdited {
            parts.append(record.isSavedWithCurrentRecipe ? String(localized: "edited") : String(localized: "edited, not saved to Photos"))
        }
        if !record.versions.isEmpty {
            let count = record.versions.count
            parts.append(count == 1 ? String(localized: "1 version") : String(localized: "\(count) versions"))
        }
        parts.append(record.createdAt.formatted(date: .omitted, time: .shortened))
        return parts.joined(separator: ", ")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.filter == .notSaved ? "checkmark.circle" : "photo.on.rectangle.angled")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.emptyMessage.title)
                .font(.headline)
            Text(model.emptyMessage.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if model.filter == .all || model.filter == .imported {
                PhotosPicker(selection: $model.pickerItems, maxSelectionCount: 50, selectionBehavior: .ordered,
                             matching: .images, preferredItemEncoding: .current) {
                    Text("Import Photos")
                        .padding(.horizontal, 22)
                }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize()
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }

    // MARK: - Bottom

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let progress = model.importProgress {
                HStack(spacing: 10) {
                    ProgressView(value: Double(progress.done), total: Double(max(progress.total, 1)))
                        .tint(Theme.accent)
                        .frame(width: 80)
                    Text("Importing \(min(progress.done + 1, progress.total)) of \(progress.total)…")
                        .font(.footnote.weight(.semibold))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                .transition(bottomTransition)
            } else if let notice = model.notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                    .padding(.horizontal, 24)
                    .transition(bottomTransition)
            }
            if model.canUndoBatch {
                Button("Undo Last Batch", systemImage: "arrow.uturn.backward") { model.undoBatch() }
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                    .disabled(model.isWorking)
            }
            if model.isSelecting {
                selectionBar
                    .transition(bottomTransition)
            }
        }
        .padding(.bottom, 6)
        .animation(animation, value: model.isSelecting)
        .animation(animation, value: model.importProgress)
        .animation(animation, value: model.notice)
    }

    private var selectionBar: some View {
        HStack(spacing: 0) {
            barButton("Share", systemImage: "square.and.arrow.up") { model.shareSelected() }
            barButton("Save", systemImage: "square.and.arrow.down") { model.saveSelected() }
            Menu {
                Button("Finish Photo Set", systemImage: "rectangle.inset.filled") {
                    finishing = FinishSelection(records: model.selectedRecords)
                }
                if model.copiedStyle != nil {
                    Button("Paste Copied Style", systemImage: "doc.on.clipboard") { model.pasteStyle(to: model.selection) }
                }
                Button("Apply a Look", systemImage: "camera.filters") { model.prepareLookChoice() }
                Button("Apply Personal Preset", systemImage: "slider.horizontal.3") {
                    if model.hasPremiumNow { model.isChoosingPreset = true }
                    else { onShowPaywall() }
                }
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "camera.filters").font(.system(size: 20, weight: .medium))
                    Text("Style").font(.caption.weight(.semibold))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).padding(.vertical, 10)
            }
            .tint(.white)
            barButton("Delete", systemImage: "trash", tint: Color(red: 1, green: 0.41, blue: 0.38)) {
                deleteTarget = model.selection
            }
        }
        .frame(minHeight: 70)
        .fixedSize(horizontal: false, vertical: true)
        // A dark tint keeps the yellow and red labels readable over bright photos.
        .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous), tint: .black.opacity(0.55))
        .padding(.horizontal, 16)
        .disabled(model.selection.isEmpty || model.isWorking)
        .overlay {
            if model.isWorking {
                ProgressView().tint(.white)
            }
        }
    }

    private func barButton(_ title: LocalizedStringKey, systemImage: String, tint: Color = .white,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .medium))
                Text(title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(model.selection.isEmpty ? Color.secondary : tint)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
    }
}

/// A small glass-on-black badge in a grid cell's corner, with an optional
/// yellow dot for "not saved yet".
private struct CellBadge: View {
    let systemImage: String
    var showsDot = false

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(.black.opacity(0.45), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if showsDot {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(.black, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
            .accessibilityHidden(true)
    }
}

/// How many versions a photo keeps, on its grid cell.
private struct VersionsBadge: View {
    let count: Int

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "square.stack.fill")
                .font(.system(size: 9, weight: .bold))
            Text("\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(.black.opacity(0.45), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.2), lineWidth: 1))
        .accessibilityHidden(true)
    }
}

/// The round check in Select mode.
private struct SelectionMark: View {
    let isSelected: Bool

    var body: some View {
        ZStack {
            if isSelected {
                Circle().fill(Theme.accent)
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.black)
            } else {
                Circle().fill(.black.opacity(0.25))
                Circle().strokeBorder(.white, lineWidth: 2)
            }
        }
        .frame(width: 24, height: 24)
        .shadow(color: .black.opacity(0.3), radius: 2)
    }
}

/// UIKit share sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
