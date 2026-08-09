import SwiftUI
import RealityKit

/// Hosts the single `ARView` owned by `ARSessionManager`. The view is created
/// once and reused so the AR session is never torn down by SwiftUI redraws.
struct ARViewContainer: UIViewRepresentable {
    let manager: ARSessionManager

    func makeUIView(context: Context) -> ARView {
        manager.arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}
