import SwiftUI

/// Full-screen photo review: change the look after the fact, adjust its
/// strength, then save, share or delete.
struct ReviewView: View {
    @Bindable var model: ReviewModel
    var onClose: () -> Void
    var onShowPaywall: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            pager
            controls
        }
        .background(Color(.systemBackground).ignoresSafeArea())
        .sheet(item: $model.shareItem) { item in
            ShareSheet(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert(alertTitle, isPresented: alertBinding, presenting: model.alert) { alert in
            switch alert {
            case .photosAccessDenied:
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                Button("Cancel", role: .cancel) {}
            case .error, .confirmDelete:
                Button("OK", role: .cancel) {}
            }
        } message: { alert in
            switch alert {
            case .photosAccessDenied:
                Text("Allow Snapper to add photos in Settings to save your shots to your library.")
            case .error(let message):
                Text(message)
            case .confirmDelete:
                EmptyView()
            }
        }
        .confirmationDialog("Delete this photo?", isPresented: $showDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) {
                withAnimation {
                    if !model.deleteCurrent() { onClose() }
                }
            }
        } message: {
            Text("It will be removed from Snapper. Copies already saved to your photo library are not affected.")
        }
        .sensoryFeedback(.success, trigger: model.savedCount)
    }

    private var alertTitle: Text {
        switch model.alert {
        case .photosAccessDenied: Text("Photo access needed")
        case .error: Text("Couldn't finish")
        default: Text("")
        }
    }

    private var alertBinding: Binding<Bool> {
        Binding(
            get: {
                if case .confirmDelete = model.alert { return false }
                return model.alert != nil
            },
            set: { if !$0 { model.alert = nil } }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(Text("Close"))

            Spacer()

            if let record = model.current {
                VStack(spacing: 2) {
                    Text(record.createdAt, format: .dateTime.month(.abbreviated).day().year())
                        .font(.subheadline.weight(.semibold))
                    Text(record.createdAt, format: .dateTime.hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                showDeleteConfirmation = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .background(.quaternary, in: Circle())
            }
            .accessibilityLabel(Text("Delete photo"))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Photos

    private var pager: some View {
        TabView(selection: $model.currentID) {
            ForEach(model.records) { record in
                photo(record)
                    .tag(Optional(record.id))
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func photo(_ record: CaptureRecord) -> some View {
        ZStack {
            if let image = model.image(for: record) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .padding(.horizontal, 12)
                    .accessibilityLabel(Text("Photo"))
            } else {
                ProgressView()
            }
            if record.id == model.currentID, model.isShowingOriginal {
                VStack {
                    Text("Original")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }
            }
        }
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
            model.isShowingOriginal = pressing
        })
        .accessibilityHint(Text("Touch and hold to compare with the original."))
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 16) {
            LookStrip(looks: model.looks,
                      selectedID: model.currentLook.id,
                      thumbnails: model.lookThumbnails,
                      lockedIDs: lockedIDs) { look in
                model.select(look)
            }

            HStack(spacing: 12) {
                Text("Strength")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Slider(value: $model.strength, in: 0...1, onEditingChanged: { editing in
                    if !editing { model.commitStrength() }
                })
                .disabled(model.currentLook.isOriginal)
                Text("\(Int((model.strength * 100).rounded()))")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
            .padding(.horizontal, 20)
            .opacity(model.currentLook.isOriginal ? 0.4 : 1)

            if model.showsWatermarkNote {
                HStack(spacing: 6) {
                    Image(systemName: "seal")
                    Text("Free exports include a small watermark.")
                    Button("Remove", action: onShowPaywall)
                        .fontWeight(.semibold)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button {
                    model.share()
                } label: {
                    Label {
                        Text("Share")
                    } icon: {
                        if model.isPreparingShare {
                            ProgressView()
                        } else {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
                .buttonStyle(PrimaryButtonStyle(isProminent: false))
                .frame(maxWidth: 140)

                Button {
                    model.save()
                } label: {
                    HStack(spacing: 8) {
                        if model.isSaving {
                            ProgressView().tint(.black)
                        } else if model.isLocked {
                            Image(systemName: "lock.fill")
                        } else if model.isSaved {
                            Image(systemName: "checkmark")
                        }
                        Text(saveTitle)
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.isSaving)
            }
            .padding(.horizontal, 20)
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: model.isSaved)
        .animation(.easeInOut(duration: 0.2), value: model.isLocked)
    }

    private var saveTitle: LocalizedStringKey {
        if model.isLocked { return "Unlock to Save" }
        if model.isSaved { return "Saved to Photos" }
        return "Save to Photos"
    }

    private var lockedIDs: Set<String> {
        model.lockedLookIDs
    }
}

/// Horizontal strip of the current photo in every look.
struct LookStrip: View {
    let looks: [Look]
    let selectedID: String
    let thumbnails: [String: UIImage]
    let lockedIDs: Set<String>
    let select: (Look) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 10) {
                    ForEach(looks) { look in
                        Button {
                            select(look)
                        } label: {
                            item(look)
                        }
                        .buttonStyle(.plain)
                        .id(look.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .frame(height: 104)
            .onAppear { proxy.scrollTo(selectedID, anchor: .center) }
            .onChange(of: selectedID) { _, id in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    private func item(_ look: Look) -> some View {
        let isSelected = look.id == selectedID
        return VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = thumbnails[look.id] {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(width: 62, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2.5)
                }
                if lockedIDs.contains(look.id) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(4)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(4)
                }
            }
            Text(look.name)
                .font(.caption2.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(lockedIDs.contains(look.id) ? Text("Premium") : Text(""))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
