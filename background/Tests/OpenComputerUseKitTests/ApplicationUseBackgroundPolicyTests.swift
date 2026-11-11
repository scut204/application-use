import AppKit
import XCTest
@testable import OpenComputerUseKit

final class ApplicationUseBackgroundPolicyTests: XCTestCase {
    func testEnvironmentCannotEnableGlobalPointerDelivery() throws {
        for value in ["1", "true", "yes", "on", "0", ""] {
            let environment = ["OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS": value]
            XCTAssertFalse(globalPointerFallbacksEnabled(environment: environment))
            XCTAssertEqual(dragDeliveryPath(environment: environment), .appPost)
            XCTAssertThrowsError(try validateClickMethod(.global, hasElementIndex: true, environment: environment))
        }
    }

    func testGlobalClickRejectsBeforeApplicationLookup() {
        XCTAssertThrowsError(try ComputerUseService().click(
            app: "NoSuchApplicationUsePolicyTestApp", elementIndex: nil,
            x: 1, y: 1, clickCount: 1, mouseButton: "left", clickMethod: .global
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("global pointer"))
        }
    }

    func testLowLevelGlobalEventEntrypointsFailClosed() {
        XCTAssertThrowsError(try InputSimulation.clickGlobally(at: .zero, button: .left, clickCount: 1))
        XCTAssertThrowsError(try InputSimulation.scrollGlobally(at: .zero, direction: "down", pages: 1))
        XCTAssertThrowsError(try InputSimulation.dragGlobally(from: .zero, to: CGPoint(x: 10, y: 10)))
    }

    func testAllActionReadbacksRemainReadOnly() {
        for method in ClickMethod.allCases {
            XCTAssertEqual(clickActionSnapshotRecoveryPolicy(for: method), .readOnly)
        }
        for method in KeyMethod.allCases {
            XCTAssertEqual(keyActionSnapshotRecoveryPolicy(for: method), .readOnly)
        }
    }

    func testDefaultAndLegacyAutoKeyboardSelectTargetedSkyKey() throws {
        XCTAssertEqual(try parseKeyMethod(nil), .skyKey)
        XCTAssertEqual(try parseKeyMethod(" auto "), .skyKey)
        XCTAssertEqual(try parseKeyMethod(" SKY_KEY "), .skyKey)
        XCTAssertThrowsError(try parseKeyMethod("global"))
    }

    func testWindowPlacementRejectsBeforeApplicationLookup() throws {
        XCTAssertNoThrow(try validateApplicationUseWindowPlacement(.keep))
        for placement in [WindowPlacement.agentDisplay, .restore] {
            XCTAssertThrowsError(try ComputerUseService().getAppState(
                app: "NoSuchApplicationUsePolicyTestApp", windowPlacement: placement
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("keeps windows in place"))
            }
        }
    }

    func testSecondaryActionsCannotRaiseOrFocusWindows() throws {
        for action in ["AXRaise", "AXFocus", "AXShowMenu", "AXOpen", "CustomAction"] {
            XCTAssertThrowsError(try validateApplicationUseSecondaryAction(action))
        }
        for action in ["AXPress", "AXConfirm", "AXIncrement", "AXDecrement", "AXPick", "AXScrollDownByPage"] {
            XCTAssertNoThrow(try validateApplicationUseSecondaryAction(action))
        }
    }

    func testPixelScrollingPreservesMagnitudeAndAxis() throws {
        let up = try applicationUsePixelScrollDelta(direction: "up", pixels: 37)
        let down = try applicationUsePixelScrollDelta(direction: "down", pixels: 37)
        let left = try applicationUsePixelScrollDelta(direction: "left", pixels: 37)
        let right = try applicationUsePixelScrollDelta(direction: "right", pixels: 37)
        XCTAssertEqual([up.vertical, up.horizontal], [37, 0])
        XCTAssertEqual([down.vertical, down.horizontal], [-37, 0])
        XCTAssertEqual([left.vertical, left.horizontal], [0, 37])
        XCTAssertEqual([right.vertical, right.horizontal], [0, -37])
        XCTAssertEqual(try applicationUsePixelScrollDelta(direction: "up", pixels: Double(Int32.max)).vertical, Int32.max)
    }

