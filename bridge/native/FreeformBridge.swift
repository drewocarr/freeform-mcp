import AppKit
import ApplicationServices
import Foundation
import Darwin
import CryptoKit
import ScreenCaptureKit

let contentType = NSPasteboard.PasteboardType("com.apple.apps.content-language.canvas-object-1.0")
struct BridgeError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }
func children(_ element: AXUIElement) -> [AXUIElement] { attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func descendants(_ root: AXUIElement, depth: Int = 12) -> [AXUIElement] {
    guard depth > 0 else { return [] }
    return children(root).flatMap { [$0] + descendants($0, depth: depth - 1) }
}
func waitForUI() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
func waitUntil(_ predicate: () -> Bool, seconds: Double = 4) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    repeat { if predicate() { return true }; waitForUI() } while Date() < deadline
    return false
}
func emit(_ result: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}
func runningApp() -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.freeform").first
}
func focusedWindow(_ app: AXUIElement) -> AXUIElement? {
    guard let value = attribute(app, kAXFocusedWindowAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return unsafeBitCast(value, to: AXUIElement.self)
}
func canvas(_ window: AXUIElement) -> AXUIElement? {
    descendants(window).first { string($0, kAXRoleAttribute) == "AXLayoutArea" }
}
func layoutItems(_ canvas: AXUIElement) -> [AXUIElement] {
    children(canvas).filter { string($0, kAXRoleAttribute) == "AXLayoutItem" }
}
func requireBoard(_ app: AXUIElement, title: String) throws -> (AXUIElement, AXUIElement) {
    guard let window = focusedWindow(app), string(window, kAXTitleAttribute) == title else {
        throw BridgeError("BOARD_MISMATCH: Open the requested board in Freeform.")
    }
    guard let target = canvas(window) else { throw BridgeError("NO_CANVAS: The focused Freeform window is not a board canvas.") }
    // A text editor changes Copy/Paste meaning. Refuse rather than paste into a label.
    if let focused = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() {
        let element = unsafeBitCast(focused, to: AXUIElement.self)
        let role = string(element, kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) {
            throw BridgeError("TEXT_EDITING: Finish editing text and select the canvas or objects before using the bridge.")
        }
        guard role == "AXLayoutArea" || role == "AXLayoutItem" else {
            throw BridgeError("CANVAS_NOT_FOCUSED: Click the board canvas or select objects before using the bridge.")
        }
    } else {
        throw BridgeError("CANVAS_NOT_FOCUSED: Click the board canvas or select objects before using the bridge.")
    }
    return (window, target)
}
func menuAction(_ app: AXUIElement, title: String, expectedWindow: AXUIElement, boardTitle: String, beforePress: () throws -> Void = {}) throws {
    var pid: pid_t = 0
    guard AXUIElementGetPid(app, &pid) == .success, let running = NSRunningApplication(processIdentifier: pid) else { throw BridgeError("APP_UNAVAILABLE") }
    running.activate()
    guard waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else { throw BridgeError("APP_NOT_FRONTMOST") }
    waitForUI()
    guard let menu = attribute(app, kAXMenuBarAttribute), CFGetTypeID(menu) == AXUIElementGetTypeID() else {
        throw BridgeError("NO_MENU_BAR: Cannot inspect Freeform menus.")
    }
    let menuBar = unsafeBitCast(menu, to: AXUIElement.self)
    guard let edit = children(menuBar).first(where: { string($0, kAXTitleAttribute) == "Edit" }) else {
        throw BridgeError("MENU_UNAVAILABLE: Expected English Edit → \(title) command.")
    }
    var command: AXUIElement?
    let available = waitUntil({
        command = descendants(edit, depth: 3).first(where: {
            let name = string($0, kAXTitleAttribute) ?? ""
            return name == title || (title == "Undo" && name.hasPrefix("Undo "))
        })
        return command.map { (attribute($0, kAXEnabledAttribute) as? Bool) == true } ?? false
    }, seconds: 2)
    guard available, let item = command else {
        throw BridgeError("COMMAND_DISABLED: Edit → \(title) is unavailable for the current selection.")
    }
    guard let current = focusedWindow(app), CFEqual(current, expectedWindow),
          string(current, kAXTitleAttribute) == boardTitle else {
        throw BridgeError("BOARD_CHANGED: Freeform or its focused board changed before the command. Command cancelled.")
    }
    try beforePress()
    // Inspect command availability without opening a menu-tracking loop. Dispatch
    // the standard shortcut once; callers verify the actual board/clipboard effect.
    _ = item
    _ = try requireBoard(app, title: boardTitle)
    let shortcuts: [String: CGKeyCode] = ["Copy": 8, "Paste": 9, "Select All": 0, "Undo": 6]
    guard let code = shortcuts[title] else { throw BridgeError("COMMAND_UNSUPPORTED") }
    try key(pid, code, modifiers: .maskCommand)

}
func key(_ pid: pid_t, _ code: CGKeyCode, modifiers: CGEventFlags = []) throws {
    guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
          let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw BridgeError("KEY_EVENT_FAILED") }
    guard let running = NSRunningApplication(processIdentifier: pid) else { throw BridgeError("APP_UNAVAILABLE") }
    running.activate()
    guard waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else { throw BridgeError("APP_NOT_FRONTMOST") }
    down.flags = modifiers; up.flags = modifiers
    down.post(tap: .cghidEventTap)
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    up.post(tap: .cghidEventTap)
    waitForUI()
}
func clickElement(_ element: AXUIElement, pid: pid_t, clicks: Int = 1, modifiers: CGEventFlags = []) throws {
    guard let p = attribute(element, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let z = attribute(element, kAXSizeAttribute), CFGetTypeID(z) == AXValueGetTypeID() else { throw BridgeError("CONTROL_BOUNDS_UNAVAILABLE") }
    var position = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(z, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0 else { throw BridgeError("CONTROL_BOUNDS_UNAVAILABLE") }
    guard let running = NSRunningApplication(processIdentifier: pid) else { throw BridgeError("APP_UNAVAILABLE") }
    running.activate()
    guard waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }) else { throw BridgeError("APP_NOT_FRONTMOST") }
    let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
    for count in 1...clicks {
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else { throw BridgeError("MOUSE_EVENT_FAILED") }
        down.flags = modifiers; up.flags = modifiers
        down.setIntegerValueField(.mouseEventClickState, value: Int64(count)); up.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { throw BridgeError("APP_CHANGED: Mouse action cancelled.") }
        down.post(tap: .cghidEventTap)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        up.post(tap: .cghidEventTap)
    }
    waitForUI()
}
func boardWindow(_ app: AXUIElement, title: String) throws -> (AXUIElement, AXUIElement) {
    guard let window = focusedWindow(app), string(window, kAXTitleAttribute) == title, let area = canvas(window) else {
        throw BridgeError("BOARD_MISMATCH: Open the requested board in Freeform.")
    }
    return (window, area)
}
func objectDescription(_ item: AXUIElement) -> String { string(item, kAXDescriptionAttribute) ?? "" }
func objectList(_ area: AXUIElement) -> [[String: Any]] {
    layoutItems(area).enumerated().map { index, item in
        ["objectIndex": index, "description": objectDescription(item), "selected": (attribute(item, kAXSelectedAttribute) as? Bool) ?? false]
    }
}
func selectOnly(_ item: AXUIElement, area: AXUIElement) throws {
    _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    let selected = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray)
    if selected != .success {
        for other in layoutItems(area) {
            let value = CFEqual(other, item) ? kCFBooleanTrue : kCFBooleanFalse
            _ = AXUIElementSetAttributeValue(other, kAXSelectedAttribute as CFString, value!)
        }
    }
    guard waitUntil({
        let items = layoutItems(area).filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
        return items.count == 1 && CFEqual(items[0], item)
    }) else { throw BridgeError("SELECTION_UNSUPPORTED: Could not select exactly the requested object.") }
    waitForUI()
    waitForUI()
}
func pressButton(_ window: AXUIElement, title: String) throws {
    guard let button = descendants(window).first(where: {
        string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXTitleAttribute) == title || string($0, kAXDescriptionAttribute) == title)
    }), AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else {
        throw BridgeError("BUTTON_UNAVAILABLE: Could not press \(title).")
    }
}
final class ClipboardTransaction {
    let board: NSPasteboard
    let original: [[(NSPasteboard.PasteboardType, Data)]]
    var expected: Int
    init(board: NSPasteboard = .general) throws {
        self.board = board
        let initial = board.changeCount
        var snapshot: [[(NSPasteboard.PasteboardType, Data)]] = []
        for item in board.pasteboardItems ?? [] {
            var entries: [(NSPasteboard.PasteboardType, Data)] = []
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    throw BridgeError("CLIPBOARD_UNAVAILABLE: An existing clipboard representation cannot be preserved. Copy plain text or clear it yourself before retrying.")
                }
                entries.append((type, data))
            }
            snapshot.append(entries)
        }
        original = snapshot
        guard initial >= 0, board.changeCount == initial else { throw BridgeError("CLIPBOARD_UNAVAILABLE: Cannot safely snapshot the clipboard.") }
        expected = initial
    }
    func put(_ data: Data) throws {
        guard board.changeCount == expected else { throw BridgeError("CLIPBOARD_CHANGED: Clipboard changed before insertion.") }
        let item = NSPasteboardItem()
        item.setData(data, forType: contentType)
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.writeObjects([item]) else { expected = board.changeCount; throw BridgeError("CLIPBOARD_WRITE_FAILED") }
        expected = board.changeCount
    }
    func copiedObjects(app: AXUIElement, window: AXUIElement, title: String) throws -> [[String: Any]] {
        guard board.changeCount == expected else { throw BridgeError("CLIPBOARD_CHANGED: Clipboard changed before readback.") }
        // A distinct marker requires fresh publication even when Copy is repeated.
        let marker = NSPasteboardItem()
        marker.setString("Freeform bridge readback " + UUID().uuidString, forType: .string)
        board.prepareForNewContents(with: .currentHostOnly)
        guard board.writeObjects([marker]) else { expected = board.changeCount; throw BridgeError("CLIPBOARD_WRITE_FAILED") }
        expected = board.changeCount
        let old = expected
        let (_, area) = try boardWindow(app, title: title)
        let selected = layoutItems(area).filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
        guard !selected.isEmpty else { throw BridgeError("NO_SELECTION") }
        func selectionMatches() -> Bool {
            guard let current = focusedWindow(app), CFEqual(current, window), string(current, kAXTitleAttribute) == title else { return false }
            let now = layoutItems(area).filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
            return now.count == selected.count && now.allSatisfy { item in selected.contains { CFEqual($0, item) } }
        }
        try menuAction(app, title: "Copy", expectedWindow: window, boardTitle: title, beforePress: {
            guard selectionMatches() else { throw BridgeError("SELECTION_CHANGED: Copy cancelled.") }
            guard self.board.changeCount == old else { throw BridgeError("CLIPBOARD_CHANGED: Clipboard changed before Copy. New contents will not be restored over.") }
        })
        guard waitUntil({ self.board.changeCount != old }, seconds: 30) else { throw BridgeError("COPY_TIMEOUT: Copy did not produce clipboard data.") }
        // Copy can publish its change count before its promised representations are ready.
        var objects: [[String: Any]]?
        var lastCount = board.changeCount
        var lastData: Data?
        var stableSince = Date()
        let ready = waitUntil({
            let count = self.board.changeCount
            let data = self.board.data(forType: contentType)
            if count != lastCount || data != lastData {
                lastCount = count; lastData = data; stableSince = Date()
            }
            if let data, let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
               self.board.changeCount == count, Date().timeIntervalSince(stableSince) >= 0.3 {
                objects = value
                self.expected = count
                return true
            }
            return false
        }, seconds: 15)
        guard ready, let objects else {
            if board.types?.contains(NSPasteboard.PasteboardType("com.sindresorhus.Pure-Paste.hasRun")) == true {
                throw BridgeError("CLIPBOARD_FILTERED: Pure Paste removed Freeform object data. Exclude Freeform in Pure Paste settings, then inspect the board before retrying.")
            }
            throw BridgeError("NO_OBJECT_JSON: Selection did not produce content-language JSON. A clipboard utility may have modified it.")
        }
        guard selectionMatches() else { throw BridgeError("SELECTION_CHANGED: Readback cannot be verified.") }
        return objects
    }
    func restore() -> Bool {
        guard board.changeCount == expected else { return false }
        let items = original.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        board.prepareForNewContents(with: .currentHostOnly)
        return items.isEmpty || board.writeObjects(items)
    }
}

