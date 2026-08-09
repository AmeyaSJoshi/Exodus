import SwiftUI

struct MappingControlsView: View {
    let canSave: Bool
    let saveBlockedReason: String?
    let isFinishing: Bool
    var onAdd: (WaypointType) -> Void
    var onUndo: () -> Void
    var onFinish: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if let saveBlockedReason, !canSave {
                Text(saveBlockedReason)
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(WaypointType.allCases) { type in
                        Button {
                            onAdd(type)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: type.symbolName)
                                    .font(.title3)
                                Text(type.title)
                                    .font(.caption2)
                            }
                            .frame(width: 74, height: 58)
                            .background(type.tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(type.tint)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    onUndo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)

                Button {
                    onFinish()
                } label: {
                    HStack {
                        if isFinishing {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down.fill")
                        }
                        Text(isFinishing ? "Saving…" : "Finish & Save")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(!canSave || isFinishing)
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.bottom, 6)
    }
}

struct AddWaypointSheet: View {
    let type: WaypointType
    let suggestedIndex: Int
    var onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit(add)
                } header: {
                    Label(type.title, systemImage: type.symbolName)
                        .foregroundStyle(type.tint)
                } footer: {
                    Text("The waypoint is anchored at your current physical position, so stand where you want it before saving.")
                }

                Button("Add Waypoint", action: add)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .navigationTitle("Add \(type.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onAppear {
                if name.isEmpty { name = "\(type.defaultNamePrefix) \(suggestedIndex)" }
                focused = true
            }
        }
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onAdd(trimmed)
        dismiss()
    }
}
