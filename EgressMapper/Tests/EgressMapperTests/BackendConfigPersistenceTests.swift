import XCTest
@testable import EgressMapper

/// A saved backend address is the only way back to a working server, so a
/// failed sign-in must not be able to overwrite one that worked.
@MainActor
final class BackendConfigPersistenceTests: XCTestCase {
    private let known = BackendConfig(url: "http://10.0.0.5:54321", anonKey: "known-good-key")

    override func setUp() {
        super.setUp()
        known.save()
    }

    override func tearDown() {
        let d = UserDefaults.standard
        d.removeObject(forKey: BackendConfig.defaultsURLKey)
        d.removeObject(forKey: BackendConfig.defaultsKeyKey)
        super.tearDown()
    }

    func testFailedSignInLeavesThePreviouslySavedConfigUntouched() async {
        let session = BackendSession()
        // Unroutable: the sign-in cannot succeed, so nothing should be kept.
        session.config = BackendConfig(url: "http://10.255.255.1:54321", anonKey: "typo-key")
        session.email = "admin@egress.test"
        session.password = "whatever"

        await session.signIn()

        XCTAssertNotNil(session.error, "A failed sign-in must report why")
        XCTAssertEqual(BackendConfig.load().url, known.url)
        XCTAssertEqual(BackendConfig.load().anonKey, known.anonKey)
    }

    func testSavingPersistsForTheNextLaunch() {
        let next = BackendConfig(url: "http://10.0.0.9:54321", anonKey: "next-key")
        next.save()
        XCTAssertEqual(BackendConfig.load().url, next.url)
        XCTAssertEqual(BackendConfig.load().anonKey, next.anonKey)
    }

    /// Guards the ordering the fix depends on: applying a config to the client
    /// is not the same act as trusting it enough to keep.
    func testConfiguringTheClientDoesNotPersist() throws {
        let service = SupabaseBuildingService()
        try service.configure(BackendConfig(url: "http://10.255.255.1:54321", anonKey: "unsaved"))
        XCTAssertEqual(BackendConfig.load().url, known.url)
    }
}
