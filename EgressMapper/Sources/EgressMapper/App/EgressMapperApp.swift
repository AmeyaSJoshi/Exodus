import SwiftUI

@main
struct EgressMapperApp: App {
    @State private var repository = ZoneRepository()
    @State private var session = BackendSession()
    @State private var startup = StartupCoordinator()
    @State private var capabilities = DeviceCapabilities()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(repository)
                .environment(session)
                .environment(startup)
                .environment(capabilities)
                .preferredColorScheme(.dark)
                .task {
                    // Nothing here blocks the first frame: the shell is already
                    // on screen by the time this runs.
                    Startup.log("root view appeared")
                    capabilities.resolve()
                    startup.start(repository: repository, session: session)
                }
        }
    }
}
