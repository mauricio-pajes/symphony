import AppKit
import ApplicationServices
import Vision

enum DemoError: Error {
    case accessibilityUnavailable, missingBruno, missingControl(String), missingWindow, requestNotReady(String), invalidCommand
}

func read(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
    return result
}

func text(_ element: AXUIElement, _ name: String) -> String {
    read(element, name) as? String ?? ""
}

func descendants(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
    guard depth < 24 else { return [] }
    let children = read(element, "AXChildren") as? [AXUIElement] ?? []
    return [element] + children.flatMap { descendants($0, depth: depth + 1) }
}

func center(_ element: AXUIElement) throws -> CGPoint {
    guard let start = read(element, "AXPosition"), let dimensions = read(element, "AXSize"),
          CFGetTypeID(start) == AXValueGetTypeID(), CFGetTypeID(dimensions) == AXValueGetTypeID() else {
        throw DemoError.missingControl("position")
    }
    var point = CGPoint.zero
    var size = CGSize.zero
    AXValueGetValue(start as! AXValue, .cgPoint, &point)
    AXValueGetValue(dimensions as! AXValue, .cgSize, &size)
    return CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
}

func pointer(_ point: CGPoint, click: Bool = false) {
    CGWarpMouseCursorPosition(point)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    if click {
        for kind in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: kind, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        }
    }
}

func newRequestShortcut(_ app: NSRunningApplication) {
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 45, keyDown: down)
        event?.flags = .maskCommand
        event?.postToPid(app.processIdentifier)
    }
}

func retry<T>(_ operation: () -> T?) -> T? {
    for _ in 0..<30 {
        if let result = operation() { return result }
        Thread.sleep(forTimeInterval: 0.12)
    }
    return nil
}

struct Bruno {
    let running: NSRunningApplication
    let window: AXUIElement

    init() throws {
        guard AXIsProcessTrusted() else { throw DemoError.accessibilityUnavailable }
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: "com.usebruno.app")
        for candidate in instances.sorted(by: { $0.isActive && !$1.isActive }) {
            if !candidate.isActive { candidate.activate(options: [.activateAllWindows]) }
            let target = AXUIElementCreateApplication(candidate.processIdentifier)
            AXUIElementSetMessagingTimeout(target, 0.5)
            AXUIElementSetAttributeValue(target, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            guard let first = retry({
                (read(target, "AXWindows") as? [AXUIElement])?.first { window in
                    (read(window, "AXChildren") as? [AXUIElement])?.isEmpty == false
                }
            }) else { continue }
            running = candidate
            window = first
            return
        }
        throw DemoError.missingBruno
    }

    func button(_ name: String) -> AXUIElement? {
        descendants(window).first { element in
            text(element, "AXRole") == "AXButton" && ["AXTitle", "AXDescription", "AXHelp"].contains { attribute in
                text(element, attribute) == name
            }
        }
    }

    func action(_ name: String) throws {
        guard let element = retry({ button(name) }) else { throw DemoError.missingControl(name) }
        if AXUIElementPerformAction(element, kAXPressAction as CFString) != .success {
            try pointer(center(element), click: true)
        }
    }

    func prepare(_ url: String) throws -> (AXUIElement, AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        if button("New Transient Request") != nil {
            try action("New Transient Request")
        } else {
            newRequestShortcut(running)
        }
        if button("Hide sidebar") != nil { try action("Hide sidebar") }
        Thread.sleep(forTimeInterval: 0.6)
        guard button("Hide sidebar") == nil else { throw DemoError.requestNotReady("the workspace sidebar is visible") }
        guard let editor = retry({ urlEditor() }) else { throw DemoError.missingControl("request URL") }
        AXUIElementSetAttributeValue(editor, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        guard AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, url as CFString) == .success else {
            throw DemoError.missingControl("editable request URL")
        }
        guard let expected = retry({ urlEditor().flatMap { text($0, "AXValue") == url ? $0 : nil } }),
              let send = button("Send") else {
            throw DemoError.requestNotReady("the URL editor rejected the value")
        }
        return (expected, send)
    }

