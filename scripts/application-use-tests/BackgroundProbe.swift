import AppKit
import ApplicationServices
import ImageIO

// This executable is deliberately unrelated to OpenComputerUseFixture: all
// automation must traverse the actual AppKit/AX/window-server implementation.
func emit(_ value: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
}

func quartzFrame(_ window: NSWindow) -> CGRect {
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    return CGRect(x: window.frame.minX, y: top - window.frame.maxY,
                  width: window.frame.width, height: window.frame.height)
}

func windowList() -> [[String: Any]] {
    CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
}

func bounds(_ info: [String: Any]) -> CGRect? {
    guard let value = info[kCGWindowBounds as String] as? [String: Any] else { return nil }
    return CGRect(dictionaryRepresentation: value as CFDictionary)
}

final class DesktopMonitor {
    let start = ProcessInfo.processInfo.systemUptime
    let sentinelPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    var appObserver: NSObjectProtocol?
    var axObserver: AXObserver?
    var axApp: AXUIElement?
    var originalWindow: AXUIElement?
    var lastWindow: AXUIElement?
    var lastPointer = CGPoint.zero
    var lastPID: pid_t = -1
    var lastPoll = 0.0
    var maxPollGap = 0.0
    var samples = 0
    var pointerChanges = 0
    var foregroundChanges = 0
    var windowChanges = 0
    var windowReadFailures = 0
    var lastAXPoll = 0.0
    var lastHeartbeat = 0.0
    var focusedWindowAvailable = false
    var notificationResults: [String: Int32] = [:]

    func focusedWindow() -> AXUIElement? {
        guard let axApp else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func record(_ kind: String, _ details: [String: Any] = [:]) {
        var value = details
        value["event"] = kind
        value["elapsed"] = ProcessInfo.processInfo.systemUptime - start
        emit(value)
    }

    func observeWindow(source: String) {
        guard focusedWindowAvailable else { return }
        guard let current = focusedWindow() else {
            windowReadFailures += 1
            record("focused-window-unavailable", ["source": source])
            return
        }
        if let lastWindow, !CFEqual(lastWindow, current) {
            windowChanges += 1
            record("focused-window-change", ["source": source,
                "returnedToOriginal": originalWindow.map { CFEqual($0, current) } ?? false])
        }
        lastWindow = current
    }

    func begin() {
        let trusted = AXIsProcessTrusted() // preflight only: never requests authorization
        if trusted, sentinelPID > 0 {
            let element = AXUIElementCreateApplication(sentinelPID)
            AXUIElementSetMessagingTimeout(element, 0.04)
            axApp = element
            originalWindow = focusedWindow()
            lastWindow = originalWindow
            focusedWindowAvailable = originalWindow != nil
            var observer: AXObserver?
            let status = AXObserverCreate(sentinelPID, { _, _, notification, refcon in
                guard let refcon else { return }
                let monitor = Unmanaged<DesktopMonitor>.fromOpaque(refcon).takeUnretainedValue()
                // Preserve the notification even if a subsequent read already
                // sees the original window again.
                monitor.record("window-notification", ["kind": notification as String])
                monitor.observeWindow(source: "notification")
            }, &observer)
            if status == .success, let observer {
                axObserver = observer
                for name in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
                    notificationResults[name] = AXObserverAddNotification(observer, element, name as CFString,
                        Unmanaged.passUnretained(self).toOpaque()).rawValue
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier ?? -1
            self.record("application-activation", ["pid": pid, "isSentinel": pid == self.sentinelPID])
        }
        lastPointer = CGEvent(source: nil)?.location ?? .zero
        lastPID = sentinelPID
        lastPoll = ProcessInfo.processInfo.systemUptime
        record("ready", ["pid": getpid(), "sentinelPID": sentinelPID,
            "pointer": [lastPointer.x, lastPointer.y], "accessibilityTrusted": trusted,
            "focusedWindowAvailable": focusedWindowAvailable,
            "windowNotifications": notificationResults, "pollIntervalMs": 10])
        Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { [self] _ in
            let now = ProcessInfo.processInfo.systemUptime
            maxPollGap = max(maxPollGap, now - lastPoll)
            lastPoll = now
            samples += 1
            let pointer = CGEvent(source: nil)?.location ?? lastPointer
            if pointer != lastPointer {
                pointerChanges += 1
                record("pointer-change", ["from": [lastPointer.x, lastPointer.y], "to": [pointer.x, pointer.y]])
                lastPointer = pointer
            }
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
            if pid != lastPID {
                foregroundChanges += 1
                record("foreground-change", ["from": lastPID, "to": pid])
                lastPID = pid
            }
            if now - lastAXPoll >= 0.05 {
                lastAXPoll = now
                observeWindow(source: "poll")
            }
            if now - lastHeartbeat >= 0.2 {
                lastHeartbeat = now
                record("heartbeat", ["samples": samples, "maxPollGapMs": maxPollGap * 1000,
                    "pointerChanges": pointerChanges, "foregroundChanges": foregroundChanges,
                    "windowChanges": windowChanges, "windowReadFailures": windowReadFailures])
            }
        }
    }
}

final class ProbeTextView: NSTextView {
    var keyCount = 0
    override func keyDown(with event: NSEvent) {
        keyCount += 1
        super.keyDown(with: event)
    }
}

final class FlippedDocument: NSView {
    override var isFlipped: Bool { true }
}

final class ProbeContent: NSView {
    var drawCount = 0
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        // A distinctive, large background also identifies a real target-window
        // capture when the entire fixture is behind the sentinel window.
        drawCount += 1
        NSColor(srgbRed: 18.0 / 255.0, green: 185.0 / 255.0, blue: 164.0 / 255.0, alpha: 1).setFill()
        dirtyRect.fill()
    }
}

final class Fixture: NSObject, NSWindowDelegate {
    let stateURL: URL
    let sentinelPID: pid_t
    let window: NSWindow
    let text = ProbeTextView(frame: NSRect(x: 16, y: 266, width: 388, height: 52))
    let scroll = NSScrollView(frame: NSRect(x: 16, y: 18, width: 388, height: 188))
    var clicks = 0
    var activations = 0
    var keyWindowEntries = 0
    var closeAttempts = 0
    var rightClicks = 0
    var lowerClicks = 0
    var observer: NSObjectProtocol?
    var previousState = Data()

