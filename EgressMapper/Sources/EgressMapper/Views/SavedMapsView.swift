import SwiftUI

/// The one Saved Maps screen. Local drafts, buildings this mapper published,
/// published buildings from the user's organization and downloaded packages all
/// appear here as a single list — a published local zone and its building are
/// one row, never two.
///
/// Which actions a row offers comes from `BuildingEntry.actions(for:)`, so the
/// view never decides what a role may do.
struct SavedMapsView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(StartupCoordinator.self) private var startup
    @Bindable var session: BackendSession

    @State private var openZone: MappingZone?
    @State private var attachZone: MappingZone?
    @State private var publishTarget: BuildingEntry?
    @State private var emergencyBuilding: CatalogBuilding?
    @State private var detailEntry: BuildingEntry?
    @State private var renaming: MappingZone?
    @State private var renameText = ""
    @State private var pendingDelete: MappingZone?
    @State private var pendingBuildingDelete: CatalogBuilding?
    @State private var deleting = false

    private var entries: [BuildingEntry] {
        session.entries(localZones: repository.zones)
    }

    var body: some View {
        List {
            if !session.isSignedIn {
                BackendSignInView(session: session, title: "Sign in to see your organization's maps")
            }

            if let error = session.error, session.isSignedIn {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Color.egEmergency)
                }
            }

            // A map whose metadata will not decode must say so. Dropping it
            // from the list would look identical to never having saved it.
            if !repository.damagedZoneIDs.isEmpty {
                Section {
                    EGBanner(
                        title: "\(repository.damagedZoneIDs.count) saved map\(repository.damagedZoneIDs.count == 1 ? "" : "s") could not be read",
                        detail: "Nothing has been deleted — the files are still on this device. Re-map the area to replace them.",
                        tone: .caution
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    #if DEBUG
                    ForEach(repository.damagedZoneIDs, id: \.self) { id in
                        Text(id.uuidString).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                    #endif
                }
            }

            Section {
                if entries.isEmpty {
                    EGEmptyState(
                        title: "No saved maps",
                        message: session.canManage
                            ? "Map a hallway or floor before starting navigation. Saved maps work with no network."
                            : "Nothing has been published to your organization yet. Maps appear here once an administrator publishes one.",
                        symbol: "map"
                    )
                    .listRowBackground(Color.clear)
                }
                ForEach(entries) { entry in
                    SavedMapRow(entry: entry, profile: session.profile) { action in
                        perform(action, on: entry)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing) {
                        // Same gate as the row's own actions, so a signed-out
                        // device can still delete a recording it made.
                        if let zone = entry.localZone,
                           entry.actions(for: session.profile).contains(.deleteLocalMap) {
                            Button(role: .destructive) { pendingDelete = zone } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameText = zone.zoneName
                                renaming = zone
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                    }
                }
            } header: {
                Text("Saved Maps")
            } footer: {
                Text("Offline Available maps work with no network. Downloading fetches the building's AR map and reference images.")
            }
        }
        .navigationTitle("Saved Maps")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await reload() }
        .task { startup.start(repository: repository, session: session) }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn { startup.authenticationChanged(session: session) }
        }
        .navigationDestination(item: $openZone) { zone in
            RouteSetupView(zone: zone)
        }
        .navigationDestination(item: $emergencyBuilding) { building in
            EvacuationView(session: session, building: building)
        }
        .sheet(item: $attachZone) { zone in
            AttachZoneToBuildingView(session: session, zone: zone)
                .environment(repository)
        }
        .sheet(item: $publishTarget) { entry in
            if let building = entry.remote {
                AttachMapView(session: session, building: building)
                    .environment(repository)
            }
        }
        .sheet(item: $detailEntry) { entry in
            PublicationStateView(entry: entry, cached: session.cachedPackage(for: entry.id))
        }
        .alert("Delete Local Map?", isPresented: .presenting($pendingDelete)) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let pendingDelete { Task { await repository.delete(pendingDelete) } }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the world map, waypoints and recorded path stored on this device for “\(pendingDelete?.displayTitle ?? "")”. Anything already published stays published.")
        }
        .alert("Delete Building?", isPresented: .presenting($pendingBuildingDelete)) {
            Button("Cancel", role: .cancel) { pendingBuildingDelete = nil }
            Button("Delete for Everyone", role: .destructive) {
                if let building = pendingBuildingDelete {
                    deleting = true
                    Task {
                        await session.deleteBuilding(building)
                        deleting = false
                    }
                }
                pendingBuildingDelete = nil
            }
        } message: {
            Text("This permanently removes “\(pendingBuildingDelete?.name ?? "")”, every published version of its map and its live closures, for everyone in your organization. Occupants will no longer see it. Local recordings on this device are kept.")
        }
        .alert("Rename Map", isPresented: .presenting($renaming)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { Task { await repository.rename(renaming, to: renameText) } }
                renaming = nil
            }
        }
    }

    /// Pull-to-refresh is an explicit user request, so it bypasses the
    /// coalescing window; view appearance goes through the coordinator.
    private func reload() async {
        startup.loadLocal(repository: repository, session: session)
        startup.refreshRemote(session: session, force: true)
    }

    private func perform(_ action: BuildingAction, on entry: BuildingEntry) {
        switch action {
        case .openDraft, .edit, .testRoute:
            openZone = entry.localZone
        case .attachToBuilding:
            attachZone = entry.localZone
        case .publishUpdate:
            publishTarget = entry
        case .download, .update:
            if let remote = entry.remote {
                Task { await session.download(building: remote) }
            }
        case .removeDownload:
            session.removeDownload(buildingID: entry.id)
        case .useInEmergency:
            if let remote = entry.remote { emergencyBuilding = remote }
            else { openZone = entry.localZone }
        case .viewBuilding, .viewPublicationState:
            detailEntry = entry
        case .deleteLocalMap:
            pendingDelete = entry.localZone
        case .deleteBuilding:
            pendingBuildingDelete = entry.remote
        }
    }
}

