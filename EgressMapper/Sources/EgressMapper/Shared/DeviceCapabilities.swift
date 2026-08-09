import Foundation
import ARKit
import os

/// Whether this device can run ARKit world tracking.
///
/// `ARWorldTrackingConfiguration.isSupported` is not a cheap constant on a real
/// iPhone: the first call pulls in ARKit and probes the sensors, which costs
/// hundreds of milliseconds. It used to be read inside `HomeView.body`, so that
/// work ran on the main actor before the first frame could be drawn — and again
/// on every re-render. The Simulator answers instantly, which is why it only
/// ever showed up on device.
///
/// The answer is resolved once, off the main thread, and assumed supported
/// until known. Assuming supported is the safe default: it means the launch
/// screen never flashes an "unsupported" banner at a device that is fine, and
/// every real AR entry point checks `ARSessionManager.isSupported` itself
/// before touching a session.
@Observable
@MainActor
final class DeviceCapabilities {

    private(set) var arWorldTrackingSupported = true
    private(set) var resolved = false

    /// Injected in tests; the real probe is the ARKit call. Deliberately not
    /// main-actor isolated — the whole point is to run it off the main thread.
    nonisolated(unsafe) static var probe: @Sendable () -> Bool = {
        ARWorldTrackingConfiguration.isSupported
    }

    private var probeTask: Task<Void, Never>?

    /// Safe to call from several views: the probe runs at most once.
    func resolve() {
        guard probeTask == nil else { return }
        probeTask = Task.detached(priority: .utility) { [weak self] in
            let supported = Self.probe()
            await MainActor.run {
                guard let self else { return }
                self.arWorldTrackingSupported = supported
                self.resolved = true
                Startup.log("AR world tracking supported: \(supported)")
            }
        }
    }
}

/// Signposted launch milestones. Read with Console/Instruments; the ring buffer
/// copy also lands in the in-app diagnostics log so a device launch can be
/// inspected without a Mac attached.
enum Startup {
    static let signposter = OSSignposter(
        subsystem: "com.egress.mapper", category: "startup"
    )

    nonisolated(unsafe) static let processStart = Date()

    static func log(_ message: String) {
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        DiagnosticsLog.shared.log("[+\(ms)ms] \(message)")
    }

    /// Measures an awaited stage and records how long it took.
    static func stage<T>(_ name: StaticString, _ body: () async throws -> T) async rethrows -> T {
        let state = signposter.beginInterval(name)
        let started = Date()
        defer {
            signposter.endInterval(name, state)
            log("\(name) took \(Int(Date().timeIntervalSince(started) * 1000))ms")
        }
        return try await body()
    }
}
