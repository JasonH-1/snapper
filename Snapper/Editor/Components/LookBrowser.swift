import SwiftUI

/// Category chips over one continuous strip of look thumbnails. Tapping a
/// chip jumps the strip to that category; scrolling the strip moves the
/// highlighted chip along.
struct LookBrowser: View {
    let catalog: LookCatalog
    let selectedID: String
    let thumbnails: [String: UIImage]
    let lockedIDs: Set<String>
    let favoriteIDs: Set<String>
    @Binding var activeCategory: LookCategory?
    var select: (Look) -> Void
    var toggleFavorite: (Look) -> Void

    @State private var stripPosition: String?
    /// Set while a chip tap scrolls the strip, so the scroll doesn't re-pick the chip.
    @State private var jumpingTo: LookCategory?

    var body: some View {
        VStack(spacing: 12) {
            CategoryChips(catalog: catalog, active: activeCategory) { category in
                jump(to: category)
            }
            strip
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 10) {
                ForEach(catalog.entries) { entry in
                    Button {
                        select(entry.look)
                    } label: {
                        LookThumbnail(look: entry.look,
                                      image: thumbnails[entry.look.id],
                                      isSelected: entry.look.id == selectedID,
                                      isLocked: lockedIDs.contains(entry.look.id),
                                      isFavorite: favoriteIDs.contains(entry.look.id))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if !entry.look.isOriginal {
                            Button {
                                toggleFavorite(entry.look)
                            } label: {
                                if favoriteIDs.contains(entry.look.id) {
                                    Label("Remove from Favorites", systemImage: "star.slash")
                                } else {
                                    Label("Add to Favorites", systemImage: "star")
                                }
                            }
                        }
                    }
                    .id(entry.id)
                }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 16)
        }
        .scrollPosition(id: $stripPosition, anchor: .leading)
        .frame(height: 108)
        .onAppear {
            // Start with the photo's look in view, one look of context before it.
            guard stripPosition == nil, let id = catalog.entryID(forLook: selectedID),
                  let index = catalog.entries.firstIndex(where: { $0.id == id }) else { return }
            stripPosition = catalog.entries[max(index - 1, 0)].id
            activeCategory = catalog.category(ofEntry: id)
        }
        .onChange(of: stripPosition) { _, position in
            guard let position, let category = catalog.category(ofEntry: position) else { return }
            if let jumpingTo {
                // Arrived (or the strip can't scroll any further).
                if category == jumpingTo { self.jumpingTo = nil }
                return
            }
            if category != activeCategory { activeCategory = category }
        }
        .onScrollPhaseChangeIfAvailable { isIdle in
            if isIdle { jumpingTo = nil }
        }
        .sensoryFeedback(.selection, trigger: selectedID)
    }

    private func jump(to category: LookCategory) {
        guard let id = catalog.firstEntryID(of: category) else { return }
        jumpingTo = category
        activeCategory = category
        withAnimation(.easeInOut(duration: 0.3)) {
            stripPosition = id
        }
        // Without scroll phases (iOS 17), let the strip lead again once the jump is done.
        Task {
            try? await Task.sleep(for: .milliseconds(600))
            if jumpingTo == category { jumpingTo = nil }
        }
    }
}

/// The row of category chips: Favorites, Recent, then each collection with
/// its count.
struct CategoryChips: View {
    let catalog: LookCatalog
    let active: LookCategory?
    var tap: (LookCategory) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(catalog.sections) { section in
                        Button {
                            tap(section.category)
                        } label: {
                            chip(section, isActive: section.category == active)
                        }
                        .buttonStyle(.plain)
                        .id(section.id)
                    }
                }
                .padding(.horizontal, 16)
            }
            .onChange(of: active) { _, category in
                guard let category else { return }
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(category.id, anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: active)
    }

    private func chip(_ section: LookCatalog.Section, isActive: Bool) -> some View {
        HStack(spacing: 5) {
            if section.category == .favorites {
                Image(systemName: "star.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isActive ? Color.black : Theme.accent)
            } else if section.category == .recent {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .bold))
            }
            Text(section.title)
                .font(.footnote.weight(isActive ? .bold : .semibold))
            if let count = section.count {
                Text("\(count)")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(isActive ? Color.black.opacity(0.6) : Color.secondary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .foregroundStyle(isActive ? Color.black : Color.white)
        .background {
            if isActive {
                Capsule().fill(Theme.accent)
            } else {
                Capsule().fill(.white.opacity(0.13))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.16), lineWidth: 1))
            }
        }
        .contentShape(Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
    }
}

/// One look in the strip: the photo in that look, its name, a lock for
/// Premium looks.
struct LookThumbnail: View {
    let look: Look
    let image: UIImage?
    let isSelected: Bool
    let isLocked: Bool
    var isFavorite = false

    var body: some View {
        VStack(spacing: 6) {
            // An overlay on a fixed box, so a wide photo can't widen the tile.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.08))
                .frame(width: 64, height: 84)
                .overlay {
                    if let image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 2.5)
                }
                .overlay(alignment: .topTrailing) {
                    if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 20, height: 20)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if isFavorite {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(Theme.accent)
                            .padding(6)
                    }
                }
            Text(look.name)
                .font(.caption.weight(isSelected ? .bold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: 70)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(isLocked ? Text("Premium") : Text(""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// Reports when scrolling comes to rest (iOS 18 and later).
    @ViewBuilder
    func onScrollPhaseChangeIfAvailable(_ action: @escaping (Bool) -> Void) -> some View {
        if #available(iOS 18, *) {
            onScrollPhaseChange { _, phase in action(phase == .idle) }
        } else {
            self
        }
    }
}