private struct SavedMapRow: View {
    let entry: BuildingEntry
    let profile: UserProfile
    var perform: (BuildingAction) -> Void

    private var tint: Color {
        switch entry.availability {
        case .offlineAvailable, .publishedByYou: return .egSafe
        case .updateAvailable: return .egCaution
        case .downloadFailed: return .egEmergency
        case .downloading: return .accentColor
        case .localDraft: return .secondary
        case .downloadRequired: return .secondary
        }
    }

    /// Availability is stated with a symbol as well as a colour.
    private var availabilitySymbol: String {
        switch entry.availability {
        case .offlineAvailable: return "arrow.down.circle.fill"
        case .publishedByYou: return "checkmark.seal.fill"
        case .updateAvailable: return "arrow.triangle.2.circlepath"
        case .downloadFailed: return "exclamationmark.triangle.fill"
        case .downloading: return "arrow.down.circle"
        case .localDraft: return "iphone"
        case .downloadRequired: return "icloud.and.arrow.down"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EG.Space.s) {
            HStack(spacing: EG.Space.m) {
                Image(systemName: entry.isRemote ? "building.2.fill" : "map.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.headline)
                    Text(entry.subtitle).font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: EG.Space.xs) {
                        if case .downloading = entry.availability {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: availabilitySymbol)
                        }
                        Text(entry.availability.label)
                    }
                    .font(.caption)
                    .foregroundStyle(tint)
                }
                Spacer()
            }

