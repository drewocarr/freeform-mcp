// Background helper: edits the regular Freeform app while another app stays frontmost.
// build-background.mjs appends this file to the declarations in FreeformBridge.swift.
// It never activates Freeform, clicks, or posts global keyboard events: only Accessibility
// actions and events addressed to Freeform's process. Each result reports whether Freeform
// activated, whether its window rose above the user's window, and whether the clipboard was used.

_ = NSApplication.shared.setActivationPolicy(.prohibited)

let pickerShapes = ["square": "Square", "circle": "Circle", "roundedRectangle": "Rounded Rectangle", "diamond": "Diamond",
                    "triangle": "Triangle", "parallelogram": "Parallelogram", "pentagon": "Pentagon", "terminator": "Terminator", "arrow": "Arrow"]
let swatches = ["black", "gray", "white", "cyan", "magenta pink", "dark indigo", "red", "orange", "light amber", "green", "teal", "blue"]
let connectionStyles = ["straight": "Straight Connection Type", "corner": "Corner Connection Type", "curve": "Curve Connection Type"]
let arrowheads = ["simple": "Simple arrow", "filled": "Filled arrow", "open": "Open arrow"]
let lineEndOrder = ["None", "Simple arrow", "Filled circle", "Open arrow", "Filled arrow", "Open circle", "Line", ""]

func pause(seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func axPoint(_ element: AXUIElement, _ point: CGPoint) -> AXError {
    var p = point
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &p)!)
}
func rect(_ r: CGRect, in area: CGRect) -> [String: Double] {
    ["x": Double(r.minX - area.minX), "y": Double(r.minY - area.minY), "width": Double(r.width), "height": Double(r.height)]
}

/// Tracks the background guarantees for one request.
final class BackgroundSession {
    let pid: pid_t
    let userApp: NSRunningApplication
    var activations: [String] = []
    var windowRaised = false
    var windowRestored: Bool?
    var clipboardUsed = false
    private var observer: NSObjectProtocol?

    private var sampler: Timer?
    init(freeform: NSRunningApplication) throws {
        pid = freeform.processIdentifier
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid else {
            throw BridgeError("FREEFORM_FRONTMOST: Background tools act only while another app is frontmost. Use the regular freeform_* tools instead.")
        }
        userApp = front
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.activations.append((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "unknown")
        }
        // Waits run the run loop, so this samples the window order every 100 ms throughout the request.
        sampler = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.noteWindowOrder() }
    }
    deinit { if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) } }

    var activated: Bool { activations.contains("com.apple.freeform") || NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

    /// Index of Freeform's first on-screen normal window, front to back (0 = above every other window).
    func freeformWindowIndex() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        return normal.firstIndex { ($0[kCGWindowOwnerPID as String] as? Int32) == pid } ?? -1
    }
    func noteWindowOrder() { if freeformWindowIndex() == 0 { windowRaised = true } }

    /// Puts the user's window back above Freeform without activating anything: first by raising the frontmost
    /// app's main window, then, for apps without Accessibility windows, by hiding and unhiding Freeform,
    /// which returns its window just below the frontmost window.
    func restoreWindowOrder() {
        guard freeformWindowIndex() == 0 else { return }
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != pid else { windowRestored = false; return }
        let app = AXUIElementCreateApplication(front.processIdentifier)
        if let raw = attribute(app, kAXMainWindowAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            _ = AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXRaiseAction as CFString)
            if waitUntil({ self.freeformWindowIndex() != 0 }, seconds: 1) { windowRestored = true; return }
        }
        guard let freeform = NSRunningApplication(processIdentifier: pid) else { windowRestored = false; return }
        _ = freeform.hide()
        _ = waitUntil({ freeform.isHidden }, seconds: 1)
        _ = freeform.unhide()
        _ = waitUntil({ !freeform.isHidden }, seconds: 1)
        windowRestored = waitUntil({ self.freeformWindowIndex() > 0 }, seconds: 1) && !activated
    }

    /// Sends a key to Freeform's process only, never to the focused app.
    func key(_ code: CGKeyCode) throws {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { throw BridgeError("FREEFORM_ACTIVATED: Stopped to avoid sending keys to the user's foreground.") }
        let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
        let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
        down.postToPid(pid); pause(seconds: 0.05); up.postToPid(pid); pause(seconds: 0.3)
    }
    /// Types text into Freeform's process in chunks of at most 20 UTF-16 units, without splitting characters.
    func type(_ text: String) throws {
        var chunks: [[UInt16]] = [[]]
        for character in text {
            let units = Array(String(character).utf16)
            if chunks[chunks.count - 1].count + units.count > 20 { chunks.append([]) }
            chunks[chunks.count - 1] += units
        }
        for chunk in chunks where !chunk.isEmpty {
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier != pid else { throw BridgeError("FREEFORM_ACTIVATED: Stopped typing.") }
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
            chunk.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress!) }
            down.postToPid(pid); pause(seconds: 0.05); up.postToPid(pid); pause(seconds: 0.1)
        }
        pause(seconds: 0.4)
    }
    func report() -> [String: Any] {
        noteWindowOrder()
        return ["activated": activated, "windowRaised": windowRaised, "windowRestored": windowRestored as Any? ?? NSNull(),
                "clipboardUsed": clipboardUsed, "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
    }
}

