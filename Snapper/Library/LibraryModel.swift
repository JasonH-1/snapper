import OSLog
import PhotosUI
import SwiftUI

/// Which photos the Library shows.
enum LibraryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case camera
    case imported
    case edited
    case notSaved

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .all: "All"
        case .camera: "Shot in Snapper"
        case .imported: "Imported"
        case .edited: "Edited"
        case .notSaved: "Not saved"
        }
    }

    func includes(_ record: CaptureRecord) -> Bool {
        switch self {
        case .all: true
        case .camera: record.source == .camera
        case .imported: record.source == .imported
        case .edited: record.isEdited
        case .notSaved: !record.isSaved
        }
    }
}

/// One day of photos in the grid.
struct LibrarySection: Identifiable, Sendable {
    /// Start of the day.
    let id: Date
    let title: String
    let records: [CaptureRecord]
}

/// The Library screen: every photo taken with Snapper or imported, by day,
/// with filters, importing and a Select mode for batch actions.
@MainActor
@Observable
final class LibraryModel: Identifiable {
    enum Alert: Identifiable {
        case photosAccessDenied
        case error(String)

        var id: String {
            switch self {
            case .photosAccessDenied: "photos"
            case .error(let message): "error-\(message)"
            }
        }
    }

    struct ShareItems: Identifiable {
        let id = UUID()
        let urls: [URL]
    }

    /// Progress while picked photos are copied in.
    struct ImportProgress: Equatable {
        var total: Int
        var done = 0
        var failed = 0
    }

    let captures: CaptureLibrary
    let looks: LookLibrary
    let settings: AppSettings

    var filter: LibraryFilter = .all
    var isSelecting = false {
        didSet { if !isSelecting { selection = [] } }
    }
    var selection: Set<UUID> = []
    /// Bound to the PhotosPicker; picking starts the import.
    var pickerItems: [PhotosPickerItem] = [] {
        didSet {
            guard !pickerItems.isEmpty else { return }
            let items = pickerItems
            pickerItems = []
            importItems(items)
        }
    }
    private(set) var importProgress: ImportProgress?
    var editor: EditorModel?
    var alert: Alert?
    var shareItems: ShareItems?
    var isChoosingLook = false
    var isChoosingPreset = false
    /// Session-only color clipboard; never includes crop, frame, or date.
    private(set) var copiedStyle: SavedPreset?
    /// Last batch only; skip any photos individually edited afterwards.
    private(set) var batchUndo: [UUID: (before: PhotoRecipe, after: PhotoRecipe)] = [:]
    var canUndoBatch: Bool { !batchUndo.isEmpty }
    /// The first selected photo in every look, for the Apply Look sheet.
    let lookThumbnails = LookThumbnails()
    private(set) var isWorking = false
    /// A short message over the grid ("Saved 3 photos").
    private(set) var notice: String?

    @ObservationIgnored private let hasPremium: () -> Bool
    @ObservationIgnored private let requestPremium: (Look, UIImage?, UIImage?) -> Void
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    @ObservationIgnored private var importTask: Task<Void, Never>?

    init(captures: CaptureLibrary,
         looks: LookLibrary,
         settings: AppSettings,
         hasPremium: @escaping () -> Bool,
         requestPremium: @escaping (Look, UIImage?, UIImage?) -> Void) {
        self.captures = captures
        self.looks = looks
        self.settings = settings
        self.hasPremium = hasPremium
        self.requestPremium = requestPremium
    }

    // MARK: - Contents

    var records: [CaptureRecord] { captures.records }

    var visibleRecords: [CaptureRecord] { records.filter(filter.includes) }

    var sections: [LibrarySection] {
        Self.sections(for: visibleRecords)
    }

    /// "214 photos · 38 imported"
    var summary: String {
        let total = records.count
        let imported = records.filter(\.isImported).count
        let photos = Self.photoCount(total)
        guard imported > 0 else { return photos }
        return photos + " · " + String(localized: "\(imported) imported")
    }

