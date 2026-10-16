import SwiftUI
import UIKit

/// Hosts the Metal layer the preview renderer draws into.
///
/// The view never draws on its own: it provides a correctly sized,
/// colour-managed CAMetalLayer, and the renderer presents frames into that
/// layer from its own queue as camera frames arrive.
struct CameraPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MetalLayerView {
        let view = MetalLayerView()
        view.isOpaque = true
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false

        let layer = view.metalLayer
        layer.device = renderer.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = false
        layer.colorspace = LookPipeline.outputColorSpace
        layer.maximumDrawableCount = 3
        renderer.attach(layer)
        return view
    }

    func updateUIView(_ view: MetalLayerView, context: Context) {}
}

/// A view backed by a CAMetalLayer whose drawable always matches the view's
/// size in pixels.
///
/// This replaces a paused MTKView, whose automatic resizing left the drawable
/// at 0×0 on iOS 27: every `nextDrawable()` then failed and the preview stayed
/// black.
final class MetalLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Layer-backed Metal views default to a scale of 1; match the screen.
        let scale = traitCollection.displayScale
        guard scale > 0 else { return }
        if contentScaleFactor != scale { contentScaleFactor = scale }

        let size = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        guard size.width > 0, size.height > 0, metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
    }
}