/// One board, found by exact title in Freeform's focused window, with no foreground requirement.
struct Board {
    let app: AXUIElement
    let window: AXUIElement
    let area: AXUIElement
    init(app: AXUIElement, title: String) throws {
        (window, area) = try boardWindow(app, title: title)
        self.app = app
    }
    var items: [AXUIElement] { layoutItems(area) }
    /// The visible viewport: the scroll area around the (much larger) layout area.
    var areaFrame: CGRect {
        if let raw = attribute(area, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let parent = unsafeBitCast(raw, to: AXUIElement.self)
            if string(parent, kAXRoleAttribute) == "AXScrollArea", let f = try? frame(parent) { return f }
        }
        return (try? frame(area)) ?? .zero
    }
    func objects() -> [[String: Any]] {
        let origin = areaFrame
        return items.enumerated().map { index, item in
            var entry: [String: Any] = ["objectIndex": index, "description": objectDescription(item), "selected": (attribute(item, kAXSelectedAttribute) as? Bool) ?? false]
            if let f = try? frame(item) { entry["frame"] = rect(f, in: origin) }
            return entry
        }
    }
    func select(_ targets: [AXUIElement]) throws {
        _ = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, targets as CFArray)
        guard waitUntil({ selectionMatches(area, targets) }, seconds: 2) else { throw BridgeError("SELECTION_UNVERIFIED: Could not select exactly the requested object.") }
    }
    /// Resolves a target from a fresh listing: the snapshot must still match and the index must carry the expected description.
    func target(_ request: [String: Any], key: String? = nil) throws -> AXUIElement {
        let spec = key.flatMap { request[$0] as? [String: Any] } ?? request
        guard let index = spec["objectIndex"] as? Int, let description = spec["expectedDescription"] as? String else { throw BridgeError("INVALID_TARGET") }
        let all = items
        guard all.indices.contains(index), objectDescription(all[index]) == description else { throw BridgeError("STALE_TARGET: List objects again before editing.") }
        return all[index]
    }
    func popover() -> AXUIElement? { descendants(app, depth: 25).first { string($0, kAXRoleAttribute) == "AXPopover" } }
}

func requireSnapshot(_ board: Board, _ request: [String: Any]) throws -> String {
    guard let expected = request["expectedSnapshot"] as? String else { throw BridgeError("SNAPSHOT_REQUIRED") }
    guard try snapshot(board.area) == expected else { throw BridgeError("STALE_BOARD: The board changed. List objects again before editing.") }
    return expected
}

