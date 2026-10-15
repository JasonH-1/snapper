import MetalKit
import SwiftUI

/// Hosts the Metal view the preview renderer draws into.
///
/// The MTKView never draws on its own (it is paused and has no delegate): it
/// provides a correctly sized, colour-managed CAMetalLayer, and the renderer
/// presents frames into that layer from its own queue as camera frames arrive.
struct CameraPreviewView: UIViewRepresentable {
    let renderer: PreviewRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = false
        view.colorPixelFormat = .bgra8Unorm
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
        view.contentMode = .scaleAspectFill
        view.isUserInteractionEnabled = false
        if let layer = view.layer as? CAMetalLayer {
            layer.colorspace = LookPipeline.outputColorSpace
            layer.maximumDrawableCount = 3
            renderer.attach(layer)
        }
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {}
}
