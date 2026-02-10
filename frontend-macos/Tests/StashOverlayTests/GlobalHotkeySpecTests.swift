import Carbon
import XCTest
@testable import StashOverlay

final class GlobalHotkeySpecTests: XCTestCase {
    func testDefaultHotkeySpecs() {
        let specs = GlobalHotkeySpec.default

        XCTAssertEqual(specs.count, 2)

        let latest = specs.first(where: { $0.action == .latestQuickChat })
        XCTAssertNotNil(latest)
        XCTAssertEqual(latest?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(latest?.modifiers, UInt32(controlKey))

        let picker = specs.first(where: { $0.action == .pickerQuickChat })
        XCTAssertNotNil(picker)
        XCTAssertEqual(picker?.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(picker?.modifiers, UInt32(controlKey | shiftKey))
    }

    func testActionLookupByEventID() {
        XCTAssertEqual(GlobalHotkeySpec.action(for: GlobalHotkeyAction.latestQuickChat.rawValue), .latestQuickChat)
        XCTAssertEqual(GlobalHotkeySpec.action(for: GlobalHotkeyAction.pickerQuickChat.rawValue), .pickerQuickChat)
        XCTAssertNil(GlobalHotkeySpec.action(for: 99))
    }
}
