import CoreGraphics
import XCTest
@testable import OpenComputerUseKit

final class ApplicationUseCursorPolicyTests: XCTestCase {
    func testMissingTargetNeverRequestsGlobalOrdering() {
        for visible in [true, false] {
            for forced in [true, false] {
                XCTAssertFalse(shouldReorderCursorPanel(activeTargetWindow: .init(windowID: 42, layer: 0),
                                                        effectiveTargetWindow: nil, panelIsVisible: visible, forceReorder: forced))
            }
        }
    }

    func testCursorRequiresExactVisibleWindowAndLayer() {
        let target = CursorTargetWindow(windowID: 42, layer: 0)
        let visible: [String: Any] = [kCGWindowNumber as String: 42, kCGWindowLayer as String: 0, kCGWindowIsOnscreen as String: true]
        XCTAssertTrue(cursorTargetWindowIsVisible(target, windowInfo: [visible]))
        XCTAssertFalse(cursorTargetWindowIsVisible(target, windowInfo: []))
        for (key, value) in [(kCGWindowNumber as String, 43 as Any), (kCGWindowLayer as String, 8 as Any),
                             (kCGWindowIsOnscreen as String, false as Any)] {
            var changed = visible
            changed[key] = value
            XCTAssertFalse(cursorTargetWindowIsVisible(target, windowInfo: [changed]))
        }
        var missingVisibility = visible
        missingVisibility.removeValue(forKey: kCGWindowIsOnscreen as String)
        XCTAssertFalse(cursorTargetWindowIsVisible(target, windowInfo: [missingVisibility]))
        XCTAssertFalse(cursorTargetWindowIsVisible(.init(windowID: 0, layer: 0), windowInfo: [visible]))
    }
}
