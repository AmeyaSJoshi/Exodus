import Foundation
import RealityKit
import ARKit
import UIKit
import simd

/// Where AR geometry sits vertically.
enum MarkerHeightMode: String, CaseIterable, Codable, Identifiable {
    /// On the detected floor plane (falls back to an assumed hand height).
    case floor
    /// At the height the phone was held when the waypoint was captured.
    case eyeLevel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .floor: return "Floor"
        case .eyeLevel: return "Eye Level"
        }
    }
}

/// Builds and places the world-anchored AR geometry: waypoint markers and
/// route arrows. Everything is attached to `AnchorEntity(world:)` so it stays
/// fixed in the room rather than following the camera.
enum ARRouteRenderer {

    /// Assumed phone height above the floor, used only when ARKit has not
    /// detected a floor plane yet.
    static let assumedCaptureHeight: Float = 1.15

    /// Resolves the world-space Y at which to draw geometry for a waypoint.
    /// - Parameters:
    ///   - capturedY: the Y of the waypoint's saved pose (phone height).
    ///   - groundY: floor plane Y detected by ARKit, if any.
    static func placementY(
        capturedY: Float,
        groundY: Float?,
        mode: MarkerHeightMode,
        offset: Float
    ) -> Float {
        switch mode {
        case .eyeLevel:
            return capturedY + offset
        case .floor:
            // Prefer the measured floor; otherwise assume the phone was held
            // at roughly chest/hand height above it.
            let base = groundY ?? (capturedY - assumedCaptureHeight)
            return base + offset
        }
    }

    // MARK: - Waypoint marker

    /// Marker geometry built about a local origin of y = 0, so the anchor's
    /// world Y alone decides its height.
    static func markerEntity(for waypoint: Waypoint) -> Entity {
        let container = Entity()
        let color = waypoint.type.uiColor

        let post = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.05, 0.45, 0.05), cornerRadius: 0.01),
            materials: [SimpleMaterial(color: color.withAlphaComponent(0.9), roughness: 0.4, isMetallic: false)]
        )
        post.position.y = 0.225
        container.addChild(post)

        let head = ModelEntity(
            mesh: .generateBox(size: SIMD3<Float>(0.16, 0.16, 0.16), cornerRadius: 0.03),
            materials: [SimpleMaterial(color: color, roughness: 0.3, isMetallic: false)]
        )
        head.position.y = 0.53
        container.addChild(head)

        container.addChild(labelEntity(waypoint.name, y: 0.74, color: .white))
        return container
    }

    static func labelEntity(_ text: String, y: Float, color: UIColor) -> Entity {
        let mesh = MeshResource.generateText(
            text,
            extrusionDepth: 0.004,
            font: .systemFont(ofSize: 0.10, weight: .semibold),
            containerFrame: .zero,
            alignment: .center,
            lineBreakMode: .byTruncatingTail
        )
        let entity = ModelEntity(mesh: mesh, materials: [UnlitMaterial(color: color)])
        let bounds = entity.model?.mesh.bounds ?? .init()
        entity.position = SIMD3<Float>(-bounds.extents.x / 2, y, 0)
        return entity
    }

    // MARK: - Route arrows

    /// Places a flat chevron at `position` (already height-resolved) pointing
    /// toward `target` on the horizontal plane.
    static func arrowAnchor(at position: SIMD3<Float>, pointingTo target: SIMD3<Float>, color: UIColor) -> AnchorEntity {
        let anchor = AnchorEntity(world: position)
        let arrow = chevronEntity(color: color)

        let flat = SIMD3<Float>(target.x - position.x, 0, target.z - position.z)
        if simd_length(flat) > 0.001 {
            let dir = simd_normalize(flat)
            let yaw = atan2(-dir.x, -dir.z)
            arrow.orientation = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
        }
        anchor.addChild(arrow)
        return anchor
    }

    /// A two-bar chevron lying in the ground plane, pointing along -Z.
    static func chevronEntity(color: UIColor) -> Entity {
        let container = Entity()
        let material = SimpleMaterial(color: color, roughness: 0.35, isMetallic: false)
        let barMesh = MeshResource.generateBox(
            size: SIMD3<Float>(0.34, 0.015, 0.075),
            cornerRadius: 0.01
        )

        for sign in [Float(1), Float(-1)] {
            let bar = ModelEntity(mesh: barMesh, materials: [material])
            bar.orientation = simd_quatf(angle: sign * (.pi / 4), axis: SIMD3<Float>(0, 1, 0))
            bar.position = SIMD3<Float>(sign * 0.12, 0, 0.12)
            container.addChild(bar)
        }
        return container
    }

    /// Renders the full route: an arrow at every leg start plus intermediate
    /// arrows down long straight runs, and a destination label.
    @discardableResult
    static func renderRoute(
        _ route: [RouteNode],
        in arView: ARView,
        groundY: Float?,
        mode: MarkerHeightMode,
        offset: Float,
        intermediateSpacing: Float = 3.0
    ) -> [AnchorEntity] {
        guard route.count > 1 else { return [] }
        var placed: [AnchorEntity] = []

        func resolved(_ w: RouteNode) -> SIMD3<Float> {
            var p = w.worldPosition
            p.y = placementY(capturedY: w.worldPosition.y, groundY: groundY, mode: mode, offset: offset)
            return p
        }

        for i in 0..<(route.count - 1) {
            let a = resolved(route[i])
            let b = resolved(route[i + 1])
            let color = route[i + 1].type == .exit ? UIColor.systemGreen : UIColor.systemYellow

            let leg = arrowAnchor(at: a, pointingTo: b, color: color)
            arView.scene.addAnchor(leg)
            placed.append(leg)

            // Reassurance arrows along long straight segments.
            let span = simd_distance(SIMD3<Float>(a.x, 0, a.z), SIMD3<Float>(b.x, 0, b.z))
            if span > intermediateSpacing {
                let steps = Int(span / intermediateSpacing)
                if steps > 1 {
                    for s in 1..<steps {
                        let t = Float(s) / Float(steps)
                        let mid = a + (b - a) * t
                        let anchor = arrowAnchor(at: mid, pointingTo: b, color: color.withAlphaComponent(0.75))
                        arView.scene.addAnchor(anchor)
                        placed.append(anchor)
                    }
                }
            }
        }

        if let destination = route.last {
            let anchor = AnchorEntity(world: resolved(destination))
            anchor.addChild(labelEntity(destination.name, y: 0.9, color: .systemGreen))
            arView.scene.addAnchor(anchor)
            placed.append(anchor)
        }
        return placed
    }
}
