import OSLog
import SwiftUI

/// The photo editor: a look and its strength, light and colour sliders, and
/// crop, straighten, turn and mirror. Everything is a recipe on the photo's
/// record; the original file is never changed.
@MainActor
@Observable
final class EditorModel: Identifiable, Hashable {
    enum Tab: String, CaseIterable, Identifiable {
        case looks, adjust, crop

        var id: String { rawValue }

        var title: LocalizedStringResource {
            switch self {
            case .looks: "Looks"
            case .adjust: "Adjust"
            case .crop: "Crop"
            }
        }
    }

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

    struct ShareItem: Identifiable {
        let url: URL
        var id: URL { url }
    }

    let id: UUID
    let library: CaptureLibrary
    let looks: LookLibrary
    let settings: AppSettings

    var tab: Tab = .looks {
        didSet {
            guard tab != oldValue else { return }
            scheduleRender()
            if tab == .looks { refreshLookThumbnails() }
        }
    }

    /// The working recipe. Changes show at once and are stored on the photo
    /// shortly after (and when leaving).
    private(set) var recipe: PhotoRecipe

    /// The edited photo at screen size.
    private(set) var preview: UIImage?
    /// The photo framed but with no look or sliders, for press-and-hold compare.
    private(set) var original: UIImage?
    /// For the Crop tab: mirrored and turned, with the look and sliders, but
    /// not straightened or cropped (the crop canvas draws those live).
    private(set) var cropBase: UIImage?
    private(set) var lookThumbnails: [String: UIImage] = [:]
    var isShowingOriginal = false

    var adjustTool: PhotoAdjustments.Kind = .brightness
    /// The chip that matches the look strip's scroll position.
    var activeCategory: LookCategory?

    private(set) var isSaving = false
    private(set) var isPreparingShare = false
    private(set) var savedCount = 0
    var alert: Alert?
    var shareItem: ShareItem?

    @ObservationIgnored private let hasPremium: () -> Bool
    @ObservationIgnored private let requestPremium: (Look, UIImage?, UIImage?) -> Void
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var renderAgain = false
    @ObservationIgnored private var commitTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailsTask: Task<Void, Never>?
    /// The sliders and crop the look thumbnails were drawn with.
    @ObservationIgnored private var thumbnailsRecipe: PhotoRecipe?
    @ObservationIgnored private var originalCrop: PhotoCrop?
    @ObservationIgnored private var cropBaseKey: CropBaseKey?
    /// Recent looks as they were when the editor opened, so the strip doesn't
    /// reshuffle while browsing.
    @ObservationIgnored private let recentIDsAtOpen: [String]

    private struct CropBaseKey: Equatable {
        var lookID: String
        var strength: Double
        var adjustments: PhotoAdjustments
        var quarterTurns: Int
        var isFlipped: Bool
    }

    init(library: CaptureLibrary,
         looks: LookLibrary,
         settings: AppSettings,
         id: UUID,
         hasPremium: @escaping () -> Bool,
         requestPremium: @escaping (Look, UIImage?, UIImage?) -> Void) {
        self.id = id
        self.library = library
        self.looks = looks
        self.settings = settings
        self.hasPremium = hasPremium
        self.requestPremium = requestPremium
        self.recipe = library.record(id: id)?.recipe ?? .untouched
        self.recentIDsAtOpen = settings.recentLookIDs
        preview = library.thumbnails[id]
        scheduleRender()
        refreshLookThumbnails()
    }

    nonisolated static func == (lhs: EditorModel, rhs: EditorModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: - State

    var record: CaptureRecord? { library.record(id: id) }
    var currentLook: Look { looks.look(id: recipe.lookID) ?? .original }
    var isLocked: Bool { currentLook.isPremium && !hasPremium() }
    var showsWatermarkNote: Bool { !hasPremium() && !currentLook.isPremium }
    var isImported: Bool { record?.isImported ?? false }
    var isEdited: Bool { record.map { recipe != $0.initialRecipe } ?? false }
    var isSaved: Bool { record?.savedRecipe == recipe }

    var catalog: LookCatalog {
        LookCatalog(library: looks, favoriteIDs: settings.favoriteLookIDs, recentIDs: recentIDsAtOpen)
    }

    var lockedLookIDs: Set<String> {
        hasPremium() ? [] : Set(looks.looks.filter(\.isPremium).map(\.id))
    }

    /// "Today", "Yesterday", "Monday" or a date.
    var title: String {
        record.map { LibraryModel.dayTitle($0.createdAt) } ?? ""
    }

    /// "9:40 PM · Shot in Snapper", or "Imported · Taken 2 Jun 2024".
    var subtitle: String {
        guard let record else { return "" }
        if record.isImported {
            guard let taken = record.takenAt else { return String(localized: "Imported") }
            return String(localized: "Imported · Taken \(taken.formatted(date: .abbreviated, time: .omitted))")
        }
        return record.createdAt.formatted(date: .omitted, time: .shortened) + " · " + String(localized: "Shot in Snapper")
    }

    /// The photo shown in the canvas.
    var displayImage: UIImage? {
        if isShowingOriginal, let original { return original }
        return preview
    }

    // MARK: - Looks

    func select(_ look: Look) {
        guard recipe.lookID != look.id else { return }
        update { $0.lookID = look.id }
    }

    var strength: Double {
        get { recipe.strength }
        set { update { $0.strength = min(max(newValue, 0), 1) } }
    }

    func toggleFavorite(_ look: Look) {
        settings.toggleFavorite(look)
    }

    // MARK: - Adjust

    func value(of kind: PhotoAdjustments.Kind) -> Double {
        recipe.adjustments[kind]
    }

    func setValue(_ value: Double, for kind: PhotoAdjustments.Kind) {
        update { $0.adjustments[kind] = value }
    }

    func resetValue(of kind: PhotoAdjustments.Kind) {
        setValue(0, for: kind)
    }

    // MARK: - Crop

    /// The turned frame's size in pixels (for box shapes).
    var frameSize: CGSize {
        if let cropBase { return cropBase.size }
        if let preview { return preview.size }
        return CGSize(width: 3, height: 4)
    }

    var cropRect: CGRect {
        CropBox.resolvedRect(of: recipe.crop, frameSize: frameSize)
    }

    var cropAspect: CGFloat? {
        CropBox.normalizedAspect(for: recipe.crop.shape, frameSize: frameSize)
    }

    func setShape(_ shape: CropShape) {
        update {
            $0.crop.shape = shape
            // Free keeps the current box; shapes start as the largest centred box.
            $0.crop.rect = shape == .free ? CropBox.resolvedRect(of: $0.crop, frameSize: frameSize) : nil
        }
    }

    func setCropRect(_ rect: CGRect) {
        update { $0.crop.rect = rect }
    }

    var straighten: Double {
        get { recipe.crop.straighten }
        set {
            let range = PhotoCrop.straightenRange
            update { $0.crop.straighten = min(max(newValue, range.lowerBound), range.upperBound) }
        }
    }

    func rotate() {
        update { $0.crop.rotateClockwise() }
    }

    func flip() {
        update { $0.crop.flipHorizontally() }
    }

    // MARK: - Recipe

    /// Changes the working recipe, redraws and stores it shortly after.
    private func update(_ change: (inout PhotoRecipe) -> Void) {
        var next = recipe
        change(&next)
        guard next != recipe else { return }
        recipe = next
        scheduleRender()
        scheduleCommit()
    }

    func reset() {
        guard let record else { return }
        recipe = record.initialRecipe
        scheduleRender()
        commit()
        refreshLookThumbnails()
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commit()
        }
    }

