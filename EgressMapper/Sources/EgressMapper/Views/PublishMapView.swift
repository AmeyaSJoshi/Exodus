import SwiftUI

/// Publishes a locally mapped zone from the map's own screen.
///
/// Uses the shared `BackendSession`, so there is one authentication path in the
/// app and the organization comes from the signed-in profile — never typed in.
struct PublishMapView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    var onPublished: (UUID) -> Void

    @Environment(ZoneRepository.self) private var repository
    @Environment(BackendSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var buildingName = ""
    @State private var busy = false
    @State private var error: String?
    @State private var result: MapPublisher.Result?

    private var dangling: Int { MapPublisher.danglingEdgeCount(in: graph) }

    private var artifacts: [PendingArtifact] {
        MapPublisher.artifacts(for: zone, store: repository.store)
    }

    /// The building this zone was already published to, if any.
    private var existing: CatalogBuilding? {
        guard let id = zone.remoteBuildingID else { return nil }
        return session.service.catalog.first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    LabeledContent("Building", value: zone.building)
                    LabeledContent("Floor", value: zone.floor)
                    LabeledContent("Nodes", value: "\(graph.nodes.count)")
                    LabeledContent("Edges", value: "\(graph.edges.count)")
                    LabeledContent("Exits", value: "\(graph.exits.count)")
                    if dangling > 0 {
                        Label("\(dangling) connection(s) reference a missing waypoint",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if graph.exits.isEmpty {
                        Label("No exit waypoints — evacuation routing needs at least one.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Section("Localization package") {
                    LabeledContent(
                        "AR world map",
                        value: artifacts.contains { $0.kind == .worldmap } ? "Included" : "None"
                    )
                    LabeledContent(
                        "Reference views",
                        value: "\(artifacts.filter { $0.kind == .referenceImage }.count)"
                    )
                    LabeledContent(
                        "Upload size",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(artifacts.reduce(0) { $0 + $1.data.count }),
                            countStyle: .file
                        )
                    )
                }

                if !session.isSignedIn {
                    BackendSignInView(session: session, title: "Sign in to publish")
                } else if !session.canManage {
                    Section {
                        Label(
                            "Your account is an occupant. Only administrators and mappers can publish maps.",
                            systemImage: "lock.fill"
                        )
                        .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        if let existing {
                            LabeledContent("Building", value: existing.name)
                            Text("Publishing again creates a new version and archives the current one. The old version is never overwritten.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            TextField("New building name", text: $buildingName)
                            Text("Created in \(session.profile.organizationName ?? "your organization").")
                                .font(.caption).foregroundStyle(.secondary)
                        }

                        Button {
                            Task { await publish() }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(existing == nil ? "Publish Building Map" : "Publish New Version")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(
                            busy || dangling > 0
                            || (existing == nil && buildingName.trimmingCharacters(in: .whitespaces).isEmpty)
                        )
                    } header: {
                        Text("Publish")
                    }
                }

                if let result {
                    Section("Published") {
                        LabeledContent("Version", value: "\(result.version)")
                        LabeledContent("Nodes", value: "\(result.nodeCount)")
                        LabeledContent("Edges", value: "\(result.edgeCount)")
                        LabeledContent("Files uploaded", value: "\(result.artifactCount)")
                        Text("Occupants in your organization can now download this building, and administrators can block parts of it.")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Publish Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task {
                await session.refresh()
                if buildingName.isEmpty {
                    buildingName = zone.building.isEmpty ? zone.displayTitle : zone.building
                }
            }
        }
    }

    private func publish() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let client = session.service.currentClient else {
                throw BackendError.notConfigured
            }
            guard let organizationID = session.profile.organizationID else {
                throw BackendError.notConfigured
            }

            // Create the building first when this map has never been published,
            // so the server assigns the organization from the caller's profile.
            var buildingID = zone.remoteBuildingID
            var name = existing?.name ?? buildingName.trimmingCharacters(in: .whitespaces)
            if buildingID == nil {
                let created = try await session.service.createBuilding(
                    name: name, address: zone.campus, description: nil
                )
                buildingID = created.id
                name = created.name
            }

            let outcome = try await MapPublisher(client: client).publish(
                zone: zone,
                graph: graph,
                organizationID: organizationID,
                existingBuildingID: buildingID,
                buildingName: name,
                artifacts: artifacts
            )
            result = outcome

            var updated = zone
            updated.remoteBuildingID = outcome.buildingID
            updated.updatedAt = Date()
            await repository.upsert(updated)
            try await session.service.loadCatalog()
            onPublished(outcome.buildingID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
