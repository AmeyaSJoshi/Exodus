import SwiftUI
import ARKit

/// "I Don't Know Where I Am": relocalize against the saved world map, then
/// work out where the user stands on the route graph.
///
/// Nothing here ever claims to have found the user while ARKit is still
/// relocalizing — a confidently wrong location is worse than no location.
struct EmergencyLocalizationView: View {
    let zone: MappingZone
    var onLocated: (RoutePosition, LocationEstimate) -> Void
    var onCancel: () -> Void

    @Environment(ZoneRepository.self) private var repository
    @State private var manager = ARSessionManager()
    @State private var graph: BuildingGraph?
    @State private var waypoints: [Waypoint] = []
    @State private var path = RoutePath()
    @State private var referenceImage: UIImage?
    @State private var estimate: LocationEstimate?
    @State private var errorMessage: String?
    @State private var showManualPicker = false
    @State private var showScanSign = false

    private var relocalized: Bool { manager.didRelocalize }

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()
            Color.black.opacity(0.4).ignoresSafeArea()

            if let estimate {
                LocationConfirmationView(
                    zone: zone,
                    estimate: estimate,
                    waypoints: waypoints,
                    path: path,
                    onConfirm: { onLocated(estimate.routePosition, estimate) },
                    onRetry: { retry() },
                    onManual: { showManualPicker = true }
                )
            } else {
                relocalizingOverlay
            }
        }
        .sheet(isPresented: $showManualPicker) {
            if let graph {
                ManualLocationPickerView(
                    zone: zone, graph: graph, waypoints: waypoints, path: path
                ) { position, manualEstimate in
                    showManualPicker = false
                    onLocated(position, manualEstimate)
                }
            }
        }
        .fullScreenCover(isPresented: $showScanSign) {
            if let graph {
                ScanRoomSignView(zone: zone, graph: graph) { position, signEstimate in
                    showScanSign = false
                    onLocated(position, signEstimate)
                }
            }
        }
        .alert("Emergency Mode", isPresented: .presenting($errorMessage)) {
            Button("Scan a Room Sign") { errorMessage = nil; showScanSign = true }
            Button("Choose Manually") { errorMessage = nil; showManualPicker = true }
            Button("Back", role: .cancel) { errorMessage = nil; stop(); onCancel() }
        } message: {
            Text(errorMessage ?? "")
        }
        .onAppear(perform: start)
        .onDisappear { manager.stop() }
        .onChange(of: manager.didRelocalize) { _, located in
            if located { computeEstimate() }
        }
    }

    // MARK: - Relocalizing

    private var relocalizingOverlay: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Finding your location…")
                    .font(.headline)
                Text("Stand near the mapped area and slowly point the camera around you.")
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                if let referenceImage {
                    Image(uiImage: referenceImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 170)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottom) {
                            Text("Try to match this view")
                                .font(.caption2)
                                .padding(4)
                                .background(.black.opacity(0.6), in: Capsule())
                                .padding(6)
                        }
                }

                Text(manager.status.trackingText)
                    .font(.caption)
                if let advice = manager.status.advice {
                    Text(advice)
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
                Text("\(manager.relocalizationSeconds)s")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                DebugOverlayView(manager: manager, estimate: estimate)

                if manager.relocalizationSeconds > 25 {
                    Text("The area may look different from when it was mapped. You can keep trying, or choose your location manually.")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 10) {
                Button {
                    manager.stop()
                    showScanSign = true
                } label: {
                    Label("Scan a Room Sign", systemImage: "text.viewfinder")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)

                Button {
                    showManualPicker = true
                } label: {
                    Label("Choose My Location Manually", systemImage: "hand.tap.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)

                HStack(spacing: 12) {
                    Button("Cancel") { stop(); onCancel() }
                        .buttonStyle(.bordered)
                    Button("Retry") { retry() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    // MARK: - Actions

    private func start() {
        referenceImage = repository.store.loadReferenceImage(zone.id)
        waypoints = repository.store.loadWaypoints(zone.id)
        path = repository.store.loadPath(zone.id)
        graph = repository.routableGraph(for: zone)

        guard graph != nil else {
            errorMessage = RoutingError.emptyGraph.localizedDescription
            return
        }
        guard ARSessionManager.isSupported else {
            errorMessage = "This device cannot use camera relocalization. Choose your location manually."
            return
        }
        do {
            let map = try repository.store.loadWorldMap(zone.id)
            try manager.startRelocalizing(zone: zone, worldMap: map, waypoints: waypoints, path: path)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func retry() {
        estimate = nil
        manager.stop()
        start()
    }

    private func stop() {
        manager.stop()
    }

    /// Only ever called once ARKit reports normal tracking after relocalizing.
    private func computeEstimate() {
        guard let graph else { return }
        let result = LocalizationService.estimate(
            worldPosition: manager.cameraPosition, graph: graph
        )
        DiagnosticsLog.shared.log(
            "Estimate: conf=\(result.confidence.rawValue) dist=\(result.distanceFromRouteMeters) near=\(result.nearestNodeName ?? "-")"
        )
        estimate = result
    }
}

/// "Your location appears to be: …" — always requires an explicit confirmation.
struct LocationConfirmationView: View {
    let zone: MappingZone
    let estimate: LocationEstimate
    let waypoints: [Waypoint]
    let path: RoutePath
    var onConfirm: () -> Void
    var onRetry: () -> Void
    var onManual: () -> Void

    private var confidenceColor: Color {
        switch estimate.confidence {
        case .high: return .green
        case .medium: return .yellow
        case .low: return .orange
        case .unavailable: return .red
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                Text("Your location appears to be")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(LocalizationService.describe(estimate, zone: zone))
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    Circle().fill(confidenceColor).frame(width: 8, height: 8)
                    Text(estimate.confidence.displayName)
                    if estimate.distanceFromRouteMeters.isFinite {
                        Text(String(format: "· %.1f m from the mapped route", estimate.distanceFromRouteMeters))
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                Divider()

                Group {
                    LabeledContent("Building", value: zone.building)
                    LabeledContent("Floor", value: zone.floor)
                    LabeledContent("Zone", value: zone.displayTitle)
                    if let name = estimate.nearestNodeName {
                        LabeledContent("Nearest point", value: name)
                    }
                }
                .font(.caption)

                TopDownRouteView(
                    path: path,
                    waypoints: waypoints,
                    currentPosition: MapPoint(projecting: estimate.routePosition.worldPosition)
                )
                .frame(height: 150)

                if !estimate.confidence.allowsAutomaticNavigation {
                    Label(
                        "Confidence is too low to start automatically. Confirm only if this looks right, or choose manually.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2)
                    .foregroundStyle(.orange)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Label("Confirm Location", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(estimate.confidence.allowsAutomaticNavigation ? .green : .orange)
                .disabled(estimate.confidence == .unavailable)

                HStack(spacing: 12) {
                    Button("Try Again", action: onRetry)
                        .buttonStyle(.bordered)
                    Button("Choose Manually", action: onManual)
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}
