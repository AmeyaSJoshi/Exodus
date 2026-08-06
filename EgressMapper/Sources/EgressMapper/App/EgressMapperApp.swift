import SwiftUI

@main
struct EgressMapperApp: App {
    @State private var repository = ZoneRepository()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(repository)
                .preferredColorScheme(.dark)
        }
    }
}
