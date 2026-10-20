import OSLog
import SwiftUI

/// The photo editor: a look and its strength, light and colour sliders, and
/// crop, straighten, turn and mirror. Everything is a recipe on the photo's
/// record; the original file is never changed.
@MainActor
@Observable
final class EditorModel: Identifiable, Hashable {
    enum Tab: String, CaseIterable, Identifiable {
        case looks, adjust, curves, color, selective, crop, finish

        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .looks: "camera.filters"
            case .adjust: "slider.horizontal.3"
            case .curves: "chart.xyaxis.line"
            case .color: "slider.horizontal.below.square.filled.and.square"
            case .selective: "person.crop.rectangle"
            case .crop: "crop.rotate"
            case .finish: "rectangle.inset.filled"
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .looks: "Looks"
            case .adjust: "Adjust"
            case .curves: "Curves"
            case .color: "Color"
            case .selective: "Selective"
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
    private(set) var subjectMaskPreview: UIImage?
    private(set) var isDetectingSubject = false
    private(set) var subjectDetectionFailed = false
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
    private(set) var isSavingFreeVersion = false
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
        var selective: SelectiveEdits
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
    var isLocked: Bool { needsPremium(recipe) }
    /// Whether the save bar offers the free save under its buttons. It
    /// follows `isLocked` but waits for the finger to lift, so the rows it
    /// adds never move the panel under a drag.
    var offersFreeSave: Bool { lockedWhenDragBegan ?? isLocked }
    /// `isLocked` when the current drag began.
    private var lockedWhenDragBegan: Bool?
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

    func setColorMix(_ value: ColorMix, for band: ColorBand) {
        guard value.isValid else { return }
        update { $0.adjustments.colorMixer[band] = value }
    }
    func resetColorMix() { step { $0.adjustments.colorMixer = ColorMixer() } }

    // MARK: - Curves and split toning

    var curveChannel: ToneCurves.Channel = .rgb
    /// Brightness histogram of the edited photo (64 bins, tallest = 1), drawn
    /// behind the curve.
    private(set) var histogram: [Double] = []

    func curve(for channel: ToneCurves.Channel) -> ToneCurve {
        recipe.adjustments.curves[channel]
    }

    /// Adds a point on the current channel's curve; part of the drag that
    /// placed it (call between `interaction(began:)` calls). Returns its index.
    func addCurvePoint(atInput x: Double) -> Int? {
        var curve = recipe.adjustments.curves[curveChannel]
        guard let index = curve.addPoint(atInput: x) else { return nil }
        let channel = curveChannel
        // Part of the same undo step as the drag that follows.
        update { $0.adjustments.curves[channel] = curve }
        return index
    }

    func moveCurvePoint(at index: Int, to point: CurvePoint) {
        let channel = curveChannel
        update { $0.adjustments.curves[channel].movePoint(at: index, to: point) }
    }

    /// Removes a point: its own undo step, or part of the drag that pulled it off.
    func removeCurvePoint(at index: Int, asPartOfDrag: Bool = false) {
        let channel = curveChannel
        if asPartOfDrag {
            update { $0.adjustments.curves[channel].removePoint(at: index) }
        } else {
            step { $0.adjustments.curves[channel].removePoint(at: index) }
        }
    }

    func resetCurve(_ channel: ToneCurves.Channel) {
        step { $0.adjustments.curves[channel] = .identity }
    }

    func resetAllCurves() {
        step { $0.adjustments.curves = .none }
    }

    var splitToning: SplitToning {
        get { recipe.adjustments.splitToning }
        set {
            var value = newValue
            value.highlightHue = min(max(value.highlightHue, 0), 360)
            value.shadowHue = min(max(value.shadowHue, 0), 360)
            value.highlightSaturation = min(max(value.highlightSaturation, 0), 1)
            value.shadowSaturation = min(max(value.shadowSaturation, 0), 1)
            value.balance = min(max(value.balance, -1), 1)
            guard value.isValid else { return }
            update { $0.adjustments.splitToning = value }
        }
    }

    func resetSplitToning() {
        step { $0.adjustments.splitToning = .none }
    }