    func testPixelScrollEventCarriesExactWindowRoutingWithoutPosting() throws {
        let spi = SkyLightSPI.shared
        guard spi.capability.isAvailable else { throw XCTSkip("SkyLight SPI unavailable") }
        let target = SkyClickTarget(screenPoint: CGPoint(x: 140, y: 260), windowPoint: CGPoint(x: 40, y: 60),
                                    windowBounds: CGRect(x: 100, y: 200, width: 800, height: 600), windowID: 1234, pid: 4321)
        let down = try SkyClickDispatcher.pixelScrollEvent(target: target, direction: "down", pixels: 451, spi: spi)
        XCTAssertEqual(down.type, .scrollWheel)
        XCTAssertEqual(down.location, target.screenPoint)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventIsContinuous), 1)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), -451)
        XCTAssertEqual(down.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 0)
        XCTAssertEqual(down.getIntegerValueField(CGEventField(rawValue: 40)!), 4321)
        // Mouse-only fields 91/92 do not read back on macOS 15 wheel events;
        // field 51 is the wheel event's retained window routing identity.
        XCTAssertEqual(down.getIntegerValueField(CGEventField(rawValue: 51)!), 1234)
        let left = try SkyClickDispatcher.pixelScrollEvent(target: target, direction: "left", pixels: 37, spi: spi)
        XCTAssertEqual(left.getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 0)
        XCTAssertEqual(left.getIntegerValueField(.scrollWheelEventPointDeltaAxis2), 37)
        let pages = try SkyClickDispatcher.scrollEvent(target: target, units: .line, vertical: -12, horizontal: 0, spi: spi)
        XCTAssertEqual(pages.getIntegerValueField(.scrollWheelEventIsContinuous), 0)
        XCTAssertEqual(pages.getIntegerValueField(.scrollWheelEventDeltaAxis1), -12)
        XCTAssertEqual(pages.getIntegerValueField(CGEventField(rawValue: 51)!), 1234)
    }

    func testAccessibilityScrollFailureIsNeverReportedAsSuccess() {
        XCTAssertNoThrow(try applicationUseRequireScrollActionSuccess(.success))
        for result in [AXError.cannotComplete, .actionUnsupported, .invalidUIElement, .apiDisabled, .failure] {
            XCTAssertThrowsError(try applicationUseRequireScrollActionSuccess(result))
        }
    }

    func testPixelScrollingRejectsInvalidValuesBeforeLookingUpApp() {
        for pixels in [0, -1, 0.5, Double.nan, Double.infinity, Double(Int32.max) + 1] {
            XCTAssertThrowsError(try ComputerUseService().applicationUseScrollPixels(
                app: "NoSuchApplicationUsePolicyTestApp", elementIndex: "1", direction: "down", pixels: pixels
            )) { error in
                XCTAssertTrue(error.localizedDescription.contains("pixels"))
            }
        }
        XCTAssertThrowsError(try applicationUsePixelScrollDelta(direction: "diagonal", pixels: 1))
    }

    func testCloseNeverTerminatesApplications() {
        XCTAssertThrowsError(try ComputerUseService().applicationUseClose(app: "NoSuchApplicationUsePolicyTestApp")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Closing applications is unavailable"))
        }
    }

    func testRunningResolutionDoesNotLaunchMissingApplication() {
        XCTAssertThrowsError(try AppDiscovery.resolveRunning("NoSuchApplicationUsePolicyTestApp", applications: []))
    }

    func testTextFocusRequiresEditableControlAndExactWindowAndExpectedElement() throws {
        func check(role: String? = "AXTextField", enabled: Bool? = true, editable: Bool? = nil,
                   valueSettable: Bool = true, selectedTextSettable: Bool = false,
                   pid: pid_t? = 42, windowID: CGWindowID? = 7, matchesExpected: Bool = true) throws {
            try validateApplicationUseTextFocus(role: role, enabled: enabled, editable: editable,
                                               valueSettable: valueSettable, selectedTextSettable: selectedTextSettable,
                                               focusedPID: pid, targetPID: 42, focusedWindowID: windowID, targetWindowID: 7,
                                               matchesExpectedElement: matchesExpected)
        }
        XCTAssertNoThrow(try check())
        XCTAssertNoThrow(try check(role: "AXTextArea", valueSettable: false, selectedTextSettable: true))
        XCTAssertNoThrow(try check(role: "AXComboBox", editable: true, valueSettable: true))
        XCTAssertNoThrow(try check(role: "AXTextArea", enabled: nil, editable: nil, valueSettable: true, selectedTextSettable: true))
        for role in [nil, "AXButton", "AXWebArea", "AXGroup", "AXSlider"] as [String?] {
            XCTAssertThrowsError(try check(role: role))
        }
        XCTAssertThrowsError(try check(enabled: false))
        XCTAssertThrowsError(try check(editable: false))
        XCTAssertThrowsError(try check(valueSettable: false))
        XCTAssertThrowsError(try check(enabled: nil, valueSettable: false))
        XCTAssertThrowsError(try check(editable: true, valueSettable: false))
        XCTAssertThrowsError(try check(pid: 43))
        XCTAssertThrowsError(try check(pid: nil))
        XCTAssertThrowsError(try check(windowID: 8))
        XCTAssertThrowsError(try check(windowID: nil))
        XCTAssertThrowsError(try check(matchesExpected: false))
    }

    func testTerminalShellKeyboardInputPreservesFocusAndReadOnlyGuards() throws {
        func check(bundle: String? = "com.apple.Terminal", role: String? = "AXTextArea",
                   description: String? = "shell", enabled: Bool? = nil, editable: Bool? = nil,
                   pid: pid_t? = 42, windowID: CGWindowID? = 7, matchesExpected: Bool = true) throws {
            try validateApplicationUseTextFocus(
                role: role, enabled: enabled, editable: editable,
                valueSettable: false, selectedTextSettable: false,
                focusedPID: pid, targetPID: 42, focusedWindowID: windowID, targetWindowID: 7,
                matchesExpectedElement: matchesExpected,
                appBundleIdentifier: bundle, elementDescription: description
            )
        }
        XCTAssertNoThrow(try check())
        XCTAssertNoThrow(try check(enabled: true, editable: true))
        for bundle in [nil, "com.apple.TextEdit", "com.googlecode.iterm2"] as [String?] {
            XCTAssertThrowsError(try check(bundle: bundle))
        }
        for role in [nil, "AXTextField", "AXStaticText", "AXButton", "AXWebArea"] as [String?] {
            XCTAssertThrowsError(try check(role: role))
        }
        XCTAssertThrowsError(try check(description: nil))
        XCTAssertThrowsError(try check(description: "Preferences"))
        XCTAssertThrowsError(try check(enabled: false))
        XCTAssertThrowsError(try check(editable: false))
        XCTAssertThrowsError(try check(pid: 43))
        XCTAssertThrowsError(try check(pid: nil))
        XCTAssertThrowsError(try check(windowID: 8))
        XCTAssertThrowsError(try check(windowID: nil))
        XCTAssertThrowsError(try check(matchesExpected: false))
    }

    func testOptionalTextFlagsDistinguishUnsupportedFromFailedReads() throws {
        XCTAssertNil(try applicationUseOptionalBooleanValue(result: .attributeUnsupported, value: nil, attribute: "AXEnabled"))
        XCTAssertNil(try applicationUseOptionalBooleanValue(result: .noValue, value: nil, attribute: "AXEditable"))
        XCTAssertEqual(try applicationUseOptionalBooleanValue(result: .success, value: kCFBooleanTrue, attribute: "AXEnabled"), true)
        XCTAssertEqual(try applicationUseOptionalBooleanValue(result: .success, value: kCFBooleanFalse, attribute: "AXEnabled"), false)
        for result in [AXError.cannotComplete, .invalidUIElement, .apiDisabled, .failure] {
            XCTAssertThrowsError(try applicationUseOptionalBooleanValue(result: result, value: nil, attribute: "AXEnabled"))
        }
        XCTAssertThrowsError(try applicationUseOptionalBooleanValue(result: .success, value: nil, attribute: "AXEnabled"))
        XCTAssertThrowsError(try applicationUseOptionalBooleanValue(result: .success, value: "true" as CFString, attribute: "AXEnabled"))
    }

    func testTextFocusFailurePreventsLowLevelKeyboardEventCreation() {
        var validations = 0
        XCTAssertThrowsError(try InputSimulation.typeText("must not be sent", pid: -1, validateBeforeChunk: {
            validations += 1
            throw ComputerUseError.stateUnavailable("focus changed")
        })) { error in
            XCTAssertEqual(error.localizedDescription, "focus changed")
        }
        XCTAssertEqual(validations, 1)
    }

    func testExpectedTextElementArgumentRejectsInvalidValuesBeforeAppLookup() {
        let dispatcher = ComputerUseToolDispatcher()
        for value in [true, -1, 1.5, "", "not-an-index", NSNull()] as [Any] {
            XCTAssertThrowsError(try dispatcher.callTool(name: "type_text", arguments: [
                "app": "NoSuchApplicationUsePolicyTestApp", "text": "never", "expected_element_index": value
            ])) { error in
                XCTAssertTrue(error.localizedDescription.contains("expected_element_index"))
            }
        }
        let schema = ToolDefinitions.all.first { $0.name == "type_text" }?.inputSchema["properties"] as? [String: Any]
        XCTAssertNotNil(schema?["expected_element_index"])
    }

    func testWindowCaptureNeverSubstitutesAnotherWindowOfSameApplication() {
        func info(id: Int, pid: Int, title: String) -> [String: Any] {
            [kCGWindowNumber as String: id, kCGWindowOwnerPID as String: pid,
             kCGWindowLayer as String: 0, kCGWindowName as String: title,
             kCGWindowBounds as String: CGRect(x: 20, y: 30, width: 800, height: 600).dictionaryRepresentation]
        }
        let windows = [info(id: 10, pid: 42, title: "Duplicate title"), info(id: 11, pid: 42, title: "Duplicate title")]
        XCTAssertEqual(applicationUseExactWindowCaptureCandidate(windowInfo: windows, windowID: 11, pid: 42)?.windowID, 11)
        XCTAssertNil(applicationUseExactWindowCaptureCandidate(windowInfo: windows, windowID: 12, pid: 42))
        XCTAssertNil(applicationUseExactWindowCaptureCandidate(windowInfo: windows, windowID: nil, pid: 42))
        XCTAssertNil(applicationUseExactWindowCaptureCandidate(windowInfo: windows, windowID: 11, pid: 43))
    }

    func testActionRequiresTheObservedAXWindowIdentityToRemainCurrent() {
        XCTAssertNoThrow(try validateApplicationUseWindowIdentity(observedWindowID: 11, currentAXWindowID: 11))
        XCTAssertThrowsError(try validateApplicationUseWindowIdentity(observedWindowID: 11, currentAXWindowID: 12))
        XCTAssertThrowsError(try validateApplicationUseWindowIdentity(observedWindowID: 11, currentAXWindowID: nil))
        XCTAssertThrowsError(try validateApplicationUseWindowIdentity(observedWindowID: 0, currentAXWindowID: 0))
    }

    func testInputRejectsWindowMovementAndResizeAfterSnapshot() {
        let observed = CGRect(x: 100, y: 200, width: 800, height: 600)
        XCTAssertNoThrow(try validateApplicationUseWindowBounds(observed: observed, current: observed))
        XCTAssertNoThrow(try validateApplicationUseWindowBounds(observed: observed, current: observed.offsetBy(dx: 0.001, dy: -0.001)))
        for changed in [observed.offsetBy(dx: 1, dy: 0), observed.offsetBy(dx: 0, dy: -1),
                        CGRect(x: 100, y: 200, width: 801, height: 600), CGRect(x: 100, y: 200, width: 800, height: 599),
                        .null, .infinite, .zero] {
            XCTAssertThrowsError(try validateApplicationUseWindowBounds(observed: observed, current: changed))
        }
        XCTAssertThrowsError(try validateApplicationUseWindowBounds(observed: observed, current: nil))
        XCTAssertThrowsError(try validateApplicationUseWindowBounds(observed: nil, current: observed))
    }

    func testWindowAndGlobalShortcutsRejectAllCommandAliasesAndExtraModifiers() throws {
        for alias in ["cmd", "command", "super", "meta"] {
            for suffix in ["q", "w", "m", "h", "tab", "space", "spacebar"] {
                for prefix in [alias, "shift+\(alias)", "alt+\(alias)", "ctrl+shift+\(alias)"] {
                    XCTAssertThrowsError(try validateApplicationUseKey(KeyPressParser.parse("\(prefix)+\(suffix)")))
                }
            }
        }
        for shortcut in ["ctrl+cmd+f", "control+shift+command+f", "cmd+option+esc", "meta+alt+escape",
                         "ctrl+left", "control+shift+right", "ctrl+alt+up", "ctrl+down", "ctrl+kp_left"] {
            XCTAssertThrowsError(try validateApplicationUseKey(KeyPressParser.parse(shortcut)), shortcut)
        }
        for shortcut in ["cmd+a", "cmd+c", "cmd+v", "cmd+f", "shift+left", "option+right", "return", "tab"] {
            XCTAssertNoThrow(try validateApplicationUseKey(KeyPressParser.parse(shortcut)), shortcut)
        }
        XCTAssertThrowsError(try ComputerUseService().pressKey(app: "NoSuchApplicationUsePolicyTestApp", key: "cmd+q")) { error in
            XCTAssertTrue(error.localizedDescription.contains("shortcut"))
        }
    }

    func testWindowChromeRoleAndCoordinateChecksRejectControls() {
        for name in ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"] {
            XCTAssertTrue(applicationUseIsWindowControl(role: "AXButton", subrole: name))
            XCTAssertTrue(applicationUseIsWindowControl(role: name, subrole: nil))
        }
        XCTAssertFalse(applicationUseIsWindowControl(role: "AXButton", subrole: nil))
        let frames = [CGRect(x: 10, y: 10, width: 14, height: 14), CGRect(x: 30, y: 10, width: 14, height: 14)]
        XCTAssertTrue(applicationUsePointTouchesWindowControl(CGPoint(x: 15, y: 15), frames: frames))
        XCTAssertTrue(applicationUsePointTouchesWindowControl(CGPoint(x: 9.5, y: 15), frames: frames))
        XCTAssertFalse(applicationUsePointTouchesWindowControl(CGPoint(x: 200, y: 200), frames: frames))
    }
}
