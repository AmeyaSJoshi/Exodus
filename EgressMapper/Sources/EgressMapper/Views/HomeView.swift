import SwiftUI

/// Top level of the app: a prominent Emergency path for someone who needs to
/// get out, and a Configure path for the administrator tooling.
struct HomeView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(BackendSession.self) private var session
    @Environment(StartupCoordinator.self) private var startup
    @Environment(DeviceCapabilities.self) private var capabilities
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
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if capabilities.resolved && !arSupported { unsupportedBanner }
                    if let status = startup.phase.label { statusStrip(status) }
                    emergencyButton
                    secondaryActions
                    disclaimer
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
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

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("EGRESS")
                .font(.system(size: 44, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
            Text("Indoor AR evacuation prototype")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 8)
    }

    private var unsupportedBanner: some View {
        Label(
            "This device does not support ARKit world tracking. AR guidance is unavailable; the 2D map still works.",
            systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.orange)
    }

    /// No account, no setup — the emergency path is always one tap away.
    private var emergencyButton: some View {
        Button {
            showEmergency = true
        } label: {
            VStack(spacing: 8) {
                Image(systemName: "figure.run.circle.fill")
                    .font(.system(size: 46))
                Text("EMERGENCY")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Guide me out of this building")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.9))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 28)
            .background(Color.red, in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(.white)
        }

    }

    private var secondaryActions: some View {
        VStack(spacing: 12) {
            Button {
                Startup.log("tap: Configure")
                showConfigure = true
            } label: {
                Label("Configure", systemImage: "slider.horizontal.3")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(.white)

            Button {
                Startup.log("tap: Saved Maps")
                showSavedZones = true
            } label: {
                Label("Saved Maps (\(repository.zones.count))", systemImage: "map")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .padding(.top, 14)
    }

    /// Non-blocking: it reports what is happening in the background and never
    /// covers or disables anything.
    private func statusStrip(_ text: String) -> some View {
        HStack(spacing: 8) {
            if startup.phase.canRetry {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if startup.phase.canRetry {
                Button("Retry") { startup.retry(session: session) }.font(.caption)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white.opacity(0.06), in: Capsule())
        .allowsHitTesting(startup.phase.canRetry)
    }

    private var disclaimer: some View {
        Text("Experimental navigation prototype. Follow official emergency instructions and posted evacuation procedures.")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
    }
}

/// Administrator tooling — mapping and route creation. Nothing was removed
/// from the original flow; it now lives behind this screen.
struct ConfigureView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(BackendSession.self) private var session
    @State private var showCreateZone = false
    @State private var showSavedZones = false
    @State private var profile = NavigationProfile.standard
    @AppStorage(DeveloperSettings.debugIndicatorKey) private var showCameraDebug = false

    var body: some View {
        List {
            Section("Mapping") {
                Button {
                    showCreateZone = true
                } label: {
                    Label("Map a New Zone", systemImage: "camera.viewfinder")
                }
                Button {
                    showSavedZones = true
                } label: {
                    Label("Saved Maps & Route Testing", systemImage: "map")
                }
                NavigationLink {
                    ActiveHazardsView()
                } label: {
                    Label("Active Hazards", systemImage: "exclamationmark.triangle")
                }

            }

            Section("Organization") {
                NavigationLink {
                    BuildingsView(session: session)
                } label: {
                    Label("Buildings", systemImage: "building.2")
                }
            }

            Section {
                NavigationLink {
                    LiveDemoView()
                } label: {
                    Label("Live Backend Diagnostics", systemImage: "stethoscope")
                }
                Toggle("Camera debug indicator", isOn: $showCameraDebug)
            } header: {
                Text("Developer Tools")
            } footer: {
                Text("The camera indicator shows feed, tracking and session state while mapping. Useful when diagnosing a frozen or black preview on a device.")
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
}

struct ZoneRowView: View {
    let zone: MappingZone

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 36, height: 36)
                .background(Color.green.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(zone.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Text(zone.displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Label("\(zone.waypointCount)", systemImage: "mappin.circle")
                    Label(zone.formattedLength, systemImage: "ruler")
                    if zone.hasWorldMap {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }
}