    /// Recounts the histogram from the current preview, off the main actor.
    func refreshHistogram() async {
        guard let cgImage = preview?.cgImage else { return }
        let bins = await Task.detached(priority: .utility) { Self.histogram(of: cgImage) }.value
        guard !Task.isCancelled else { return }
        histogram = bins
    }

    /// Brightness histogram of `image` from a small copy, square-rooted so
    /// quiet tones still show next to a big peak.
    nonisolated static func histogram(of image: CGImage, bins: Int = 64) -> [Double] {
        let width = 160, height = max(1, Int(Double(image.height) / Double(max(image.width, 1)) * 160))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return [] }
        var counts = [Double](repeating: 0, count: bins)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let luma = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
            counts[min(bins - 1, Int(luma / 256 * Double(bins)))] += 1
        }
        let rooted = counts.map { $0.squareRoot() }
        let peak = max(rooted.max() ?? 1, 1)
        return rooted.map { $0 / peak }
    }
    func setSelective(_ value: Double, key: WritableKeyPath<SelectiveAdjustment, Double>, background: Bool) {
        guard value.isFinite, canEditSelection else { return }
        let safe = min(max(value, -1), 1)
        update {
            if background { $0.selective.background[keyPath: key] = safe }
            else { $0.selective.subject[keyPath: key] = safe }
        }
    }
    func resetSelective() { step { $0.selective = SelectiveEdits() } }
    func prepareSelective(retry: Bool = false) async {
        guard let record, !isDetectingSubject else { return }
        guard recipe.selective.usesSubjectDetection else {
            // Painting from scratch: nothing to detect.
            subjectDetectionFailed = false
            scheduleRender()
            return
        }
        isDetectingSubject = true
        subjectDetectionFailed = false
        subjectMaskPreview = nil
        let crop = recipe.crop
        let mask = await library.renderer.prepareSubject(sourceURL: library.url(for: record), crop: crop, retry: retry)
        isDetectingSubject = false
        guard recipe.crop == crop else {
            await prepareSelective(retry: retry)
            return
        }
        subjectMaskPreview = mask
        subjectDetectionFailed = mask == nil
        if mask != nil {
            scheduleRender()
            thumbnailsRecipe = nil
            if tab == .looks { refreshLookThumbnails() }
        }
    }
    // MARK: - Zoom

    /// The canvas zoom, reported by the view. Zoomed in, the preview is drawn
    /// at a higher resolution so faces, hair and edges stay sharp.
    var canvasZoom: CGFloat = 1 {
        didSet {
            if (oldValue > Self.detailZoom) != (canvasZoom > Self.detailZoom) { scheduleRender() }
        }
    }
    static let detailZoom: CGFloat = 1.6
    private var previewPixelSize: Int { canvasZoom > Self.detailZoom ? 3600 : 1800 }

    // MARK: - Selection brush

    enum SelectiveMode: String, CaseIterable, Identifiable {
        /// The sliders for the subject and background.
        case adjust
        /// The brush that corrects the selection.
        case refine

        var id: String { rawValue }
    }

    var selectiveMode: SelectiveMode = .adjust {
        didSet { if selectiveMode != oldValue { scheduleRender() } }
    }
    /// The sliders change the background rather than the subject.
    var editsBackground = false {
        didSet { if editsBackground != oldValue { scheduleRender() } }
    }
    /// Show the selection over the photo while adjusting (always shown while refining).
    var showsMaskWhileAdjusting = false {
        didSet { if showsMaskWhileAdjusting != oldValue { scheduleRender() } }
    }
    var brushMode: MaskStroke.Mode = .paint
    /// Brush diameter on screen, in points.
    var brushSize = EditorModel.defaultBrushSize
    static let brushSizeRange = 8.0...160.0
    static let defaultBrushSize = 50.0
    /// 0 is a hard edge, 1 fully feathered.
    var brushSoftness = EditorModel.defaultBrushSoftness
    static let defaultBrushSoftness = 0.5

    /// The selection tinted, the same shape as the preview.
    private(set) var maskOverlay: UIImage?
    @ObservationIgnored private var maskOverlayKey: MaskOverlayKey?
    /// The preview was drawn without finishing (frames, layouts), so it lines
    /// up with the selection and with touches on it.
    private(set) var previewIsUnfinished = false
    @ObservationIgnored private var activeStroke: MaskStroke?
    /// Original-photo pixels per brush radius, for spacing a stroke's points.
    @ObservationIgnored private var activeStrokePixelRadius: CGFloat = 1

    private struct MaskOverlayKey: Equatable {
        var strokes: [MaskStroke]
        var usesSubjectDetection: Bool
        var crop: PhotoCrop
        var background: Bool
    }

    /// There's a selection to edit: a detected subject, or painting from scratch.
    var canEditSelection: Bool {
        subjectMaskPreview != nil || !recipe.selective.usesSubjectDetection
    }

    var isBrushActive: Bool {
        tab == .selective && selectiveMode == .refine && canEditSelection && !isShowingOriginal && previewIsUnfinished
    }

    var showsMaskOverlay: Bool {
        tab == .selective && canEditSelection && previewIsUnfinished && !isShowingOriginal
            && (selectiveMode == .refine || showsMaskWhileAdjusting)
    }

    /// The overlay tints the background when its sliders are showing.
    private var overlayShowsBackground: Bool {
        selectiveMode == .adjust && editsBackground
    }

    var hasBrushStrokes: Bool { !recipe.selective.strokes.isEmpty }

    /// A stroke on the canvas, in its coordinates; kept in the original
    /// photo's, so it stays put whatever the crop.
    func handleStroke(_ event: CanvasStroke) {
        switch event {
        case .began(let point, let radius):
            guard isBrushActive, let size = sourceSize, size.width > 0, size.height > 0 else { return }
            let crop = recipe.crop
            let framed = PhotoEditing.frameTransform(for: crop, imageSize: size).size
            let pixelRadius = radius * framed.width / PhotoEditing.frameScale(for: crop, imageSize: size)
            let fraction = Double(pixelRadius / min(size.width, size.height))
            let range = MaskStroke.radiusRange
            activeStrokePixelRadius = max(pixelRadius, 1)
            activeStroke = MaskStroke(mode: brushMode, radius: min(max(fraction, range.lowerBound), range.upperBound),
                                      softness: min(max(brushSoftness, 0), 1),
                                      points: [PhotoEditing.originalPoint(fromFramed: point, crop: crop, imageSize: size)])
        case .moved(let points):
            guard var stroke = activeStroke, let size = sourceSize else { return }
            let crop = recipe.crop
            // Points closer than a fifth of the radius add nothing to the shape.
            let spacing = activeStrokePixelRadius * 0.2
            for point in points {
                let original = PhotoEditing.originalPoint(fromFramed: point, crop: crop, imageSize: size)
                guard let last = stroke.points.last, stroke.points.count < MaskStroke.maxPoints else { break }
                let distance = hypot((original.x - last.x) * size.width, (original.y - last.y) * size.height)
                if distance >= spacing { stroke.points.append(original) }
            }
            activeStroke = stroke
        case .ended:
            guard let stroke = activeStroke else { return }
            activeStroke = nil
            addStroke(stroke)
        case .cancelled:
            activeStroke = nil
        }
    }

    func addStroke(_ stroke: MaskStroke) {
        guard stroke.isValid else { return }
        guard recipe.selective.strokes.count < SelectiveEdits.maxStrokes else {
            alert = .error(String(localized: "This photo has the most brush strokes Snapper keeps. Clear the brush edits to start over."))
            return
        }
        step { $0.selective.strokes.append(stroke) }
    }

    func clearBrushStrokes() {
        step { $0.selective.strokes = [] }
    }

    /// No usable subject was found: paint the area instead.
    func paintSelectionManually() {
        step { $0.selective.usesSubjectDetection = false }
        subjectDetectionFailed = false
        selectiveMode = .refine
        brushMode = .paint
    }

    /// Back to starting from the detected subject.
    func useSubjectDetection() {
        step { $0.selective.usesSubjectDetection = true }
        Task { await prepareSelective(retry: true) }
    }

    func applyCuratedStyle(_ style: CuratedStyle) {
        guard CuratedCollection.contains(style), looks.look(id: style.recipe.lookID) != nil else { return }
        step {
            $0.lookID = style.recipe.lookID
            $0.strength = style.recipe.strength
            $0.adjustments = style.recipe.adjustments
        }
        refreshLookThumbnails()
    }

    // MARK: - Versions

    /// The named edits kept with this photo, oldest first. The one showing
    /// keeps every change as it's made, so switching never loses work.
    var versions: [PhotoVersion] { record?.versions ?? [] }

    /// The photo with no look or edits, framed as it was taken.
    var originalRecipe: PhotoRecipe {
        PhotoRecipe(lookID: Look.original.id, crop: initialRecipe.crop)
    }

    /// How the photo arrived (a camera shot's look), when that differs from
    /// the plain original.
    var asShotRecipe: PhotoRecipe? {
        initialRecipe == originalRecipe ? nil : initialRecipe
    }

    /// The version showing and being edited, if any.
    var activeVersion: PhotoVersion? {
        versions.first { $0.id == record?.activeVersionID }
    }

    /// An edit that belongs to no version and isn't the original or as shot:
    /// it would be lost by switching, so switching keeps it as a version.
    var hasUnkeptEdit: Bool {
        activeVersion == nil && recipe != originalRecipe && recipe != asShotRecipe
            && !versions.contains { $0.recipe == recipe }
    }

    /// What the canvas says is showing: "Warm", "Original", "New Edit", or
    /// nil for a photo without versions.
    var versionLabel: String? {
        guard !versions.isEmpty else { return nil }
        if let active = activeVersion { return active.name }
        if recipe == originalRecipe { return String(localized: "Original") }
        if let asShot = asShotRecipe, recipe == asShot { return String(localized: "As Shot") }
        if let match = versions.first(where: { $0.recipe == recipe }) { return match.name }
        return String(localized: "New Edit")
    }

    private(set) var versionThumbnails: [UUID: UIImage] = [:]
    private(set) var originalThumbnail: UIImage?
    private(set) var asShotThumbnail: UIImage?
    private(set) var savingVersionIDs: Set<UUID> = []
    /// A short note after switching ("Your edit was kept as “Warm 2”").
    private(set) var versionNotice: String?

    func suggestedVersionName(for recipe: PhotoRecipe? = nil) -> String {
        let recipe = recipe ?? self.recipe
        return PhotoVersion.suggestedName(for: recipe, look: looks.look(id: recipe.lookID) ?? .original, existing: versions)
    }

    /// Keeps the current edit as a new version and goes on editing it.
    func saveVersion(named name: String) {
        commit()
        do {
            let version = try library.saveVersion(photoID: id, name: name, recipe: recipe)
            Task { await loadVersionThumbnail(version) }
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    /// Starts a new version from `recipe` (a copy of the current edit, or the
    /// original) and switches to it.
    func createVersion(named name: String, from source: PhotoRecipe) {
        commit()
        guard keepUnkeptEditIfNeeded(reserving: 1) else { return }
        do {
            let version = try library.saveVersion(photoID: id, name: name, recipe: source)
            show(version.recipe)
            Task { await loadVersionThumbnail(version) }
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    /// Shows a version, or a built-in recipe (Original, As Shot) when
    /// `version` is nil. An edit not kept anywhere is kept as a version first.
    func switchTo(_ target: PhotoRecipe, version: PhotoVersion?) {
        guard version?.id != activeVersion?.id || recipe != target else { return }
        commit()
        guard keepUnkeptEditIfNeeded(reserving: 0) else { return }
        library.setActiveVersion(photoID: id, versionID: version?.id)
        show(target)
    }

    /// Loads a recipe into the editor with a fresh undo history: each version
    /// keeps its own edits, so undo never reaches into another version.
    private func show(_ target: PhotoRecipe) {
        undoStack.removeAll()
        redoStack.removeAll()
        recipe = target
        isShowingOriginal = false
        commit()
        scheduleRender()
        refreshLookThumbnails()
    }

    /// Keeps an edit that would otherwise be lost as a new version. Returns
    /// false (and explains) when there's no room for it.
    private func keepUnkeptEditIfNeeded(reserving extra: Int) -> Bool {
        guard hasUnkeptEdit else {
            guard versions.count + extra <= PhotoVersion.maxCount else {
                alert = .error(CaptureLibrary.VersionError.limitReached.localizedDescription)
                return false
            }
            return true
        }
        guard versions.count + 1 + extra <= PhotoVersion.maxCount else {
            alert = .error(CaptureLibrary.VersionError.limitReached.localizedDescription)
            return false
        }
        let name = suggestedVersionName()
        guard let kept = try? library.saveVersion(photoID: id, name: name, recipe: recipe) else { return false }
        Task { await loadVersionThumbnail(kept) }
        noteVersion(String(localized: "Your edit was kept as “\(kept.name)”."))
        return true
    }

    private func noteVersion(_ message: String) {
        versionNotice = message
        Task {
            try? await Task.sleep(for: .seconds(3))
            if versionNotice == message { versionNotice = nil }
        }
    }

    func renameVersion(_ version: PhotoVersion, to name: String) {
        do {
            try library.renameVersion(photoID: id, versionID: version.id, to: name)
        } catch {
            alert = .error(error.localizedDescription)
        }
    }

    /// Forgets a version. If it was showing, the photo keeps showing that
    /// edit, no longer kept as a version.
    func deleteVersion(_ version: PhotoVersion) {
        library.deleteVersion(photoID: id, versionID: version.id)
        versionThumbnails[version.id] = nil
    }

    /// Whether exporting `recipe` needs Premium the person doesn't have.
    /// Premium edits made while Premium was active stay exportable.
    func needsPremium(_ recipe: PhotoRecipe) -> Bool {
        guard !hasPremium() else { return false }
        guard let record else { return library.usesPremium(recipe) }
        return library.needsPremium(recipe, of: record)
    }

    /// Saves one version to Photos with the export settings.
    func saveVersionToPhotos(_ version: PhotoVersion) {
        commit()
        guard let record, !savingVersionIDs.contains(version.id) else { return }
        // The version showing may have changed since the list was drawn.
        let recipe = versions.first { $0.id == version.id }?.recipe ?? version.recipe
        if needsPremium(recipe) {
            requestPremium(looks.look(id: recipe.lookID) ?? .original, original, preview)
            return
        }
        savingVersionIDs.insert(version.id)
        let options = settings.exportOptions
        let includeOriginal = settings.alsoSaveOriginal
        Task {
            defer { savingVersionIDs.remove(version.id) }
            do {
                try await library.saveToPhotos(record, recipe: recipe, includeOriginal: includeOriginal, options: options)
                savedCount += 1
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                alert = .photosAccessDenied
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    /// Saves every version to Photos, skipping ones that need Premium.
    /// Returns how many were skipped.
    @discardableResult
    func saveAllVersionsToPhotos() -> Int {
        commit()
        let unlocked = versions.filter { !needsPremium($0.recipe) }
        for version in unlocked { saveVersionToPhotos(version) }
        return versions.count - unlocked.count
    }

    /// Small renders of every version and the built-in ones for the list.
    func loadVersionThumbnails() async {
        commit()
        guard let record else { return }
        let url = library.url(for: record)
        let renderer = library.renderer
        if originalThumbnail == nil {
            originalThumbnail = await renderer.thumbnail(sourceURL: url, look: .original, recipe: originalRecipe,
                                                         seed: id.effectsSeed, maxPixelSize: 160)
        }
        if let asShot = asShotRecipe, asShotThumbnail == nil {
            asShotThumbnail = await renderer.thumbnail(sourceURL: url, look: looks.look(id: asShot.lookID) ?? .original,
                                                       recipe: asShot, seed: id.effectsSeed, maxPixelSize: 160)
        }
        for version in versions {
            await loadVersionThumbnail(version)
        }
    }

    private func loadVersionThumbnail(_ version: PhotoVersion) async {
        guard let record, versionThumbnailRecipes[version.id] != version.recipe else { return }
        let image = await library.renderer.thumbnail(sourceURL: library.url(for: record),
                                                     look: looks.look(id: version.recipe.lookID) ?? .original,
                                                     recipe: version.recipe, seed: id.effectsSeed, maxPixelSize: 160)
        // Skip a drawing overtaken by an edit.
        guard versions.first(where: { $0.id == version.id })?.recipe == version.recipe else { return }
        versionThumbnails[version.id] = image
        versionThumbnailRecipes[version.id] = version.recipe
    }

    @ObservationIgnored private var versionThumbnailRecipes: [UUID: PhotoRecipe] = [:]

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
        if began {
            if lockedWhenDragBegan == nil { lockedWhenDragBegan = isLocked }
        } else {
            lockedWhenDragBegan = nil
            commit()
        }
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
        // The version showing keeps every change.
        if let active = activeVersion, active.recipe != recipe {
            library.updateVersion(photoID: id, versionID: active.id, recipe: recipe)
        }
    }

    /// Called when the editor closes.
    func finish() {
        isInteracting = false
        lockedWhenDragBegan = nil
        commit()
        estimateTask?.cancel()
        discardPreparedExport()
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
                                  selective: recipe.selective, quarterTurns: recipe.crop.quarterTurns, isFlipped: recipe.crop.isFlipped)
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

        // Selective shows the photo without finishing, so the selection and
        // brush line up with it.
        var shown = recipe
        let unfinished = tab == .selective
        if unfinished { shown.finish = .none }
        if let image = await renderer.preview(id: id, sourceURL: url, look: look, recipe: shown, maxPixelSize: previewPixelSize) {
            // Mid-drag the recipe has usually moved on by the time a render
            // finishes. Show it anyway when the next render is already
            // queued, so the photo keeps up with the slider; that render
            // draws the latest value.
            guard self.recipe == recipe || renderAgain, tab == renderingTab else { return }
            preview = image
            previewIsUnfinished = unfinished || recipe.finish == .none
        }
        if showsMaskOverlay || (unfinished && (selectiveMode == .refine || showsMaskWhileAdjusting)) {
            let key = MaskOverlayKey(strokes: recipe.selective.strokes, usesSubjectDetection: recipe.selective.usesSubjectDetection,
                                     crop: recipe.crop, background: overlayShowsBackground)
            if key != maskOverlayKey || maskOverlay == nil {
                let overlay = await renderer.selectionOverlay(sourceURL: url, edits: recipe.selective, crop: recipe.crop,
                                                              background: key.background)
                guard self.recipe == recipe, tab == renderingTab else { return }
                maskOverlay = overlay
                maskOverlayKey = overlay == nil ? nil : key
            }
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
        guard let record, !isSaving, !isSavingFreeVersion else { return }
        if isLocked {
            requestPremium(currentLook, original, preview)
            return
        }
        isSaving = true
        let includeOriginal = settings.alsoSaveOriginal
        let options = settings.exportOptions
        // The file the export sheet measured is exactly what would be written.
        let prepared = takePreparedExport(for: recipe, options: options)
        Task {
            defer { isSaving = false }
            do {
                try await library.saveToPhotos(record, includeOriginal: includeOriginal, options: options, prepared: prepared)
                savedCount += 1
            } catch PhotoLibrarySaver.SaveError.notAuthorized {
                alert = .photosAccessDenied
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Saving without Premium

    /// The current edit without its Premium look and tools, which can always
    /// be saved.
    var freeRecipe: PhotoRecipe { library.freeVersion(of: recipe) }

    /// "Save Without Sunburn", naming what saving for free leaves out.
    var freeSaveTitle: String {
        let parts = library.premiumParts(of: recipe)
        switch (parts.look, parts.usesTools) {
        case (let look?, false): return String(localized: "Save Without \(look.name)")
        case (let look?, true): return String(localized: "Save Without \(look.name) & Premium Tools")
        case (nil, _): return String(localized: "Save Without Premium Tools")
        }
    }

    var isFreeVersionSaved: Bool { record?.savedRecipe == freeRecipe }

    /// Saves the photo without its Premium parts, so no photo is ever stuck
    /// behind Premium. The full edit stays on the photo in Snapper.
    func saveWithoutPremium() {
        commit()
        guard let record, !isSaving, !isSavingFreeVersion else { return }
        isSavingFreeVersion = true
        let recipe = freeRecipe
        let includeOriginal = settings.alsoSaveOriginal
        let options = settings.exportOptions
        Task {
            defer { isSavingFreeVersion = false }
            do {
                try await library.saveToPhotos(record, recipe: recipe, includeOriginal: includeOriginal, options: options)
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
        let options = settings.exportOptions
        if let prepared = preparedExport, prepared.recipe == recipe, prepared.options == options {
            shareItem = ShareItem(url: prepared.url)
            isPreparingShare = false
            return
        }
        let recipe = self.recipe
        Task {
            defer { isPreparingShare = false }
            do {
                shareItem = ShareItem(url: try await library.prepareExport(record, recipe: recipe, options: options).url)
            } catch {
                alert = .error(error.localizedDescription)
            }
        }
    }

    // MARK: - Export settings

    /// The export settings, shared with Settings and the Library.
    var exportOptions: ExportOptions {
        get { settings.exportOptions }
        set {
            guard newValue != settings.exportOptions else { return }
            settings.exportOptions = newValue
            scheduleExportEstimate()
        }
    }

    /// The photo exported with the current settings, measured in the
    /// background: its real file size and pixel size.
    private(set) var preparedExport: PreparedExport?
    private(set) var isMeasuringExport = false
    private(set) var exportMeasureFailed = false
    /// The full-resolution size of the edited photo (the Full option).
    private(set) var fullExportSize: CGSize?
    /// Whether the original file records where it was taken.
    private(set) var photoHasLocation = false
    @ObservationIgnored private var estimateTask: Task<Void, Never>?

    /// The export sheet opened: measure what it would write.
    func exportOptionsAppeared() {
        if let record {
            photoHasLocation = PhotoRenderer.hasLocation(url: library.url(for: record))
        }
        scheduleExportEstimate(delay: .zero)
    }

    func exportOptionsDisappeared() {
        estimateTask?.cancel()
        isMeasuringExport = false
    }

    /// Exports in the background after a short pause, so dragging the
    /// quality slider measures once, at the end.
    private func scheduleExportEstimate(delay: Duration = .milliseconds(350)) {
        estimateTask?.cancel()
        commit()
        guard let record else { return }
        if let stale = preparedExport, stale.recipe != recipe || stale.options != settings.exportOptions {
            discardPreparedExport()
        }
        guard preparedExport == nil else { return }
        isMeasuringExport = true
        exportMeasureFailed = false
        let recipe = self.recipe
        let options = settings.exportOptions
        let look = currentLook
        let url = library.url(for: record)
        estimateTask = Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            if fullExportSize == nil || fullExportSizeRecipe != recipe {
                var full = options
                full.size = .full
                fullExportSize = await library.renderer.exportSize(sourceURL: url, look: look, recipe: recipe,
                                                                   seed: id.effectsSeed, options: full)
                fullExportSizeRecipe = recipe
            }
            do {
                let prepared = try await library.prepareExport(record, recipe: recipe, options: options)
                guard !Task.isCancelled, recipe == self.recipe, options == settings.exportOptions else {
                    try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent())
                    return
                }
                discardPreparedExport()
                preparedExport = prepared
            } catch {
                guard !Task.isCancelled else { return }
                exportMeasureFailed = true
            }
            isMeasuringExport = false
        }
    }

    @ObservationIgnored private var fullExportSizeRecipe: PhotoRecipe?

    /// Hands over the measured file if it matches, so it isn't written twice.
    private func takePreparedExport(for recipe: PhotoRecipe, options: ExportOptions) -> PreparedExport? {
        guard let prepared = preparedExport, prepared.recipe == recipe, prepared.options == options else { return nil }
        preparedExport = nil
        return prepared
    }

    private func discardPreparedExport() {
        guard let prepared = preparedExport else { return }
        preparedExport = nil
        let folder = prepared.url.deletingLastPathComponent()
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: folder) }
    }

}

private extension CGSize {
    /// The size after `turns` quarter turns (negative turns back).
    func applyingTurns(_ turns: Int) -> CGSize {
        turns % 2 == 0 ? self : CGSize(width: height, height: width)
    }
}