    /// Stores the working recipe on the photo now.
    func commit() {
        commitTask?.cancel()
        commitTask = nil
        library.updateRecipe(id: id, recipe)
    }

    /// Called when the editor closes.
    func finish() {
        commit()
        if !currentLook.isOriginal {
            settings.noteRecentlyUsed(currentLook)
        }
    }

    // MARK: - Rendering

    /// Redraws what the current tab needs; repeated calls coalesce, so
    /// slider drags only ever draw the latest value.
    private func scheduleRender() {
        guard renderTask == nil else {
            renderAgain = true
            return
        }
        renderTask = Task {
            repeat {
                renderAgain = false
                await renderOnce()
            } while renderAgain
            renderTask = nil
        }
    }

    private func renderOnce() async {
        guard let record else { return }
        let url = library.url(for: record)
        let renderer = library.renderer
        let recipe = self.recipe
        let look = currentLook

        if tab == .crop {
            let key = CropBaseKey(lookID: recipe.lookID, strength: recipe.strength, adjustments: recipe.adjustments,
                                  quarterTurns: recipe.crop.quarterTurns, isFlipped: recipe.crop.isFlipped)
            if key != cropBaseKey || cropBase == nil {
                var base = recipe
                base.crop = PhotoCrop(shape: .free, quarterTurns: recipe.crop.quarterTurns, isFlipped: recipe.crop.isFlipped)
                if let image = await renderer.preview(id: id, sourceURL: url, look: look, recipe: base) {
                    cropBase = image
                    cropBaseKey = key
                }
            }
            return
        }

        if let image = await renderer.preview(id: id, sourceURL: url, look: look, recipe: recipe) {
            preview = image
        }
        if originalCrop != recipe.crop || original == nil {
            if let image = await renderer.original(id: id, sourceURL: url, crop: recipe.crop) {
                original = image
                originalCrop = recipe.crop
            }
        }
    }

    /// Draws this photo in every look (keeping its sliders and crop) for the
    /// strip, when they changed since last time.
    func refreshLookThumbnails() {
        guard let record else { return }
        var key = recipe
        key.lookID = Look.original.id
        key.strength = 1
        guard key != thumbnailsRecipe else { return }
        thumbnailsRecipe = key
        thumbnailsTask?.cancel()
        let url = library.url(for: record)
        let renderer = library.renderer
        let all = looks.looks
        thumbnailsTask = Task {
            let images = await renderer.thumbnails(sourceURL: url, looks: all, recipe: key, seed: id.effectsSeed)
            guard !Task.isCancelled else { return }
            lookThumbnails = images
        }
    }

    // MARK: - Save and share

    var saveTitle: LocalizedStringKey {
        if isLocked { return "Unlock to Save" }
        if isSaved { return isImported ? "Copy Saved" : "Saved to Photos" }
        return isImported ? "Save Copy" : "Save to Photos"
    }

    func save() {
        commit()
        guard let record, !isSaving else { return }
        if isLocked {
            requestPremium(currentLook, original, preview)
            return
        }
        isSaving = true
        let watermark = !hasPremium()
        let includeOriginal = settings.alsoSaveOriginal
        let format = settings.photoFormat
        Task {
            defer { isSaving = false }
            do {
                try await library.saveToPhotos(record, watermark: watermark, includeOriginal: includeOriginal, format: format)
                savedCount += 1
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                alert = .photosAccessDenied
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    func share() {
        commit()
        guard let record, !isPreparingShare else { return }
        if isLocked {
            requestPremium(currentLook, original, preview)
            return
        }
        isPreparingShare = true
        let watermark = !hasPremium()
        Task {
            defer { isPreparingShare = false }
            do {
                shareItem = ShareItem(url: try await library.exportForSharing(record, watermark: watermark))
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

}
