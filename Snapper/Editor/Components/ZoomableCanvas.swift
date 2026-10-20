import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Lets SwiftUI zoom the canvas (accessibility actions, the Fit button).
@MainActor
final class CanvasController {
    fileprivate weak var view: ZoomableCanvasView?

    func zoomIn() { view?.stepZoom(by: 2) }
    func zoomOut() { view?.stepZoom(by: 0.5) }
    func fit() { view?.fit(animated: true) }
}

/// The brush, when the canvas is painting the selection.
struct CanvasBrush: Equatable {
    /// Diameter on screen, in points; zooming in makes the brush finer.
    var diameter: CGFloat
    var mode: MaskStroke.Mode
}

/// A brush stroke on the canvas. Points are on the photo shown, 0…1 from
/// its top left; the radius is a fraction of its width.
enum CanvasStroke {
    case began(CGPoint, radius: CGFloat)
    case moved([CGPoint])
    case ended
    case cancelled
}

/// The editor's photo: pinch to zoom, drag to move around a zoomed photo,
/// double-tap to zoom in or back out, and touch and hold to compare. With a
/// brush, one finger paints and two fingers zoom and move, as in drawing
/// apps; a stroke that turns into a pinch is dropped.
struct ZoomableCanvas: UIViewRepresentable {
    var image: UIImage?
    /// A see-through layer the same shape as the photo (the selection).
    var overlay: UIImage?
    var overlayOpacity: CGFloat = 0.55
    var brush: CanvasBrush?
    var controller: CanvasController
    var onStroke: (CanvasStroke) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }

    func makeUIView(context: Context) -> ZoomableCanvasView {
        ZoomableCanvasView()
    }

    func updateUIView(_ view: ZoomableCanvasView, context: Context) {
        controller.view = view
        view.onStroke = onStroke
        view.onPress = onPress
        view.onZoom = onZoom
        view.setImage(image)
        view.setOverlay(overlay, opacity: overlayOpacity)
        view.brush = brush
    }
}

final class ZoomableCanvasView: UIScrollView, UIScrollViewDelegate {
    var onStroke: (CanvasStroke) -> Void = { _ in }
    var onPress: (Bool) -> Void = { _ in }
    var onZoom: (CGFloat) -> Void = { _ in }
    var brush: CanvasBrush? {
        didSet { if brush != oldValue { brushChanged() } }
    }

    private let content = UIView()
    private let imageView = UIImageView()
    private let overlayView = UIImageView()
    /// The stroke being painted, drawn at once while the mask catches up.
    private let strokeLayer = CAShapeLayer()
    private let cursorLayer = CAShapeLayer()
    private let strokeRecognizer = StrokeGestureRecognizer()
    private let doubleTapRecognizer = UITapGestureRecognizer()
    private let pressRecognizer = UILongPressGestureRecognizer()
    /// Lets the stroke and the press run alongside the scroll view's own
    /// gestures, without taking over the scroll view's delegate role for them.
    private let simultaneous = SimultaneousGestures()

    private var imageAspect: CGFloat = 0
    private var laidOutBounds: CGSize = .zero
    private var strokePath = UIBezierPath()
    private var sentPoints = 0
    private var reportedZoom: CGFloat = 1
    /// The overlay the finished stroke is waiting on before it's cleared.
    private var overlayAtStrokeEnd: UIImage?

    static let maximumZoom: CGFloat = 8
    private static let cornerRadius: CGFloat = 10