    init(stateURL: URL, demonstration: Bool = false) {
        self.stateURL = stateURL
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        sentinelPID = frontPID
        let frontBounds = windowList().first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int32) == frontPID &&
            ($0[kCGWindowLayer as String] as? Int) == 0 &&
            (bounds($0)?.width ?? 0) >= 440 && (bounds($0)?.height ?? 0) >= 400
        }).flatMap(bounds)
        let top = NSScreen.screens.first?.frame.maxY ?? 900
        let visibleFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1280, height: 800)
        let origin = demonstration
            ? CGPoint(x: max(visibleFrame.minX + 16, visibleFrame.maxX - 444),
                      y: max(visibleFrame.minY + 16, visibleFrame.midY - 175))
            : frontBounds.map { CGPoint(x: $0.minX + 10, y: top - $0.minY - 390) }
                ?? CGPoint(x: 100, y: 100)
        window = NSWindow(contentRect: NSRect(origin: origin, size: NSSize(width: 420, height: 350)),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = demonstration ? "Application Use · 代理光标演示" : "Application Use Background Probe"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: 18.0 / 255.0, green: 185.0 / 255.0, blue: 164.0 / 255.0, alpha: 1)
        window.contentView = ProbeContent(frame: NSRect(x: 0, y: 0, width: 420, height: 350))
        let button = NSButton(frame: NSRect(x: 16, y: 218, width: 220, height: 34))
        button.title = "Background increment"
        button.setAccessibilityLabel("Background increment")
        button.target = self
        button.action = #selector(increment(_:))
        text.isRichText = false
        text.string = ""
        text.setAccessibilityLabel("Background text")
        text.setAccessibilityTitle("Background text")
        scroll.setAccessibilityLabel("Background scroll")
        scroll.setAccessibilityTitle("Background scroll")
        scroll.hasVerticalScroller = true
        let document = FlippedDocument(frame: NSRect(x: 0, y: 0, width: 360, height: 1800))
        for row in 0..<60 {
            let label = NSTextField(labelWithString: "Fixture-only row \(row)")
            label.frame = NSRect(x: 8, y: CGFloat(row * 28), width: 320, height: 24)
            document.addSubview(label)
        }
        scroll.documentView = document
        window.contentView?.addSubview(text)
        window.contentView?.addSubview(button)
        window.contentView?.addSubview(scroll)
        if demonstration {
            button.title = "左侧目标"
            button.setAccessibilityTitle("Background increment")
            scroll.isHidden = true
            let right = NSButton(frame: NSRect(x: 256, y: 170, width: 148, height: 34))
            right.title = "右侧目标"
            right.setAccessibilityLabel("Demo right target")
            right.setAccessibilityTitle("Demo right target")
            right.target = self
            right.action = #selector(incrementRight(_:))
            let lower = NSButton(frame: NSRect(x: 90, y: 62, width: 200, height: 34))
            lower.title = "下方目标"
            lower.setAccessibilityLabel("Demo lower target")
            lower.setAccessibilityTitle("Demo lower target")
            lower.target = self
            lower.action = #selector(incrementLower(_:))
            let caption = NSTextField(labelWithString: "代理光标在这里操作，真实鼠标保持原位")
            caption.frame = NSRect(x: 16, y: 122, width: 388, height: 24)
            caption.textColor = .white
            caption.alignment = .center
            let fieldCaption = NSTextField(labelWithString: "后台输入区")
            fieldCaption.frame = NSRect(x: 16, y: 323, width: 388, height: 20)
            fieldCaption.textColor = .white
            window.contentView?.addSubview(right)
            window.contentView?.addSubview(lower)
            window.contentView?.addSubview(caption)
            window.contentView?.addSubview(fieldCaption)
        }
        // A normal key-capable window exposes focus regressions. Never activate,
        // makeKeyAndOrderFront, raise, or touch any pre-existing window.
        if demonstration { window.orderFront(nil) } else { window.orderBack(nil) }
        window.makeFirstResponder(text)
        // The window starts fully occluded. Populate its backing store without
        // ordering it forward, rather than depending on a visibility-driven draw.
        window.contentView?.needsDisplay = true
        window.display()
        window.contentView?.display()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
            object: nil, queue: .main) { [weak self] _ in self?.activations += 1 }
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [self] _ in publish() }
        publish()
    }

    @objc func increment(_ sender: Any?) { clicks += 1 }
    @objc func incrementRight(_ sender: Any?) { rightClicks += 1 }
    @objc func incrementLower(_ sender: Any?) { lowerClicks += 1 }
    func windowDidBecomeKey(_ notification: Notification) { keyWindowEntries += 1 }
    func windowShouldClose(_ sender: NSWindow) -> Bool { closeAttempts += 1; return false }

    func publish() {
        let all = windowList()
        let ownIndex = all.firstIndex { ($0[kCGWindowNumber as String] as? Int) == window.windowNumber }
        let ownBounds = quartzFrame(window)
        let cover = ownIndex.flatMap { index in
            all.prefix(index).first {
                ($0[kCGWindowOwnerPID as String] as? Int32) == sentinelPID &&
                ($0[kCGWindowAlpha as String] as? Double ?? 1) >= 0.99 &&
                bounds($0)?.contains(ownBounds) == true
            }
        }
        let value: [String: Any] = ["pid": getpid(), "sentinelPID": sentinelPID,
            "windowNumber": window.windowNumber, "windowBounds": [ownBounds.minX, ownBounds.minY, ownBounds.width, ownBounds.height],
            "clicks": clicks, "rightClicks": rightClicks, "lowerClicks": lowerClicks,
            "text": text.string, "keyCount": text.keyCount,
            "scrollY": scroll.contentView.bounds.origin.y, "activations": activations,
            "keyWindowEntries": keyWindowEntries, "isActive": NSApp.isActive, "isKeyWindow": window.isKeyWindow,
            "closeAttempts": closeAttempts, "occludedBySentinel": cover != nil,
            "drawCount": (window.contentView as? ProbeContent)?.drawCount ?? 0]
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? data.write(to: stateURL, options: .atomic)
        if data != previousState { emit(value); previousState = data }
    }
}

