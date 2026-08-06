import SwiftUI

/// Shared backend session for the product flows. One instance is created at the
/// app root so Saved Maps, Buildings, Emergency and Diagnostics all use the
/// same authentication, catalogue, cache, live state and routing.
@Observable
@MainActor
final class BackendSession {
    let service = SupabaseBuildingService()
    var config = BackendConfig.load()
    var email = ""
    var password = ""
    var busy = false
    var error: String?

    var profile: UserProfile { service.profile }
    var isSignedIn: Bool { service.signedInEmail != nil }
    var canManage: Bool { profile.canManageBuildings }

    func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try service.configure(config)
            try await service.signIn(email: email, password: password)
            try await service.loadProfile()
            guard service.profile.hasOrganization else {
                error = "Your account is not assigned to an organization. Ask an administrator to add you."
                return
            }
            try await service.loadCatalog()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refresh() async {
        guard isSignedIn else { return }
        do {
            try await service.loadProfile()
            try await service.loadCatalog()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        await service.signOut()
    }

    /// Unified Saved Maps rows: organization buildings merged with local zones.
    func entries(localZones: [MappingZone]) -> [BuildingEntry] {
        BuildingCatalogMerger.merge(
            remote: service.catalog,
            localZones: localZones,
            cachedVersion: { service.cachedVersions[$0] },
            profile: service.profile
        )
    }
}

/// Sign-in used by every product screen. Kept in one place so there is a single
/// authentication implementation.
struct BackendSignInView: View {
    @Bindable var session: BackendSession
    var title = "Sign in"

    var body: some View {
        Section {
            TextField("Backend URL", text: $session.config.url)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
            SecureField("Anon / publishable key", text: $session.config.anonKey)
            TextField("Email", text: $session.email)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .keyboardType(.emailAddress)
            SecureField("Password", text: $session.password)
            Button {
                Task { await session.signIn() }
            } label: {
                HStack {
                    if session.busy { ProgressView() }
                    Text(title)
                }
            }
            .disabled(session.busy || session.config.anonKey.isEmpty || session.email.isEmpty)
            if let error = session.error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        } header: {
            Text("Account")
        } footer: {
            Text("Your organization and role come from your account — you never type an organization ID.")
        }
    }
}

/// Configure → Buildings. Administrator/mapper only.
struct BuildingsView: View {
    @Environment(ZoneRepository.self) private var repository
    @Bindable var session: BackendSession

    @State private var showAdd = false
    @State private var attachTarget: CatalogBuilding?

