import SwiftUI

/// Grid of every look, grouped by collection. Tap to switch the camera to a
/// look; star to keep it near the front of the swipe order.
struct LookPickerView: View {
    let library: LookLibrary
    let selectedID: String
    let hasPremium: Bool
    @Bindable var settings: AppSettings
    let thumbnails: LookThumbnails
    var onSelect: (Look) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 98), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    section(title: nil, tagline: nil, looks: [.original])
                    if !favorites.isEmpty {
                        section(title: String(localized: "Favorites"), tagline: nil, looks: favorites)
                    }
                    ForEach(library.collections) { collection in
                        section(title: collection.name,
                                tagline: collection.tagline,
                                looks: library.looks.filter { $0.collectionID == collection.id })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .navigationTitle("Looks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var favorites: [Look] {
        settings.favoriteLookIDs.compactMap(library.look(id:))
    }

    private func section(title: String?, tagline: String?, looks: [Look]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title3.weight(.semibold))
                    if let tagline {
                        Text(tagline).font(.footnote).foregroundStyle(.secondary)
                    }
                }
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
                Group {
                    if let image {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                }
                .frame(height: 124)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
                }

                if let toggleFavorite {
                    Button(action: toggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isFavorite ? Color.yellow : .white)
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
                        .foregroundStyle(Theme.premiumGradient)
                }
                Text(look.name)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
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
