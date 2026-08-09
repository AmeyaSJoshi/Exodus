import MapLibre
import SwiftUI

/// The 3D building focus view — the native counterpart of the dashboard's
/// `BuildingFocusView`. Same engine (MapLibre) and same style, so a building
/// looks the same on the phone as it does on the command console.
struct FocusMapView: View {
    let building: RemoteBuilding
    /// The published graph, already loaded by the app's Supabase layer. Passing
    /// it in avoids a second fetch and keeps this view's "which map version"
    /// answer identical to every other screen's.
    var graph: BuildingGraph?

    /// `nil` means "all floors": everything at full opacity, matching the web
    /// view's default.
    @State private var activeFloor: String?

    private var floors: [String] {
        guard let graph else { return [] }
        return FocusOverlayBuilder.floors(in: graph)
    }

    var body: some View {
        Group {
            if let anchor = building.anchor {
                ZStack(alignment: .topLeading) {
                    FocusMapRepresentable(
                        anchor: anchor,
                        footprint: building.footprintGeoJSON,
                        footprintHeightM: building.footprintHeightM,
                        graph: graph,
                        activeFloor: activeFloor
                    )
                    .ignoresSafeArea(edges: .bottom)

                    if floors.count > 1 {
                        floorPicker
                    }
                }
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

    private var floorPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(title: "All floors", isActive: activeFloor == nil) { activeFloor = nil }
                ForEach(floors, id: \.self) { floor in
                    chip(title: floor, isActive: activeFloor == floor) { activeFloor = floor }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func chip(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? Color.red : Color.black.opacity(0.55), in: Capsule())
                .foregroundStyle(isActive ? .white : .secondary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }
}

/// Loads the published graph for a building, then hands it to the map. Uses
/// the app's existing service — same fetch, same cache, same "which version is
/// live" answer as every other screen.
struct FocusMapLoader: View {
    @Bindable var session: BackendSession
    let building: RemoteBuilding

    @State private var graph: BuildingGraph?

    var body: some View {
        FocusMapView(building: building, graph: graph)
            .task {
                guard graph == nil else { return }
                try? await session.service.loadGraph(for: building)
                graph = session.service.graph
            }
    }
}

// MARK: - UIKit bridge

private struct FocusMapRepresentable: UIViewRepresentable {
    let anchor: BuildingAnchor
    let footprint: FootprintPolygon?
    let footprintHeightM: Double?
    let graph: BuildingGraph?
    let activeFloor: String?

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
        let coordinator = context.coordinator
        let overlaysChanged = coordinator.footprint != footprint
            || coordinator.footprintHeightM != footprintHeightM
            || coordinator.graph != graph
            || coordinator.activeFloor != activeFloor

        // Data and floor selection can both change after the style has loaded,
        // in which case didFinishLoading has been and gone — apply them here.
        if overlaysChanged {
            coordinator.footprint = footprint
            coordinator.footprintHeightM = footprintHeightM
            coordinator.graph = graph
            coordinator.activeFloor = activeFloor
            coordinator.anchor = anchor
            if let style = mapView.style { coordinator.applyOverlays(to: style) }
        }

        // Re-centre only when the anchor itself changed; leaving the camera
        // alone otherwise means a user's pan/tilt is not yanked back on every
        // SwiftUI update.
        guard coordinator.appliedAnchor != anchor else { return }
        coordinator.appliedAnchor = anchor
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
        Coordinator(
            anchor: anchor,
            footprint: footprint,
            footprintHeightM: footprintHeightM,
            graph: graph,
            activeFloor: activeFloor
        )
    }

    final class Coordinator: NSObject, MLNMapViewDelegate {
        var anchor: BuildingAnchor
        var appliedAnchor: BuildingAnchor
        var footprint: FootprintPolygon?
        var footprintHeightM: Double?
        var graph: BuildingGraph?
        var activeFloor: String?

        private let prefix = FocusMapRepresentable.overlayPrefix
        private let ghostOpacity = 0.1

        init(
            anchor: BuildingAnchor,
            footprint: FootprintPolygon?,
            footprintHeightM: Double?,
            graph: BuildingGraph?,
            activeFloor: String?
        ) {
            self.anchor = anchor
            self.appliedAnchor = anchor
            self.footprint = footprint
            self.footprintHeightM = footprintHeightM
            self.graph = graph
            self.activeFloor = activeFloor
        }

        func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            muteBaseStyle(style)
            applyOverlays(to: style)
        }

        /// Mutes the base style in place so the surroundings read as faint
        /// context, exactly as the dashboard does. Editing the loaded style
        /// rather than shipping a second style keeps one source of truth.
        private func muteBaseStyle(_ style: MLNStyle) {
            for layer in style.layers {
                if layer.identifier.hasPrefix(prefix) { continue }
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
        }

        /// Idempotent: every source is updated in place when it already exists,
        /// so this is safe to call on style load and on every data change.
        func applyOverlays(to style: MLNStyle) {
            applyShell(to: style)
            guard let graph else { return }

            let floors = FocusOverlayBuilder.floors(in: graph)
            // Ghosting is done with a predicate pair rather than a data-driven
            // opacity expression: MapLibre Native's NSExpression dialect
            // diverges from the web style spec, and the visual result is what
            // the spec calls for, not the mechanism.
            let activeIdx = activeFloor.map { FocusOverlayBuilder.floorIndex($0, in: floors) }

            upsert(
                style, "slabs",
                features: FocusOverlayBuilder.slabs(graph: graph, anchor: anchor, floors: floors),
                activeIdx: activeIdx,
                fullOpacity: 0.6
            ) { layer in
                layer.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.89, green: 0.91, blue: 0.94, alpha: 1))
            }

            upsert(
                style, "rooms",
                features: FocusOverlayBuilder.rooms(graph: graph, anchor: anchor, floors: floors),
                activeIdx: activeIdx,
                fullOpacity: 0.85
            ) { layer in
                layer.fillExtrusionColor = NSExpression(forConstantValue: UIColor(red: 0.38, green: 0.65, blue: 0.98, alpha: 1))
            }

            upsert(
                style, "routes",
                features: FocusOverlayBuilder.routes(graph: graph, anchor: anchor, floors: floors),
                activeIdx: activeIdx,
                fullOpacity: 1
            ) { layer in
                // Bright green for a step-free route, red where it involves
                // stairs — the split the graph actually records.
                layer.fillExtrusionColor = NSExpression(
                    format: "TERNARY(stepFree == YES, %@, %@)",
                    UIColor(red: 0.13, green: 1.0, blue: 0.53, alpha: 1),
                    UIColor(red: 1.0, green: 0.30, blue: 0.30, alpha: 1)
                )
            }

            applyLabels(to: style, graph: graph, floors: floors, activeIdx: activeIdx)
        }

        // MARK: Layers

        /// Adds (or updates) one source plus an active/ghost fill-extrusion
        /// pair. Splitting by predicate is what gives the active floor full
        /// opacity while the others stay faint.
        private func upsert(
            _ style: MLNStyle,
            _ name: String,
            features: [[String: Any]],
            activeIdx: Int?,
            fullOpacity: Double,
            configure: (MLNFillExtrusionStyleLayer) -> Void
        ) {
            let sourceID = prefix + name
            guard let data = FocusOverlayBuilder.collectionData(features),
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            else { return }

            let source: MLNShapeSource
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
                source = existing
            } else {
                source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
            }

            for variant in ["", "-ghost"] {
                let isGhost = !variant.isEmpty
                let layerID = sourceID + variant
                let layer: MLNFillExtrusionStyleLayer
                if let existing = style.layer(withIdentifier: layerID) as? MLNFillExtrusionStyleLayer {
                    layer = existing
                } else {
                    layer = MLNFillExtrusionStyleLayer(identifier: layerID, source: source)
                    layer.fillExtrusionHeight = NSExpression(forKeyPath: "top")
                    layer.fillExtrusionBase = NSExpression(forKeyPath: "base")
                    configure(layer)
                    style.addLayer(layer)
                }
                layer.fillExtrusionOpacity = NSExpression(forConstantValue: isGhost ? ghostOpacity : fullOpacity)
                layer.predicate = predicate(activeIdx: activeIdx, ghost: isGhost)
            }
        }

        private func applyLabels(to style: MLNStyle, graph: BuildingGraph, floors: [String], activeIdx: Int?) {
            let sourceID = prefix + "labels"
            let features = FocusOverlayBuilder.labels(graph: graph, anchor: anchor, floors: floors)
            guard let data = FocusOverlayBuilder.collectionData(features),
                  let shape = try? MLNShape(data: data, encoding: String.Encoding.utf8.rawValue)
            else { return }

            let source: MLNShapeSource
            if let existing = style.source(withIdentifier: sourceID) as? MLNShapeSource {
                existing.shape = shape
                source = existing
            } else {
                source = MLNShapeSource(identifier: sourceID, shape: shape, options: nil)
                style.addSource(source)
            }

            for variant in ["", "-ghost"] {
                let isGhost = !variant.isEmpty
                let layerID = sourceID + variant
                let layer: MLNSymbolStyleLayer
                if let existing = style.layer(withIdentifier: layerID) as? MLNSymbolStyleLayer {
                    layer = existing
                } else {
                    layer = MLNSymbolStyleLayer(identifier: layerID, source: source)
                    layer.text = NSExpression(forKeyPath: "label")
                    layer.textFontSize = NSExpression(format: "TERNARY(isExit == YES, 13, 11)")
                    layer.textColor = NSExpression(
                        format: "TERNARY(isExit == YES, %@, %@)",
                        UIColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1),
                        UIColor(red: 0.90, green: 0.91, blue: 0.93, alpha: 1)
                    )
                    layer.textHaloColor = NSExpression(forConstantValue: UIColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1))
                    layer.textHaloWidth = NSExpression(forConstantValue: 1.5)
                    layer.textTranslation = NSExpression(forConstantValue: NSValue(cgVector: CGVector(dx: 0, dy: -8)))
                    style.addLayer(layer)
                }
                layer.textOpacity = NSExpression(forConstantValue: isGhost ? ghostOpacity : 1.0)
                layer.predicate = predicate(activeIdx: activeIdx, ghost: isGhost)
            }
        }

        /// With no floor selected every feature is drawn at full opacity and
        /// the ghost layer is switched off entirely.
        private func predicate(activeIdx: Int?, ghost: Bool) -> NSPredicate {
            guard let activeIdx else { return NSPredicate(value: !ghost) }
            return ghost
                ? NSPredicate(format: "floorIdx != %d", activeIdx)
                : NSPredicate(format: "floorIdx == %d", activeIdx)
        }

        /// The OSM building shell, cached into the anchor row by the dashboard.
        func applyShell(to style: MLNStyle) {
            let sourceID = prefix + "shell"
            let fillID = prefix + "shell-fill"
            let outlineID = prefix + "shell-outline"

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
