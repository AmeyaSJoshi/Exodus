import SwiftUI

struct SavedZonesView: View {
    @Environment(ZoneRepository.self) private var repository
    @State private var pendingDelete: MappingZone?
    @State private var renaming: MappingZone?
    @State private var renameText = ""
    @State private var selected: MappingZone?

    var body: some View {
        List {
            if repository.zones.isEmpty {
                ContentUnavailableView(
                    "No Saved Zones",
                    systemImage: "map",
                    description: Text("Map a hallway to create your first zone.")
                )
            }

            ForEach(repository.grouped, id: \.key) { group in
                Section(group.key) {
                    ForEach(group.zones) { zone in
                        Button {
                            selected = zone
                        } label: {
                            ZoneRowView(zone: zone)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                pendingDelete = zone
                            } label: {
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
            }
        }
        .navigationTitle("Saved Zones")
        .refreshable { await repository.refresh() }
        .navigationDestination(item: $selected) { zone in
            RouteSetupView(zone: zone)
        }
        .alert("Delete Zone?", isPresented: .constant(pendingDelete != nil)) {
            Button("Cancel", role: .cancel) { pendingDelete = nil }
            Button("Delete", role: .destructive) {
                if let pendingDelete {
                    Task { await repository.delete(pendingDelete) }
                }
                pendingDelete = nil
            }
        } message: {
            Text("This permanently removes the world map, waypoints and recorded path for “\(pendingDelete?.displayTitle ?? "")”.")
        }
        .alert("Rename Zone", isPresented: .constant(renaming != nil)) {
            TextField("Zone name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let renaming {
                    Task { await repository.rename(renaming, to: renameText) }
                }
                renaming = nil
            }
        }
        .task { await repository.refresh() }
    }
}
