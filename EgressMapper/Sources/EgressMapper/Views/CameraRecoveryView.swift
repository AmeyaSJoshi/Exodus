import SwiftUI

/// Shown over the AR view when the camera feed is not healthy.
///
/// The point is that the user never stares at a black rectangle wondering
/// whether the app is broken. Nothing here resets tracking: the map recorded so
/// far is still in memory, and throwing it away to "fix" the preview would cost
/// the user their whole walk.
struct CameraRecoveryView: View {
    let state: CameraFeedState
    let waypointCount: Int
    var onResume: () -> Void
    var onClose: () -> Void

    private var title: String {
        switch state {
        case .interrupted: return "Camera Interrupted"
        case .recovering: return "Reconnecting the Camera"
        case .stalled: return "Camera Feed Stopped"
        case .failed: return "Camera Session Failed"
        case .idle, .active: return ""
        }
    }

    private var explanation: String {
        switch state {
        case .interrupted:
            return "Something else took the camera — a call, another app, or the phone locking. Your mapping session is still open."
        case .recovering:
            return "Reconnecting to the same session. Point the camera at part of the area you have already walked."
        case .stalled(let seconds):
            return "No camera frames have arrived for \(seconds) seconds. The recorded map is still held in memory."
        case .failed(let reason):
            return reason
        case .idle, .active:
            return ""
        }
    }

    private var tint: Color {
        switch state {
        case .failed: return .red
        case .stalled, .interrupted: return .orange
        case .recovering: return .blue
        case .idle, .active: return .green
        }
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: state == .recovering ? "arrow.triangle.2.circlepath.camera" : "video.slash.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(tint)

                Text(title).font(.title3.weight(.semibold))
                Text(explanation)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)

                Label(
                    "\(waypointCount) waypoint\(waypointCount == 1 ? "" : "s") recorded so far are safe.",
                    systemImage: "checkmark.shield.fill"
                )
                .font(.caption)
                .foregroundStyle(.green)

                VStack(spacing: 10) {
                    Button {
                        onResume()
                    } label: {
                        Label("Resume Camera", systemImage: "play.circle.fill")
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)

                    Button("Close Without Saving", role: .destructive, action: onClose)
                        .buttonStyle(.bordered)
                }
                .padding(.top, 4)

                Text("Resuming keeps the map you have already recorded. It does not restart it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(26)
        }
    }
}

/// Compact camera/AR health strip for physical-device debugging.
/// Hidden unless developer mode is on, so it never appears to an occupant.
struct CameraDebugIndicator: View {
    let manager: ARSessionManager

    @AppStorage(DeveloperSettings.debugIndicatorKey) private var enabled = false

    private var tint: Color {
        switch manager.cameraFeed {
        case .active: return .green
        case .recovering: return .blue
        case .stalled, .interrupted: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    var body: some View {
        if enabled {
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 7, height: 7)
                Text(manager.cameraFeed.label)
                Text("·").foregroundStyle(.secondary)
                Text(manager.status.trackingText)
                Spacer()
                Text("\(manager.frameCount)f")
                    .foregroundStyle(.secondary)
                Text(manager.shortID)
                    .foregroundStyle(.secondary)
            }
            .font(.caption2.monospaced())
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

enum DeveloperSettings {
    /// Off by default. Toggled in Configure → Developer Tools.
    static let debugIndicatorKey = "egress.debug.cameraIndicator"
}
