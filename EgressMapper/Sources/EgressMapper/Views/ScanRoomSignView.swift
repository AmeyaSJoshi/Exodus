import SwiftUI
import ARKit

/// Optional localization aid: point the camera at a room-number or exit sign
/// and match it against this zone's known labels. OCR is never trusted on its
/// own — the user confirms the match before it becomes a start position.
struct ScanRoomSignView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    var onConfirm: (RoutePosition, LocationEstimate) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var manager = ARSessionManager()
    @State private var matches: [SignMatcher.Match] = []
    @State private var lastText: String?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            ARViewContainer(manager: manager)
                .ignoresSafeArea()
            Color.black.opacity(0.25).ignoresSafeArea()

            VStack(spacing: 12) {
                header
                Spacer()
                if !matches.isEmpty { results } else { hint }
                Button("Cancel") { stop(); dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(20)
        }
        .onAppear(perform: start)
        .onDisappear { stop() }
        .onChange(of: manager.lastRecognizedSign?.text) { _, text in
            guard let text else { return }
            lastText = text
            matches = SignMatcher.matches(text: text, nodes: graph.nodes)
            if matches.isEmpty {
                DiagnosticsLog.shared.log("Sign '\(text)' matched no node in this zone")
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text("Scan a Room Sign")
                .font(.headline)
            Text("Point the camera at a room number, stairwell or exit sign.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let errorMessage {
                Text(errorMessage).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var hint: some View {
        VStack(spacing: 8) {
            ProgressView().tint(.white)
            if let lastText {
                Text("Read “\(lastText)” — not a label in this zone.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text("Looking for text…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var results: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Is this where you are?")
                .font(.subheadline.weight(.semibold))
            if let lastText {
                Text("Read: “\(lastText)”")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ForEach(matches) { match in
                Button {
                    confirm(match)
                } label: {
                    HStack {
                        Image(systemName: match.node.type.symbolName)
                            .foregroundStyle(match.node.type.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(match.node.name)
                                .font(.subheadline.weight(.medium))
                            Text("\(Int(match.score * 100))% match")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .padding(10)
                    .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            Button("None of these") {
                matches = []
                manager.dismissRecognizedSign()
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Actions

    private func start() {
        guard ARSessionManager.isSupported else {
            errorMessage = "This device cannot use the camera for scanning."
            return
        }
        do {
            // A plain mapping session is enough; we only need camera frames + OCR.
            try manager.startMapping(zone: zone)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func stop() { manager.stop() }

    /// A user-confirmed sign is a reliable position — they can read the door.
    private func confirm(_ match: SignMatcher.Match) {
        let position = RoutePosition(nodeID: match.node.id, worldPosition: match.node.worldPosition)
        let estimate = LocationEstimate(
            routePosition: position,
            nearestNodeName: match.node.name,
            distanceFromRouteMeters: 0,
            confidence: .high
        )
        DiagnosticsLog.shared.log("Sign confirmed: \(match.node.name) (\(match.score))")
        stop()
        onConfirm(position, estimate)
        dismiss()
    }
}
