import SwiftUI
import ARKit

/// Emergency → "I Don't Know Where I Am", scoped to the building the occupant
/// already selected.
///
/// Everything it searches comes from that building's downloaded package: its
/// mapping zones' ARWorldMaps, its reference photographs, its room aliases.
/// Nothing here reports a location merely because AR tracking went normal — a
/// zone must have been relocalized against, or a sign recognised.
struct BuildingLocalizationView: View {
    let manifest: MapPackageManifest
    let graph: BuildingGraph
    let cache: MapPackageCache
    var onLocated: (BuildingLocalizationService.Result) -> Void
    var onCancel: () -> Void

    @State private var manager = ARSessionManager()
    @State private var zoneIndex = 0
    @State private var result: BuildingLocalizationService.Result?
    @State private var errorMessage: String?
    @State private var showManualPicker = false
    @State private var attemptedZoneIDs: Set<UUID> = []
    @State private var scannedText: [String] = []

    private var candidates: [PackageZone] {
        BuildingLocalizationService.relocalizableZones(in: manifest)
    }

    private var currentZone: PackageZone? {
        guard zoneIndex < candidates.count else { return nil }
        return candidates[zoneIndex]
    }

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()
            Color.black.opacity(0.4).ignoresSafeArea()

            if let result {
                LocalizationConfirmationView(
                    result: result,
                    manifest: manifest,
                    onConfirm: { onLocated(result) },
                    onRetry: { retry() },
                    onManual: { showManualPicker = true }
                )
            } else {
                searchingOverlay
            }
        }
        .sheet(isPresented: $showManualPicker) {
            ManualRoomPickerView(manifest: manifest, graph: graph) { nodeID in
                showManualPicker = false
                if let picked = BuildingLocalizationService.locate(
                    manuallySelectedNodeID: nodeID, manifest: manifest, graph: graph
                ) {
                    onLocated(picked)
                }
            }
        }
        .onAppear { startCurrentZone() }
        .onDisappear { manager.stop() }
        .onChange(of: manager.didRelocalize) { _, relocalized in
            if relocalized { evaluateRelocalization() }
        }
        .onChange(of: manager.lastRecognizedSign?.text) { _, text in
            guard let text else { return }
            evaluateSign(text)
        }
    }

    // MARK: - Searching

    private var searchingOverlay: some View {
        VStack(spacing: 14) {
            Spacer()

            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Finding you in \(manifest.buildingName)")
                    .font(.headline)

                if let zone = currentZone {
                    Text(BuildingLocalizationService.scanInstructions(for: zone, in: manifest))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text("Area \(zoneIndex + 1) of \(candidates.count): \(zone.name)")
                        .font(.caption2).foregroundStyle(.secondary)

                    referenceStrip(for: zone)
                } else {
                    Text("This building has no AR maps to match against. Choose your location instead.")
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.orange)
                }

                Text(manager.status.trackingText).font(.caption)
                if let advice = manager.status.advice {
                    Text(advice).font(.caption2).foregroundStyle(.yellow)
                        .multilineTextAlignment(.center)
                }
                Text("\(manager.relocalizationSeconds)s").font(.caption2).foregroundStyle(.secondary)

                if !scannedText.isEmpty {
                    Text("Read: \(scannedText.suffix(3).joined(separator: ", "))")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                if manager.relocalizationSeconds > 20, candidates.count > 1 {
                    Text("Still looking. If you are somewhere else in the building, try the next area.")
                        .font(.caption2).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }

                if let errorMessage {
                    Text(errorMessage).font(.caption2).foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 10) {
                if candidates.count > 1 {
                    Button {
                        nextZone()
                    } label: {
                        Label("Try the Next Area", systemImage: "arrow.right.circle")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent).tint(.blue)
                }

                Button {
                    showManualPicker = true
                } label: {
                    Label("Choose My Location", systemImage: "hand.tap.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent).tint(.orange)

                HStack(spacing: 12) {
                    Button("Cancel") { manager.stop(); onCancel() }
                        .buttonStyle(.bordered)
                    Button("Retry") { retry() }
                        .buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(20)
    }

    /// Every recorded viewpoint for this zone. Showing several is the point:
    /// the user only has to match one of them.
    @ViewBuilder
    private func referenceStrip(for zone: PackageZone) -> some View {
        let artifacts = BuildingLocalizationService.referenceArtifacts(for: zone, in: manifest)
        if !artifacts.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(artifacts) { artifact in
                        if let data = cache.data(
                            for: artifact, buildingID: manifest.buildingID, version: manifest.version
                        ), let image = UIImage(data: data) {
                            VStack(spacing: 4) {
                                Image(uiImage: image)
                                    .resizable().scaledToFill()
                                    .frame(width: 130, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                Text(artifact.viewpoint ?? "Reference view")
                                    .font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
            .frame(height: 128)
        }
    }

    // MARK: - Actions

    private func startCurrentZone() {
        errorMessage = nil
        guard let zone = currentZone else {
            errorMessage = "No AR map is available for this building."
            return
        }
        guard ARSessionManager.isSupported else {
            errorMessage = "This device cannot use camera relocalization. Choose your location instead."
            return
        }
        guard
            let artifactID = zone.worldMapArtifactID,
            let artifact = manifest.artifact(artifactID),
            let data = cache.data(
                for: artifact, buildingID: manifest.buildingID, version: manifest.version
            )
        else {
            errorMessage = "This area's AR map is missing from the download. Try downloading the building again."
            return
        }

        do {
            guard let worldMap = try NSKeyedUnarchiver.unarchivedObject(
                ofClass: ARWorldMap.self, from: data
            ) else {
                throw ZoneStoreError.worldMapUnarchiveFailed
            }
            // The AR session takes a MappingZone for its own bookkeeping; the
            // package zone's identity is what matters and is preserved.
            let sessionZone = MappingZone(
                id: zone.id,
                campus: "",
                building: manifest.buildingName,
                floor: zone.floorID,
                zoneName: zone.name
            )
            try manager.startRelocalizing(
                zone: sessionZone, worldMap: worldMap, waypoints: [], path: RoutePath()
            )
            attemptedZoneIDs.insert(zone.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func nextZone() {
        manager.stop()
        zoneIndex = (zoneIndex + 1) % max(candidates.count, 1)
        startCurrentZone()
    }

    private func retry() {
        result = nil
        manager.stop()
        startCurrentZone()
    }

    /// Called only once ARKit reports it relocalized against the loaded map.
    private func evaluateRelocalization() {
        guard let zone = currentZone else { return }
        let located = BuildingLocalizationService.locate(
            worldPosition: manager.cameraPosition,
            relocalizedZoneID: zone.id,
            manifest: manifest,
            graph: graph
        )
        guard let located else {
            // Relocalized, but standing nowhere near the mapped route.
            errorMessage = "Matched this area, but you are too far from the mapped route to place you. Walk toward a hallway, or choose your location."
            return
        }
        DiagnosticsLog.shared.log(
            "Localized in \(manifest.buildingName)/\(zone.name) via world map, confidence \(located.confidence.rawValue)"
        )
        result = located
    }

    private func evaluateSign(_ text: String) {
        scannedText.append(text)
        guard let located = BuildingLocalizationService.locate(
            recognizedText: [text], manifest: manifest, graph: graph
        ) else { return }
        DiagnosticsLog.shared.log("Localized by sign '\(text)' in \(manifest.buildingName)")
        manager.stop()
        result = located
    }
}

/// "Your location appears to be…" — always confirmed explicitly, and always
/// stating how it was worked out.
private struct LocalizationConfirmationView: View {
    let result: BuildingLocalizationService.Result
    let manifest: MapPackageManifest
    var onConfirm: () -> Void
    var onRetry: () -> Void
    var onManual: () -> Void

    private var tint: Color {
        switch result.confidence {
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
                    .font(.subheadline).foregroundStyle(.secondary)
                Text(BuildingLocalizationService.describe(result, manifest: manifest))
                    .font(.title3.weight(.semibold))

                HStack(spacing: 6) {
                    Circle().fill(tint).frame(width: 8, height: 8)
                    Text(result.confidence.displayName)
                    Text("· \(result.method.displayName)").foregroundStyle(.secondary)
                }
                .font(.caption)

                if let matched = result.matchedText {
                    LabeledContent("Sign read", value: matched).font(.caption)
                }
                if result.estimate.distanceFromRouteMeters.isFinite,
                   result.method == .worldMapRelocalization {
                    Text(String(
                        format: "%.1f m from the mapped route",
                        result.estimate.distanceFromRouteMeters
                    ))
                    .font(.caption).foregroundStyle(.secondary)
                }

                if !result.canStartAutomatically {
                    Label(
                        "Confidence is too low to start on its own. Confirm only if this looks right.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption2).foregroundStyle(.orange)
                }
            }
            .padding(18)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))

            VStack(spacing: 10) {
                Button(action: onConfirm) {
                    Label("Confirm and Start", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .tint(result.canStartAutomatically ? .green : .orange)

                HStack(spacing: 12) {
                    Button("Not Right — Try Again", action: onRetry).buttonStyle(.bordered)
                    Button("Choose Manually", action: onManual).buttonStyle(.bordered)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

/// The fallback that always works, listing only this building's rooms.
private struct ManualRoomPickerView: View {
    let manifest: MapPackageManifest
    let graph: BuildingGraph
    var onPick: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var rooms: [RouteNode] {
        let all = BuildingLocalizationService.selectableRooms(in: graph)
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(rooms) { node in
                        Button {
                            onPick(node.id)
                        } label: {
                            HStack {
                                Image(systemName: node.type.symbolName)
                                    .foregroundStyle(node.type.tint)
                                Text(node.name)
                                Spacer()
                                Text(node.type.displayName)
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("Where are you in \(manifest.buildingName)?")
                }
            }
            .searchable(text: $search, prompt: "Room or landmark")
            .navigationTitle("Choose Location")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
