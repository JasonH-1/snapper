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
                    HStack(spacing: 12) {
                        if onSelectStyle != nil {
                            Button { showCollections = true } label: {
                                Label("Curated collections", systemImage: "square.stack")
                                    .font(.footnote.weight(.semibold))
                                    .chip(isSelected: false)
                                    .minimumTapTarget()
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        Spacer(minLength: 0)
                        Button {
                            showGuide = true
                        } label: {
                            HStack(spacing: 5) {
                                Text("Need a guide?").foregroundStyle(.secondary)
                                Text("Tap here").foregroundStyle(Theme.accent).underline()
                            }
                            .font(.caption)
                            .lineLimit(1)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open the Snapper guide")
                        .accessibilityHint("Learn about looks, editing and saving")
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
                            OriginalRow(image: thumbnails.images[Look.original.id],
                                        isSelected: selectedID == Look.original.id) {
                                onSelect(.original)
                                dismiss()
                            }
                            .id(LookCatalog.originalEntryID)
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
            .pinnedHeader {
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
                // The guide's home page, where every topic is listed, not one topic.
                GuideView(library: library)
            }
            .onAppear {
                if recentIDs == nil { recentIDs = settings.recentLookIDs }
                if activeCategory == nil { activeCategory = catalog.sections.first?.category }
            }
        }
    }

    private var occasionDiscovery: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What are you shooting?").font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    occasionChip(String(localized: "All Looks"), isSelected: occasion == nil) { occasion = nil }
                    ForEach(LookOccasion.allCases) { item in
                        occasionChip(item.title, isSelected: occasion == item) { occasion = item }
                    }
                }
            }
            .edgeToEdgeScroll()
            if let occasion {
                Text(occasion.tip).font(.subheadline).foregroundStyle(.secondary)
                section(id: "occasion-results", title: "Try these looks", tagline: "Creative starting points; adjust for your light.",
                        looks: occasion.lookIDs.compactMap { library.look(id: $0) })
                Text("All looks are still below.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .id("occasion-discovery")
    }

    private func occasionChip(_ title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .chip(isSelected: isSelected)
                .minimumTapTarget()
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            // Styled like every other section heading on the page.
            VStack(alignment: .leading, spacing: 2) {
                Text("Find your signature.").font(.title3.weight(.semibold))
                Text("A little direction for your next photo.").font(.footnote).foregroundStyle(.secondary)
            }
            .accessibilityAddTraits(.isHeader)
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
                                        Text(guide.bestFor).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(2, reservesSpace: true)
                                            .multilineTextAlignment(.leading)
                                    }.padding(12)
                                }
                                .frame(width: 200).background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                            }.buttonStyle(PressableButtonStyle())
                            .accessibilityLabel("\(look.name), \(guide.bestFor)\(look.isPremium && !hasPremium ? ", Premium look" : "")")
                        }
                    }
                }.padding(.bottom, 4)
            }
            .edgeToEdgeScroll()
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
                            .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 3)
                    }
                    .overlay(alignment: .bottomLeading) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.black, .white).padding(8)
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
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(isFavorite ? Theme.accent : .white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(isFavorite ? Text("Remove \(look.name) from favorites") : Text("Add \(look.name) to favorites"))
            }
        }
        .sensoryFeedback(.selection, trigger: isFavorite)
    }
}

/// "No look" as one slim row, so it doesn't sit alone in a mostly empty row
/// of the grid.
private struct OriginalRow: View {
    let image: UIImage?
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Rectangle().fill(.quaternary)
                    .frame(width: 52, height: 52)
                    .overlay {
                        if let image { Image(uiImage: image).resizable().scaledToFill() }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text(Look.original.name).font(Theme.lookName(.headline))
                    Text("No look, just your photo").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.black, .white)
                }
            }
            .padding(10)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(Text(Look.original.name))
        .accessibilityValue(Text("No look"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private extension View {
    /// Lets a horizontal row inside the sheet's 16 pt margins scroll out to
    /// the screen edges, while its first item still lines up with the margin.
    func edgeToEdgeScroll() -> some View {
        contentMargins(.horizontal, 16, for: .scrollContent)
            .padding(.horizontal, -16)
    }

    /// Pins the scope picker and chips under the search field. On iOS 26 they
    /// share the navigation bar's soft scroll edge, so the sheet is one colour
    /// instead of a grey band over a darker page.
    @ViewBuilder
    func pinnedHeader<Header: View>(@ViewBuilder _ header: () -> Header) -> some View {
        if #available(iOS 26, *) {
            safeAreaBar(edge: .top, spacing: 0, content: header)
        } else {
            safeAreaInset(edge: .top, spacing: 0) { header().background(.bar) }
        }
    }
}
