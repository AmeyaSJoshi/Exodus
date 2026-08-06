import SwiftUI

/// Live control over where AR geometry is drawn vertically. Exposed because
/// without LiDAR the floor estimate can be wrong, and a floating arrow is
/// useless — the user needs to be able to fix it on the spot.
struct HeightControlView: View {
    @Bindable var manager: ARSessionManager
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Label("Marker Height", systemImage: "arrow.up.and.down.square")
                    Spacer()
                    Text(manager.heightMode.title)
                        .foregroundStyle(.secondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .font(.caption)
            }

            if expanded {
                Picker("Height", selection: $manager.heightMode) {
                    ForEach(MarkerHeightMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text(String(format: "%+.2f m", manager.heightOffset))
                        .font(.caption2.monospaced())
                        .frame(width: 62, alignment: .leading)
                    Slider(value: $manager.heightOffset, in: -2.0...2.0, step: 0.05)
                    Button {
                        manager.heightOffset = 0
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .font(.caption)
                }

                Text(
                    manager.estimatedFloorY == nil
                    ? "No floor plane detected yet — point the camera at the floor for a second. Using an assumed height until then."
                    : "Floor detected. Nudge the slider if markers still sit too high or low."
                )
                .font(.caption2)
                .foregroundStyle(manager.estimatedFloorY == nil ? .yellow : .secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Fast-access accessibility controls, reachable during active navigation.
struct AccessibilitySheet: View {
    @Binding var profile: NavigationProfile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        profile.avoidStairs = true
                        profile.requireWheelchairAccessible = true
                    } label: {
                        Label("I Need an Accessible Route", systemImage: "figure.roll")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(profile.avoidStairs && profile.requireWheelchairAccessible)
                }

                Section {
                    Toggle("Avoid stairs", isOn: $profile.avoidStairs)
                    Toggle("Wheelchair accessible only", isOn: $profile.requireWheelchairAccessible)
                    Toggle("Avoid elevators", isOn: $profile.avoidElevators)
                } footer: {
                    Text("Rerouting happens immediately. If no route satisfies these, you will be told — the preference is never silently dropped.")
                }
            }
            .navigationTitle("Accessibility")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
