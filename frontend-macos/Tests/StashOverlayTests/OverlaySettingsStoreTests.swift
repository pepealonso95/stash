import Foundation
import XCTest
@testable import StashOverlay

final class OverlaySettingsStoreTests: XCTestCase {
    func testOverlayModeDefaultsToHidden() {
        let defaults = makeDefaults()
        defaults.removeObject(forKey: OverlaySettingsStore.overlayModeKey)

        let store = OverlaySettingsStore(defaults: defaults)
        XCTAssertEqual(store.overlayMode(), .hidden)
    }

    func testOverlayModeFallsBackToHiddenWhenInvalid() {
        let defaults = makeDefaults()
        defaults.set("unexpected-value", forKey: OverlaySettingsStore.overlayModeKey)

        let store = OverlaySettingsStore(defaults: defaults)
        XCTAssertEqual(store.overlayMode(), .hidden)
    }

    func testOverlayModeRoundTrip() {
        let defaults = makeDefaults()

        let store = OverlaySettingsStore(defaults: defaults)
        store.setOverlayMode(.disabled)
        XCTAssertEqual(store.overlayMode(), .disabled)

        store.setOverlayMode(.visible)
        XCTAssertEqual(store.overlayMode(), .visible)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "com.stash.overlay.settings.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Could not create test UserDefaults suite")
        }
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }
}
