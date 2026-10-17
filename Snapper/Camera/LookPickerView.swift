import SwiftUI

/// Grid of every look, grouped like the editor's strip: Favorites, Recent,
/// then each collection, with category chips pinned on top to jump between
/// them. Tap to pick a look; star to keep it near the front of the camera's
/// swipe order.
struct LookPickerView: View {
    let library: LookLibrary
    let selectedID: String
    let hasPremium: Bool
    @Bindable var settings: AppSettings
    let thumbnails: LookThumbnails
    var title: String = String(localized: "Looks")
    var onSelect: (Look) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var position: String?
    @State private var activeCategory: LookCategory?
    @State private var jumpingTo: LookCategory?
    /// Recent looks when the sheet opened, so sections don't move while browsing.
    @State private var recentIDs: [String]?

    private let columns = [GridItem(.adaptive(minimum: 98), spacing: 12)]

    private var catalog: LookCatalog {
        LookCatalog(library: library, favoriteIDs: settings.favoriteLookIDs, recentIDs: recentIDs ?? settings.recentLookIDs)
    }

    var body: some View {
        let catalog = self.catalog
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    featuredGuidance
                    section(id: LookCatalog.originalEntryID, title: nil, tagline: nil, looks: [.original])
                    ForEach(catalog.sections) { section in
                        self.section(id: section.id, title: section.title, tagline: section.tagline, looks: section.looks)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollPosition(id: $position, anchor: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                CategoryChips(catalog: catalog, active: activeCategory) { category in
                    jump(to: category)
                }
                .padding(.vertical, 8)
                .background(.bar)
            }
            .onChange(of: position) { _, id in
                guard let id else { return }
                let category = id == LookCatalog.originalEntryID
                    ? catalog.sections.first?.category
                    : catalog.sections.first { $0.id == id }?.category
                if let jumpingTo {
                    if category == jumpingTo { self.jumpingTo = nil }
                    return
                }
                activeCategory = category
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if recentIDs == nil { recentIDs = settings.recentLookIDs }
                if activeCategory == nil { activeCategory = catalog.sections.first?.category }
            }
        }
    }

    private var featuredGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Start with a Signature Look").font(.headline)
            Text("Choose for the light you're in. Tap a sample to try it.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(LookGuide.featured) { guide in
                if let look = library.look(id: guide.id) {
                    Button {
                        onSelect(look)
                        dismiss()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            if let image = thumbnails.images[look.id] {
                                Image(uiImage: image).resizable().scaledToFill()
                                    .frame(width: 64, height: 80).clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(look.name).font(.headline)
                                Text(guide.bestFor).font(.subheadline)
                                Text(guide.tip).font(.caption).foregroundStyle(.secondary)
                                if look.isPremium && !hasPremium {
                                    Text("Preview free · Premium to save").font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id("signature-guidance")
    }

    private func jump(to category: LookCategory) {
        jumpingTo = category
        activeCategory = category
        withAnimation(.easeInOut(duration: 0.3)) { position = category.id }
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if jumpingTo == category { jumpingTo = nil }
        }
    }

    private func section(id: String, title: String?, tagline: String?, looks: [Look]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let tagline {
                        Text(tagline).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityAddTraits(.isHeader)
            }
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(looks) { look in
                    LookTile(look: look,
                             image: thumbnails.images[look.id],
                             isSelected: look.id == selectedID,
                             isLocked: look.isPremium && !hasPremium,
                             isFavorite: settings.isFavorite(look),
                             toggleFavorite: look.isOriginal ? nil : { settings.toggleFavorite(look) })
                        .onTapGesture {
                            onSelect(look)
                            dismiss()
                        }
                }
            }
        }
        .id(id)
    }
}

private struct LookTile: View {
    let look: Look
    let image: UIImage?
    let isSelected: Bool
    let isLocked: Bool
    let isFavorite: Bool
    let toggleFavorite: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                // The thumbnail is an overlay on a fixed box, so a landscape
                // image fills and crops instead of widening the grid cell.
                Rectangle().fill(.quaternary)
                    .frame(height: 124)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 3)
                }

                if let toggleFavorite {
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isFavorite ? Theme.accent : .white)
                            .frame(width: 30, height: 30)
                            .background(.black.opacity(0.4), in: Circle())
                    }
                    .padding(5)
                    .accessibilityLabel(isFavorite ? Text("Remove from favorites") : Text("Add to favorites"))
                }
            }
            HStack(spacing: 4) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.accent)
                }
                Text(look.name)
                    .font(Theme.lookName(.subheadline, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
        }
        .contentShape(Rectangle())
        .sensoryFeedback(.selection, trigger: isFavorite)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(isLocked ? Text("Premium") : Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