final class FixtureApplicationDelegate: NSObject, NSApplicationDelegate {
    let stateURL: URL
    let demonstration: Bool
    var fixture: Fixture?

    init(stateURL: URL, demonstration: Bool = false) {
        self.stateURL = stateURL
        self.demonstration = demonstration
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // AppKit can activate an accessory app's pre-existing key-capable
        // window during finishLaunching. Complete that phase with no windows
        // and a prohibited activation policy, then create the ordinary window
        // on the next event-loop turn. Do not deactivate or restore another app.
        DispatchQueue.main.async { [self] in
            guard NSApp.setActivationPolicy(.accessory) else {
                emit(["event": "fixture-startup-error", "reason": "Cannot switch to accessory policy"])
                NSApp.terminate(nil)
                return
            }
            emit(["event": "fixture-launch-complete", "isActive": NSApp.isActive,
                  "frontPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1])
            fixture = Fixture(stateURL: stateURL, demonstration: demonstration)
        }
    }
}

func inspectImage(_ path: String) -> Never {
    // NSBitmapImageRep.colorAt can return calibrated RGB components even for
    // an ICC-tagged bitmap, losing the original display profile on conversion.
    // Drawing CGImageSource's tagged image into an explicit sRGB context lets
    // ColorSync apply the embedded ICC transform exactly once.
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
          image.width > 0, image.height > 0, image.width <= 16_384, image.height <= 16_384,
          let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: image.width, height: image.height,
              bitsPerComponent: 8, bytesPerRow: image.width * 4, space: colorSpace,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let buffer = context.data?.assumingMemoryBound(to: UInt8.self) else {
        emit(["error": "Cannot decode fixture screenshot"]); exit(1)
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    var matching = 0
    var samples = 0
    var colors: [String: Int] = [:]
    var transparent = 0
    let stride = max(1, min(image.width, image.height) / 150)
    for y in Swift.stride(from: 0, to: image.height, by: stride) {
        for x in Swift.stride(from: 0, to: image.width, by: stride) {
            samples += 1
            let pixel = buffer + (y * image.width + x) * 4
            let rgba = (0..<4).map { Int(pixel[$0]) }
            if rgba[3] < 26 { transparent += 1 }
            let key = rgba.map(String.init).joined(separator: ",")
            colors[key, default: 0] += 1
            if abs(Double(rgba[0]) / 255.0 - 18.0 / 255.0) < 0.06 &&
                abs(Double(rgba[1]) / 255.0 - 185.0 / 255.0) < 0.06 &&
                abs(Double(rgba[2]) / 255.0 - 164.0 / 255.0) < 0.06 {
                matching += 1
            }
        }
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    emit(["width": image.width, "height": image.height,
        "sourceColorSpace": properties[kCGImagePropertyProfileName] as? String ?? image.colorSpace?.name as String? ?? "unknown",
        "sampleColorSpace": "sRGB",
        "markerFraction": Double(matching) / Double(samples), "markerSamples": matching,
        "transparentFraction": Double(transparent) / Double(samples),
        "commonRGBA": colors.sorted { $0.value > $1.value }.prefix(8).map { ["rgba": $0.key, "samples": $0.value] as [String: Any] }])
    exit(matching >= 100 ? 0 : 1)
}

let arguments = CommandLine.arguments
if arguments.count == 3 && arguments[1] == "--inspect-image" {
    inspectImage(arguments[2])
} else if arguments.count == 2 && arguments[1] == "--monitor" {
    let monitor = DesktopMonitor()
    monitor.begin()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 240))
} else if arguments.count == 3 && ["--fixture", "--demo-fixture"].contains(arguments[1]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let delegate = FixtureApplicationDelegate(stateURL: URL(fileURLWithPath: arguments[2]),
        demonstration: arguments[1] == "--demo-fixture")
    app.delegate = delegate
    Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in app.terminate(nil) }
    withExtendedLifetime(delegate) { app.run() }
} else {
    emit(["error": "Use --monitor, --fixture STATE_PATH, --demo-fixture STATE_PATH, or --inspect-image PNG_PATH"])
    exit(2)
}
