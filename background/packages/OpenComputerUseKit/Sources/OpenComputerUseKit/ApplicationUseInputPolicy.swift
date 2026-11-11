import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

func applicationUseEditableTextRole(_ role: String?) -> Bool {
    guard let role else { return false }
    return ["AXTextField", "AXTextArea", "AXTextView", "AXComboBox"].contains(role)
}

func applicationUseRequireScrollActionSuccess(_ result: AXError) throws {
    guard result == .success else {
        throw ComputerUseError.message("The accessibility scroll action failed (AXError \(result.rawValue)); no fallback input was sent")
    }
}

func validateApplicationUseTextFocus(
    role: String?, enabled: Bool?, editable: Bool?, valueSettable: Bool, selectedTextSettable: Bool,
    focusedPID: pid_t?, targetPID: pid_t, focusedWindowID: CGWindowID?, targetWindowID: CGWindowID?,
    matchesExpectedElement: Bool, appBundleIdentifier: String? = nil, elementDescription: String? = nil
) throws {
    guard focusedPID == targetPID, let targetWindowID, targetWindowID != 0, focusedWindowID == targetWindowID else {
        throw ComputerUseError.stateUnavailable("type_text focus does not belong to the observed application window; take a fresh snapshot")
    }
    guard matchesExpectedElement else {
        throw ComputerUseError.stateUnavailable("type_text focus does not match the requested text control; no text was sent")
    }
    // Terminal's keyboard-driven shell exposes neither writable text attribute.
    // Recognize the tested shell control by its real app identity and AX metadata;
    // explicit disabled/read-only flags and every focus check still apply.
    let isTerminalShell = appBundleIdentifier == "com.apple.Terminal"
        && role == "AXTextArea" && elementDescription == "shell"
    // Other AppKit text controls can omit AXEnabled/AXEditable, but still need
    // a writable text attribute as positive evidence of editability.
    guard applicationUseEditableTextRole(role), enabled != false, editable != false,
          valueSettable || selectedTextSettable || isTerminalShell else {
        let flags = "role=\(role ?? "unknown"), enabled=\(enabled.map(String.init) ?? "unknown"), editable=\(editable.map(String.init) ?? "unknown"), valueSettable=\(valueSettable), selectedTextSettable=\(selectedTextSettable)"
        throw ComputerUseError.stateUnavailable("type_text requires a verified enabled, editable text control; no text was sent (\(flags))")
    }
}

func applicationUseOptionalBooleanValue(result: AXError, value: CFTypeRef?, attribute: String) throws -> Bool? {
    switch result {
    case .attributeUnsupported, .noValue:
        return nil
    case .success:
        guard let value, CFGetTypeID(value) == CFBooleanGetTypeID(), let boolean = value as? Bool else {
            throw ComputerUseError.stateUnavailable("type_text received an invalid boolean for \(attribute); no text was sent")
        }
        return boolean
    default:
        throw ComputerUseError.stateUnavailable("type_text could not read \(attribute) (AXError \(result.rawValue)); no text was sent")
    }
}

func validateApplicationUseWindowIdentity(observedWindowID: CGWindowID, currentAXWindowID: CGWindowID?) throws {
    guard observedWindowID != 0, currentAXWindowID == observedWindowID else {
        throw ComputerUseError.stateUnavailable("The observed accessibility window identity changed or is unavailable; take a fresh snapshot")
    }
}

func validateApplicationUseWindowBounds(observed: CGRect?, current: CGRect?) throws {
    guard let observed, let current, CursorRestingAnchor.isUsable(observed), CursorRestingAnchor.isUsable(current),
          abs(observed.minX - current.minX) <= 0.01,
          abs(observed.minY - current.minY) <= 0.01,
          abs(observed.width - current.width) <= 0.01,
          abs(observed.height - current.height) <= 0.01 else {
        throw ComputerUseError.stateUnavailable("The target window moved, resized, or its geometry is unavailable; take a fresh snapshot before input")
    }
}

func validateApplicationUseKey(_ parsed: ParsedKeyPress) throws {
    let command = parsed.modifiers.contains { $0.flag == .maskCommand }
    let control = parsed.modifiers.contains { $0.flag == .maskControl }
    let option = parsed.modifiers.contains { $0.flag == .maskAlternate }
    let lifecycleCodes: [CGKeyCode] = [kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_M, kVK_ANSI_H, kVK_Tab, kVK_Space].map { CGKeyCode($0) }
    let arrowCodes: [CGKeyCode] = [kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow].map { CGKeyCode($0) }
    let forbidden = (command && lifecycleCodes.contains(parsed.keyCode))
        || (control && arrowCodes.contains(parsed.keyCode))
        || (command && control && parsed.keyCode == CGKeyCode(kVK_ANSI_F))
        || (command && option && parsed.keyCode == CGKeyCode(kVK_Escape))
    guard !forbidden else {
        throw ComputerUseError.invalidArguments("This shortcut can close, hide, resize, or switch windows or applications and is unavailable in background-only application-use")
    }
}

func applicationUseIsWindowControl(role: String?, subrole: String?) -> Bool {
    let blocked = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"]
    return role.map(blocked.contains) == true || subrole.map(blocked.contains) == true
}

func applicationUsePointTouchesWindowControl(_ point: CGPoint, frames: [CGRect]) -> Bool {
    frames.contains { $0.insetBy(dx: -1, dy: -1).contains(point) }
}
