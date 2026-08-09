import SwiftUI

/// Top level of the app: a dominant Emergency path for someone who needs to
/// get out, and quieter administrative entry points beneath it.
struct HomeView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(BackendSession.self) private var session
    @Environment(StartupCoordinator.self) private var startup
    @Environment(DeviceCapabilities.self) private var capabilities
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showEmergency = false
    @State private var showConfigure = false
    @State private var showSavedZones = false

    /// Read from the resolved capability, never probed here. Calling
    /// `ARWorldTrackingConfiguration.isSupported` from `body` loaded ARKit on
    /// the main thread before the first frame, on every re-render.
    private var arSupported: Bool { capabilities.arWorldTrackingSupported }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: EG.Space.l) {
                    EGBrandMark(subtitle: "Indoor evacuation guidance")
                        .padding(.top, EG.Space.s)
                        .padding(.bottom, EG.Space.xs)

                    emergencyButton

                    if capabilities.resolved && !arSupported { unsupportedBanner }
                    if let status = startup.phase.label { statusStrip(status) }

                    secondaryActions
                    disclaimer
                }
                .padding(EG.Space.l)
            }
            .background(Color(.systemBackground).ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showEmergency) {
                EmergencyBuildingListView(session: session)
                    .onAppear { Startup.firstUse("emergency-open") }
            }
            .navigationDestination(isPresented: $showConfigure) {
                ConfigureView()
                    .onAppear { Startup.firstUse("configure-open") }
            }
            .navigationDestination(isPresented: $showSavedZones) {
                SavedMapsView(session: session)
                    .onAppear { Startup.firstUse("saved-maps-open") }
            }
            // The coordinator owns this; every screen calling its own refresh
            // is what produced overlapping scans and catalogue requests.
            .task { startup.start(repository: repository, session: session) }
        }
    }

    private var unsupportedBanner: some View {
        EGBanner(
            title: "AR guidance unavailable",
            detail: "This device does not support ARKit world tracking. The 2D route map works as normal.",
            tone: .caution,
            symbol: "arkit"
        )
        .egAnimation(arSupported)
    }

    /// No account, no setup — the emergency path is always one tap away and is
    /// the only red element on the screen.
    private var emergencyButton: some View {
        Button {
            showEmergency = true
        } label: {
            // Side by side normally; stacked at accessibility text sizes, where
            // a horizontal layout hyphenated "Emergency" mid-word.
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: EG.Space.m))
                : AnyLayout(HStackLayout(spacing: EG.Space.l))

            layout {
                Image(systemName: "figure.run")
                    .font(.system(size: 40, weight: .semibold))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: EG.Space.xs) {
                    Text("Emergency")
                        .font(.largeTitle.weight(.heavy))
                    Text("Find the safest available exit")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.92))
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EG.Space.xl)
            .background(Color.egEmergency, in: RoundedRectangle(cornerRadius: EG.Radius.prominent))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Emergency")
        .accessibilityHint("Finds the safest available exit from this building")
    }

    private var secondaryActions: some View {
        VStack(spacing: EG.Space.s) {
            secondaryRow(
                "Saved Maps",
                detail: repository.zones.isEmpty
                    ? "Buildings available on this device"
                    : "\(repository.zones.count) on this device",
                symbol: "map"
            ) {
                Startup.log("tap: Saved Maps")
                showSavedZones = true
            }

            secondaryRow(
                "Configure",
                detail: "Mapping, buildings and navigation settings",
                symbol: "slider.horizontal.3"
            ) {
                Startup.log("tap: Configure")
                showConfigure = true
            }
        }
    }

    private func secondaryRow(
        _ title: String, detail: String, symbol: String, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: EG.Space.m) {
                Image(systemName: symbol)
                    .font(.body)
                    .frame(width: 26)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(EGSecondaryButtonStyle())
    }

    /// Non-blocking: it reports what is happening in the background and never
    /// covers or disables anything.
    private func statusStrip(_ text: String) -> some View {
        HStack(spacing: EG.Space.s) {
            if startup.phase.canRetry {
                EGStatusBadge(status: .custom(text, "exclamationmark.triangle.fill", .caution))
                Spacer(minLength: 0)
                Button("Retry") { startup.retry(session: session) }
                    .font(.subheadline.weight(.medium))
            } else {
                EGStatusBadge(status: .custom(text, "arrow.clockwise", .neutral))
                Spacer(minLength: 0)
            }
        }
        .egAnimation(startup.phase.canRetry)
        .modifier(EGTransition())
    }

    private var disclaimer: some View {
        Text("Experimental navigation aid. Always follow official emergency instructions and posted evacuation procedures.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, EG.Space.s)
    }
}

