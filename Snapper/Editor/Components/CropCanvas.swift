import SwiftUI

/// The Crop tab's canvas: the turned photo, straightened live, with a crop
/// box to drag (inside to move it, corners to resize it). Outside the box is
/// dimmed; a rule-of-thirds grid sits inside.
struct CropCanvas: View {
    /// Mirrored and turned, not straightened or cropped.
    let image: UIImage
    let straighten: Double
    /// The box in normalised top-left coordinates of the frame.
    let rect: CGRect
    /// Normalised width over height to hold the box to, or nil when free.
    let aspect: CGFloat?
    var onChange: (CGRect) -> Void

    @State private var dragStart: CGRect?
    @State private var isDragging = false

    private static let handleLength: CGFloat = 20
    private static let handleHitSize: CGFloat = 44

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedFrame(in: geometry.size)
            let box = CGRect(x: frame.minX + rect.minX * frame.width,
                             y: frame.minY + rect.minY * frame.height,
                             width: rect.width * frame.width,
                             height: rect.height * frame.height)
            ZStack(alignment: .topLeading) {
                // The straightened photo: rotated about the centre and zoomed
                // so it covers the frame, exactly as the renderer does.
                Image(uiImage: image)
                    .resizable()
                    .frame(width: frame.width, height: frame.height)
                    .rotationEffect(.degrees(straighten))
                    .scaleEffect(PhotoCrop.straightenScale(degrees: straighten, size: image.size))
                    .frame(width: frame.width, height: frame.height)
                    .clipped()
                    .overlay(alignment: .topLeading) {
                        dimming(around: box.offsetBy(dx: -frame.minX, dy: -frame.minY), in: frame.size)
                    }
                    .offset(x: frame.minX, y: frame.minY)

                boxOverlay(box)
                    .allowsHitTesting(false)

                // Moving: anywhere inside the box.
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: max(box.width - Self.handleHitSize, 1), height: max(box.height - Self.handleHitSize, 1))
                    .position(x: box.midX, y: box.midY)
                    .gesture(moveGesture(frame: frame))

                ForEach(CropBox.Handle.allCases, id: \.self) { handle in
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: Self.handleHitSize, height: Self.handleHitSize)
                        .position(point(of: handle, in: box))
                        .gesture(resizeGesture(handle, frame: frame))
                        .accessibilityHidden(true)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Crop box"))
    }

    /// Darkens the photo outside the box: four bands around it, in the
    /// photo's own coordinates.
    private func dimming(around box: CGRect, in size: CGSize) -> some View {
        let shade = Color.black.opacity(0.62)
        return ZStack(alignment: .topLeading) {
            shade.frame(width: size.width, height: max(box.minY, 0))
            shade.frame(width: size.width, height: max(size.height - box.maxY, 0))
                .offset(y: box.maxY)
            shade.frame(width: max(box.minX, 0), height: max(box.height, 0))
                .offset(y: box.minY)
            shade.frame(width: max(size.width - box.maxX, 0), height: max(box.height, 0))
                .offset(x: box.maxX, y: box.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The largest frame of the image's shape that fits, with room for the handles.
    private func fittedFrame(in size: CGSize) -> CGRect {
        let inset: CGFloat = 16
        let available = CGSize(width: max(size.width - inset * 2, 1), height: max(size.height - inset * 2, 1))
        let aspect = image.size.width / max(image.size.height, 1)
        var fitted = available
        if available.width / available.height > aspect {
            fitted.width = available.height * aspect
        } else {
            fitted.height = available.width / aspect
        }
        return CGRect(x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    private func boxOverlay(_ box: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(.white.opacity(0.9), lineWidth: 1)
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)

            // Thirds, brighter while dragging.
            Path { path in
                for i in 1...2 {
                    let x = box.minX + box.width * CGFloat(i) / 3
                    path.move(to: CGPoint(x: x, y: box.minY))
                    path.addLine(to: CGPoint(x: x, y: box.maxY))
                    let y = box.minY + box.height * CGFloat(i) / 3
                    path.move(to: CGPoint(x: box.minX, y: y))
                    path.addLine(to: CGPoint(x: box.maxX, y: y))
                }
            }
            .stroke(.white.opacity(isDragging ? 0.55 : 0.35), lineWidth: 1)

            Path { path in
                let l = min(Self.handleLength, box.width / 2, box.height / 2)
                let corners: [(CGPoint, CGFloat, CGFloat)] = [
                    (CGPoint(x: box.minX, y: box.minY), 1, 1),
                    (CGPoint(x: box.maxX, y: box.minY), -1, 1),
                    (CGPoint(x: box.minX, y: box.maxY), 1, -1),
                    (CGPoint(x: box.maxX, y: box.maxY), -1, -1),
                ]
                for (corner, dx, dy) in corners {
                    let c = CGPoint(x: corner.x - dx * 1.5, y: corner.y - dy * 1.5)
                    path.move(to: CGPoint(x: c.x + dx * l, y: c.y))
                    path.addLine(to: c)
                    path.addLine(to: CGPoint(x: c.x, y: c.y + dy * l))
                }
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 4, lineCap: .square))
        }
    }

    private func point(of handle: CropBox.Handle, in box: CGRect) -> CGPoint {
        switch handle {
        case .topLeft: CGPoint(x: box.minX, y: box.minY)
        case .topRight: CGPoint(x: box.maxX, y: box.minY)
        case .bottomLeft: CGPoint(x: box.minX, y: box.maxY)
        case .bottomRight: CGPoint(x: box.maxX, y: box.maxY)
        }
    }

    private func normalized(_ translation: CGSize, in frame: CGRect) -> CGSize {
        CGSize(width: translation.width / max(frame.width, 1), height: translation.height / max(frame.height, 1))
    }

    private func moveGesture(frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                isDragging = true
                onChange(CropBox.moved(start, by: normalized(value.translation, in: frame)))
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false
            }
    }

    private func resizeGesture(_ handle: CropBox.Handle, frame: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? rect
                dragStart = start
                isDragging = true
                onChange(CropBox.resized(start, handle: handle, by: normalized(value.translation, in: frame),
                                         aspect: aspect, frameAspect: frame.width / max(frame.height, 1)))
            }
            .onEnded { _ in
                dragStart = nil
                isDragging = false
            }
    }
}
