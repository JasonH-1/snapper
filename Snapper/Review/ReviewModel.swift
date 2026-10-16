import OSLog
import SwiftUI

/// View model for the photo review screen: browse captures, change the look
/// and its strength, save, share or delete.
@MainActor
@Observable
final class ReviewModel: Identifiable {
    enum Alert: Identifiable {
        case photosAccessDenied
        case error(String)
        case confirmDelete

        var id: String {
            switch self {
            case .photosAccessDenied: "photos"
            case .error(let message): "error-\(message)"
            case .confirmDelete: "delete"
            }
        }
    }

    struct ShareItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var currentID: UUID? {
        willSet { commitStrength() }
        didSet {
            guard currentID != oldValue else { return }
            loadCurrent()
        }
    }

    private(set) var previews: [UUID: UIImage] = [:]
    private(set) var originals: [UUID: UIImage] = [:]
    private(set) var lookThumbnails: [String: UIImage] = [:]
    private(set) var isSaving = false
    private(set) var isPreparingShare = false
    private(set) var savedCount = 0
    var alert: Alert?
    var shareItem: ShareItem?
    var isShowingOriginal = false
    /// Strength while the slider is being dragged; committed when it ends.
    private(set) var draftStrength: Double?

    let library: CaptureLibrary
    let looks: [Look]

    @ObservationIgnored private let hasPremium: () -> Bool
    @ObservationIgnored private let requestPremium: (Look, UIImage?, UIImage?) -> Void
    @ObservationIgnored private let alsoSaveOriginal: () -> Bool
    @ObservationIgnored private let saveFormat: () -> PhotoRenderer.ExportFormat
    @ObservationIgnored private var thumbnailsForID: UUID?
    @ObservationIgnored private var pendingRender: (id: UUID, look: Look, strength: Float)?
    @ObservationIgnored private var renderTask: Task<Void, Never>?

    init(library: CaptureLibrary,
         looks: [Look],
         startAt id: UUID?,
         hasPremium: @escaping () -> Bool,
         alsoSaveOriginal: @escaping () -> Bool,
         saveFormat: @escaping () -> PhotoRenderer.ExportFormat = { .heic },
         requestPremium: @escaping (Look, UIImage?, UIImage?) -> Void) {
        self.library = library
        self.looks = looks
        self.hasPremium = hasPremium
        self.alsoSaveOriginal = alsoSaveOriginal
        self.saveFormat = saveFormat
        self.requestPremium = requestPremium
        self.currentID = id ?? library.latest?.id
        loadCurrent()
    }

    var records: [CaptureRecord] { library.records }
    var current: CaptureRecord? { currentID.flatMap(library.record(id:)) }
    var currentLook: Look { current.map(library.look(for:)) ?? .original }
    var isLocked: Bool { currentLook.isPremium && !hasPremium() }
    var showsWatermarkNote: Bool { !hasPremium() && !currentLook.isPremium }
    var isSaved: Bool { draftStrength == nil && (current?.isSavedWithCurrentRecipe ?? false) }
    var lockedLookIDs: Set<String> {
        hasPremium() ? [] : Set(looks.filter(\.isPremium).map(\.id))
    }

    var strength: Double {
        get { draftStrength ?? current?.strength ?? 1 }
        set {
            guard let current else { return }
            draftStrength = newValue
            scheduleRender(id: current.id, look: currentLook, strength: Float(newValue))
        }
    }

    /// Stores the slider's value on the photo (called when a drag ends).
    func commitStrength() {
        guard let draft = draftStrength, let current else { return }
        draftStrength = nil
        library.updateRecipe(id: current.id, lookID: current.lookID, strength: draft)
    }

    func select(_ look: Look) {
        commitStrength()
        guard let current, current.lookID != look.id else { return }
        library.updateRecipe(id: current.id, lookID: look.id, strength: current.strength)
        scheduleRender(id: current.id, look: look, strength: Float(current.strength))
    }

    func image(for record: CaptureRecord) -> UIImage? {
        if record.id == currentID, isShowingOriginal, let original = originals[record.id] {
            return original
        }
        return previews[record.id] ?? library.thumbnails[record.id]
    }

    // MARK: - Loading

    private func loadCurrent() {
        guard let record = current else { return }
        if previews[record.id] == nil {
            scheduleRender(id: record.id, look: library.look(for: record), strength: Float(record.strength))
        }
        let url = library.url(for: record)
        let renderer = library.renderer
        if originals[record.id] == nil {
            Task {
                if let original = await renderer.original(id: record.id, sourceURL: url, aspect: record.aspect ?? .fourThree) {
                    originals[record.id] = original
                }
            }
        }
        guard thumbnailsForID != record.id else { return }
        thumbnailsForID = record.id
        lookThumbnails = [:]
        let looks = self.looks
        Task {
            let thumbs = await renderer.thumbnails(sourceURL: url, looks: looks)
            if thumbnailsForID == record.id {
                lookThumbnails = thumbs
            }
        }
    }

    /// Renders the newest request only; slider drags coalesce.
    private func scheduleRender(id: UUID, look: Look, strength: Float) {
        pendingRender = (id, look, strength)
        guard renderTask == nil else { return }
        renderTask = Task {
            while let next = pendingRender {
                pendingRender = nil
                guard let record = library.record(id: next.id) else { continue }
                let image = await library.renderer.preview(id: next.id, sourceURL: library.url(for: record),
                                                           look: next.look, strength: next.strength,
                                                           aspect: record.aspect ?? .fourThree)
                if let image {
                    previews[next.id] = image
                }
            }
            renderTask = nil
        }
    }

    // MARK: - Actions

    func save() {
        commitStrength()
        guard let record = current, !isSaving else { return }
        let look = currentLook
        if look.isPremium && !hasPremium() {
            requestPremium(look, originals[record.id], previews[record.id])
            return
        }
        isSaving = true
        let watermark = !hasPremium()
        let includeOriginal = alsoSaveOriginal()
        Task {
            defer { isSaving = false }
            do {
                try await library.saveToPhotos(record, watermark: watermark, includeOriginal: includeOriginal,
                                               format: saveFormat())
                savedCount += 1
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                alert = .photosAccessDenied
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    func share() {
        commitStrength()
        guard let record = current, !isPreparingShare else { return }
        let look = currentLook
        if look.isPremium && !hasPremium() {
            requestPremium(look, originals[record.id], previews[record.id])
            return
        }
        isPreparingShare = true
        let watermark = !hasPremium()
        Task {
            defer { isPreparingShare = false }
            do {
                let url = try await library.exportForSharing(record, watermark: watermark)
                shareItem = ShareItem(url: url)
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    func requestDelete() {
        alert = .confirmDelete
    }

    /// Deletes the current photo. Returns false when the roll is now empty.
    func deleteCurrent() -> Bool {
        guard let record = current else { return false }
        let ids = records.map(\.id)
        let index = ids.firstIndex(of: record.id) ?? 0
        library.delete(id: record.id)
        previews[record.id] = nil
        originals[record.id] = nil
        let remaining = records
        guard !remaining.isEmpty else {
            currentID = nil
            return false
        }
        currentID = remaining[min(index, remaining.count - 1)].id
        return true
    }
}