func frame(_ element: AXUIElement) throws -> CGRect {
    guard let p = attribute(element, kAXPositionAttribute), let s = attribute(element, kAXSizeAttribute),
          CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { throw BridgeError("BOUNDS_UNAVAILABLE") }
    var position = CGPoint.zero; var size = CGSize.zero
    guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &position),
          AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { throw BridgeError("BOUNDS_UNAVAILABLE") }
    return CGRect(origin: position, size: size)
}
func snapshot(_ area: AXUIElement) throws -> String {
    let values = try layoutItems(area).map { item -> [String: Any] in
        let r = try frame(item)
        return ["description": objectDescription(item), "frame": [r.minX, r.minY, r.width, r.height]]
    }
    return SHA256.hash(data: try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
}
func selectionMatches(_ area: AXUIElement, _ targets: [AXUIElement]) -> Bool {
    let selected = layoutItems(area).filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
    return selected.count == targets.count && selected.allSatisfy { item in targets.contains { CFEqual(item, $0) } }
}
func selectTargets(_ targets: [AXUIElement], area: AXUIElement, app: AXUIElement, window: AXUIElement, title: String, pid: pid_t) throws {
    _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    _ = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, targets as CFArray)
    if !waitUntil({ selectionMatches(area, targets) }, seconds: 0.4) {
        for (index, item) in targets.enumerated() {
            let (current, _) = try requireBoard(app, title: title)
            guard CFEqual(current, window) else { throw BridgeError("BOARD_CHANGED") }
            try clickElement(item, pid: pid, modifiers: index == 0 ? [] : .maskShift)
        }
    }
    guard waitUntil({ selectionMatches(area, targets) }) else { throw BridgeError("SELECTION_UNVERIFIED: Could not select exactly the requested objects.") }
}
func arrangementItem(_ app: AXUIElement, action: String) throws -> AXUIElement {
    guard let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw BridgeError("NO_MENU_BAR") }
    let bar = unsafeBitCast(raw, to: AXUIElement.self)
    guard let arrange = children(bar).first(where: { string($0, kAXTitleAttribute) == "Arrange" }) else { throw BridgeError("MENU_UNAVAILABLE: English Arrange menu required.") }
    let names = ["group": "Group", "ungroup": "Ungroup", "left": "Left", "center": "Center", "right": "Right", "top": "Top", "middle": "Middle", "bottom": "Bottom"]
    guard let name = names[action] else { throw BridgeError("INVALID_ARRANGEMENT") }
    var root = arrange
    if action != "group" && action != "ungroup" {
        guard let submenu = descendants(arrange, depth: 3).first(where: { string($0, kAXTitleAttribute) == "Align Objects" }) else { throw BridgeError("MENU_UNAVAILABLE") }
        root = submenu
    }
    guard let item = descendants(root, depth: 3).first(where: { string($0, kAXTitleAttribute) == name }),
          (attribute(item, kAXEnabledAttribute) as? Bool) == true else { throw BridgeError("COMMAND_DISABLED: Arrange → \(name) unavailable.") }
    return item
}
func screenshot(_ app: AXUIElement, window: AXUIElement, title: String, pid: pid_t) throws -> [String: Any] {
    guard CGPreflightScreenCaptureAccess() else { throw BridgeError("SCREEN_RECORDING_REQUIRED: Enable Screen Recording for the host launching the bridge. No permission settings were changed.") }
    let expectedFrame = try frame(window)
    var content: SCShareableContent?; var captureError: Error?; var done = false
    SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { value, error in
        DispatchQueue.main.async { content = value; captureError = error; done = true }
    }
    guard waitUntil({ done }, seconds: 15), let content else { throw BridgeError("SCREENSHOT_UNAVAILABLE: \(captureError?.localizedDescription ?? "Window discovery timed out")") }
    let matches = content.windows.filter { $0.owningApplication?.processID == pid && $0.title == title &&
        abs($0.frame.minX - expectedFrame.minX) < 2 && abs($0.frame.minY - expectedFrame.minY) < 2 &&
        abs($0.frame.width - expectedFrame.width) < 2 && abs($0.frame.height - expectedFrame.height) < 2 }
    guard matches.count == 1 else { throw BridgeError("SCREENSHOT_WINDOW_AMBIGUOUS: Cannot identify exactly the requested board window.") }
    let filter = SCContentFilter(desktopIndependentWindow: matches[0])
    let config = SCStreamConfiguration()
    let scale = min(1, 1600 / max(expectedFrame.width, expectedFrame.height))
    config.width = max(1, Int(expectedFrame.width * scale)); config.height = max(1, Int(expectedFrame.height * scale))
    config.showsCursor = false; config.ignoreShadowsSingleWindow = true
    let (current, _) = try boardWindow(app, title: title)
    guard CFEqual(current, window), try frame(window) == expectedFrame else { throw BridgeError("BOARD_CHANGED") }
    var captured: CGImage?; done = false; captureError = nil
    SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) { image, error in
        DispatchQueue.main.async { captured = image; captureError = error; done = true }
    }
    guard waitUntil({ done }, seconds: 15), let captured else { throw BridgeError("SCREENSHOT_FAILED: \(captureError?.localizedDescription ?? "Capture timed out")") }
    let (final, _) = try boardWindow(app, title: title)
    guard CFEqual(final, window), try frame(window) == expectedFrame else { throw BridgeError("BOARD_CHANGED: Screenshot discarded.") }
    guard let png = NSBitmapImageRep(cgImage: captured).representation(using: .png, properties: [:]), png.count <= 8_000_000 else { throw BridgeError("SCREENSHOT_ENCODING_FAILED") }
    return ["ok": true, "boardTitle": title, "mimeType": "image/png", "imageBase64": png.base64EncodedString(), "width": captured.width, "height": captured.height, "scope": "visible board window", "clipboardUsed": false]
}

