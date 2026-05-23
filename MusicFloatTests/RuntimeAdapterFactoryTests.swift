import XCTest
@testable import MusicFloat

final class RuntimeAdapterFactoryTests: XCTestCase {
    @MainActor
    func testArchitectureDefaultFactoryUsesMockAdapters() {
        let adapters = RuntimeAdapterFactory.makeAdapters(for: .architectureDefault)

        XCTAssertEqual(adapters.musicBridge.displayName, "Mock Music bridge")
        XCTAssertEqual(adapters.lyricsProvider.displayName, "Mock lyrics provider")
        XCTAssertEqual(adapters.translationProvider.displayName, "Mock translation provider")
    }
}