    init() {
        super.init(frame: .zero)
        delegate = self
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        minimumZoomScale = 1
        maximumZoomScale = Self.maximumZoom
        bouncesZoom = true
        decelerationRate = .fast
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        clipsToBounds = true
        layer.cornerRadius = Self.cornerRadius
        layer.cornerCurve = .continuous

        addSubview(content)
        for view in [imageView, overlayView] {
            view.contentMode = .scaleToFill
            view.clipsToBounds = true
            view.layer.cornerCurve = .continuous
            content.addSubview(view)
        }
        overlayView.isUserInteractionEnabled = false
        strokeLayer.fillColor = nil
        strokeLayer.lineCap = .round
        strokeLayer.lineJoin = .round
        content.layer.addSublayer(strokeLayer)
        cursorLayer.fillColor = nil
        cursorLayer.strokeColor = UIColor.white.withAlphaComponent(0.9).cgColor
        cursorLayer.shadowColor = UIColor.black.cgColor
        cursorLayer.shadowOpacity = 0.6
        cursorLayer.shadowRadius = 1
        cursorLayer.shadowOffset = .zero
        cursorLayer.isHidden = true
        content.layer.addSublayer(cursorLayer)

        strokeRecognizer.addTarget(self, action: #selector(handleStroke(_:)))
        strokeRecognizer.delegate = simultaneous
        addGestureRecognizer(strokeRecognizer)

        doubleTapRecognizer.numberOfTapsRequired = 2
        doubleTapRecognizer.addTarget(self, action: #selector(handleDoubleTap(_:)))
        addGestureRecognizer(doubleTapRecognizer)

        pressRecognizer.minimumPressDuration = 0.15
        pressRecognizer.allowableMovement = 40
        pressRecognizer.addTarget(self, action: #selector(handlePress(_:)))
        pressRecognizer.delegate = simultaneous
        addGestureRecognizer(pressRecognizer)

        pinchGestureRecognizer?.addTarget(self, action: #selector(handlePinch(_:)))
        brushChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Content

    func setImage(_ image: UIImage?) {
        guard imageView.image !== image else { return }
        imageView.image = image
        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let aspect = image.size.width / image.size.height
        // A new shape (a crop or turn) starts again from the whole photo.
        if abs(aspect - imageAspect) > 0.005 {
            imageAspect = aspect
            layoutContent(resettingZoom: true)
        }
    }

    func setOverlay(_ overlay: UIImage?, opacity: CGFloat) {
        overlayView.alpha = opacity
        guard overlayView.image !== overlay else { return }
        overlayView.image = overlay
        // The finished stroke is in the new overlay now.
        if overlayAtStrokeEnd != nil, overlay !== overlayAtStrokeEnd {
            clearStrokePreview()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != laidOutBounds {
            laidOutBounds = bounds.size
            layoutContent(resettingZoom: true)
        }
    }

    private func layoutContent(resettingZoom: Bool) {
        guard imageAspect > 0, bounds.width > 0, bounds.height > 0 else { return }
        if resettingZoom { setZoomScale(1, animated: false) }
        let fit = bounds.width / bounds.height > imageAspect
            ? CGSize(width: bounds.height * imageAspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / imageAspect)
        content.bounds = CGRect(origin: .zero, size: fit)
        content.center = CGPoint(x: fit.width * zoomScale / 2, y: fit.height * zoomScale / 2)
        imageView.frame = content.bounds
        overlayView.frame = content.bounds
        strokeLayer.frame = content.bounds
        cursorLayer.frame = content.bounds
        contentSize = CGSize(width: fit.width * zoomScale, height: fit.height * zoomScale)
        centerContent()
        if resettingZoom {
            contentOffset = CGPoint(x: -contentInset.left, y: -contentInset.top)
        }
        updateCorners()
    }

    /// Keeps a photo smaller than the view in its middle.
    private func centerContent() {
        let horizontal = max(0, (bounds.width - contentSize.width) / 2)
        let vertical = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    /// The photo's rounded corners stay the same size on screen at any zoom.
    private func updateCorners() {
        let radius = Self.cornerRadius / max(zoomScale, 1)
        imageView.layer.cornerRadius = radius
        overlayView.layer.cornerRadius = radius
    }

    // MARK: - Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateCorners()
        updateStrokeWidths()
        reportZoom()
    }

    private func reportZoom() {
        let zoom = zoomScale
        guard abs(zoom - reportedZoom) > 0.01 else { return }
        reportedZoom = zoom
        let onZoom = self.onZoom
        // Not during a SwiftUI update.
        Task { @MainActor in onZoom(zoom) }
    }

    func fit(animated: Bool) {
        setZoomScale(1, animated: animated)
    }

    func stepZoom(by factor: CGFloat) {
        let target = min(max(zoomScale * factor, minimumZoomScale), maximumZoomScale)
        let center = CGPoint(x: (contentOffset.x + bounds.width / 2) / zoomScale,
                             y: (contentOffset.y + bounds.height / 2) / zoomScale)
        zoom(around: center, scale: target)
    }

    private func zoom(around point: CGPoint, scale: CGFloat) {
        let size = CGSize(width: bounds.width / scale, height: bounds.height / scale)
        zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                        width: size.width, height: size.height), animated: true)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            zoom(around: recognizer.location(in: content), scale: 2.5)
        }
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        // A stroke that turned into a pinch was never meant as paint.
        if recognizer.state == .began, strokeRecognizer.state == .began || strokeRecognizer.state == .changed {
            strokeRecognizer.cancel()
        }
    }

    // MARK: - Compare

    @objc private func handlePress(_ recognizer: UILongPressGestureRecognizer) {
        switch recognizer.state {
        case .began: onPress(true)
        case .ended, .cancelled, .failed: onPress(false)
        default: break
        }
    }

    // MARK: - Brush

    private func brushChanged() {
        let painting = brush != nil
        strokeRecognizer.isEnabled = painting
        pressRecognizer.isEnabled = !painting
        // A tap paints a dab, so double-tap zoom is for viewing only.
        doubleTapRecognizer.isEnabled = !painting
        // While painting, moving the photo takes two fingers.
        panGestureRecognizer.minimumNumberOfTouches = painting ? 2 : 1
        if !painting { clearStrokePreview() }
        let color: UIColor = brush?.mode == .erase
            ? UIColor.white.withAlphaComponent(0.45)
            : UIColor(red: 1, green: 0.25, blue: 0.2, alpha: 0.5)
        strokeLayer.strokeColor = color.cgColor
        updateStrokeWidths()
    }

    private func updateStrokeWidths() {
        let zoom = max(zoomScale, 0.01)
        strokeLayer.lineWidth = (brush?.diameter ?? 20) / zoom
        cursorLayer.lineWidth = 1.5 / zoom
    }

    @objc private func handleStroke(_ recognizer: StrokeGestureRecognizer) {
        guard let brush, content.bounds.width > 0, content.bounds.height > 0 else { return }
        let source = recognizer.view
        let points = recognizer.points.map { point in source?.convert(point, to: content) ?? point }
        switch recognizer.state {
        case .began:
            clearStrokePreview()
            guard let first = points.first else { return }
            onStroke(.began(normalized(first), radius: brush.diameter / 2 / max(zoomScale, 0.01) / content.bounds.width))
            strokePath = UIBezierPath()
            strokePath.move(to: first)
            sentPoints = 1
            sendNewPoints(points)
        case .changed:
            sendNewPoints(points)
        case .ended:
            if sentPoints == 0, let first = points.first {
                // A tap: one dab.
                onStroke(.began(normalized(first), radius: brush.diameter / 2 / max(zoomScale, 0.01) / content.bounds.width))
                strokePath = UIBezierPath()
                strokePath.move(to: first)
                strokePath.addLine(to: first)
                sentPoints = 1
            }
            sendNewPoints(points)
            onStroke(.ended)
            cursorLayer.isHidden = true
            // Kept on screen until the mask has the stroke drawn in.
            overlayAtStrokeEnd = overlayView.image ?? UIImage()
        case .cancelled, .failed:
            if sentPoints > 0 { onStroke(.cancelled) }
            clearStrokePreview()
        default:
            break
        }
    }

    private func sendNewPoints(_ points: [CGPoint]) {
        guard points.count > sentPoints else { return }
        let fresh = Array(points[sentPoints...])
        sentPoints = points.count
        for point in fresh { strokePath.addLine(to: point) }
        strokeLayer.path = strokePath.cgPath
        if let last = fresh.last { moveCursor(to: last) }
        onStroke(.moved(fresh.map(normalized)))
    }

    private func moveCursor(to point: CGPoint) {
        let radius = (brush?.diameter ?? 20) / 2 / max(zoomScale, 0.01)
        cursorLayer.path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                       width: radius * 2, height: radius * 2)).cgPath
        cursorLayer.isHidden = false
    }

    private func clearStrokePreview() {
        strokePath = UIBezierPath()
        strokeLayer.path = nil
        cursorLayer.isHidden = true
        sentPoints = 0
        overlayAtStrokeEnd = nil
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / content.bounds.width, y: point.y / content.bounds.height)
    }
}

