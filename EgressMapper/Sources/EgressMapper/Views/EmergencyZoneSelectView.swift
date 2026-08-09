import SwiftUI

/// Emergency entry point: pick the building/zone you are in, then either let
/// the camera work out where you are or choose manually.
struct EmergencyZoneSelectView: View {
    @Environment(ZoneRepository.self) private var repository
    @State private var selected: MappingZone?
    @State private var localizing: MappingZone?
    @State private var located: LocatedStart?

    /// A confirmed position plus the estimate that produced it.
    struct LocatedStart: Identifiable, Hashable {
        let id = UUID()
        let zone: MappingZone
        let position: RoutePosition
        let estimate: LocationEstimate
    }

    var body: some View {
        List {
            Section {
                Label(
                    "Follow official emergency instructions and posted evacuation procedures. This prototype is an aid, not an authority.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }

            Section {
                if repository.zones.isEmpty {
                    ContentUnavailableView(
                        "No Mapped Zones",
                        systemImage: "map",
                        description: Text("Map a zone in Configure before using Emergency mode.")
                    )
                }
                ForEach(repository.grouped, id: \.key) { group in
                    ForEach(group.zones) { zone in
                        zoneRow(zone)
                    }
                }
            } header: {
                Text("Which building are you in?")
            } footer: {
                Text("Pick your zone, then let the camera find you or choose your location manually.")
            }
        }
        .navigationTitle("Emergency")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $localizing) { zone in
            EmergencyLocalizationView(zone: zone) { position, estimate in
                localizing = nil
                located = LocatedStart(zone: zone, position: position, estimate: estimate)
            } onCancel: {
                localizing = nil
            }
            .environment(repository)
        }
        .navigationDestination(item: $located) { start in
            RouteSetupView(
                zone: start.zone,
                presetStart: start.position,
                presetEstimate: start.estimate
            )
        }
        .navigationDestination(item: $selected) { zone in
            RouteSetupView(zone: zone)
        }
        .task { await repository.refresh() }
    }

    @ViewBuilder
    private func zoneRow(_ zone: MappingZone) -> some View {
        VStack(spacing: 8) {
            ZoneRowView(zone: zone)

            HStack(spacing: 8) {
                Button {
                    localizing = zone
                } label: {
                    Label("I Don't Know Where I Am", systemImage: "location.magnifyingglass")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!zone.hasWorldMap)

                Button {
                    selected = zone
                } label: {
                    Image(systemName: "list.bullet")
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Choose start and destination manually")
            }

            if !zone.hasWorldMap {
                Text("No saved world map — camera localization unavailable for this zone.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8))
    }
}
