import MapLibre
import SwiftUI

/// The 3D building focus view — the native counterpart of the dashboard's
/// `BuildingFocusView`. Same engine (MapLibre) and same style, so a building
/// looks the same on the phone as it does on the command console.
///
/// Phase 1 renders the georeferenced base map only; the indoor overlays
/// (slabs, rooms, route ribbons, labels) arrive with the graph.
struct FocusMapView: View {
    let building: RemoteBuilding

    var body: some View {
        Group {
            if let anchor = building.anchor {
                FocusMapRepresentable(
                    anchor: anchor,
                    footprint: building.footprintGeoJSON,
                    footprintHeightM: building.footprintHeightM
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView(
                    "No location set",
                    systemImage: "mappin.slash",
                    description: Text("Set this building's location on the dashboard first.")
                )
            }
        }
        .navigationTitle(building.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - UIKit bridge

private struct FocusMapRepresentable: UIViewRepresentable {
    let anchor: BuildingAnchor
    let footprint: FootprintPolygon?
    let footprintHeightM: Double?

    /// Every source and layer this view adds carries this prefix. The mute
    /// pass skips it — without that guard the pass repaints the overlay into
    /// the background it is meant to stand out from, which is exactly the bug
    /// the web version shipped.
    static let overlayPrefix = "egress-"

    /// Matches the dashboard: OpenFreeMap's Liberty style, no key required.
    private static let styleURL = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    /// Metres from the camera to the anchor. The dashboard frames the building
    /// at zoom 18.5; an explicit altitude is the equivalent on iOS, where
    /// `MLNMapCamera` is expressed in distance rather than zoom.
    private static let cameraDistanceM: CLLocationDistance = 250
    private static let pitch: CGFloat = 60

    func makeUIView(context: Context) -> MLNMapView {
        let mapView = MLNMapView(frame: .zero, styleURL: Self.styleURL)
        mapView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        mapView.logoView.isHidden = false
        mapView.compassView.isHidden = false

        // Tilt and rotate are what make this a 3D view rather than a floor plan.
        mapView.allowsRotating = true
        mapView.allowsTilting = true
        mapView.allowsZooming = true
        mapView.allowsScrolling = true

        mapView.delegate = context.coordinator

        let center = CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
        mapView.setCamera(
            MLNMapCamera(
                lookingAtCenter: center,
                altitude: Self.cameraDistanceM,
                pitch: Self.pitch,
                heading: anchor.headingDeg
            ),
            animated: false
        )
        return mapView
    }

    func updateUIView(_ mapView: MLNMapView, context: Context) {
        // The footprint can arrive after the style has already loaded, in
        // which case didFinishLoading has been and gone — apply it here too.
        if context.coordinator.footprint != footprint || context.coordinator.footprintHeightM != footprintHeightM {
            context.coordinator.footprint = footprint
            context.coordinator.footprintHeightM = footprintHeightM
            if let style = mapView.style { context.coordinator.applyShell(to: style) }
        }

        // Re-centre only when the anchor itself changed; leaving the camera
        // alone otherwise means a user's pan/tilt is not yanked back on every
        // SwiftUI update.
        guard context.coordinator.appliedAnchor != anchor else { return }
        context.coordinator.appliedAnchor = anchor
        mapView.setCamera(
            MLNMapCamera(
                lookingAtCenter: CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude),
                altitude: Self.cameraDistanceM,
                pitch: Self.pitch,
                heading: anchor.headingDeg
            ),
            animated: true
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(anchor: anchor, footprint: footprint, footprintHeightM: footprintHeightM)
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var appliedAnchor: BuildingAnchor
        var footprint: FootprintPolygon?
        var footprintHeightM: Double?

        init(anchor: BuildingAnchor, footprint: FootprintPolygon?, footprintHeightM: Double?) {
            self.appliedAnchor = anchor
            self.footprint = footprint
            self.footprintHeightM = footprintHeightM
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            // Mute the base style in place so the surroundings read as faint
            // context, exactly as the dashboard does. Editing the loaded style
            // rather than shipping a second style keeps one source of truth.
            for layer in style.layers {
                if layer.identifier.hasPrefix(FocusMapRepresentable.overlayPrefix) { continue }
                switch layer {
                case let fill as MLNFillStyleLayer:
                    fill.fillColor = NSExpression(forConstantValue: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1))
                    fill.fillOpacity = NSExpression(forConstantValue: 0.6)
                case let line as MLNLineStyleLayer:
                    line.lineColor = NSExpression(forConstantValue: UIColor(red: 0.16, green: 0.18, blue: 0.22, alpha: 1))
                    line.lineOpacity = NSExpression(forConstantValue: 0.5)
                case let symbol as MLNSymbolStyleLayer:
                    symbol.textColor = NSExpression(forConstantValue: UIColor(red: 0.36, green: 0.39, blue: 0.45, alpha: 1))
                    symbol.textHaloColor = NSExpression(forConstantValue: UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
                case let background as MLNBackgroundStyleLayer:
                    background.backgroundColor = NSExpression(forConstantValue: UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
                case let extrusion as MLNFillExtrusionStyleLayer:
                    extrusion.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.11, green: 0.13, blue: 0.16, alpha: 1))
                    extrusion.fillExtrusionOpacity = NSExpression(forConstantValue: 0.4)
                default:
                    continue
                }
            }

            applyShell(to: style)
        }

        /// Idempotent: updates the existing source when the footprint changes
        /// rather than adding a second one.
        func applyShell(to style: MLNStyle) {
            let sourceID = FocusMapRepresentable.overlayPrefix + "shell"
            let fillID = FocusMapRepresentable.overlayPrefix + "shell-fill"
            let outlineID = FocusMapRepresentable.overlayPrefix + "shell-outline"

            guard let footprint else { return }
            let height = footprintHeightM ?? 3

            let shape: MLNShape
            do {
                shape = try MLNShape(data: footprint.featureData(), encoding: String.Encoding.utf8.rawValue)
            } catch {
                return
            }

            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
                if let fill = style.layer(withIdentifier: fillID) as? MLNFillExtrusionStyleLayer {
                    fill.fillExtrusionHeight = NSExpression(forConstantValue: height)
                }
                return
            }

            let source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
            style.addSource(source)

            let fill = MLNFillExtrusionStyleLayer(identifier: fillID, source: source)
            fill.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.22, green: 0.74, blue: 0.99, alpha: 1))
            fill.fillExtrusionHeight = NSExpression(forConstantValue: height)
            fill.fillExtrusionBase = NSExpression(forConstantValue: 0)
            fill.fillExtrusionOpacity = NSExpression(forConstantValue: 0.25)
            style.addLayer(fill)

            let outline = MLNLineStyleLayer(identifier: outlineID, source: source)
            outline.lineColor = NSExpression(forConstantValue: UIColor(red: 0.49, green: 0.83, blue: 0.99, alpha: 1))
            outline.lineWidth = NSExpression(forConstantValue: 3)
            outline.lineOpacity = NSExpression(forConstantValue: 1)
            style.addLayer(outline)
        }
    }
}
