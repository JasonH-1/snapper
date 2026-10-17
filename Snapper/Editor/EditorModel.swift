import OSLog
import SwiftUI

/// The photo editor: a look and its strength, light and colour sliders, and
/// crop, straighten, turn and mirror. Everything is a recipe on the photo's
/// record; the original file is never changed.
@MainActor
@Observable
final class EditorModel: Identifiable, Hashable {
    enum Tab: String, CaseIterable, Identifiable {
        case looks, adjust, crop, finish

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .looks: "camera.filters"
            case .adjust: "slider.horizontal.3"
            case .crop: "crop.rotate"
            case .finish: "rectangle.inset.filled"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .looks: "Looks"
            case .adjust: "Adjust"
            case .crop: "Crop"
            case .finish: "Finish"
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
            interaction(began: false)
            isShowingOriginal = false
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
    /// The one-time note that edits stay in Snapper until saved.
    private(set) var showsEditsKeptHint = false

    /// Recipes to step back to, oldest first, and ones undone.
    private(set) var undoStack: [PhotoRecipe] = []
    private(set) var redoStack: [PhotoRecipe] = []

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
    /// True while a run of changes (one slider drag, one crop drag) is
    /// collecting into a single undo step; closed when it is stored.
    @ObservationIgnored private var isChangeGroupOpen = false
    @ObservationIgnored private var hintTask: Task<Void, Never>?
    /// A finger is on a slider, dial or the crop box: everything until it
    /// lifts is one undo step, however long it pauses.
    @ObservationIgnored private var isInteracting = false
    /// The original photo's upright size in pixels.
    @ObservationIgnored private let sourceSize: CGSize?

    /// Undo steps kept per editing session.
    static let maxUndoSteps = 50

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
        // Only the file's header is read, so this is quick enough to do here.
        self.sourceSize = library.record(id: id).flatMap { PhotoRenderer.orientedPixelSize(url: library.url(for: $0)) }
        preview = library.thumbnails[id]
        scheduleRender()
        refreshLookThumbnails()
    }

    nonisolated static func == (lhs: EditorModel, rhs: EditorModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    // MARK: - State

    var record: CaptureRecord? { library.record(id: id) }
    var currentLook: Look { looks.look(id: recipe.lookID) ?? .original }
    var isLocked: Bool { (currentLook.isPremium || recipe.finish.isActive) && !hasPremium() }
    var hasPremiumNow: Bool { hasPremium() }
    var isImported: Bool { record?.isImported ?? false }
    var isEdited: Bool { record.map { recipe != $0.initialRecipe } ?? false }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// What each per-part reset would go back to.
    private var initialRecipe: PhotoRecipe { record?.initialRecipe ?? .untouched }
    var isLookChanged: Bool { recipe.lookID != initialRecipe.lookID || recipe.strength != initialRecipe.strength }
    var isLightChanged: Bool { recipe.adjustments != initialRecipe.adjustments }
    var isCropChanged: Bool { recipe.crop != initialRecipe.crop }
    var isFinishChanged: Bool { recipe.finish != initialRecipe.finish }

    var collectionName: String? { looks.collection(for: currentLook)?.name }
    var isCurrentLookFavorite: Bool { settings.isFavorite(currentLook) }
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
        step { $0.lookID = look.id }
    }

    var strength: Double {
        get { recipe.strength }
        set { update { $0.strength = min(max(newValue, 0), 1) } }
    }

    func toggleFavorite(_ look: Look) {
        settings.toggleFavorite(look)
    }

    // MARK: - Personal presets and finishing

    @discardableResult
    func applyPreset(_ preset: SavedPreset) -> Bool {
        guard settings.presets.canUse(preset, hasPremium: hasPremium()), looks.look(id: preset.lookID) != nil else { return false }
        step { $0 = preset.applying(to: $0) }
        refreshLookThumbnails()
        return true
    }