/// Administrator tooling — mapping, buildings and route testing. An
/// administrative workspace, deliberately not styled like an emergency screen.
struct ConfigureView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(BackendSession.self) private var session
    @State private var showCreateZone = false
    @State private var showSavedZones = false
    @State private var profile = NavigationProfile.standard
    @AppStorage(DeveloperSettings.debugIndicatorKey) private var showCameraDebug = false

    var body: some View {
        List {
            Section {
                Button {
                    showCreateZone = true
                } label: {
                    row("Map a Zone", "Record a hallway or floor with the camera", "camera.viewfinder", chevron: true)
                }
                .buttonStyle(.plain)
                Button {
                    showSavedZones = true
                } label: {
                    row("Saved Zones", "Open, rename, test or publish a recorded map", "map", chevron: true)
                }
                .buttonStyle(.plain)
                NavigationLink {
                    ActiveHazardsView()
                } label: {
                    row("Active Hazards", "Closures reported from this device", "exclamationmark.triangle")
                }
            } header: {
                Text("Mapping")
            } footer: {
                Text("Route testing runs from a saved zone, using the same router as evacuation.")
            }

            Section {
                NavigationLink {
                    BuildingsView(session: session)
                } label: {
                    row("Buildings", "Publish a building map for your organization", "building.2")
                }
            } header: {
                Text("Organization")
            }

            Section {
                Toggle("Avoid stairs", isOn: $profile.avoidStairs)
                Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)
                Toggle("Avoid elevators", isOn: $profile.avoidElevators)
                Toggle("Voice guidance", isOn: $profile.audioGuidanceEnabled)
                Toggle("Haptic guidance", isOn: $profile.hapticGuidanceEnabled)
            } header: {
                Text("Navigation Profile")
            } footer: {
                Text("Applied to every route. If no route satisfies these constraints, the app says so rather than quietly ignoring them.")
            }

            Section {
                NavigationLink {
                    LiveDemoView()
                } label: {
                    row("Live Backend Demo", "Exercise the backend and live rerouting without AR", "stethoscope")
                }
                Toggle("Camera debug indicator", isOn: $showCameraDebug)
            } header: {
                Text("Developer Tools")
            } footer: {
                Text("Diagnostics for development. The camera indicator shows feed, tracking and session state while mapping — useful when a preview freezes on a device.")
            }
        }
        .navigationTitle("Configure")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showCreateZone) {
            CreateZoneView().environment(repository)
        }
        .navigationDestination(isPresented: $showSavedZones) {
            SavedMapsView(session: session)
        }
        .task { profile = repository.store.loadProfile() }
        .onChange(of: profile) { _, updated in
            try? repository.store.saveProfile(updated)
        }
    }

    /// One consistent list row: title, one-line description, symbol. `chevron`
    /// is drawn for plain Buttons so they match the NavigationLink rows.
    private func row(
        _ title: String, _ detail: String, _ symbol: String, chevron: Bool = false
    ) -> some View {
        HStack(spacing: 0) {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: symbol).foregroundStyle(Color.accentColor)
            }
            if chevron {
                Spacer(minLength: EG.Space.s)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct ZoneRowView: View {
    let zone: MappingZone

    var body: some View {
        HStack(spacing: EG.Space.m) {
            Image(systemName: "map.fill")
                .font(.title3)
                .foregroundStyle(Color.egSafe)
                .frame(width: 36, height: 36)
                .background(Color.egSafe.opacity(0.15), in: RoundedRectangle(cornerRadius: EG.Space.s))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(zone.displayTitle)
                    .font(.subheadline.weight(.semibold))
                Text(zone.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: EG.Space.s) {
                    Label("\(zone.waypointCount)", systemImage: "mappin.circle")
                    Label(zone.formattedLength, systemImage: "ruler")
                    if zone.hasWorldMap {
                        Label("AR ready", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Color.egSafe)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .padding(EG.Space.m)
        .background(Color.egSurface, in: RoundedRectangle(cornerRadius: EG.Radius.card))
        .accessibilityElement(children: .combine)
    }
}
