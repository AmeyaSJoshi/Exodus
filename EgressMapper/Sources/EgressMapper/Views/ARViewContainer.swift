import SwiftUI
import RealityKit

/// Hosts the single `ARView` owned by `ARSessionManager`.
///
/// The view is created once, lives in the manager, and is handed to SwiftUI —
/// so a body re-evaluation, a sheet, or a navigation change can never build a
/// second one. What SwiftUI *can* do is take the ARView out of the window while
/// something is presented over it, which is exactly where RealityKit parks its
/// render loop and leaves the last drawn frame on screen. `HostingARView`
/// reports both edges of that so the manager can tell a parked renderer apart
/// from a stopped session.
struct ARViewContainer: UIViewRepresentable {
    let manager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        let view = manager.arView
        (view as? HostingARView)?.manager = manager
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

/// An `ARView` that tells its manager when it enters and leaves the window.
final class HostingARView: ARView {
    weak var manager: ARSessionManager?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            manager?.viewAttachedToWindow()
        } else {
            manager?.viewDetachedFromWindow()
        }
    }
}