    var body: some View {
        List {
            if !session.isSignedIn {
                BackendSignInView(session: session)
            } else if !session.canManage {
                Section {
                    Label(
                        "Your account is an occupant. Only administrators and mappers can create or publish buildings.",
                        systemImage: "lock.fill"
                    )
                    .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Building", systemImage: "plus.circle.fill")
                    }
                } header: {
                    Text(session.profile.organizationName ?? "Organization")
                } footer: {
                    Text("New buildings are created in your own organization and start as drafts.")
                }

                Section("Buildings") {
                    if session.service.catalog.isEmpty {
                        Text("No buildings yet.").foregroundStyle(.secondary)
                    }
                    ForEach(session.service.catalog) { building in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(building.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(building.isPublished ? "v\(building.version ?? 0)" : "Draft")
                                    .font(.caption)
                                    .foregroundStyle(building.isPublished ? .green : .orange)
                            }
                            Text(BuildingCatalogMerger.subtitle(for: building))
                                .font(.caption2).foregroundStyle(.secondary)
                            Button("Attach a saved map and publish") { attachTarget = building }
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .navigationTitle("Buildings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showAdd) {
            AddBuildingView(session: session)
        }
        .sheet(item: $attachTarget) { building in
            AttachMapView(session: session, building: building)
                .environment(repository)
        }
        .task { await session.refresh() }
    }
}

struct AddBuildingView: View {
    @Bindable var session: BackendSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var address = ""
    @State private var description = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Building") {
                    TextField("Name", text: $name)
                    TextField("Address (optional)", text: $address)
                    TextField("Campus or description (optional)", text: $description)
                }
                Section {
                    Button {
                        Task { await create() }
                    } label: {
                        HStack {
                            if busy { ProgressView() }
                            Text("Create Building")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(busy || name.trimmingCharacters(in: .whitespaces).isEmpty)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else {
                        Text("Created in \(session.profile.organizationName ?? "your organization"). Attach a mapped zone next, then publish.")
                    }
                }
            }
            .navigationTitle("Add Building")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await session.service.createBuilding(
                name: name.trimmingCharacters(in: .whitespaces),
                address: address, description: description
            )
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Attaches a locally saved zone to an existing building and publishes it as a
/// new immutable map version.
struct AttachMapView: View {
    @Bindable var session: BackendSession
    let building: CatalogBuilding

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MappingZone?
    @State private var busy = false
    @State private var error: String?
    @State private var result: MapPublisher.Result?

    var body: some View {
        NavigationStack {
            Form {
                Section("Building") {
                    Text(building.name).font(.headline)
                    if let version = building.version {
                        Text("Currently published: v\(version)").font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section {
                    if repository.zones.isEmpty {
                        Text("No saved maps on this device. Record a zone in Configure → Map a New Zone.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(repository.zones) { zone in
                        Button {
                            selected = zone
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(zone.displayTitle)
                                    Text("\(zone.waypointCount) waypoints · \(zone.formattedLength)")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selected?.id == zone.id {
                                    Image(systemName: "checkmark").foregroundStyle(.green)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Saved map to attach")
                } footer: {
                    Text("Publishing validates the route graph first and creates a new version; the previous one is archived, never overwritten.")
                }

                if let zone = selected, let graph = repository.graph(for: zone) {
                    Section("Validation") {
                        let dangling = MapPublisher.danglingEdgeCount(in: graph)
                        LabeledContent("Nodes", value: "\(graph.nodes.count)")
                        LabeledContent("Edges", value: "\(graph.edges.count)")
                        LabeledContent("Exits", value: "\(graph.exits.count)")
                        if dangling > 0 {
                            Label("\(dangling) edge(s) reference a missing waypoint", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else if graph.exits.isEmpty {
                            Label("No exit waypoints — evacuation routing needs at least one.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Label("Graph is valid", systemImage: "checkmark.seal.fill")
                                .font(.caption).foregroundStyle(.green)
                        }

                        Button {
                            Task { await publish(zone: zone, graph: graph) }
                        } label: {
                            HStack {
                                if busy { ProgressView() }
                                Text(building.version == nil ? "Publish" : "Publish Update")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .disabled(busy || dangling > 0)
                    }
                }

                if let result {
                    Section("Published") {
                        LabeledContent("Version", value: "\(result.version)")
                        LabeledContent("Nodes", value: "\(result.nodeCount)")
                        LabeledContent("Edges", value: "\(result.edgeCount)")
                        Text("Occupants in your organization will see this building.")
                            .font(.caption).foregroundStyle(.green)
                    }
                }

                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Attach & Publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(result == nil ? "Cancel" : "Done") { dismiss() }
                }
            }
            .task { await repository.refresh() }
        }
    }

    private func publish(zone: MappingZone, graph: BuildingGraph) async {
        busy = true; error = nil
        defer { busy = false }
        do {
            guard let client = session.service.currentClient else {
                throw BackendError.notConfigured
            }
            let outcome = try await MapPublisher(client: client).publish(
                zone: zone,
                graph: graph,
                organizationID: session.profile.organizationID ?? UUID(),
                existingBuildingID: building.id
            )
            result = outcome

            var updated = zone
            updated.remoteBuildingID = outcome.buildingID
            updated.updatedAt = Date()
            await repository.upsert(updated)
            try await session.service.loadCatalog()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
