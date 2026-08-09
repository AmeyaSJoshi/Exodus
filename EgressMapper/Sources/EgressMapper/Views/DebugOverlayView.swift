import SwiftUI

/// Debug-build-only technical readout. Collapsed by default so it does not
/// obscure the camera while mapping.
struct DebugOverlayView: View {
    let manager: ARSessionManager
    var routeNode: String?
    var distanceToNext: Double?
    var estimate: LocationEstimate?
    var destinationExit: String?
    var activeHazardCount: Int?
    var profile: NavigationProfile?

    @State private var expanded = false
    @State private var exportURL: URL?

    var body: some View {
        #if DEBUG
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                Label("Diagnostics", systemImage: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2.monospaced())
            }

            if expanded {
                Group {
                    row("pos", vectorText(manager.cameraPosition))
                    row("heading", String(format: "%.1f°", manager.cameraHeading * 180 / .pi))
                    row("tracking", manager.status.trackingText)
                    row("mapping", manager.status.mappingText)
                    row("canSave", "\(manager.status.canSave)")
                    row("pathPts", "\(manager.path.count)")
                    row("waypoints", "\(manager.waypoints.count)")
                    row("anchors", "\(manager.restoredAnchorCount)")
                    row("reloc", "\(manager.relocalizationSeconds)s / ok=\(manager.didRelocalize)")
                    if let estimate {
                        row("edge", estimate.routePosition.edgeID?.uuidString.prefix(8).description ?? "—")
                        row("frac", estimate.routePosition.fractionAlongEdge.map { String(format: "%.3f", $0) } ?? "—")
                        row("offRoute", String(format: "%.2f m", estimate.distanceFromRouteMeters))
                        row("confidence", estimate.confidence.rawValue)
                    }
                    if let routeNode { row("node", routeNode) }
                    if let distanceToNext { row("toNext", String(format: "%.2f m", distanceToNext)) }
                    if let destinationExit { row("exit", destinationExit) }
                    if let activeHazardCount { row("hazards", "\(activeHazardCount)") }
                    if let profile {
                        row("profile", profile.constraintSummary ?? "standard")
                    }
                    if let ocr = manager.lastRecognizedSign {
                        row("ocr", "\(ocr.text) (\(String(format: "%.2f", ocr.confidence)))")
                    }
                }

                HStack(spacing: 10) {
                    Button("Export Log") { exportURL = DiagnosticsLog.shared.exportFile() }
                    Button("Clear") { DiagnosticsLog.shared.clear() }
                }
                .font(.caption2)
                .padding(.top, 2)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white)
        .padding(8)
        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
        .sheet(item: $exportURL) { url in
            ShareSheet(items: [url])
        }
        #else
        EmptyView()
        #endif
    }

    private func row(_ key: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(key).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
        }
    }

    private func vectorText(_ v: SIMD3<Float>) -> String {
        String(format: "%.2f, %.2f, %.2f", v.x, v.y, v.z)
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