var transaction: ClipboardTransaction?
var mayHaveInserted = false
var mayHaveChanged = false
var lockDescriptor: Int32 = -1
defer { if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 8_000_000, let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let command = request["command"] as? String else { throw BridgeError("INVALID_REQUEST") }
    let trusted = AXIsProcessTrusted()
    let running = runningApp()
    if command == "status" {
        var result: [String: Any] = ["ok": true, "accessibilityTrusted": trusted, "running": running != nil,
            "clipboardType": contentType.rawValue, "requiresEnglishMenus": true,
            "bridgeClipboardWritesLocalOnly": true, "freeformCopyLocalOnlyGuaranteed": false]
        if trusted, let running {
            let app = AXUIElementCreateApplication(running.processIdentifier)
            if let window = focusedWindow(app) {
                result["boardTitle"] = string(window, kAXTitleAttribute)
                if let area = canvas(window) { result["canvasObjectCount"] = layoutItems(area).count }
            }
        }
        emit(result)
        exit(0)
    }
    guard ["insert", "readSelection", "createBoard", "renameBoard", "openBoard", "listObjects", "moveObject", "undo", "screenshot", "arrangeObjects"].contains(command) else { throw BridgeError("UNKNOWN_COMMAND") }
    guard trusted else { throw BridgeError("ACCESSIBILITY_REQUIRED: Grant Accessibility to the host launching this helper in System Settings, then retry. This helper does not request or change permissions.") }
    guard let running else { throw BridgeError("FREEFORM_NOT_RUNNING: Open Freeform and the intended board first.") }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 3)
    let lockPath = NSTemporaryDirectory() + "freeform-bridge-\(getuid()).lock"
    lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else {
        throw BridgeError("BRIDGE_BUSY: Another bridge operation owns the clipboard. Try again after it completes.")
    }
    if command != "listObjects" {
        running.activate()
        guard waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier }) else { throw BridgeError("APP_NOT_FRONTMOST") }
        waitForUI()
    }
    if command == "createBoard" || command == "renameBoard" || command == "openBoard" {
        guard let title = request["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError("BOARD_TITLE_REQUIRED") }
        guard let window = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
        if command == "openBoard" {
            if string(window, kAXTitleAttribute) == title, canvas(window) != nil {
                emit(["ok": true, "boardTitle": title, "opened": true]); exit(0)
            }
            if canvas(window) != nil { try pressButton(window, title: "Go Back") }
            guard waitUntil({ focusedWindow(app).map { canvas($0) == nil } ?? false }), let library = focusedWindow(app) else { throw BridgeError("LIBRARY_UNAVAILABLE") }
            let matches = descendants(library).filter {
                string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXDescriptionAttribute) ?? "").hasPrefix("Board: " + title + ", ")
            }
            guard matches.count == 1 else { throw BridgeError("BOARD_NOT_UNIQUE: Expected one visible board matching the exact title; found \(matches.count).") }
            // Library board cards may expose no usable Press action despite being interactive.
            let press = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
            if press != .success { try clickElement(matches[0], pid: running.processIdentifier, clicks: 2) }
            guard waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == title && canvas($0) != nil } ?? false }) else { throw BridgeError("OPEN_UNVERIFIED") }
            emit(["ok": true, "boardTitle": title, "opened": true]); exit(0)
        }
        var created = window
        if command == "createBoard" {
            let previousTitle = string(window, kAXTitleAttribute)
            mayHaveChanged = true
            try pressButton(window, title: "New Board")
            guard waitUntil({
                guard let current = focusedWindow(app), let area = canvas(current) else { return false }
                return (!CFEqual(current, window) || string(current, kAXTitleAttribute) != previousTitle) && layoutItems(area).isEmpty
            }), let newWindow = focusedWindow(app) else { throw BridgeError("CREATE_UNVERIFIED: Inspect Freeform before retrying.") }
            created = newWindow
        } else {
            guard let expected = request["expectedBoardTitle"] as? String,
                  string(window, kAXTitleAttribute) == expected, canvas(window) != nil else { throw BridgeError("BOARD_MISMATCH") }
        }
        guard let toolbar = descendants(created).first(where: { string($0, kAXRoleAttribute) == "AXToolbar" }) else { throw BridgeError("RENAME_UNSUPPORTED: No toolbar.") }
        var field = descendants(toolbar).first { string($0, kAXRoleAttribute) == "AXTextField" }
        if field == nil {
            guard let name = descendants(toolbar).first(where: {
                string($0, kAXRoleAttribute) == "AXStaticText" && (string($0, kAXValueAttribute) == string(created, kAXTitleAttribute) || string($0, kAXTitleAttribute) == string(created, kAXTitleAttribute))
            }) else { throw BridgeError("RENAME_UNSUPPORTED: Title control not found.") }
            _ = AXUIElementPerformAction(name, kAXPressAction as CFString)
            let editorReady = waitUntil({ field = descendants(toolbar).first { string($0, kAXRoleAttribute) == "AXTextField" }; return field != nil }, seconds: 0.5)
            if !editorReady { try clickElement(name, pid: running.processIdentifier) }
        }
        guard waitUntil({ field = descendants(toolbar).first { string($0, kAXRoleAttribute) == "AXTextField" }; return field != nil }), let field else { throw BridgeError("RENAME_UNSUPPORTED: No title editor.") }
        mayHaveChanged = true
        guard AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, title as CFString) == .success else { throw BridgeError("RENAME_FAILED") }
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let confirm = AXUIElementPerformAction(field, "AXConfirm" as CFString)
        if confirm != .success {
            try key(running.processIdentifier, 36)
        }
        guard waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == title } ?? false }) else { throw BridgeError("RENAME_UNVERIFIED") }
        if let current = focusedWindow(app), let area = canvas(current) {
            _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        emit(["ok": true, "boardTitle": title, "created": command == "createBoard", "renamed": true, "syncVerified": false])
        exit(0)
    }
    guard let title = request["expectedBoardTitle"] as? String, !title.isEmpty else { throw BridgeError("BOARD_TITLE_REQUIRED") }
    if command == "listObjects" {
        let (_, area) = try boardWindow(app, title: title)
        emit(["ok": true, "boardTitle": title, "objects": objectList(area), "snapshotToken": try snapshot(area)])
        exit(0)
    }
    if command == "screenshot" {
        let (window, _) = try boardWindow(app, title: title)
        emit(try screenshot(app, window: window, title: title, pid: running.processIdentifier)); exit(0)
    }
    if command == "arrangeObjects" {
        let (window, area) = try requireBoard(app, title: title)
        guard let action = request["action"] as? String,
              ["group", "ungroup", "left", "center", "right", "top", "middle", "bottom"].contains(action),
              let expected = request["expectedSnapshot"] as? String,
              let requested = request["targets"] as? [[String: Any]],
              (action == "ungroup" ? requested.count == 1 : (2...100).contains(requested.count)) else { throw BridgeError("INVALID_ARRANGEMENT") }
        guard try snapshot(area) == expected else { throw BridgeError("STALE_BOARD: Read objects again before arranging.") }
        let all = layoutItems(area)
        var indices = Set<Int>()
        let targets = try requested.map { target -> AXUIElement in
            guard let index = target["objectIndex"] as? Int, all.indices.contains(index), indices.insert(index).inserted,
                  let description = target["expectedDescription"] as? String, !description.isEmpty,
                  objectDescription(all[index]) == description,
                  all.filter({ objectDescription($0) == description }).count == 1 else { throw BridgeError("STALE_OR_AMBIGUOUS_OBJECT: Targets require unique current descriptions.") }
            return all[index]
        }
        let untouched = all.filter { item in !targets.contains { CFEqual(item, $0) } }
        let untouchedFrames = try untouched.map { try frame($0) }
        try selectTargets(targets, area: area, app: app, window: window, title: title, pid: running.processIdentifier)
        let clip = try ClipboardTransaction(); transaction = clip
        let before = try clip.copiedObjects(app: app, window: window, title: title)
        guard before.count == targets.count else { throw BridgeError("SELECTION_UNVERIFIED") }
        func plainShapes(_ objects: [[String: Any]]) -> Bool {
            objects.allSatisfy { object in
                guard object["type_identifier"] as? String == "com.apple.apps.content-language.shape",
                      let g = object["geometry"] as? [String: Any] else { return false }
                return (g["angle"] as? Double ?? 0) == 0 && (g["flip_horizontally"] as? Bool ?? false) == false
            }
        }
        var groupChildren: [[String: Any]] = []
        if action == "ungroup" {
            guard before.count == 1, before[0]["type_identifier"] as? String == "com.apple.apps.content-language.group",
                  let wrappers = before[0]["children"] as? [[String: Any]],
                  let g = before[0]["geometry"] as? [String: Any], (g["angle"] as? Double ?? 0) == 0,
                  (g["flip_horizontally"] as? Bool ?? false) == false else { throw BridgeError("UNSUPPORTED_OBJECT: Select one unrotated group of shapes.") }
            groupChildren = wrappers.compactMap { $0["shape"] as? [String: Any] }
            guard (2...100).contains(groupChildren.count), groupChildren.count == wrappers.count, plainShapes(groupChildren) else { throw BridgeError("UNSUPPORTED_OBJECT: Nested groups and non-shape children are not supported yet.") }
        } else {
            guard plainShapes(before) else { throw BridgeError("UNSUPPORTED_OBJECT: This version arranges only unrotated, unflipped shapes.") }
        }
        let item = try arrangementItem(app, action: action)
        let (current, _) = try requireBoard(app, title: title)
        guard CFEqual(window, current), try snapshot(area) == expected, selectionMatches(area, targets),
              clip.board.changeCount == clip.expected else { throw BridgeError("STATE_CHANGED: Arrangement cancelled before dispatch.") }
        mayHaveChanged = true
        if action == "group" || action == "ungroup" {
            try key(running.processIdentifier, 5, modifiers: action == "group" ? [.maskCommand, .maskAlternate] : [.maskCommand, .maskAlternate, .maskShift])
        } else {
            guard AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { throw BridgeError("ARRANGE_DISPATCH_FAILED") }
            waitForUI()
            try key(running.processIdentifier, 53)
        }
        let expectedCount = action == "group" ? all.count - targets.count + 1 : action == "ungroup" ? all.count - 1 + groupChildren.count : all.count
        guard waitUntil({ layoutItems(area).count == expectedCount }) else { throw BridgeError("ARRANGE_UNVERIFIED: Unexpected object count; inspect before retrying.") }
        let remaining = layoutItems(area)
        for (index, other) in untouched.enumerated() {
            guard remaining.contains(where: { CFEqual($0, other) }), try frame(other) == untouchedFrames[index] else { throw BridgeError("ARRANGE_UNVERIFIED: An unrequested object changed.") }
        }
        let resultTargets = action == "group" || action == "ungroup" ? remaining.filter { item in !untouched.contains { CFEqual(item, $0) } } : targets
        try selectTargets(resultTargets, area: area, app: app, window: window, title: title, pid: running.processIdentifier)
        let after = try clip.copiedObjects(app: app, window: window, title: title)
        let restored = clip.restore(); transaction = nil
        emit(["ok": true, "boardTitle": title, "action": action, "before": before, "after": after,
              "clipboardRestored": restored, "objects": objectList(area), "snapshotToken": try snapshot(area), "mayHaveChanged": true])
        exit(0)
    }
    if command == "moveObject" {
        let (window, area) = try requireBoard(app, title: title)
        guard let index = request["objectIndex"] as? Int, let description = request["expectedDescription"] as? String,
              let dx = request["dx"] as? Int, let dy = request["dy"] as? Int,
              (-100...100).contains(dx), (-100...100).contains(dy), dx != 0 || dy != 0 else { throw BridgeError("INVALID_MOVE") }
        let items = layoutItems(area)
        guard items.indices.contains(index), objectDescription(items[index]) == description else { throw BridgeError("STALE_OBJECT: Read the objects again before moving.") }
        try selectOnly(items[index], area: area)
        let clip = try ClipboardTransaction(); transaction = clip
        let before = try clip.copiedObjects(app: app, window: window, title: title)
        guard before.count == 1 else { throw BridgeError("SELECTION_UNVERIFIED") }
        for (count, code) in [(dx, CGKeyCode(dx < 0 ? 123 : 124)), (dy, CGKeyCode(dy < 0 ? 126 : 125))] {
            for _ in 0..<abs(count) {
                _ = try requireBoard(app, title: title)
                guard (attribute(items[index], kAXSelectedAttribute) as? Bool) == true else { throw BridgeError("SELECTION_CHANGED") }
                mayHaveChanged = true
                try key(running.processIdentifier, code)
            }
        }
        let after = try clip.copiedObjects(app: app, window: window, title: title)
        guard after.count == 1,
              let oldGeometry = before[0]["geometry"] as? [String: Any], let newGeometry = after[0]["geometry"] as? [String: Any],
              let oldPosition = oldGeometry["position"] as? [String: Any], let newPosition = newGeometry["position"] as? [String: Any],
              let oldX = oldPosition["x"] as? Double, let oldY = oldPosition["y"] as? Double,
              let newX = newPosition["x"] as? Double, let newY = newPosition["y"] as? Double,
              abs(newX - oldX - Double(dx)) < 0.0001, abs(newY - oldY - Double(dy)) < 0.0001 else { throw BridgeError("MOVE_UNVERIFIED: The requested position change was not confirmed. Inspect the board before retrying.") }
        let restored = clip.restore(); transaction = nil
        emit(["ok": true, "boardTitle": title, "before": before, "after": after, "dx": dx, "dy": dy, "clipboardRestored": restored, "objects": objectList(area)])
        exit(0)
    }
    if command == "undo" {
        let (window, _) = try requireBoard(app, title: title)
        let action = "Undo"
        try menuAction(app, title: action, expectedWindow: window, boardTitle: title, beforePress: { mayHaveChanged = true })
        emit(["ok": true, "boardTitle": title, "action": action, "requested": true, "verified": false, "note": "Read the board afterward to verify Undo; command acceptance alone does not prove a change."])
        exit(0)
    }
    let (initialWindow, initialCanvas) = try requireBoard(app, title: title)
    let fitAfterPaste = request["fitAfterPaste"] as? Bool == true
    if command == "insert", fitAfterPaste {
        try key(running.processIdentifier, 29, modifiers: [.maskCommand, .maskAlternate, .maskShift])
        waitForUI()
    }
    if command == "readSelection", request["selectAll"] as? Bool == true {
        try menuAction(app, title: "Select All", expectedWindow: initialWindow, boardTitle: title)
        _ = waitUntil({ layoutItems(initialCanvas).contains { (attribute($0, kAXSelectedAttribute) as? Bool) == true } })
    }
    let initialItems = layoutItems(initialCanvas)
    let before = initialItems.count
    var payload: [[String: Any]] = []
    if command == "insert" {
        guard let objects = request["objects"] as? [[String: Any]], (1...(fitAfterPaste ? 1000 : 100)).contains(objects.count) else { throw BridgeError("INVALID_OBJECTS") }
        payload = objects
    } else {
        guard layoutItems(initialCanvas).contains(where: { (attribute($0, kAXSelectedAttribute) as? Bool) == true }) else {
            throw BridgeError("NO_SELECTION: Select objects on the board first.")
        }
    }
    let clip = try ClipboardTransaction()
    transaction = clip
    if command == "insert" {
        running.activate()
        guard waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier }) else { throw BridgeError("APP_NOT_FRONTMOST") }
        try clip.put(JSONSerialization.data(withJSONObject: payload))
        _ = try requireBoard(app, title: title)
        try menuAction(app, title: "Paste", expectedWindow: initialWindow, boardTitle: title, beforePress: {
            guard clip.board.changeCount == clip.expected else { throw BridgeError("CLIPBOARD_CHANGED: Clipboard changed before Paste.") }
            mayHaveInserted = true
        })
        if fitAfterPaste {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            _ = try boardWindow(app, title: title)
            try key(running.processIdentifier, 29, modifiers: [.maskCommand, .maskAlternate, .maskShift])
        }
        guard waitUntil({
            guard let window = focusedWindow(app), let area = canvas(window) else { return false }
            return layoutItems(area).count == before + payload.count
        }, seconds: 15) else { throw BridgeError("INSERT_UNVERIFIED: Expected object count was not observed. Inspect the board before retrying.") }
        let (_, area) = try boardWindow(app, title: title)
        let added = layoutItems(area).filter { item in !initialItems.contains { CFEqual($0, item) } }
        guard added.count == payload.count else { throw BridgeError("INSERT_UNVERIFIED: New object identities could not be isolated. Inspect before retrying.") }
        func insertedSelectionMatches() -> Bool {
            let selected = layoutItems(area).filter { (attribute($0, kAXSelectedAttribute) as? Bool) == true }
            return selected.count == added.count && selected.allSatisfy { item in added.contains { CFEqual($0, item) } }
        }
        if !insertedSelectionMatches() {
            _ = AXUIElementSetAttributeValue(area, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            let selectionResult = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, added as CFArray)
            if selectionResult != .success, added.count == 1 {
                try selectOnly(added[0], area: area)
            }
        }
        if !waitUntil(insertedSelectionMatches, seconds: 0.5) {
            if initialItems.isEmpty {
                try menuAction(app, title: "Select All", expectedWindow: initialWindow, boardTitle: title)
            } else {
                // Some Freeform builds accept SelectedChildren but retain only its last item.
                // Rebuild selection through ordinary clicks; never repeat the paste.
                for (offset, item) in added.enumerated() {
                    let (current, _) = try boardWindow(app, title: title)
                    guard CFEqual(current, initialWindow) else { throw BridgeError("BOARD_CHANGED") }
                    try clickElement(item, pid: running.processIdentifier, modifiers: offset == 0 ? [] : .maskShift)
                }
            }
        }
        guard waitUntil(insertedSelectionMatches) else { throw BridgeError("INSERT_UNVERIFIED: Could not select exactly the inserted objects. Inspect before retrying.") }
    }
    let (_, finalCanvas) = try requireBoard(app, title: title)
    let objects = try clip.copiedObjects(app: app, window: initialWindow, title: title)
    if command == "insert", objects.count != payload.count {
        throw BridgeError("INSERT_UNVERIFIED: Readback object count does not match the request. Inspect the board before retrying.")
    }
    let restored = clip.restore()
    transaction = nil
    emit(["ok": true, "boardTitle": title, "objects": objects, "selectedObjectCount": objects.count,
          "canvasObjectCount": layoutItems(finalCanvas).count, "clipboardRestored": restored,
          "inserted": command == "insert", "insertedCount": command == "insert" ? payload.count : 0])
} catch {
    let restored = transaction?.restore()
    var result: [String: Any] = ["ok": false, "error": String(describing: error), "mayHaveInserted": mayHaveInserted, "mayHaveChanged": mayHaveChanged]
    if let restored { result["clipboardRestored"] = restored }
    emit(result)
    exit(1)
}