/// Inserts one object from the toolbar (text box, sticky note) or the shape picker, and returns it.
func insertObject(_ board: Board, _ session: BackgroundSession, kind: String) throws -> AXUIElement {
    let before = board.items
    if kind == "textBox" || kind == "stickyNote" {
        try pressButton(board.window, title: kind == "textBox" ? "Insert Text Box" : "Insert Sticky Note")
    } else {
        guard let name = pickerShapes[kind] ?? (kind == "connectionLine" ? "Connection Line" : nil) else { throw BridgeError("UNSUPPORTED_SHAPE") }
        func pickerButton() -> AXUIElement? {
            board.popover().flatMap { descendants($0).first { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXTitleAttribute) == name || objectDescription($0) == name) } }
        }
        if pickerButton() == nil {
            if let stale = board.popover() { _ = AXUIElementPerformAction(stale, kAXCancelAction as CFString); pause(seconds: 0.3) }
            try pressButton(board.window, title: "Insert Shape")
        }
        // The picker can appear before its shape buttons load, especially on a new board.
        guard waitUntil({ pickerButton() != nil }, seconds: 4), let button = pickerButton() else { throw BridgeError("NO_SHAPE_PICKER: \(name) unavailable.") }
        _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
    guard waitUntil({ board.items.count == before.count + 1 }, seconds: 4) else { throw BridgeError("INSERT_UNVERIFIED: Inspect the board before retrying.") }
    let added = board.items.filter { item in !before.contains { CFEqual($0, item) } }
    guard added.count == 1 else { throw BridgeError("INSERT_UNVERIFIED: Inspect the board before retrying.") }
    return added[0]
}

func resize(_ board: Board, _ item: AXUIElement, width: Double?, height: Double?) throws {
    guard width != nil || height != nil else { return }
    try board.select([item])
    let old = try frame(item)
    let dw = (width ?? Double(old.width)) - Double(old.width), dh = (height ?? Double(old.height)) - Double(old.height)
    guard abs(dw) >= 0.5 || abs(dh) >= 0.5 else { return }
    guard let handles = attribute(item, "AXHandles") as? [AXUIElement],
          let handle = handles.first(where: { objectDescription($0).hasPrefix("Lower right") }) else { throw BridgeError("RESIZE_UNAVAILABLE: No lower-right handle for this object.") }
    let h = try frame(handle)
    _ = axPoint(handle, CGPoint(x: h.minX + dw, y: h.minY + dh))
    guard waitUntil({ (try? frame(item)).map { abs(Double($0.width) - Double(old.width) - dw) < 1 && abs(Double($0.height) - Double(old.height) - dh) < 1 } ?? false }, seconds: 2)
    else { throw BridgeError("RESIZE_UNVERIFIED: The object may have been resized partially; inspect before retrying.") }
}

func move(_ board: Board, _ item: AXUIElement, x: Double?, y: Double?) throws {
    guard x != nil || y != nil else { return }
    try board.select([item])
    let origin = board.areaFrame, old = try frame(item)
    let target = CGPoint(x: x.map { origin.minX + $0 } ?? old.minX, y: y.map { origin.minY + $0 } ?? old.minY)
    _ = axPoint(item, target)
    guard waitUntil({ (try? frame(item)).map { abs($0.minX - target.x) < 1 && abs($0.minY - target.y) < 1 } ?? false }, seconds: 2)
    else { throw BridgeError("MOVE_UNVERIFIED: Inspect the board before retrying.") }
}

