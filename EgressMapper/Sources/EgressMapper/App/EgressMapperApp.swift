import SwiftUI

@main
struct EgressMapperApp: App {
    @State private var repository = ZoneRepository()
    @State private var session = BackendSession()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(repository)
                .environment(session)
                .preferredColorScheme(.dark)
        }
    }
}
