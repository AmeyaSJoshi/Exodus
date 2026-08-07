import Foundation

/// One place that owns launch sequencing, so Home, Saved Maps and Emergency do
/// not each independently rescan disk and re-fetch the catalogue.
///
/// Before this, every screen ran its own `.task { repository.refresh(); session
/// .refresh() }`, and `onChange(of: isSignedIn)` added another. Opening Saved
/// Maps from Home could fire three overlapping catalogue requests and three
/// full directory scans, all racing on the main actor.
@Observable
@MainActor
final class StartupCoordinator {

    /// What the UI may honestly say it is doing. The shell is interactive in
    /// every one of these states — none of them gate the interface.
    enum Phase: Equatable {
        case idle
        case scanningLocalMaps
        case restoringSession
        case syncingBuildings
        case ready
        case offlineUsingCache
        case failed(String)

        var label: String? {
            switch self {
            case .idle, .ready: return nil
            case .scanningLocalMaps: return "Loading saved maps…"
            case .restoringSession: return "Restoring session…"
            case .syncingBuildings: return "Syncing buildings…"
            case .offlineUsingCache: return "Offline — using saved data"
            case .failed(let reason): return "Sync failed — \(reason)"
            }
        }

        var canRetry: Bool {
            if case .failed = self { return true }
            if case .offlineUsingCache = self { return true }
            return false
        }

        /// Nothing here ever blocks the UI. Kept explicit so a future change
        /// cannot quietly reintroduce a blocking phase.
        var blocksInteraction: Bool { false }
    }

    private(set) var phase: Phase = .idle
    /// True once local maps are on screen — the point at which the app is
    /// genuinely useful, independent of any network.
    private(set) var localReady = false

    /// A remote refresh is slow or unavailable often enough that it must never
    /// be able to hang the UI indefinitely.
    static let remoteTimeout: Duration = .seconds(10)

    private var localTask: Task<Void, Never>?
    private var remoteTask: Task<Void, Never>?
    private var lastRemoteRefresh: Date?
    /// Repeated view appearances inside this window reuse the last result
    /// rather than re-fetching.
    static let refreshCoalescingWindow: TimeInterval = 5

    // MARK: - Launch

    /// Stage 1 and 2: local metadata first, then remote in the background.
    /// Safe to call from every screen's `.task`; duplicate calls coalesce.
    func start(repository: ZoneRepository, session: BackendSession) {
        loadLocal(repository: repository, session: session)
        refreshRemote(session: session, force: false)
    }

    /// Scans saved-map metadata only. No world maps, no reference images, no
    /// checksums — those are for the screens that actually need them.
    func loadLocal(repository: ZoneRepository, session: BackendSession) {
        guard localTask == nil else { return }
        if phase == .idle { phase = .scanningLocalMaps }
        localTask = Task { [weak self] in
            await Startup.stage("local-maps") {
                await repository.refresh()
            }
            await Startup.stage("package-index") {
                session.refreshCachedVersions()
            }
            guard let self else { return }
            self.localReady = true
            if self.phase == .scanningLocalMaps { self.phase = .ready }
            Startup.log("local maps ready (\(repository.zones.count) zones)")
        }
    }

    /// Stage 5: remote metadata, in the background, never blocking the shell.
    func refreshRemote(session: BackendSession, force: Bool) {
        guard session.isSignedIn else {
            if phase == .scanningLocalMaps || phase == .idle { phase = .ready }
            return
        }
        if !force, let last = lastRemoteRefresh,
           Date().timeIntervalSince(last) < Self.refreshCoalescingWindow {
            return
        }
        // A newer request supersedes one already in flight.
        remoteTask?.cancel()
        lastRemoteRefresh = Date()
        phase = .syncingBuildings

        remoteTask = Task { [weak self] in
            let outcome: Phase = await Startup.stage("catalogue") {
                do {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask { await session.refresh() }
                        group.addTask {
                            try await Task.sleep(for: Self.remoteTimeout)
                            throw StartupError.timedOut
                        }
                        try await group.next()
                        group.cancelAll()
                    }
                    if let error = session.error { return .failed(error) }
                    return .ready
                } catch is CancellationError {
                    return .ready
                } catch {
                    // Cached buildings and local maps still work.
                    return .offlineUsingCache
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.phase = outcome
            Startup.log("catalogue refresh finished: \(outcome)")
        }
    }

    /// Sign-in changes the catalogue, so this one is allowed to bypass the
    /// coalescing window — but it still replaces any in-flight request rather
    /// than adding to it.
    func authenticationChanged(session: BackendSession) {
        refreshRemote(session: session, force: true)
    }

    func retry(session: BackendSession) {
        refreshRemote(session: session, force: true)
    }

    /// Test seam.
    func reset() {
        localTask?.cancel(); localTask = nil
        remoteTask?.cancel(); remoteTask = nil
        lastRemoteRefresh = nil
        localReady = false
        phase = .idle
    }
}

enum StartupError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        "The backend did not respond in time. Saved maps still work."
    }
}