/// Replaces an object's label by typing into the selected object, then ends editing.
/// Retries once only when no object's text changed at all, so a retry cannot duplicate text.
func setText(_ board: Board, _ session: BackgroundSession, _ item: AXUIElement, _ text: String) throws {
    let matches = { objectDescription(item).hasPrefix(text + ", ") || objectDescription(item) == text }
    for attempt in 0..<2 {
        let before = board.items.map(objectDescription)
        try board.select([item])
        pause(seconds: 0.4)
        try session.type(text)
        try session.key(53)
        if waitUntil(matches, seconds: 2) { return }
        let after = board.items.map(objectDescription)
        guard attempt == 0, after == before else {
            throw BridgeError("TEXT_UNVERIFIED: Label is now \"\(objectDescription(item))\"\(after == before ? "" : "; another object's text changed"). Inspect before retrying.")
        }
    }
}

/// Opens the selected object's format bar and one inspector popover. Returns the inspector button.
func openInspector(_ board: Board, _ item: AXUIElement, _ name: String) throws -> AXUIElement {
    try board.select([item])
    func inspectorButton() -> AXUIElement? { descendants(board.app, depth: 25).first { string($0, kAXRoleAttribute) == "AXButton" && objectDescription($0) == name } }
    // "Show format options" toggles the format bar, so invoke it only when the bar is not already showing.
    if inspectorButton() == nil {
        var actions: CFArray?; AXUIElementCopyActionNames(item, &actions)
        guard let show = ((actions as? [String]) ?? []).first(where: { $0.hasPrefix("Name:Show format options") }) else { throw BridgeError("FORMAT_UNAVAILABLE") }
        _ = AXUIElementPerformAction(item, show as CFString)
    }
    var button: AXUIElement?
    guard waitUntil({ button = inspectorButton(); return button != nil }, seconds: 2), let button
    else { throw BridgeError("INSPECTOR_UNAVAILABLE: \(name)") }
    _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
    guard waitUntil({ board.popover() != nil }, seconds: 2) else { throw BridgeError("INSPECTOR_UNAVAILABLE: \(name)") }
    // The popover appears before its controls finish loading; early elements are replaced.
    pause(seconds: 1)
    return button
}
func closeInspector(_ board: Board, _ session: BackgroundSession) throws {
    if let popover = board.popover() { _ = AXUIElementPerformAction(popover, kAXCancelAction as CFString) }
    try session.key(53)
}

func setFill(_ board: Board, _ session: BackgroundSession, _ item: AXUIElement, _ color: String) throws {
    guard swatches.contains(color) else { throw BridgeError("UNSUPPORTED_COLOR") }
    let inspector = try openInspector(board, item, "Fill Inspector")
    defer { try? closeInspector(board, session) }
    guard let popover = board.popover(), let swatch = descendants(popover).first(where: { string($0, kAXRoleAttribute) == "AXButton" && objectDescription($0) == color })
    else { throw BridgeError("COLOR_UNAVAILABLE") }
    _ = AXUIElementPerformAction(swatch, kAXPressAction as CFString)
    guard waitUntil({ string(inspector, kAXValueAttribute) == color }, seconds: 2) else { throw BridgeError("FILL_UNVERIFIED: Inspect before retrying.") }
}

/// Sets a connection line's style (hidden) and, optionally, its head arrowhead (pop-up menu: raises the window).
func styleConnector(_ board: Board, _ s: BackgroundSession, _ line: AXUIElement, style: String?, arrowhead: String) throws {
    if let style {
        let styleWord = style == "curve" ? "curved" : style
        if !objectDescription(line).contains(styleWord) {
            _ = try openInspector(board, line, "Connection Line Style Inspector")
            if let popover = board.popover(), let segment = descendants(popover).first(where: { objectDescription($0) == connectionStyles[style]! }) {
                _ = AXUIElementPerformAction(segment, kAXPressAction as CFString)
            }
            try closeInspector(board, s)
            guard waitUntil({ objectDescription(line).contains(styleWord) }, seconds: 2) else { throw BridgeError("STYLE_UNVERIFIED: Connector attached but its style is \(objectDescription(line)).") }
        }
    }
    if let item = arrowheads[arrowhead] {
        _ = try openInspector(board, line, "Line Ends Inspector")
        let popups = board.popover().map { descendants($0).filter { string($0, kAXRoleAttribute) == "AXPopUpButton" } } ?? []
        guard popups.count >= 2 else { try closeInspector(board, s); throw BridgeError("ARROWHEAD_UNAVAILABLE") }
        _ = AXUIElementPerformAction(popups[1], kAXPressAction as CFString)
        pause(seconds: 0.5)
        var choice: AXUIElement?
        var seen: [String] = []
        _ = waitUntil({
            let items = descendants(popups[1], depth: 4).filter { string($0, kAXRoleAttribute) == "AXMenuItem" }
            seen = items.map { string($0, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? objectDescription($0) }
            choice = items.first { string($0, kAXTitleAttribute) == item || objectDescription($0) == item }
            // Item titles can stay blank until the menu renders; fall back to the observed fixed order.
            // The "End: …" check below rejects a wrong pick.
            if choice == nil, items.count == lineEndOrder.count, seen.allSatisfy({ $0.isEmpty }), let index = lineEndOrder.firstIndex(of: item) {
                choice = items[index]
            }
            return choice != nil
        }, seconds: 3)
        let structure = descendants(popups[1], depth: 4).map { "\(string($0, kAXRoleAttribute) ?? "?"):\(string($0, kAXTitleAttribute) ?? "")" }
        s.noteWindowOrder()
        if let choice { _ = AXUIElementPerformAction(choice, kAXPressAction as CFString) }
        let applied = waitUntil({ objectDescription(line).contains("End: " + item) }, seconds: 3)
        try closeInspector(board, s)
        s.noteWindowOrder(); s.restoreWindowOrder()
        guard applied else { throw BridgeError("ARROWHEAD_UNVERIFIED: Connector attached; arrowhead not confirmed (\(objectDescription(line))). Menu items seen: \(seen). Pop-ups: \(popups.map { string($0, kAXValueAttribute) ?? "?" }). Under pressed pop-up: \(structure).") }
    }

}

func describe(_ board: Board, _ item: AXUIElement) -> [String: Any] {
    let all = board.items
    var result: [String: Any] = ["description": objectDescription(item), "objectIndex": all.firstIndex { CFEqual($0, item) } ?? -1]
    if let f = try? frame(item) { result["frame"] = rect(f, in: board.areaFrame) }
    return result
}

var lockDescriptor: Int32 = -1
var session: BackgroundSession?
var mayHaveChanged = false
defer { if lockDescriptor >= 0 { flock(lockDescriptor, LOCK_UN); close(lockDescriptor) } }
do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 1_000_000, let request = try JSONSerialization.jsonObject(with: input) as? [String: Any],
          let command = request["command"] as? String else { throw BridgeError("INVALID_REQUEST") }
    let trusted = AXIsProcessTrusted()
    let running = runningApp()
    if command == "status" {
        var result: [String: Any] = ["ok": true, "accessibilityTrusted": trusted, "running": running != nil,
                                     "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
        if let running {
            result["freeformFrontmost"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == running.processIdentifier
            if trusted, let window = focusedWindow(AXUIElementCreateApplication(running.processIdentifier)) {
                result["boardTitle"] = string(window, kAXTitleAttribute)
                if let area = canvas(window) { result["canvasObjectCount"] = layoutItems(area).count }
            }
        }
        emit(result); exit(0)
    }
    let commands = ["listObjects", "screenshot", "openBoard", "createBoard", "renameBoard", "addShape", "updateObject", "connect", "deleteObject"]
    guard commands.contains(command) else { throw BridgeError("UNKNOWN_COMMAND") }
    guard trusted else { throw BridgeError("ACCESSIBILITY_REQUIRED: Grant Accessibility to the host launching this helper. No permissions were changed.") }
    guard let running else { throw BridgeError("FREEFORM_NOT_RUNNING: Open Freeform first; background tools do not launch it.") }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 3)
    // Shares the regular helper's lock so foreground and background operations never overlap.
    let lockPath = NSTemporaryDirectory() + "freeform-bridge-\(getuid()).lock"
    lockDescriptor = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
    guard lockDescriptor >= 0, flock(lockDescriptor, LOCK_EX | LOCK_NB) == 0 else { throw BridgeError("BRIDGE_BUSY: Another Freeform bridge operation is running.") }
    let s = try BackgroundSession(freeform: running); session = s
    func finish(_ result: [String: Any]) -> Never {
        var value = result
        value["ok"] = true
        value["background"] = s.report()
        emit(value); exit(0)
    }
    let allowRaise = request["allowWindowRaise"] as? Bool == true

    if command == "openBoard" || command == "createBoard" || command == "renameBoard" {
        guard let title = request["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError("BOARD_TITLE_REQUIRED") }
        guard let current = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
        func cards(_ name: String) -> [AXUIElement] {
            guard let library = focusedWindow(app), canvas(library) == nil else { return [] }
            return descendants(library).filter { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXDescriptionAttribute) ?? "").hasPrefix("Board: " + name + ", ") }
        }
        func toLibrary() throws {
            // A just-created board can ignore an immediate Go Back, so press again until the library appears.
            for _ in 0..<3 {
                guard let window = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
                if canvas(window) == nil { return }
                try pressButton(window, title: "Go Back")
                if waitUntil({ focusedWindow(app).map { canvas($0) == nil } ?? false }, seconds: 2) { return }
            }
            throw BridgeError("LIBRARY_UNAVAILABLE")
        }
        func open(_ name: String) throws {
            let matches = cards(name)
            guard matches.count == 1 else { throw BridgeError("BOARD_NOT_UNIQUE: Expected one visible board titled \"\(name)\"; found \(matches.count).") }
            _ = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
            guard waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == name && canvas($0) != nil } ?? false }, seconds: 5) else { throw BridgeError("OPEN_UNVERIFIED") }
        }
        if command == "openBoard" {
            if string(current, kAXTitleAttribute) == title, canvas(current) != nil { finish(["boardTitle": title, "opened": true]) }
            try toLibrary(); try open(title)
            finish(["boardTitle": title, "opened": true])
        }
        // Naming needs the board card's context menu, which raises Freeform's window.
        guard allowRaise else { throw BridgeError("WINDOW_RAISE_REQUIRED: Naming a board uses a context menu that raises Freeform's window. Pass allowWindowRaise: true to accept a brief raise; the window order is restored afterward.") }
        try toLibrary()
        guard cards(title).isEmpty else { throw BridgeError("BOARD_EXISTS: A visible board already has this title.") }
        var created: String
        if command == "renameBoard" {
            guard let from = request["fromTitle"] as? String, !from.isEmpty else { throw BridgeError("FROM_TITLE_REQUIRED") }
            created = from
        } else {
            guard let library = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
            mayHaveChanged = true
            try pressButton(library, title: "New Board")
            guard waitUntil({ focusedWindow(app).flatMap { canvas($0) }.map { layoutItems($0).isEmpty } ?? false }, seconds: 5),
                  let name = focusedWindow(app).flatMap({ string($0, kAXTitleAttribute) }) else { throw BridgeError("CREATE_UNVERIFIED: Inspect Freeform before retrying.") }
            created = name
            s.noteWindowOrder()
            // Freeform discards a new board that is still empty when it is left, so keep a placeholder until it is named.
            let fresh = try Board(app: app, title: name)
            // A new board can ignore its first toolbar presses; press again only while nothing has been added.
            pause(seconds: 1)
            var placed = false
            for _ in 0..<3 where !placed {
                try pressButton(fresh.window, title: "Insert Sticky Note")
                placed = waitUntil({ !fresh.items.isEmpty }, seconds: 2)
            }
            guard placed, fresh.items.count == 1 else { throw BridgeError("PLACEHOLDER_UNVERIFIED: Created \"\(name)\" but could not keep it with a placeholder; Freeform discards empty boards.") }
            try s.key(53)
            pause(seconds: 0.5)
            try toLibrary()
        }
        // A new board's card can appear in the library a moment after returning to it.
        _ = waitUntil({ cards(created).count == 1 }, seconds: 5)
        let card = cards(created)
        guard card.count == 1 else { throw BridgeError("RENAME_UNAVAILABLE: Could not find \"\(created)\" uniquely to rename.") }
        mayHaveChanged = true
        var actions: CFArray?; AXUIElementCopyActionNames(card[0], &actions)
        let show = ((actions as? [String]) ?? []).first { $0.hasPrefix("Name:Show Menu") } ?? (kAXShowMenuAction as String)
        _ = AXUIElementPerformAction(card[0], show as CFString)
        // Context menus only: the menu bar's Edit ▸ Rename is disabled in the background and must not match.
        var rename: AXUIElement?
        _ = waitUntil({
            rename = children(app).filter { string($0, kAXRoleAttribute) != "AXMenuBar" }.flatMap { descendants($0, depth: 15) }
                .filter { string($0, kAXRoleAttribute) == "AXMenu" }.flatMap { children($0) }
                .first { string($0, kAXTitleAttribute) == "Rename" && attribute($0, kAXEnabledAttribute) as? Bool == true }
            return rename != nil
        }, seconds: 3)
        s.noteWindowOrder()
        guard let rename else { try? s.key(53); s.restoreWindowOrder(); throw BridgeError("RENAME_UNAVAILABLE: Created \"\(created)\" but its Rename command was not available.") }
        _ = AXUIElementPerformAction(rename, kAXPressAction as CFString)
        var field: AXUIElement?
        guard waitUntil({ field = descendants(app, depth: 20).first { string($0, kAXRoleAttribute) == "AXTextField" && string($0, kAXValueAttribute) == created }; return field != nil }, seconds: 3), let field
        else { try? s.key(53); s.restoreWindowOrder(); throw BridgeError("RENAME_UNAVAILABLE: Created \"\(created)\" but no title editor appeared.") }
        _ = AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, title as CFString)
        if AXUIElementPerformAction(field, "AXConfirm" as CFString) != .success { try s.key(36) }
        guard waitUntil({ cards(title).count == 1 }, seconds: 5) else { s.restoreWindowOrder(); throw BridgeError("RENAME_UNVERIFIED: Created \"\(created)\"; inspect before retrying.") }
        try open(title)
        s.noteWindowOrder(); s.restoreWindowOrder()
        if command == "createBoard" {
            let named = try Board(app: app, title: title)
            guard named.items.count == 1 else { throw BridgeError("PLACEHOLDER_UNVERIFIED: Board \"\(title)\" was created; inspect it before editing.") }
            try named.select(named.items)
            try s.key(51)
            guard waitUntil({ named.items.isEmpty }, seconds: 2) else { throw BridgeError("PLACEHOLDER_REMAINS: Board \"\(title)\" was created with a placeholder circle still on it.") }
        }
        finish(["boardTitle": title, "created": command == "createBoard", "renamedFrom": created, "syncVerified": false,
                "note": command == "createBoard" ? "Freeform discards empty untitled boards when they are left; this board is named, which is expected to keep it." : NSNull()])
    }

    guard let title = request["expectedBoardTitle"] as? String else { throw BridgeError("BOARD_TITLE_REQUIRED") }
    let board = try Board(app: app, title: title)

    if command == "listObjects" {
        let f = board.areaFrame
        finish(["boardTitle": title, "objects": board.objects(), "snapshotToken": try snapshot(board.area),
                "viewport": ["width": Double(f.width), "height": Double(f.height)],
                "coordinates": "Points relative to the top-left of the visible canvas at the current zoom and scroll."])
    }
    if command == "screenshot" {
        var value = try screenshot(app, window: board.window, title: title, pid: running.processIdentifier)
        value.removeValue(forKey: "ok")
        finish(value)
    }
    if command == "addShape" {
        guard let kind = request["shape"] as? String else { throw BridgeError("SHAPE_REQUIRED") }
        let text = request["text"] as? String
        mayHaveChanged = true
        let item = try insertObject(board, s, kind: kind)
        if kind == "textBox" || kind == "stickyNote" {
            // New text boxes and sticky notes start in text editing; type before anything else,
            // because ending editing on an empty text box can discard it.
            if let text {
                pause(seconds: 0.4)
                try s.type(text)
                try s.key(53)
                guard waitUntil({ objectDescription(item).hasPrefix(text + ", ") }, seconds: 2)
                else { throw BridgeError("TEXT_UNVERIFIED: \(kind) label is \"\(objectDescription(item))\". Inspect before retrying.") }
            } else { try s.key(53) }
        } else { try s.key(53) }
        try resize(board, item, width: request["width"] as? Double, height: request["height"] as? Double)
        try move(board, item, x: request["x"] as? Double, y: request["y"] as? Double)
        if let text, kind != "textBox" && kind != "stickyNote" { try setText(board, s, item, text) }
        if let fill = request["fill"] as? String { try setFill(board, s, item, fill) }
        try s.key(53)
        finish(["boardTitle": title, "object": describe(board, item), "snapshotToken": try snapshot(board.area)])
    }
    if command == "updateObject" || command == "deleteObject" {
        _ = try requireSnapshot(board, request)
        let item = try board.target(request)
        mayHaveChanged = true
        if command == "deleteObject" {
            let count = board.items.count
            try board.select([item])
            try s.key(51)
            guard waitUntil({ board.items.count == count - 1 && !board.items.contains { CFEqual($0, item) } }, seconds: 2) else { throw BridgeError("DELETE_UNVERIFIED: Inspect before retrying.") }
            finish(["boardTitle": title, "deleted": true, "snapshotToken": try snapshot(board.area)])
        }
        try resize(board, item, width: request["width"] as? Double, height: request["height"] as? Double)
        try move(board, item, x: request["x"] as? Double, y: request["y"] as? Double)
        if let text = request["text"] as? String { try setText(board, s, item, text) }
        if let fill = request["fill"] as? String { try setFill(board, s, item, fill) }
        let style = request["style"] as? String, head = request["arrowhead"] as? String
        if style != nil || head != nil {
            guard objectDescription(item).hasPrefix("connection line") else { throw BridgeError("NOT_A_CONNECTOR: style and arrowhead apply to connection lines.") }
            guard style.map({ connectionStyles[$0] != nil }) ?? true, head.map({ $0 == "none" || arrowheads[$0] != nil }) ?? true else { throw BridgeError("UNSUPPORTED_STYLE") }
            guard (head ?? "none") == "none" || allowRaise else { throw BridgeError("WINDOW_RAISE_REQUIRED: Arrowheads raise Freeform's window; pass allowWindowRaise: true.") }
            try styleConnector(board, s, item, style: style, arrowhead: head ?? "none")
        }
        try s.key(53)
        finish(["boardTitle": title, "object": describe(board, item), "snapshotToken": try snapshot(board.area)])
    }
    if command == "connect" {
        _ = try requireSnapshot(board, request)
        let from = try board.target(request, key: "from"), to = try board.target(request, key: "to")
        guard !CFEqual(from, to) else { throw BridgeError("SAME_TARGET") }
        let style = request["style"] as? String ?? "straight"
        let head = request["arrowhead"] as? String ?? "none"
        guard let styleName = connectionStyles[style] else { throw BridgeError("UNSUPPORTED_STYLE") }
        guard head == "none" || arrowheads[head] != nil else { throw BridgeError("UNSUPPORTED_ARROWHEAD") }
        guard head == "none" || allowRaise else { throw BridgeError("WINDOW_RAISE_REQUIRED: Arrowheads are set through a pop-up menu that raises Freeform's window. Pass allowWindowRaise: true, or use arrowhead: \"none\".") }
        mayHaveChanged = true
        let line = try insertObject(board, s, kind: "connectionLine")
        try s.key(53)
        try board.select([line])
        guard let handles = attribute(line, "AXHandles") as? [AXUIElement],
              let tail = handles.first(where: { objectDescription($0).hasPrefix("Tail") }), let headHandle = handles.first(where: { objectDescription($0).hasPrefix("Head") })
        else { throw BridgeError("CONNECTOR_UNAVAILABLE: Connection line handles not found; a loose line may remain on the board.") }
        // Attach to the facing edges, 10 points inside each object.
        let a = try frame(from), b = try frame(to)
        let horizontal = abs(b.midX - a.midX) >= abs(b.midY - a.midY)
        func anchor(_ r: CGRect, toward other: CGRect) -> CGPoint {
            horizontal ? CGPoint(x: other.midX > r.midX ? r.maxX - 10 : r.minX + 10, y: r.midY)
                       : CGPoint(x: r.midX, y: other.midY > r.midY ? r.maxY - 10 : r.minY + 10)
        }
        for (handle, point) in [(tail, anchor(a, toward: b)), (headHandle, anchor(b, toward: a))] {
            let h = try frame(handle)
            _ = axPoint(handle, CGPoint(x: point.x - h.width / 2, y: point.y - h.height / 2))
            pause(seconds: 0.5)
        }
        guard waitUntil({ objectDescription(line).contains("Connected from") && objectDescription(line).contains(" to ") }, seconds: 2)
        else { throw BridgeError("CONNECT_UNVERIFIED: The connection line did not attach to both objects (\(objectDescription(line))). Inspect before retrying.") }
        try s.key(53)
        try styleConnector(board, s, line, style: style, arrowhead: head)
        try s.key(53)
        finish(["boardTitle": title, "connector": describe(board, line), "snapshotToken": try snapshot(board.area)])
    }
    throw BridgeError("UNKNOWN_COMMAND")
} catch {
    session?.restoreWindowOrder()
    var result: [String: Any] = ["ok": false, "error": String(describing: error), "mayHaveChanged": mayHaveChanged]
    if let session { result["background"] = session.report() }
    emit(result)
    exit(1)
}