    var frame: PhotoFinish.Frame {
        get { recipe.finish.frame }
        set { step { $0.finish.frame = newValue } }
    }
    var border: Double {
        get { recipe.finish.border }
        set { update { $0.finish.border = min(max(newValue, 0.01), 0.16) } }
    }
    var exportLayout: PhotoFinish.Layout {
        get { recipe.finish.layout }
        set { step { $0.finish.layout = newValue } }
    }
    var hasDateStamp: Bool {
        get { recipe.finish.dateStamp != nil }
        set {
            let date = newValue ? Self.stampFormatter.string(from: stampDate) : nil
            step { $0.finish.dateStamp = date }
        }
    }
    var stampDate: Date {
        get {
            recipe.finish.dateStamp.flatMap(Self.stampFormatter.date(from:))
                ?? record?.takenAt ?? record?.createdAt ?? Date()
        }
        set { step { $0.finish.dateStamp = Self.stampFormatter.string(from: newValue) } }
    }
    private static var stampFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy.MM.dd"
        return formatter
    }
    func resetFinish() { step { $0.finish = .none } }

    // MARK: - Adjust

    func value(of kind: PhotoAdjustments.Kind) -> Double {
        recipe.adjustments[kind]
    }

    func setValue(_ value: Double, for kind: PhotoAdjustments.Kind) {
        update { $0.adjustments[kind] = value }
    }

    func resetValue(of kind: PhotoAdjustments.Kind) {
        step { $0.adjustments[kind] = 0 }
    }

    // MARK: - Crop

    /// The turned, uncropped frame's size in pixels (for box shapes). Taken
    /// from the original, never from the preview, which is already cropped.
    var frameSize: CGSize {
        if let size = sourceSize ?? cropBase?.size.applyingTurns(-recipe.crop.quarterTurns) {
            return size.applyingTurns(recipe.crop.quarterTurns)
        }
        return CGSize(width: 3, height: 4)
    }

    var cropRect: CGRect {
        CropBox.resolvedRect(of: recipe.crop, frameSize: frameSize)
    }

    var cropAspect: CGFloat? {
        CropBox.normalizedAspect(for: recipe.crop.shape, frameSize: frameSize)
    }

    /// Shapes to offer: 4:3 is left out when it is the photo's own shape
    /// (every Snapper shot), where it would only repeat Original.
    var cropShapes: [CropShape] {
        let size = frameSize
        let long = max(size.width, size.height), short = max(min(size.width, size.height), 1)
        let isFourThree = abs(long / short - 4.0 / 3.0) < 0.02
        return isFourThree ? CropShape.allCases.filter { $0 != .fourThree } : CropShape.allCases
    }

    /// The shape chip to highlight.
    var selectedShape: CropShape {
        let shape = recipe.crop.shape
        return shape == .fourThree && !cropShapes.contains(.fourThree) ? .original : shape
    }

    func setShape(_ shape: CropShape) {
        step {
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
        step { $0.crop.rotateClockwise() }
    }

    func flip() {
        step { $0.crop.flipHorizontally() }
    }

    // MARK: - Recipe

    /// Changes the working recipe, redraws and stores it shortly after.
    /// Changes in quick succession (a drag) make one undo step.
    private func update(_ change: (inout PhotoRecipe) -> Void) {
        var next = recipe
        change(&next)
        guard next != recipe else { return }
        if !isChangeGroupOpen {
            undoStack.append(recipe)
            if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst() }
            redoStack.removeAll()
            isChangeGroupOpen = true
        }
        recipe = next
        // Comparing would hide the change being made.
        isShowingOriginal = false
        scheduleRender()
        scheduleCommit()
        showEditsKeptHintIfNeeded()
    }

    /// A slider, dial or crop drag started or ended.
    func interaction(began: Bool) {
        isInteracting = began
        if !began { commit() }
    }

    /// A single tap's change (a look, a shape, a turn, a reset): always its
    /// own undo step, stored at once.
    private func step(_ change: (inout PhotoRecipe) -> Void) {
        if isChangeGroupOpen { commit() }
        update(change)
        commit()
    }

    func undo() {
        commit()
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(recipe)
        apply(previous)
    }

    func redo() {
        commit()
        guard let next = redoStack.popLast() else { return }
        undoStack.append(recipe)
        apply(next)
    }

    /// Jumps to a recipe from the undo history and stores it.
    private func apply(_ recipe: PhotoRecipe) {
        self.recipe = recipe
        scheduleRender()
        commit()
        if tab == .looks { refreshLookThumbnails() }
    }

    /// Everything back to how the photo was taken or imported (undoable).
    func reset() {
        let initial = initialRecipe
        step { $0 = initial }
        if tab == .looks { refreshLookThumbnails() }
    }

    func resetLook() {
        let initial = initialRecipe
        step {
            $0.lookID = initial.lookID
            $0.strength = initial.strength
        }
    }

    func resetLight() {
        let initial = initialRecipe
        step { $0.adjustments = initial.adjustments }
    }

    func resetCrop() {
        let initial = initialRecipe
        step { $0.crop = initial.crop }
    }

    private func showEditsKeptHintIfNeeded() {
        guard !settings.hasSeenEditsKeptHint else { return }
        settings.hasSeenEditsKeptHint = true
        withAnimation(.easeOut(duration: 0.25)) { showsEditsKeptHint = true }
        hintTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: 0.3)) { showsEditsKeptHint = false }
        }
    }

    func dismissEditsKeptHint() {
        hintTask?.cancel()
        withAnimation(.easeIn(duration: 0.2)) { showsEditsKeptHint = false }
    }

    private func scheduleCommit() {
        commitTask?.cancel()
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if isInteracting {
                // Store it in case the app goes away mid-drag, but keep the undo step open.
                library.updateRecipe(id: id, recipe)
            } else {
                commit()
            }
        }
    }

    /// Stores the working recipe on the photo now, closing the current undo step.
    func commit() {
        commitTask?.cancel()
        commitTask = nil
        isChangeGroupOpen = false
        library.updateRecipe(id: id, recipe)
    }

    /// Called when the editor closes.
    func finish() {
        isInteracting = false
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
        let renderingTab = tab

        if tab == .crop {
            let key = CropBaseKey(lookID: recipe.lookID, strength: recipe.strength, adjustments: recipe.adjustments,
                                  quarterTurns: recipe.crop.quarterTurns, isFlipped: recipe.crop.isFlipped)
            if key != cropBaseKey || cropBase == nil {
                var base = recipe
                base.crop = PhotoCrop(shape: .free, quarterTurns: recipe.crop.quarterTurns, isFlipped: recipe.crop.isFlipped)
                base.finish = .none
                if let image = await renderer.preview(id: id, sourceURL: url, look: look, recipe: base) {
                    guard self.recipe == recipe, tab == renderingTab else { return }
                    cropBase = image
                    cropBaseKey = key
                }
            }
            return
        }

        if let image = await renderer.preview(id: id, sourceURL: url, look: look, recipe: recipe) {
            guard self.recipe == recipe, tab == renderingTab else { return }
            preview = image
        }
        if originalCrop != recipe.crop || original == nil {
            if let image = await renderer.original(id: id, sourceURL: url, crop: recipe.crop) {
                guard self.recipe == recipe, tab == renderingTab else { return }
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
        let watermark = false
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
        let watermark = false
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

private extension CGSize {
    /// The size after `turns` quarter turns (negative turns back).
    func applyingTurns(_ turns: Int) -> CGSize {
        turns % 2 == 0 ? self : CGSize(width: height, height: width)
    }
}
