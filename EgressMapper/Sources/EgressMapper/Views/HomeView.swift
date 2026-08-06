import SwiftUI
import ARKit

/// Top level of the app: a prominent Emergency path for someone who needs to
/// get out, and a Configure path for the administrator tooling.
struct HomeView: View {
    @Environment(ZoneRepository.self) private var repository
    @State private var showEmergency = false
    @State private var showConfigure = false
    @State private var showSavedZones = false

    private var arSupported: Bool { ARWorldTrackingConfiguration.isSupported }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    if !arSupported { unsupportedBanner }
                    emergencyButton
                    secondaryActions
                    disclaimer
                }
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(isPresented: $showEmergency) {
                EmergencyZoneSelectView()
            }
            .navigationDestination(isPresented: $showConfigure) {
                ConfigureView()
            }
            .navigationDestination(isPresented: $showSavedZones) {
                SavedZonesView()
            }
            .task { await repository.refresh() }
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
        .disabled(repository.zones.isEmpty)
        .overlay(alignment: .bottom) {
            if repository.zones.isEmpty {
                Text("Map a zone in Configure first")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, -18)
            }
        }
    }

    private var secondaryActions: some View {
        VStack(spacing: 12) {
            Button {
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
    @State private var showCreateZone = false
    @State private var showSavedZones = false
    @State private var profile = NavigationProfile.standard

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
            SavedZonesView()
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
