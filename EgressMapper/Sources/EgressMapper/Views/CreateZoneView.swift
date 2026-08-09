import SwiftUI

struct CreateZoneView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var campus = ""
    @State private var building = ""
    @State private var floor = ""
    @State private var zoneName = ""
    @State private var startedZone: MappingZone?

    private var isValid: Bool {
        !building.trimmingCharacters(in: .whitespaces).isEmpty &&
        !zoneName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    TextField("Campus or property", text: $campus)
                    TextField("Building", text: $building)
                    TextField("Floor", text: $floor)
                }
                Section {
                    TextField("Zone name (e.g. East Hallway)", text: $zoneName)
                } header: {
                    Text("Zone")
                } footer: {
                    Text("Map one hallway or wing at a time. Small zones relocalize far more reliably than one map of an entire floor.")
                }

                Section {
                    Button {
                        start()
                    } label: {
                        Label("Start Mapping", systemImage: "camera.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!isValid)
                }
            }
            .navigationTitle("New Zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .fullScreenCover(item: $startedZone) { zone in
                MappingView(zone: zone) {
                    startedZone = nil
                    dismiss()
                }
                .environment(repository)
            }
        }
    }

    private func start() {
        let zone = MappingZone(
            campus: campus.trimmingCharacters(in: .whitespaces),
            building: building.trimmingCharacters(in: .whitespaces),
            floor: floor.trimmingCharacters(in: .whitespaces),
            zoneName: zoneName.trimmingCharacters(in: .whitespaces)
        )
        startedZone = zone
    }
}
