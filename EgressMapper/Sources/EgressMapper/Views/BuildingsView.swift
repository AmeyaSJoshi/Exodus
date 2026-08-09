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

    /// Downloaded map packages. One cache for the whole app, so Saved Maps,
    /// Emergency and Diagnostics all agree on what is available offline.
    let packages = MapPackageCache()
    /// In-flight download state, which nothing stored on disk can imply.
    private(set) var downloadStates: [UUID: BuildingAvailability] = [:]
    private(set) var cachedVersions: [UUID: Int] = [:]

    var profile: UserProfile { service.profile }
    var isSignedIn: Bool { service.signedInEmail != nil }
    var canManage: Bool { profile.canManageBuildings }

    /// A request that never came back. An unreachable host does not fail fast
    /// on its own — the socket just sits there — so a sign-in against a stale
    /// LAN address would spin forever with nothing on screen to explain it.
    struct BackendTimeout: Error {}

    /// Runs `operation`, or throws `BackendTimeout` if it outlasts `seconds`.
    private func withTimeout(
        _ seconds: Double,
        _ operation: @escaping @MainActor () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw BackendTimeout()
            }
            // Whichever finishes first decides; the loser is cancelled.
            try await group.next()
            group.cancelAll()
        }
    }

    func signIn() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try service.configure(config)
            try await withTimeout(15) {
                try await self.service.signIn(email: self.email, password: self.password)
                try await self.service.loadProfile()
            }
            guard service.profile.hasOrganization else {
                error = "Your account is not assigned to an organization. Ask an administrator to add you."
                return
            }
            try await withTimeout(15) {
                try await self.service.loadCatalog()
                try await self.service.loadBuildings()
            }
        } catch is BackendTimeout {
            // Naming the address turns the most common cause — the Mac's LAN
            // IP moved, or the phone is on another network — into something
            // the person holding the phone can diagnose without a debugger.
            error = "Can't reach server at \(config.url). Check the Mac is running and both are on the same Wi-Fi."
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Reads only the cached version numbers — a directory listing per
    /// building, no manifests, no checksums, no artifacts.
    func refreshCachedVersions() {
        cachedVersions = packages.allCachedVersions()
    }

    func refresh() async {
        refreshCachedVersions()
        guard isSignedIn else { return }
        do {
            try await service.loadProfile()
            try await service.loadCatalog()
            // The catalogue RPC does not carry the georeference anchor, so the
            // buildings table is read alongside it for the focus map.
            try await service.loadBuildings()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func signOut() async {
        await service.signOut()
    }

    /// Unified Saved Maps rows: organization buildings merged with local zones
    /// and the download cache.
    func entries(localZones: [MappingZone]) -> [BuildingEntry] {
        BuildingCatalogMerger.merge(
            remote: service.catalog,
            localZones: localZones,
            cachedVersion: { [cachedVersions] in cachedVersions[$0] },
            profile: service.profile,
            transient: downloadStates
        )
    }

    // MARK: - Map packages

    /// The verified package on this device, or nil when nothing is cached.
    /// Reading it never touches the network, so Emergency works offline.
    func cachedPackage(for buildingID: UUID) -> MapPackageManifest? {
        packages.manifest(buildingID: buildingID)
    }

    /// Downloads and verifies the published package. Metadata discovery is
    /// automatic elsewhere; the large artifacts only come down when the user
    /// asks for them here.
    func download(building: CatalogBuilding) async {
        guard let client = service.currentClient else {
            downloadStates[building.id] = .downloadFailed("Not signed in")
            return
        }
        guard let mapVersionID = building.activeMapVersionID else {
            downloadStates[building.id] = .downloadFailed("No published map")
            return
        }

        downloadStates[building.id] = .downloading
        let downloader = MapPackageDownloader(
            source: SupabaseMapPackageSource(client: client), cache: packages
        )
        do {
            let outcome = try await downloader.download(
                buildingID: building.id, mapVersionID: mapVersionID
            )
            service.markCached(buildingID: building.id, version: outcome.version)
            cachedVersions = packages.allCachedVersions()
            downloadStates[building.id] = nil
            DiagnosticsLog.shared.log(
                "Downloaded \(building.name) v\(outcome.version) — \(outcome.artifactCount) artifact(s)"
            )
        } catch {
            // The previous package, if any, is still intact — the merge will
            // go on reporting it as offline available.
            cachedVersions = packages.allCachedVersions()
            downloadStates[building.id] = .downloadFailed(error.localizedDescription)
            DiagnosticsLog.shared.log("Download failed for \(building.name): \(error)")
        }
    }

    /// Deletes the building for the whole organization, and drops this
    /// device's downloaded copy with it.
    func deleteBuilding(_ building: CatalogBuilding) async {
        do {
            try await service.deleteBuilding(id: building.id)
            packages.remove(buildingID: building.id)
            cachedVersions = packages.allCachedVersions()
            downloadStates[building.id] = nil
            error = nil
        } catch {
            self.error = "Could not delete \(building.name): \(error.localizedDescription)"
        }
    }

    func removeDownload(buildingID: UUID) {
        packages.remove(buildingID: buildingID)
        cachedVersions = packages.allCachedVersions()
        downloadStates[buildingID] = nil
    }

    func clearDownloadState(_ buildingID: UUID) {
        downloadStates[buildingID] = nil
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
                HStack(spacing: EG.Space.s) {
                    if session.busy {
                        ProgressView().tint(.white)
                        Text("Signing in…")
                    } else {
                        Text(title)
                    }
                }
            }
            .buttonStyle(EGPrimaryButtonStyle(tone: .neutral))
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            .disabled(session.busy || session.config.anonKey.isEmpty || session.email.isEmpty)
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(Color.egEmergency)
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
                            NavigationLink {
                                FocusMapLoader(session: session, building: building)
                            } label: {
                                Label("View in 3D", systemImage: "view.3d")
                                    .font(.caption)
                            }
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
    /// Set when the mapper started from a specific local map in Saved Maps.
    var preselected: MappingZone?

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var selected: MappingZone?
    @State private var busy = false
    @State private var error: String?
    @State private var progress: String?
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
                    Section("Localization package") {
                        // Sizes, not contents: reading the world map here meant
                        // loading well over a megabyte on every re-render.
                        let summary = MapPublisher.artifactSummary(for: zone, store: repository.store)
                        LabeledContent("AR world map", value: summary.hasWorldMap ? "Included" : "None")
                        LabeledContent("Reference views", value: "\(summary.referenceViewCount)")
                        LabeledContent(
                            "Upload size",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(summary.totalBytes), countStyle: .file
                            )
                        )
                        if !summary.hasWorldMap {
                            Label(
                                "No saved AR world map. The route will publish and work, but occupants cannot use camera relocalization in this building.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.caption2).foregroundStyle(.orange)
                        }
                        if summary.referenceViewCount < 2 {
                            Label(
                                "Only \(summary.referenceViewCount) reference view. Add photos from other directions so relocalization works from more than one spot.",
                                systemImage: "camera.viewfinder"
                            )
                            .font(.caption2).foregroundStyle(.secondary)
                        }
                    }

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
                                Text(progress ?? (building.version == nil ? "Publish" : "Publish Update"))
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
                        LabeledContent("Files uploaded", value: "\(result.artifactCount)")
                        LabeledContent("AR world map", value: result.hasWorldMap ? "Included" : "None")
                        Text("Occupants in your organization will see this building and can download it.")
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
            .task {
                await repository.refresh()
                if selected == nil { selected = preselected }
            }
        }
    }

    private func publish(zone: MappingZone, graph: BuildingGraph) async {
        busy = true; error = nil; progress = "Uploading map package…"
        defer { busy = false; progress = nil }
        do {
            guard let client = session.service.currentClient else {
                throw BackendError.notConfigured
            }
            let artifacts = MapPublisher.artifacts(for: zone, store: repository.store)
            let outcome = try await MapPublisher(client: client).publish(
                zone: zone,
                graph: graph,
                organizationID: session.profile.organizationID ?? UUID(),
                existingBuildingID: building.id,
                buildingName: building.name,
                artifacts: artifacts
            )
            result = outcome

            var updated = zone
            updated.remoteBuildingID = outcome.buildingID
            updated.updatedAt = Date()
            await repository.upsert(updated)
            try await session.service.loadCatalog()
        } catch {
            // Nothing was published: the version stays a draft and the objects
            // that did upload have been removed.
            self.error = error.localizedDescription
        }
    }
}
