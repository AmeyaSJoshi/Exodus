import SwiftUI

/// Spoken reports. The transcript is always shown before anything happens, and
/// anything that would block a route requires an explicit confirmation.
struct VoiceReportView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    let routeEdges: [RouteEdge]
    let currentLegIndex: Int
    var onHazard: (RouteHazard, UUID) -> Void
    var onAccessibility: (NavigationProfileChange) -> Void
    var onAlternativeExit: () -> Void
    /// Undoes this phone's own hazard reports. Nothing published is touched.
    var onClearReports: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var listener = SpeechListener()
    @State private var command: EmergencyVoiceCommand?

    private var targetEdge: RouteEdge? {
        guard currentLegIndex >= 0, currentLegIndex < routeEdges.count else { return routeEdges.first }
        return routeEdges[currentLegIndex]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    micButton
                } footer: {
                    Text("Try: “the hallway ahead is blocked”, “there is smoke ahead”, “I can't use stairs”, “take me to another exit”.")
                }

                if !listener.transcript.isEmpty {
                    Section("Heard") {
                        Text("“\(listener.transcript)”")
                            .font(.subheadline)
                            .italic()
                    }
                }

                if let command { interpretation(command) }

                if let error = listener.errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Voice Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { listener.stop(); dismiss() }
                }
            }
            .task { await listener.requestAuthorization() }
            .onDisappear { listener.stop() }
            .onChange(of: listener.isListening) { _, listening in
                // Interpret only once the user has finished speaking.
                if !listening, !listener.transcript.isEmpty {
                    command = VoiceCommandParser.parse(listener.transcript)
                }
            }
        }
    }

    private var micButton: some View {
        Button {
            if listener.isListening {
                listener.stop()
            } else {
                command = nil
                listener.start()
            }
        } label: {
            VStack(spacing: 8) {
                Image(systemName: listener.isListening ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(listener.isListening ? .red : .blue)
                Text(listener.isListening ? "Listening — tap to stop" : "Tap and speak")
                    .font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .disabled(!listener.isAuthorized)
    }

    @ViewBuilder
    private func interpretation(_ command: EmergencyVoiceCommand) -> some View {
        switch command {
        case .reportHazard(let type, let hint):
            Section {
                Label(type.displayName, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(type.blocksTravel ? .red : .orange)
                if let hint {
                    LabeledContent("You said", value: hint)
                }
                if let edge = targetEdge {
                    LabeledContent("Segment", value: segmentLabel(edge))
                }
                Text(type.blocksTravel
                     ? "Confirming removes this segment from routing."
                     : "Confirming makes this segment heavily avoided.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    guard let edge = targetEdge else { return }
                    onHazard(RouteHazard(type: type, severity: type.blocksTravel ? 5 : 3), edge.id)
                    dismiss()
                } label: {
                    Label("Confirm and reroute", systemImage: "checkmark.circle.fill")
                }
                .disabled(targetEdge == nil)

                Button("Cancel", role: .destructive) { self.command = nil }
            } header: {
                Text("Confirm before this changes your route")
            }

        case .updateAccessibility(let change):
            Section("Understood") {
                Label(change.description, systemImage: "figure.roll")
                Button {
                    onAccessibility(change)
                    dismiss()
                } label: {
                    Label("Apply and reroute", systemImage: "checkmark.circle.fill")
                }
            }

        case .requestAlternativeExit:
            Section("Understood") {
                Label("Find a different exit", systemImage: "arrow.triangle.branch")
                Button {
                    onAlternativeExit()
                    dismiss()
                } label: {
                    Label("Show other exits", systemImage: "checkmark.circle.fill")
                }
            }

        case .clearMyReports:
            Section("Understood") {
                Label("Mark my reported blockages as clear", systemImage: "checkmark.seal")
                Text("This only undoes what you reported on this phone. Closures published by an administrator are not affected.")
                    .font(.caption).foregroundStyle(.secondary)
                Button {
                    onClearReports()
                    dismiss()
                } label: {
                    Label("Clear my reports and reroute", systemImage: "checkmark.circle.fill")
                }
            }

        case .unknown(let transcript):
            Section {
                Label("That wasn't understood.", systemImage: "questionmark.circle")
                    .foregroundStyle(.orange)
                Text("“\(transcript)”")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Nothing was changed. Try again, or close this and use the buttons.")
                    .font(.caption)
            }
        }
    }

    private func segmentLabel(_ edge: RouteEdge) -> String {
        let from = graph.node(edge.fromNodeID)?.name ?? "Here"
        let to = graph.node(edge.toNodeID)?.name ?? "Next point"
        return "\(from) → \(to)"
    }
}
