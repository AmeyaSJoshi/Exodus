import SwiftUI

struct CreateZoneView: View {
    @Environment(ZoneRepository.self) private var repository
    @Environment(\.dismiss) private var dismiss

    @State private var campus = ""
    @State private var building = ""
    @State private var floor = ""
    @State private var zoneName = ""
    @State private var startedZone: MappingZone?
    @State private var firstEditLogged = false
    @FocusState private var focused: Field?

    private enum Field: Hashable { case campus, building, floor, zoneName }

    private var isValid: Bool {
        !building.trimmingCharacters(in: .whitespaces).isEmpty &&
        !zoneName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Location") {
                    TextField("Campus or property", text: $campus)
                        .focused($focused, equals: .campus)
                        .submitLabel(.next)
                    TextField("Building", text: $building)
                        .focused($focused, equals: .building)
                        .submitLabel(.next)
                    TextField("Floor", text: $floor)
                        .focused($focused, equals: .floor)
                        .submitLabel(.next)
                }
                Section {
                    TextField("Zone name (e.g. East Hallway)", text: $zoneName)
                        .focused($focused, equals: .zoneName)
                        .submitLabel(.done)
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
            .onAppear { Startup.firstUse("create-zone-form") }
            // The first required field takes focus on its own. Tapping a
            // TextField to raise the keyboard was landing inconsistently while
            // the sheet was still settling, which read as "it takes a few taps
            // before typing works".
            .task {
                try? await Task.sleep(for: .milliseconds(400))
                if focused == nil { focused = .building }
            }
            .onSubmit {
                switch focused {
                case .campus: focused = .building
                case .building: focused = .floor
                case .floor: focused = .zoneName
                default: focused = nil
                }
            }
            .scrollDismissesKeyboard(.interactively)
            // Names the cost of the first keystroke, which is where the
            // keyboard's own cold start lands. Logs once, then stays quiet.
            .onChange(of: zoneName) { _, _ in
                guard !firstEditLogged else { return }
                firstEditLogged = true
                Startup.firstUse("create-zone-first-keystroke")
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