    func urlEditor() -> AXUIElement? {
        guard let send = button("Send"), let sendPoint = try? center(send) else { return nil }
        return descendants(window).first { element in
            guard text(element, "AXRole") == "AXTextArea", let point = try? center(element) else { return false }
            return point.x < sendPoint.x && abs(point.y - sendPoint.y) <= 15
        }
    }

    func captureTarget() throws -> [String: Int] {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let row = windows.first(where: {
            ($0["kCGWindowOwnerPID"] as? Int32) == running.processIdentifier && ($0["kCGWindowLayer"] as? Int) == 0
        }), let bounds = row["kCGWindowBounds"] as? [String: Double],
            let width = bounds["Width"], let height = bounds["Height"], let windowID = row["kCGWindowNumber"] as? Int else {
            throw DemoError.missingWindow
        }
        return ["id": windowID, "width": Int(width), "height": Int(height)]
    }

    func send(_ editor: AXUIElement, _ send: AXUIElement, url: String, status: String, emphasis: String) throws {
        let value = text(editor, "AXValue")
        guard value.isEmpty || value.contains(url) else {
            throw DemoError.requestNotReady("the URL changed during recording")
        }
        guard button("Hide sidebar") == nil else {
            throw DemoError.requestNotReady("the workspace sidebar is visible before Send")
        }

        try pointer(center(editor))
        Thread.sleep(forTimeInterval: 1.2)
        try pointer(center(send))
        Thread.sleep(forTimeInterval: 0.9)
        if AXUIElementPerformAction(send, kAXPressAction as CFString) != .success {
            try pointer(center(send), click: true)
        }

        Thread.sleep(forTimeInterval: 0.8)
        let elements = descendants(window)
        let statusLabel = elements.first { element in
            ["AXValue", "AXTitle", "AXDescription"].contains { name in
                text(element, name).hasPrefix(status + " ")
            }
        }
        let responseTab = elements.first { element in
            ["AXValue", "AXTitle", "AXDescription"].contains { text(element, $0) == "Response" }
        }
        if emphasis == "status", let statusLabel, let point = try? center(statusLabel) {
            pointer(point)
        } else if let responseTab, let point = try? center(responseTab) {
            pointer(CGPoint(x: point.x + 16, y: point.y + (status == "200" ? 125 : 67)))
        } else {
            let point = try center(send)
            pointer(CGPoint(x: point.x - 195, y: point.y + (emphasis == "status" ? 47 : 155)))
        }
    }
}

let args = Array(CommandLine.arguments.dropFirst())
NSApplication.shared.setActivationPolicy(.accessory)
do {
    switch args.first {
    case "ocr" where args.count == 2:
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(url: URL(fileURLWithPath: args[1])).perform([request])
        print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
    case "target":
        let data = try JSONSerialization.data(withJSONObject: Bruno().captureTarget())
        print(String(decoding: data, as: UTF8.self))
    case "diagnose":
        let bruno = try Bruno()
        print("Bruno process: \(bruno.running.processIdentifier)")
        print("Window elements: \(descendants(bruno.window).count)")
        for name in ["New Transient Request", "Send", "Hide sidebar", "Show sidebar"] {
            print("\(name): \(bruno.button(name) != nil)")
        }
    case "shot" where args.count == 4:
        let bruno = try Bruno()
        let (editor, send) = try bruno.prepare(args[1])
        let data = try JSONSerialization.data(withJSONObject: bruno.captureTarget())
        print(String(decoding: data, as: UTF8.self))
        fflush(stdout)
        guard readLine() == "recording" else { throw DemoError.invalidCommand }
        try bruno.send(editor, send, url: args[1], status: args[2], emphasis: args[3])
    case "restore":
        let bruno = try Bruno()
        if bruno.button("Show sidebar") != nil { try bruno.action("Show sidebar") }
    default:
        throw DemoError.invalidCommand
    }
} catch {
    fputs("Bruno demo: \(error)\n", stderr)
    exit(1)
}
