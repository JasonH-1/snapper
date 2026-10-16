import PhotosUI
import SwiftUI

/// The Library: every photo taken with Snapper or imported, by day. Filter
/// chips at the top, + to import, Select for batch actions; tap a photo to
/// edit it.
struct LibraryView: View {
    @Bindable var model: LibraryModel
    var onClose: () -> Void
    var onShowPaywall: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirmation = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            content
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(model.isSelecting ? selectionTitle : String(localized: "Library"))
                .navigationBarTitleDisplayMode(model.isSelecting ? .inline : .large)
                .toolbar { toolbar }
                .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                .navigationDestination(item: $model.editor) { editor in
                    EditorView(model: editor, onShowPaywall: onShowPaywall)
                }
        }
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
        .confirmationDialog(deleteTitle, isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                withAnimation { model.deleteSelected() }
            }
        } message: {
            Text("They will be removed from Snapper. Copies already saved to your photo library are not affected.")
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
        Text("Delete \(LibraryModel.photoCount(model.selection.count))?")
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
                    withAnimation(.easeInOut(duration: 0.2)) { model.isSelecting = false }
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
                    withAnimation(.easeInOut(duration: 0.2)) { model.isSelecting = true }
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
            Image(systemName: "square.and.arrow.down")
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
                if !model.isSelecting {
                    Text(model.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .padding(.top, -6)
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
            .animation(.easeInOut(duration: 0.2), value: model.filter)
        }
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
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .foregroundStyle(isActive ? Color.black : Color.white)
                            .background {
                                if isActive {
                                    Capsule().fill(Theme.accent)
                                } else {
                                    Capsule().fill(.white.opacity(0.13))
                                        .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
                                }
                            }
                    }
                    .buttonStyle(.plain)
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
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(.black.opacity(0.45), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.2), lineWidth: 1))
                            .padding(6)
                            .accessibilityHidden(true)
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
        }
        .buttonStyle(.plain)
        .onAppear { model.cellAppeared(record) }
        .contextMenu {
            if !model.isSelecting {
                Button {
                    model.open(record)
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                Button(role: .destructive) {
                    model.selection = [record.id]
                    showDeleteConfirmation = true
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let notice = model.notice {
                Text(notice)
                    .font(.footnote.weight(.semibold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassSurface(in: Capsule(), tint: .black.opacity(0.55))
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.isSelecting {
                selectionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .padding(.bottom, 6)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.isSelecting)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.importProgress)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: model.notice)
    }

    private var selectionBar: some View {
        HStack(spacing: 0) {
            barButton("Share", systemImage: "square.and.arrow.up") { model.shareSelected() }
            barButton("Save", systemImage: "square.and.arrow.down") { model.saveSelected() }
            barButton("Apply Look", systemImage: "camera.filters", tint: Theme.accent) {
                model.prepareLookChoice()
            }
            barButton("Delete", systemImage: "trash", tint: Color(red: 1, green: 0.41, blue: 0.38)) {
                showDeleteConfirmation = true
            }
        }
        .frame(height: 70)
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
            }
            .foregroundStyle(model.selection.isEmpty ? Color.secondary : tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
