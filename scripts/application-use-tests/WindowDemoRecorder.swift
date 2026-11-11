import AppKit
import ApplicationServices
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Records only two identified window backing stores. It never captures a
// display or a screen rectangle, and never draws a simulated cursor.
enum RecordingError: Error { case invalid(String) }
typealias MainConnection = @convention(c) () -> UInt32
typealias CaptureWindows = @convention(c) (UInt32, UnsafePointer<CGWindowID>, Int32, UInt32) -> Unmanaged<CFArray>?

func emit(_ value: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
    }
}

func readState(_ path: String) throws -> [String: Any] {
    guard let value = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any]
    else { throw RecordingError.invalid("Invalid fixture state") }
    return value
}

func frame(_ info: [String: Any]) -> CGRect? {
    guard let dictionary = info[kCGWindowBounds as String] as? [String: Any],
          let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
          rect.minX.isFinite, rect.minY.isFinite, rect.width > 0, rect.height > 0 else { return nil }
    return rect
}

func inspectCursor(_ runtimePID: pid_t) {
    let all = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    let visible = all.filter {
        ($0[kCGWindowOwnerPID as String] as? Int32) == runtimePID &&
        ($0[kCGWindowName as String] as? String) == "Application Use Cursor"
    }.map { info -> [String: Any] in
        let bounds = frame(info)
        return ["windowID": info[kCGWindowNumber as String] ?? NSNull(), "ownerPID": runtimePID,
            "bounds": bounds.map { [$0.minX, $0.minY, $0.width, $0.height] } as Any? ?? NSNull()]
    }
    let alive = kill(runtimePID, 0) == 0 || errno == EPERM
    emit(["runtimePID": runtimePID, "runtimeAlive": alive, "visibleWindows": visible])
}