    /// "1 photo", "3 photos".
    nonisolated static func photoCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 photo") : String(localized: "\(count) photos")
    }

    var emptyMessage: (title: LocalizedStringResource, detail: LocalizedStringResource) {
        switch filter {
        case .all: ("No photos yet", "Photos you take in Snapper show up here. Tap Import Photos to bring in photos from your library.")
        case .camera: ("No Snapper shots yet", "Photos you take with Snapper's camera show up here.")
        case .imported: ("Nothing imported", "Tap Import Photos to pick photos from your library. Snapper edits its own copy.")
        case .edited: ("No edited photos", "Photos you change after taking or importing them show up here.")
        case .notSaved: ("Everything is saved", "Every photo here is already in your photo library.")
        }
    }

    /// Groups photos (newest first) into days, titled like Photos does.
    nonisolated static func sections(for records: [CaptureRecord], now: Date = Date(), calendar: Calendar = .current) -> [LibrarySection] {
        var sections: [LibrarySection] = []
        var current: (day: Date, records: [CaptureRecord])?
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            if current?.day == day {
                current?.records.append(record)
            } else {
                if let current {
                    sections.append(LibrarySection(id: current.day, title: dayTitle(current.day, now: now, calendar: calendar),
                                                   records: current.records))
                }
                current = (day, [record])
            }
        }
        if let current {
            sections.append(LibrarySection(id: current.day, title: dayTitle(current.day, now: now, calendar: calendar),
                                           records: current.records))
        }
        return sections
    }

    nonisolated static func dayTitle(_ day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return String(localized: "Today") }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(day, inSameDayAs: yesterday) {
            return String(localized: "Yesterday")
        }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? 0
        if days > 0, days < 7 {
            return day.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(day, equalTo: now, toGranularity: .year) {
            return day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
        return day.formatted(.dateTime.month(.abbreviated).day().year())
    }

    func thumbnail(for record: CaptureRecord) -> UIImage? {
        captures.thumbnails[record.id]
    }

    func cellAppeared(_ record: CaptureRecord) {
        captures.requestThumbnail(for: record.id)
    }

    // MARK: - Opening

    func tapped(_ record: CaptureRecord) {
        if isSelecting {
            toggleSelection(record)
        } else {
            open(record)
        }
    }

    func open(_ record: CaptureRecord) {
        editor = EditorModel(library: captures, looks: looks, settings: settings, id: record.id,
                             hasPremium: hasPremium, requestPremium: requestPremium)
    }

    // MARK: - Importing

    private func importItems(_ items: [PhotosPickerItem]) {
        importTask?.cancel()
        importProgress = ImportProgress(total: items.count)
        // The first photo picked ends up on top.
        let start = Date()
        importTask = Task {
            for (index, item) in items.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CaptureLibrary.ImportError.unreadable
                    }
                    try await captures.importPhoto(data, createdAt: start.addingTimeInterval(-Double(index) * 0.001))
                } catch {
                    Logger.library.error("Import failed: \(error.localizedDescription, privacy: .public)")
                    importProgress?.failed += 1
                }
                importProgress?.done += 1
            }
            if let progress = importProgress {
                let imported = progress.done - progress.failed
                if progress.failed > 0 {
                    show(String(localized: "Imported \(imported) of \(progress.total). Some photos couldn't be opened."))
                } else {
                    show(String(localized: "Imported \(Self.photoCount(imported))"))
                }
            }
            if filter != .all && filter != .imported && filter != .notSaved {
                filter = .all
            }
            importProgress = nil
        }
    }

    // MARK: - Selecting

    func toggleSelection(_ record: CaptureRecord) {
        if selection.contains(record.id) {
            selection.remove(record.id)
        } else {
            selection.insert(record.id)
        }
    }

    var allVisibleSelected: Bool {
        let visible = Set(visibleRecords.map(\.id))
        return !visible.isEmpty && visible.isSubset(of: selection)
    }

    func toggleSelectAll() {
        if allVisibleSelected {
            selection.subtract(visibleRecords.map(\.id))
        } else {
            selection.formUnion(visibleRecords.map(\.id))
        }
    }

    /// Selected photos in Library order.
    var selectedRecords: [CaptureRecord] {
        records.filter { selection.contains($0.id) }
    }

    private func isLocked(_ record: CaptureRecord) -> Bool {
        (captures.look(for: record).isPremium || record.recipe.requiresPremium) && !hasPremium()
    }

    // MARK: - Batch actions

    func shareSelected() {
        let chosen = selectedRecords
        let allowed = chosen.filter { !isLocked($0) }
        guard !isWorking else { return }
        guard !allowed.isEmpty else {
            if let first = chosen.first { requestPremium(captures.look(for: first), nil, captures.thumbnails[first.id]) }
            return
        }
        isWorking = true
        let watermark = false
        Task {
            defer { isWorking = false }
            do {
                shareItems = ShareItems(urls: try await captures.exportForSharing(allowed, watermark: watermark))
                if allowed.count < chosen.count {
                    show(String(localized: "Photos with Premium looks or finishing were left out."))
                }
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    func saveSelected() {
        let chosen = selectedRecords
        let allowed = chosen.filter { !isLocked($0) }
        guard !isWorking else { return }
        guard !allowed.isEmpty else {
            if let first = chosen.first { requestPremium(captures.look(for: first), nil, captures.thumbnails[first.id]) }
            return
        }
        isWorking = true
        let watermark = false
        let includeOriginal = settings.alsoSaveOriginal
        let format = settings.photoFormat
        Task {
            defer { isWorking = false }
            var saved = 0
            do {
                for record in allowed {
                    try await captures.saveToPhotos(record, watermark: watermark, includeOriginal: includeOriginal,
                                                    format: format)
                    saved += 1
                }
                let skipped = chosen.count - allowed.count
                show(skipped > 0
                     ? String(localized: "Saved \(Self.photoCount(saved)). Premium looks and finishing need Premium to save.")
                     : String(localized: "Saved \(Self.photoCount(saved)) to Photos"))
                isSelecting = false
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                alert = .photosAccessDenied
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    /// Gives every selected photo `look` at full strength, keeping their
    /// other edits.
    func applyLookToSelection(_ look: Look) {
        let chosen = selectedRecords
        applyBatch(chosen) { record in
            var recipe = record.recipe
            recipe.lookID = look.id
            recipe.strength = 1
            return recipe
        }
        settings.noteRecentlyUsed(look)
        show(String(localized: "Applied \(look.name) to \(Self.photoCount(chosen.count))"))
    }

    @discardableResult
    func applyPresetToSelection(_ preset: SavedPreset) -> Bool {
        guard hasPremium(), !isWorking, looks.look(id: preset.lookID) != nil else { return false }
        let chosen = selectedRecords
        guard !chosen.isEmpty else { return false }
        applyBatch(chosen) { preset.applying(to: $0.recipe) }
        if let look = looks.look(id: preset.lookID) { settings.noteRecentlyUsed(look) }
        show(String(localized: "Applied \(preset.name) to \(Self.photoCount(chosen.count)). Crops and finishing kept."))
        return true
    }

    func copyStyle(from record: CaptureRecord) {
        guard let current = captures.record(id: record.id) else { return }
        let name = captures.look(for: current).name
        copiedStyle = SavedPreset(name: name, recipe: current.recipe)
        show(String(localized: "Copied \(name). Choose another photo or select a set to paste."))
    }

    @discardableResult
    func pasteStyle(to ids: Set<UUID>) -> Bool {
        guard !isWorking, let style = copiedStyle, let look = looks.look(id: style.lookID) else { return false }
        let chosen = records.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return false }
        if chosen.count > 1 && !hasPremium() {
            requestPremium(look, nil, nil)
            return false
        }
        applyBatch(chosen) { style.applying(to: $0.recipe) }
        settings.noteRecentlyUsed(look)
        show(String(localized: "Pasted style to \(Self.photoCount(chosen.count)). Crops and finishing kept."))
        return true
    }

    /// Snapshot-based application avoids overwriting changes made since preview opened.
    @discardableResult
    func applyFinishing(_ finish: BatchFinish, to snapshots: [CaptureRecord]) -> Bool {
        guard hasPremium(), !isWorking, finish.hasChanges, !snapshots.isEmpty else { return false }
        let unchanged = snapshots.compactMap { snapshot -> CaptureRecord? in
            guard let current = captures.record(id: snapshot.id), current.recipe == snapshot.recipe else { return nil }
            return current
        }
        guard !unchanged.isEmpty else {
            show(String(localized: "These photos changed. Reopen the finishing preview to try again."))
            return false
        }
        applyBatch(unchanged) { finish.applying(to: $0.recipe) }
        isSelecting = true
        selection = Set(unchanged.map(\.id))
        let skipped = snapshots.count - unchanged.count
        show(skipped == 0 ? String(localized: "Finishing applied. Your photo set is ready to save or share.")
             : String(localized: "Finishing applied. \(skipped) changed or deleted photos were skipped."))
        return true
    }

    private func applyBatch(_ records: [CaptureRecord], recipe: (CaptureRecord) -> PhotoRecipe) {
        batchUndo = [:]
        for record in records {
            let next = recipe(record)
            guard next != record.recipe else { continue }
            batchUndo[record.id] = (before: record.recipe, after: next)
            captures.updateRecipe(id: record.id, next)
        }
    }

    func undoBatch() {
        var restored = 0
        for (id, change) in batchUndo {
            guard let current = captures.record(id: id), current.recipe == change.after else { continue }
            captures.updateRecipe(id: id, change.before)
            restored += 1
        }
        batchUndo = [:]
        show(String(localized: "Restored \(Self.photoCount(restored)). Later edits were kept."))
    }

    func prepareLookChoice() {
        guard let first = selectedRecords.first else { return }
        lookThumbnails.load(photo: captures.url(for: first), recipe: first.recipe, seed: first.id.effectsSeed,
                            looks: looks.looks, renderer: captures.renderer)
        isChoosingLook = true
    }

    var hasPremiumNow: Bool { hasPremium() }

    /// Deletes photos (copies already in Photos are not affected) and leaves Select mode.
    func delete(_ ids: Set<UUID>) {
        captures.delete(ids: ids)
        selection.subtract(ids)
        isSelecting = false
    }

    // MARK: - Notices

    func show(_ message: String) {
        noticeTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { notice = message }
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { notice = nil }
        }
    }
}
