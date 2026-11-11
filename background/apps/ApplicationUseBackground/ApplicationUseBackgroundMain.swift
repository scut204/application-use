import AppKit
import ApplicationServices
import Foundation
import OpenComputerUseKit

@main
enum ApplicationUseBackgroundMain {
    @MainActor
    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--help"] || arguments.isEmpty {
            print("ApplicationUseBackground: background-only JSON-line runtime. Use --stdio or doctor.")
            return
        }
        if arguments == ["doctor"] {
            if let data = try? JSONSerialization.data(withJSONObject: runtimePermissions(), options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            return
        }
        guard arguments == ["--stdio"] else {
            FileHandle.standardError.write(Data("Unsupported invocation; no foreground or management modes exist.\n".utf8))
            exit(2)
        }

        // The cursor is a nonactivating visual panel, independent of real input.
        setenv("OPEN_COMPUTER_USE_VISUAL_CURSOR", "1", 1)
        setenv("OPEN_COMPUTER_USE_VIRTUAL_DISPLAY_ENABLED", "0", 1)
        setenv("OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS", "0", 1)
        setenv("OPEN_COMPUTER_USE_ACTION_READ_BACK", "0", 1)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = BackgroundRuntimeDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class BackgroundRuntimeDelegate: NSObject, NSApplicationDelegate {
    private let service = ComputerUseService()
    private lazy var dispatcher = ComputerUseToolDispatcher(service: service)
    private let recognizer = WindowImageRecognizer()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finish launch while activation is prohibited and no windows exist.
        // Only then allow the nonactivating cursor panel to be displayed.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
            Thread.detachNewThreadSelector(#selector(self.processInput), toTarget: self, with: nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { resetOpenComputerUseVisualCursor() }
    }

    @objc private func processInput() {
        while let line = readLine() {
            autoreleasepool {
                let result: [String: Any]
                do {
                    guard let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let tool = request["tool"] as? String else {
                        throw RuntimeError.message("Expected an object with tool and arguments.")
                    }
                    result = try call(tool, arguments: request["arguments"] as? [String: Any] ?? [:])
                } catch {
                    result = ["isError": true, "content": [["type": "text", "text": error.localizedDescription]]]
                }
                do {
                    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data([10]))
                } catch {
                    FileHandle.standardError.write(Data("Unable to encode runtime response.\n".utf8))
                }
            }
        }
        resetOpenComputerUseBackgroundWindowState()
        DispatchQueue.main.async {
            resetOpenComputerUseVisualCursor()
            NSApp.terminate(nil)
        }
    }

    private func call(_ tool: String, arguments: [String: Any]) throws -> [String: Any] {
        switch tool {
        case "doctor":
            return runtimePermissions()
        case "recognize":
            return try recognizer.recognize(arguments: arguments)
        case "search":
            return try service.applicationUseSearch(query: arguments["query"] as? String ?? "")
        case "open":
            return try service.applicationUseOpen(app: string("app", arguments))
        case "close":
            return try service.applicationUseClose(app: string("app", arguments))
        case "snapshot":
            try requirePermissions()
            return try service.applicationUseSnapshot(app: string("app", arguments))
        case "scroll_pixels":
            try requirePermissions()
            guard let pixels = arguments["pixels"] as? Double, pixels.isFinite, pixels > 0, pixels <= 100_000 else {
                throw RuntimeError.message("pixels must be finite and between 0 and 100000.")
            }
            return try service.applicationUseScrollPixels(
                app: string("app", arguments),
                elementIndex: string("element_index", arguments),
                direction: string("direction", arguments), pixels: pixels
            ).asDictionary
        case "click", "scroll", "type_text", "press_key", "set_value":
            try requirePermissions()
            return try dispatcher.callTool(name: tool, arguments: arguments).asDictionary
        default:
            throw RuntimeError.message("Unsupported background-only operation: \(tool).")
        }
    }

    private func requirePermissions() throws {
        // Inspect current runtime access only. This must never prompt or open System Settings.
        guard AXIsProcessTrusted() else { throw RuntimeError.message("Accessibility permission is missing for this runtime; run doctor.") }
        guard CGPreflightScreenCaptureAccess() else { throw RuntimeError.message("Screen Recording permission is missing for this runtime; run doctor.") }
    }

    private func string(_ key: String, _ arguments: [String: Any]) throws -> String {
        if let value = arguments[key] as? String, !value.isEmpty { return value }
        if let value = arguments[key] as? Int { return String(value) }
        throw RuntimeError.message("Missing argument: \(key).")
    }
}

enum RuntimeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { return value }; return nil }
}

private func runtimePermissions() -> [String: Any] {
    let accessibility = AXIsProcessTrusted()
    let capture = CGPreflightScreenCaptureAccess()
    return [
        "platform": "macos", "accessibilityTrusted": accessibility,
        "screenCaptureGranted": capture, "allGranted": accessibility && capture,
        "missingPermissions": (accessibility ? [] : ["accessibility"]) + (capture ? [] : ["screenRecording"]),
        "backgroundOnly": true,
        "runtimePID": Int(getpid()),
        "visualCursorEnabled": VisualCursorSupport.isEnabled,
    ]
}
