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
    var onSelectStyle: ((CuratedStyle) -> Void)? = nil
    var onSelect: (Look) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var showGuide = false
    @State private var showCollections = false
    @State private var collectionRenderer = PhotoRenderer()
    @State private var scope: LookDiscovery.Scope = .all
    @State private var occasion: LookOccasion?
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
                    Button {
                        showGuide = true
                    } label: {
                        HStack(spacing: 5) {
                            Text("Need a guide?").foregroundStyle(.secondary)
                            Text("Tap here").foregroundStyle(Theme.accent).underline()
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open the Looks guide")
                    .accessibilityHint("Learn about filters, favorites and look strength")
                    if onSelectStyle != nil {
                        Button { showCollections = true } label: {
                            Label("Explore curated collections", systemImage: "square.stack").minimumTapTarget()
                        }.font(.subheadline.weight(.semibold))
                    }
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scope == .all {
                        occasionDiscovery
                        if occasion == nil { featuredGuidance }
                    }
                    if filteredLooks.isEmpty {
                        ContentUnavailableView {
                            Label(scope == .favorites ? "No favorite looks" : "No matching looks", systemImage: "camera.filters")
                        } description: {
                            Text(scope == .favorites ? "Star a look to keep it here." : "Try a look name, collection, or lighting like daylight.")
                        } actions: {
                            Button("Show All Looks") { query = ""; scope = .all; occasion = nil }
                        }
                    } else if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || scope != .all {
                        section(id: "search-results", title: "\(filteredLooks.count) looks", tagline: nil, looks: filteredLooks)
                    } else {
                        if accepts(.original) {
                            section(id: LookCatalog.originalEntryID, title: nil, tagline: nil, looks: [.original])
                        }
                        ForEach(catalog.sections) { section in
                            let matches = section.looks.filter(accepts)
                            if !matches.isEmpty {
                                self.section(id: section.id, title: section.title, tagline: section.tagline, looks: matches)
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollPosition(id: $position, anchor: .top)
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 8) {
                    Picker("Show looks", selection: $scope) {
                        ForEach(LookDiscovery.Scope.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 16)
                    if query.isEmpty && scope == .all {
                        CategoryChips(catalog: catalog, active: activeCategory) { category in jump(to: category) }
                    }
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
            .onChange(of: query) { _, _ in resetSearchPosition() }
            .onChange(of: scope) { _, _ in resetSearchPosition() }
            .background(Theme.canvas)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search looks, moods, or light")
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showCollections) {
                CuratedCollectionsView(library: library, renderer: collectionRenderer) { style in
                    onSelectStyle?(style)
                }
            }
            .fullScreenCover(isPresented: $showGuide) {
                GuideView(library: library, initialTopicID: "looks")
            }
            .onAppear {
                if recentIDs == nil { recentIDs = settings.recentLookIDs }
                if activeCategory == nil { activeCategory = catalog.sections.first?.category }
            }
        }
    }

    private var occasionDiscovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are you shooting?").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    Button("All Looks") { occasion = nil }
                        .buttonStyle(.bordered).tint(occasion == nil ? Theme.accent : .secondary)
                    ForEach(LookOccasion.allCases) { item in
                        Button(item.title) { occasion = item }
                            .buttonStyle(.bordered).tint(occasion == item ? Theme.accent : .secondary)
                            .accessibilityAddTraits(occasion == item ? .isSelected : [])
                    }
                }
            }
            if let occasion {
                Text(occasion.tip).font(.subheadline).foregroundStyle(.secondary)
                section(id: "occasion-results", title: "Try these looks", tagline: "Creative starting points; adjust for your light.",
                        looks: occasion.lookIDs.compactMap { library.look(id: $0) })
                Text("All looks are still below.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .id("occasion-discovery")
    }

    private func resetSearchPosition() {
        jumpingTo = nil
        position = query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && scope == .all
            ? "occasion-discovery" : "search-results"
    }

    private func accepts(_ look: Look) -> Bool {
        LookDiscovery.matches(look, library: library, query: query, scope: scope, favoriteIDs: settings.favoriteLookIDs)
    }

    private var filteredLooks: [Look] { library.looks.filter(accepts) }

    private var featuredGuidance: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Find your signature.").font(Theme.lookName(.largeTitle))
                Text("A little direction for your next photo.").font(.subheadline).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(LookGuide.featured) { guide in
                        if let look = library.look(id: guide.id) {
                            Button {
                                onSelect(look)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 0) {
                                    Color.white.opacity(0.08).frame(height: 160)
                                        .overlay {
                                            if let image = thumbnails.images[look.id] {
                                                Image(uiImage: image).resizable().scaledToFill()
                                            }
                                        }.clipped()
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(look.name).font(Theme.lookName(.title3))
                                            Spacer()
                                            Image(systemName: look.isPremium && !hasPremium ? "lock.fill" : "arrow.up.right")
                                                .foregroundStyle(Theme.accent)
                                        }
                                        Text(guide.bestFor).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.padding(12)
                                }
                                .frame(width: 210).background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("\(look.name), \(guide.bestFor)\(look.isPremium && !hasPremium ? ", Premium look" : "")")
                        }
                    }
                }.padding(.bottom, 4)
            }
        }.id("signature-guidance")
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
                             toggleFavorite: look.isOriginal ? nil : { settings.toggleFavorite(look) },
                             onSelect: { onSelect(look); dismiss() })
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
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(.quaternary)
                    .frame(height: 138)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Theme.accent : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, Theme.accent).padding(8)
                        }
                    }
                HStack(spacing: 4) {
                    if isLocked { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.accent) }
                    Text(look.name).font(Theme.lookName(.subheadline, weight: isSelected ? .semibold : .regular))
                }.lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(look.name))
        .accessibilityValue(isLocked ? Text("Premium look") : Text("Free"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .overlay(alignment: .topTrailing) {
            if let toggleFavorite {
                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isFavorite ? Theme.accent : .white)
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.65), in: Circle())
                }
                .padding(4)
                .accessibilityLabel(isFavorite ? Text("Remove \(look.name) from favorites") : Text("Add \(look.name) to favorites"))
            }
        }
        .sensoryFeedback(.selection, trigger: isFavorite)
    }
}