@MainActor
private final class SimultaneousGestures: NSObject, UIGestureRecognizerDelegate {
    // The stroke gives way to a pinch itself; the press ends when one starts.
    // Gestures around the canvas don't run alongside a stroke.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        !(gestureRecognizer is StrokeGestureRecognizer) || other.view === gestureRecognizer.view
    }

    // While painting, gestures around the canvas, like the zoom transition's
    // drag to close the editor, wait for the stroke, so a stroke never closes it.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer is StrokeGestureRecognizer && gestureRecognizer.isEnabled && other.view !== gestureRecognizer.view
    }
}

/// One finger's path across the canvas. It waits a moment before starting so
/// a second finger landing turns the touch into a pinch instead, and it
/// cancels itself if a second finger arrives mid-stroke. A quick tap counts
/// as a single dab.
final class StrokeGestureRecognizer: UIGestureRecognizer {
    /// Points so far, in the recognizer's view.
    private(set) var points: [CGPoint] = []
    private var touch: UITouch?
    private var startTask: Task<Void, Never>?

    /// How long one finger rests before it counts as painting.
    private static let startDelay: Duration = .milliseconds(70)
    /// Moving this far starts the stroke before the delay is up.
    private static let startDistance: CGFloat = 6

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if touch != nil || touches.count > 1 || (event.allTouches?.count ?? 0) > 1 {
            // A second finger: a pinch or a two-finger move, not paint.
            cancel()
            return
        }
        guard let first = touches.first else { return }
        touch = first
        points = [first.location(in: view)]
        startTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.startDelay)
            guard let self, !Task.isCancelled, self.state == .possible, self.touch != nil else { return }
            self.state = .began
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        let samples = event.coalescedTouches(for: touch) ?? [touch]
        points += samples.map { $0.location(in: view) }
        switch state {
        case .possible:
            if let first = points.first, let last = points.last,
               hypot(last.x - first.x, last.y - first.y) >= Self.startDistance {
                startTask?.cancel()
                state = .began
            }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch, touches.contains(touch) else { return }
        startTask?.cancel()
        points.append(touch.location(in: view))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancel()
    }

    /// Ends the stroke without painting it.
    func cancel() {
        startTask?.cancel()
        switch state {
        case .began, .changed: state = .cancelled
        case .possible: state = .failed
        default: break
        }
    }

    override func reset() {
        super.reset()
        startTask?.cancel()
        startTask = nil
        touch = nil
        points = []
    }
}