func run() throws {
    let args = CommandLine.arguments
    if args.count == 3, args[1] == "--inspect-cursor", let runtimePID = Int32(args[2]), runtimePID > 0 {
        inspectCursor(runtimePID)
        return
    }
    guard args.count == 6, let runtimePID = Int32(args[2]), let maxSeconds = Double(args[5]),
          maxSeconds > 0, maxSeconds <= 60 else {
        throw RecordingError.invalid("Use FIXTURE_STATE RUNTIME_PID OUTPUT_GIF STOP_FILE MAX_SECONDS")
    }
    guard CGPreflightScreenCaptureAccess() else { throw RecordingError.invalid("Screen Recording access is unavailable; no permission was requested") }
    guard !FileManager.default.fileExists(atPath: args[3]) else { throw RecordingError.invalid("Output already exists") }
    let fixture = try readState(args[1])
    guard let fixturePID = fixture["pid"] as? Int32,
          let fixtureID = fixture["windowNumber"] as? UInt32,
          let coordinates = fixture["windowBounds"] as? [Double], coordinates.count == 4 else {
        throw RecordingError.invalid("Missing fixture identity or bounds")
    }
    let fixtureFrame = CGRect(x: coordinates[0], y: coordinates[1], width: coordinates[2], height: coordinates[3])
    let canvas = fixtureFrame.insetBy(dx: -96, dy: -96)
    guard canvas.width < 1600, canvas.height < 1600,
          let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
          let connectionSymbol = dlsym(library, "SLSMainConnectionID"),
          let captureSymbol = dlsym(library, "SLSHWCaptureWindowList") else {
        throw RecordingError.invalid("Isolated window capture is unavailable")
    }
    defer { dlclose(library) }
    let connection = unsafeBitCast(connectionSymbol, to: MainConnection.self)
    let captureFunction = unsafeBitCast(captureSymbol, to: CaptureWindows.self)
    func capture(_ windowID: CGWindowID) -> CGImage? {
        var id = windowID
        guard let result = captureFunction(connection(), &id, 1, 0x800)?.takeRetainedValue(), CFArrayGetCount(result) == 1 else { return nil }
        let image = unsafeBitCast(CFArrayGetValueAtIndex(result, 0), to: CGImage.self)
        return image.width > 0 && image.height > 0 ? image : nil
    }
    let output = URL(fileURLWithPath: args[3])
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, 0, nil),
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
        throw RecordingError.invalid("Cannot create GIF output")
    }
    CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let start = ProcessInfo.processInfo.systemUptime
    var lastFrame = start
    var frameCount = 0
    var overlayFrames = 0
    var trajectory: [[String: Any]] = []
    var observedIDs = Set<UInt32>()
    var failure: String?
    emit(["event": "recording-ready", "fixtureWindowID": fixtureID, "fixturePID": fixturePID,
          "runtimePID": runtimePID, "output": output.path])
    while ProcessInfo.processInfo.systemUptime - start < maxSeconds && !FileManager.default.fileExists(atPath: args[4]) {
        let tick = ProcessInfo.processInfo.systemUptime
        autoreleasepool {
            let windows = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
            guard let fixtureInfo = windows.first(where: {
                ($0[kCGWindowNumber as String] as? UInt32) == fixtureID &&
                ($0[kCGWindowOwnerPID as String] as? Int32) == fixturePID
            }), let currentFrame = frame(fixtureInfo), currentFrame == fixtureFrame,
            let baseImage = capture(fixtureID) else {
                failure = "Fixture identity, geometry, or isolated capture became unavailable"
                return
            }
            let matches = windows.filter {
                ($0[kCGWindowOwnerPID as String] as? Int32) == runtimePID &&
                ($0[kCGWindowName as String] as? String) == "Application Use Cursor" &&
                ($0[kCGWindowIsOnscreen as String] as? Bool) == true
            }
            guard matches.count <= 1 else { failure = "Ambiguous cursor window identity"; return }
            guard let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                bitsPerComponent: 8, bytesPerRow: Int(canvas.width) * 4, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                failure = "Cannot allocate output frame"; return
            }
            context.setFillColor(CGColor(gray: 0.12, alpha: 1))
            context.fill(CGRect(origin: .zero, size: canvas.size))
            func draw(_ image: CGImage, in bounds: CGRect) {
                context.draw(image, in: CGRect(x: bounds.minX - canvas.minX, y: canvas.maxY - bounds.maxY,
                    width: bounds.width, height: bounds.height))
            }
            draw(baseImage, in: currentFrame)
            if let overlay = matches.first, let overlayID = overlay[kCGWindowNumber as String] as? UInt32,
               let overlayFrame = frame(overlay), let overlayImage = capture(overlayID) {
                // The only overlaid pixels come from the actual native panel.
                draw(overlayImage, in: overlayFrame)
                observedIDs.insert(overlayID)
                overlayFrames += 1
                trajectory.append(["elapsed": tick - start, "windowID": overlayID, "ownerPID": runtimePID,
                    "bounds": [Double(overlayFrame.minX), Double(overlayFrame.minY),
                               Double(overlayFrame.width), Double(overlayFrame.height)]])
            }
            guard let result = context.makeImage() else { failure = "Cannot finish output frame"; return }
            let delay = max(0.05, min(0.5, tick - lastFrame))
            CGImageDestinationAddImage(destination, result, [kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            lastFrame = tick
            frameCount += 1
        }
        if failure != nil { break }
        Thread.sleep(forTimeInterval: max(0, 0.1 - (ProcessInfo.processInfo.systemUptime - tick)))
    }
    let finalized = CGImageDestinationFinalize(destination)
    let points = trajectory.compactMap { $0["bounds"] as? [Double] }
    let movement = points.first.map { first in points.map { hypot($0[0] - first[0], $0[1] - first[1]) }.max() ?? 0 } ?? 0
    let passed = finalized && frameCount >= 10 && overlayFrames >= 5 && movement >= 30 && failure == nil
    let summary: [String: Any] = ["event": "recording-complete", "status": passed ? "passed" : "failed",
        "frames": frameCount, "overlayFrames": overlayFrames, "overlayWindowIDs": Array(observedIDs).sorted(),
        "elapsedSeconds": ProcessInfo.processInfo.systemUptime - start, "observedMovementPoints": movement,
        "fixtureWindowID": fixtureID, "fixturePID": fixturePID, "runtimePID": runtimePID,
        "output": output.path, "error": failure as Any? ?? NSNull(),
        "captureScope": "Only exact fixture and runtime cursor window backing stores; neutral canvas elsewhere"]
    let evidence: [String: Any] = ["summary": summary, "trajectory": trajectory]
    try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[3] + ".json"))
    emit(summary)
    if !passed { exit(1) }
}

do { try run() }
catch { emit(["event": "recording-error", "error": String(describing: error)]); exit(1) }
