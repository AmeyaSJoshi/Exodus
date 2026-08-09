import SwiftUI

/// Emergency entry point: pick the building/zone you are in.
/// Camera-based localization ("I Don't Know Where I Am") lands in Milestone 2;
/// until then this hands off to the existing, working route flow.
struct EmergencyZoneSelectView: View {
    @Environment(ZoneRepository.self) private var repository
    @State private var selected: MappingZone?

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
                        Button {
                            selected = zone
                        } label: {
                            ZoneRowView(zone: zone)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    }
                }
            } header: {
                Text("Where are you?")
            } footer: {
                Text("Select the building and floor you are currently in.")
            }
        }
        .navigationTitle("Emergency")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $selected) { zone in
            RouteSetupView(zone: zone)
        }
        .task { await repository.refresh() }
    }
}
