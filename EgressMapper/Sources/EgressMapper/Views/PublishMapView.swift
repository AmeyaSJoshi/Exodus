import SwiftUI
import Supabase

/// Publishes a locally mapped zone to the backend so administrators can see it
/// and mark parts of it blocked. Requires an administrator sign-in.
struct PublishMapView: View {
    let zone: MappingZone
    let graph: BuildingGraph
    var onPublished: (UUID) -> Void

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var config = BackendConfig.load()
    @State private var email = "admin@egress.test"
    @State private var password = "egress-admin-pw"
    @State private var organizationID = ""
    @State private var signedIn = false
    @State private var busy = false
    @State private var error: String?
    @State private var result: MapPublisher.Result?
    @State private var client: SupabaseClient?

    private var dangling: Int { MapPublisher.danglingEdgeCount(in: graph) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Zone") {
                    LabeledContent("Building", value: zone.building)
                    LabeledContent("Floor", value: zone.floor)
                    LabeledContent("Nodes", value: "\(graph.nodes.count)")
                    LabeledContent("Edges", value: "\(graph.edges.count)")
                    if dangling > 0 {
                        Label("\(dangling) connection(s) reference a missing waypoint",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let existing = zone.remoteBuildingID {
                        Text("Already published. Publishing again creates a new version and archives the old one.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(existing.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }

                if !signedIn {
                    Section("Administrator sign-in") {
                        TextField("Backend URL", text: $config.url)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        SecureField("Anon key", text: $config.anonKey)
                        TextField("Email", text: $email)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                        SecureField("Password", text: $password)
                        Button("Sign in") { Task { await signIn() } }
                            .disabled(busy || config.anonKey.isEmpty)
                    }
                } else {
                    Section {
                        TextField("Organization UUID", text: $organizationID)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .font(.caption.monospaced())
                    } header: {
                        Text("Organization")
                    } footer: {
                        Text("Only needed the first time a zone is published. Copy it from the dashboard or the seed.")
                    }

                    Section {
                        Button {
                            Task { await publish() }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(zone.remoteBuildingID == nil ? "Publish Building Map" : "Publish New Version")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(busy || dangling > 0 || (zone.remoteBuildingID == nil && UUID(uuidString: organizationID) == nil))
                    }
                }

                if let result {
                    Section("Published") {
                        LabeledContent("Version", value: "\(result.version)")
                        LabeledContent("Nodes", value: "\(result.nodeCount)")
                        LabeledContent("Edges", value: "\(result.edgeCount)")
                        Text(result.buildingID.uuidString)
                            .font(.caption2.monospaced()).foregroundStyle(.secondary)
                        Text("Administrators can now block parts of this map, and this phone will reroute.")
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
        }
    }

    private func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        guard config.isConfigured, let url = URL(string: config.url) else {
            error = BackendError.notConfigured.localizedDescription
            return
        }
        do {
            let c = SupabaseClient(supabaseURL: url, supabaseKey: config.anonKey)
            _ = try await c.auth.signIn(email: email, password: password)
            client = c
            config.save()
            signedIn = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func publish() async {
        guard let client else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let publisher = MapPublisher(client: client)
            let outcome = try await publisher.publish(
                zone: zone,
                graph: graph,
                organizationID: UUID(uuidString: organizationID) ?? UUID(),
                existingBuildingID: zone.remoteBuildingID
            )
            result = outcome

            var updated = zone
            updated.remoteBuildingID = outcome.buildingID
            updated.updatedAt = Date()
            await repository.upsert(updated)
            onPublished(outcome.buildingID)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
