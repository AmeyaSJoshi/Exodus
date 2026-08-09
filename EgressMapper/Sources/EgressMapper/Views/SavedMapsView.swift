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
    @Bindable var session: BackendSession

    @State private var openZone: MappingZone?
    @State private var attachZone: MappingZone?
    @State private var publishTarget: BuildingEntry?
    @State private var emergencyBuilding: CatalogBuilding?
    @State private var detailEntry: BuildingEntry?
    @State private var renaming: MappingZone?
    @State private var renameText = ""
    @State private var pendingDelete: MappingZone?

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
                        .font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Maps Yet",
                        systemImage: "map",
                        description: Text(
                            session.canManage
                            ? "Map a zone in Configure, or sign in to see buildings your organization published."
                            : "No published buildings in your organization yet."
                        )
                    )
                }
                ForEach(entries) { entry in
                    SavedMapRow(entry: entry, profile: session.profile) { action in
                        perform(action, on: entry)
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .swipeActions(edge: .trailing) {
                        if let zone = entry.localZone, session.canManage {
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
        .task { await reload() }
        .onChange(of: session.isSignedIn) { _, signedIn in
            if signedIn { Task { await reload() } }
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
        .alert("Delete Local Map?", isPresented: .constant(pendingDelete != nil)) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let pendingDelete { Task { await repository.delete(pendingDelete) } }
                pendingDelete = nil
            }
        } message: {
            Text("This removes the world map, waypoints and recorded path stored on this device for “\(pendingDelete?.displayTitle ?? "")”. Anything already published stays published.")
        }
        .alert("Rename Map", isPresented: .constant(renaming != nil)) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming { Task { await repository.rename(renaming, to: renameText) } }
                renaming = nil
            }
        }
    }

    private func reload() async {
        await repository.refresh()
        await session.refresh()
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
        }
    }
}

private struct SavedMapRow: View {
    let entry: BuildingEntry
    let profile: UserProfile
    var perform: (BuildingAction) -> Void

    private var tint: Color {
        switch entry.availability {
        case .offlineAvailable, .publishedByYou: return .green
        case .updateAvailable: return .yellow
        case .downloadFailed: return .red
        case .downloading: return .blue
        case .localDraft: return .orange
        case .downloadRequired: return .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: entry.isRemote ? "building.2.fill" : "map.fill")
                    .font(.title3)
                    .foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.subheadline.weight(.semibold))
                    Text(entry.subtitle).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if case .downloading = entry.availability {
                            ProgressView().controlSize(.mini)
                        }
                        Text(entry.availability.label).font(.caption2).foregroundStyle(tint)
                    }
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

    private var rows: [[BuildingAction]] {
        stride(from: 0, to: actions.count, by: 3).map {
            Array(actions[$0..<min($0 + 3, actions.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(row, id: \.self) { action in
                        Button { perform(action) } label: {
                            Label(action.label, systemImage: action.symbolName)
                                .font(.caption2)
                                .lineLimit(1)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(action == .useInEmergency ? .red : .accentColor)
                    }
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