            let actions = entry.actions(for: profile)
            if !actions.isEmpty {
                // Wraps rather than scrolls, so nothing is hidden off-screen
                // during an emergency.
                FlowActions(actions: actions, perform: perform)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Small wrapping row of action buttons.
private struct FlowActions: View {
    let actions: [BuildingAction]
    var perform: (BuildingAction) -> Void

    /// Evacuating is never one of several equal chips — it gets its own full
    /// width row above the administrative actions.
    private var primary: BuildingAction? {
        actions.first { $0 == .useInEmergency }
    }

    private var secondary: [BuildingAction] {
        actions.filter { $0 != .useInEmergency }
    }

    /// Two per row: three chips truncated "Use in Emergency" and "Delete From
    /// Device" at every Dynamic Type size.
    private var rows: [[BuildingAction]] {
        stride(from: 0, to: secondary.count, by: 2).map {
            Array(secondary[$0..<min($0 + 2, secondary.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: EG.Space.s) {
            if let primary {
                Button { perform(primary) } label: {
                    Label(primary.label, systemImage: primary.symbolName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .tint(Color.egEmergency)
            }
            ForEach(rows, id: \.self) { row in
                HStack(spacing: EG.Space.s) {
                    ForEach(row, id: \.self) { action in
                        Button { perform(action) } label: {
                            Label(action.label, systemImage: action.symbolName)
                                .font(.caption)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(action == .deleteLocalMap || action == .deleteBuilding
                              ? Color.egEmergency : .accentColor)
                    }
                    if row.count == 1 { Spacer(minLength: 0) }
                }
            }
        }
    }
}

/// What has actually been published and what is on this device.
struct PublicationStateView: View {
    let entry: BuildingEntry
    let cached: MapPackageManifest?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Building") {
                    LabeledContent("Name", value: entry.name)
                    if let remote = entry.remote {
                        LabeledContent("Status", value: remote.status.capitalized)
                        LabeledContent("Published version", value: remote.version.map { "v\($0)" } ?? "—")
                        LabeledContent("Nodes", value: "\(remote.nodeCount)")
                        LabeledContent("Artifacts", value: "\(remote.artifactCount)")
                        if let published = remote.publishedAt {
                            LabeledContent("Published at", value: published)
                                .font(.caption)
                        }
                    } else {
                        Text("Not published — this map exists only on this device.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("On this device") {
                    LabeledContent("Availability", value: entry.availability.label)
                    if let cached {
                        LabeledContent("Cached version", value: "v\(cached.version)")
                        LabeledContent("Package format", value: "v\(cached.schemaVersion)")
                        LabeledContent("Mapping zones", value: "\(cached.zones.count)")
                        LabeledContent(
                            "AR world maps",
                            value: "\(cached.zones.filter(\.hasWorldMap).count)"
                        )
                        if !cached.zones.contains(where: \.hasWorldMap) {
                            Label(
                                "AR localization unavailable — map contains routing data only. Routing and 2D guidance still work.",
                                systemImage: "arkit"
                            )
                            .font(.caption2).foregroundStyle(.orange)
                        }
                        LabeledContent(
                            "Reference views",
                            value: "\(cached.artifacts.filter { $0.kind == .referenceImage }.count)"
                        )
                        LabeledContent(
                            "Total size",
                            value: ByteCountFormatter.string(
                                fromByteCount: Int64(cached.artifacts.reduce(0) { $0 + $1.byteSize }),
                                countStyle: .file
                            )
                        )
                    } else {
                        Text("No downloaded package. Camera relocalization is unavailable until this building is downloaded.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let zone = entry.localZone {
                        LabeledContent("Local map", value: zone.displayTitle)
                        LabeledContent("Waypoints", value: "\(zone.waypointCount)")
                    }
                }
            }
            .navigationTitle("Publication State")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

/// Attaching starts from a local zone rather than a building: the mapper picks
/// which building it belongs to, or creates one.
struct AttachZoneToBuildingView: View {
    @Bindable var session: BackendSession
    let zone: MappingZone

    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var selected: CatalogBuilding?
    @State private var showAdd = false

    private var drafts: [CatalogBuilding] {
        session.service.catalog
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Local map") {
                    Text(zone.displayTitle).font(.headline)
                    Text("\(zone.waypointCount) waypoints · \(zone.formattedLength)")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Create a New Building", systemImage: "plus.circle.fill")
                    }
                    ForEach(drafts) { building in
                        Button {
                            selected = building
                        } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(building.name)
                                    Text(building.isPublished ? "Published v\(building.version ?? 0)" : "Draft")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                        }
                    }
                } header: {
                    Text("Attach to")
                } footer: {
                    Text("Publishing uploads the route graph and this zone's AR world map and reference views as a new version.")
                }
            }
            .navigationTitle("Attach to Building")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showAdd) { AddBuildingView(session: session) }
            .sheet(item: $selected) { building in
                AttachMapView(session: session, building: building, preselected: zone)
                    .environment(repository)
            }
            .task { await session.refresh() }
        }
    }
}
