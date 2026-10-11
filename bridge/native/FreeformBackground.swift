// Background helper: edits the regular Freeform app while another app stays frontmost.
// build-background.mjs appends this file to the declarations in FreeformBridge.swift.
// It never activates Freeform, clicks, or posts global keyboard events: only Accessibility
// actions and events addressed to Freeform's process. Each result reports whether Freeform
// activated, whether its window rose above the user's window, and whether the clipboard was used.

// The activation policy is set after reading the command: every command runs as .prohibited (it can never
// activate anything) except wake, whose brief activation macOS refuses from a .prohibited process (Round 9).

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
/// Drags a handle so its centre lands on `point`. Freeform scales a handle's AXPosition change by the board's
/// zoom (at 50 % a handle moved half the requested distance and connector ends attached to whatever sat near
/// the middle, Round 9), so measure the first move and correct until within 3 pt.
func dragHandle(_ handle: AXUIElement, to point: CGPoint) {
    var ratio: CGFloat = 1
    for _ in 0..<5 {
        guard let f = try? frame(handle) else { return }
        let c = CGPoint(x: f.midX, y: f.midY)
        let want = CGVector(dx: point.x - c.x, dy: point.y - c.y)
        if abs(want.dx) < 3 && abs(want.dy) < 3 { return }
        let ask = CGVector(dx: want.dx / ratio, dy: want.dy / ratio)
        _ = axPoint(handle, CGPoint(x: f.minX + ask.dx, y: f.minY + ask.dy))
        pause(seconds: 0.4)
        guard let g = try? frame(handle) else { return }
        let moved = hypot(g.midX - c.x, g.midY - c.y), asked = hypot(ask.dx, ask.dy)
        if asked > 1, moved > 0.5 { ratio = max(0.05, min(4, moved / asked)) }
    }
}
func rect(_ r: CGRect, in area: CGRect) -> [String: Double] {
    ["x": Double(r.minX - area.minX), "y": Double(r.minY - area.minY), "width": Double(r.width), "height": Double(r.height)]
}

/// Asks Freeform to build its full Accessibility tree, as an assistive app would. Both calls report an error
/// (-25208/-25205), yet Freeform then exposes a board canvas it had not built, within ~0.5 s, provided its window
/// is on screen. No activation or window change (Round 9).
func requestFullAccessibility(_ app: AXUIElement) {
    for name in ["AXEnhancedUserInterface", "AXManualAccessibility"] { _ = AXUIElementSetAttributeValue(app, name as CFString, kCFBooleanTrue) }
}

/// Tracks the background guarantees for one request.
final class BackgroundSession {
    let pid: pid_t
    let userApp: NSRunningApplication
    var activations: [String] = []
    var windowRaised = false
    var windowRestored: Bool?
    var clipboardUsed = false
    var zoomSteps = 0
    var wokeSeconds: Double?
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

    /// After a background launch Freeform never puts its board window on screen, so it never builds the canvas.
    /// No non-activating route fixed that (Round 9); a brief activation does: canvas ~0.3 s after activation, then
    /// the user's app is reactivated. Only used when the caller passes allowActivation.
    /// Activates Freeform just long enough for macOS to put its window on screen, then reactivates the user's app.
    func wake(_ freeform: NSRunningApplication) -> Bool {
        let started = Date()
        let config = NSWorkspace.OpenConfiguration(); config.activates = true
        if let url = freeform.bundleURL { NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in } }
        let front = waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == self.pid }, seconds: 3)
        // Measured on fresh background launches: a 0.5 s activation lets the window drop off screen again within
        // ~20 s; 1 s keeps it on screen (Round 9).
        pause(seconds: 1.0)
        userApp.activate()
        _ = waitUntil({ NSWorkspace.shared.frontmostApplication?.processIdentifier == self.userApp.processIdentifier }, seconds: 3)
        wokeSeconds = (Date().timeIntervalSince(started) * 100).rounded() / 100
        return front
    }

    /// Index of Freeform's first on-screen normal window, front to back (0 = above every other window).
    func freeformWindowIndex() -> Int {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
        return normal.firstIndex { ($0[kCGWindowOwnerPID as String] as? Int32) == pid } ?? -1
    }
    func noteWindowOrder() { if freeformWindowIndex() == 0 { windowRaised = true } }
    /// A background-launched Freeform takes its window off screen after ~10 s; popovers and menus then never
    /// appear, so edits that need them fail (Round 9).
    var windowOnScreen: Bool { freeformWindowIndex() >= 0 }

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
        var value: [String: Any] = ["activated": activated, "windowRaised": windowRaised, "windowRestored": windowRestored as Any? ?? NSNull(),
                "clipboardUsed": clipboardUsed, "frontmostApp": NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""]
        if zoomSteps > 0 { value["zoomedOutSteps"] = zoomSteps }
        if let wokeSeconds { value["wokeWithActivationSeconds"] = wokeSeconds }
        return value
    }
}

/// One board, found by exact title in Freeform's focused window, with no foreground requirement.
struct Board {
    let app: AXUIElement
    let window: AXUIElement
    let area: AXUIElement
    init(app: AXUIElement, title: String) throws {
        // After a background launch Freeform can expose the board window before its canvas.
        var found: (AXUIElement, AXUIElement)?
        _ = waitUntil({ found = try? boardWindow(app, title: title); return found != nil }, seconds: 3)
        if found == nil, focusedWindow(app).map({ string($0, kAXTitleAttribute) == title }) ?? false {
            // The canvas may simply not be built yet: request the full tree (no activation) and look again.
            requestFullAccessibility(app)
            _ = waitUntil({ found = try? boardWindow(app, title: title); return found != nil }, seconds: 2)
        }
        guard let found else {
            if let window = focusedWindow(app), string(window, kAXTitleAttribute) == title {
                throw BridgeError("CANVAS_NOT_READY: The board is open but its canvas is not exposed to Accessibility. After a background launch Freeform never puts its window on screen; call freeform_bg_wake (a brief activation) once, then retry.")
            }
            throw BridgeError("BOARD_MISMATCH: Open the requested board in Freeform.")
        }
        (window, area) = found
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
    /// The part of the canvas actually on screen: the scroll area, clipped to the window and the screen.
    /// Freeform only attaches connectors, anchors inspectors and moves objects reliably inside it; touching an
    /// object outside it makes Freeform scroll mid-operation (Round 9).
    var visibleFrame: CGRect {
        var r = areaFrame
        if let w = try? frame(window) { r = r.intersection(w) }
        if let screen = NSScreen.screens.first {
            // AX uses top-left origin on the primary screen; NSScreen frames are bottom-left.
            let primaryHeight = screen.frame.height
            let union = NSScreen.screens.reduce(CGRect.null) { acc, sc in
                acc.union(CGRect(x: sc.frame.minX, y: primaryHeight - sc.frame.maxY, width: sc.frame.width, height: sc.frame.height))
            }
            r = r.intersection(union)
        }
        return r
    }
    func isVisible(_ item: AXUIElement) -> Bool {
        guard let f = try? frame(item) else { return false }
        return visibleFrame.insetBy(dx: 2, dy: 2).contains(f)
    }
    /// Brings every target fully on screen without changing scale when possible: scrolls the canvas through its
    /// scroll bars (works hidden, no activation) so the targets are centred, and zooms out one step with the
    /// window's Decrease zoom button only when they cannot fit together. Throws rather than letting Freeform
    /// auto-scroll during the edit. Zooming out further than needed crowds small objects together, where a
    /// connector end can land on a neighbour (Round 9).
    func ensureVisible(_ targets: [AXUIElement], _ session: BackgroundSession) throws {
        var zoomed = 0
        for _ in 0..<6 {
            if targets.allSatisfy(isVisible) { break }
            let boxes = targets.compactMap { try? frame($0) }
            guard boxes.count == targets.count else { throw BridgeError("TARGET_NOT_VISIBLE: An object has no frame.") }
            let box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
            let view = visibleFrame.insetBy(dx: 30, dy: 30)
            if box.width <= view.width && box.height <= view.height {
                scroll(by: CGVector(dx: box.midX - view.midX, dy: box.midY - view.midY), probe: targets[0])
                continue
            }
            guard zoomed < 4, let button = descendants(window).first(where: { string($0, kAXRoleAttribute) == "AXButton" && objectDescription($0) == "Decrease zoom" }) else { break }
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
            zoomed += 1
            pause(seconds: 0.6)
        }
        session.zoomSteps += zoomed
        guard targets.allSatisfy(isVisible) else {
            throw BridgeError("TARGET_NOT_VISIBLE: An object stays outside the visible board area after scrolling and \(zoomed) zoom-out steps. Scroll or zoom Freeform so it is on screen, list objects again, and retry.")
        }
    }
    /// Scrolls the canvas so content moves by -delta (points), measuring how far one scroll-bar unit moves `probe`.
    func scroll(by delta: CGVector, probe: AXUIElement) {
        guard let raw = attribute(area, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return }
        let scrollArea = unsafeBitCast(raw, to: AXUIElement.self)
        for (axis, amount) in [(kAXVerticalScrollBarAttribute, delta.dy), (kAXHorizontalScrollBarAttribute, delta.dx)] where abs(amount) > 1 {
            guard let barRaw = attribute(scrollArea, axis), CFGetTypeID(barRaw) == AXUIElementGetTypeID() else { continue }
            let bar = unsafeBitCast(barRaw, to: AXUIElement.self)
            guard let value = (attribute(bar, kAXValueAttribute) as? NSNumber)?.doubleValue, let before = try? frame(probe) else { continue }
            let vertical = axis == kAXVerticalScrollBarAttribute
            // Measure points per unit with a small step in the needed direction, then set the final value.
            let step = amount > 0 ? min(0.05, 1 - value) : -min(0.05, value)
            guard abs(step) > 0.0001 else { continue }
            _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: value + step))
            pause(seconds: 0.3)
            guard let after = try? frame(probe) else { continue }
            let moved = vertical ? before.minY - after.minY : before.minX - after.minX
            guard abs(moved) > 0.5 else { continue }
            let perUnit = moved / step
            let target = max(0, min(1, value + Double(amount) / perUnit))
            _ = AXUIElementSetAttributeValue(bar, kAXValueAttribute as CFString, NSNumber(value: target))
            pause(seconds: 0.4)
        }
    }
    /// Closes a popover left open by an earlier step; a stale picker or inspector blocks the toolbar (Round 9).
    func dismissPopovers(_ session: BackgroundSession) throws {
        for _ in 0..<2 {
            guard let open = popover() else { return }
            _ = AXUIElementPerformAction(open, kAXCancelAction as CFString)
            try session.key(53)
            _ = waitUntil({ self.popover() == nil }, seconds: 1)
        }
        if popover() != nil { throw BridgeError("POPOVER_STUCK: A Freeform popover stays open; close it in Freeform and retry.") }
    }
    /// Re-resolves an element that may have been replaced (e.g. after an inspector closes) by its index.
    func fresh(_ item: AXUIElement, index: Int) -> AXUIElement {
        let all = items
        if all.contains(where: { CFEqual($0, item) }) { return item }
        return all.indices.contains(index) ? all[index] : item
    }
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
    dragHandle(handle, to: CGPoint(x: h.midX + dw, y: h.midY + dh))
    guard waitUntil({ (try? frame(item)).map { abs(Double($0.width) - Double(old.width) - dw) < 1 && abs(Double($0.height) - Double(old.height) - dh) < 1 } ?? false }, seconds: 2)
    else { throw BridgeError("RESIZE_UNVERIFIED: The object may have been resized partially; inspect before retrying.") }
}

func move(_ board: Board, _ item: AXUIElement, x: Double?, y: Double?) throws {
    guard x != nil || y != nil else { return }
    try board.select([item])
    let origin = board.areaFrame, old = try frame(item)
    let target = CGPoint(x: x.map { origin.minX + $0 } ?? old.minX, y: y.map { origin.minY + $0 } ?? old.minY)
    // A destination outside the visible area makes Freeform scroll during the move (Round 9).
    let visible = board.visibleFrame
    guard visible.insetBy(dx: -1, dy: -1).contains(CGRect(origin: target, size: old.size)) else {
        throw BridgeError("TARGET_NOT_VISIBLE: x/y would place the object outside the visible board area (\(Int(visible.minX - origin.minX)),\(Int(visible.minY - origin.minY)) to \(Int(visible.maxX - origin.minX)),\(Int(visible.maxY - origin.minY)) in list coordinates). Choose a point inside it.")
    }
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
/// The first inspector after a launch can fail to load once; one retry after closing popovers (Round 9).
func openInspector(_ board: Board, _ item: AXUIElement, _ name: String) throws -> AXUIElement {
    do { return try openInspectorOnce(board, item, name) } catch let error as BridgeError where String(describing: error).contains("INSPECTOR_UNAVAILABLE") {
        if let popover = board.popover() { _ = AXUIElementPerformAction(popover, kAXCancelAction as CFString) }
        pause(seconds: 0.5)
        return try openInspectorOnce(board, item, name)
    }
}
func openInspectorOnce(_ board: Board, _ item: AXUIElement, _ name: String) throws -> AXUIElement {
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
    let index = board.items.firstIndex { CFEqual($0, line) } ?? -1
    if let style {
        // Freeform describes corner lines as "angled" and curve lines as "curved" (Round 9).
        let styleWord = ["straight": "straight", "corner": "angled", "curve": "curved"][style] ?? style
        if !objectDescription(line).contains(styleWord) {
            _ = try openInspector(board, line, "Connection Line Style Inspector")
            if let popover = board.popover(), let segment = descendants(popover).first(where: { objectDescription($0) == connectionStyles[style]! }) {
                _ = AXUIElementPerformAction(segment, kAXPressAction as CFString)
            }
            try closeInspector(board, s)
            // The line element can be replaced while the inspector is open; read it fresh by index.
            guard waitUntil({ objectDescription(board.fresh(line, index: index)).contains(styleWord) }, seconds: 2)
            else { throw BridgeError("STYLE_UNVERIFIED: Connector attached but its style is \(objectDescription(board.fresh(line, index: index))).") }
        }
    }
    if let item = arrowheads[arrowhead] {
        _ = try openInspector(board, board.fresh(line, index: index), "Line Ends Inspector")
        var seen: [String] = [], structure: [String] = []
        func popups() -> [AXUIElement] { board.popover().map { descendants($0).filter { string($0, kAXRoleAttribute) == "AXPopUpButton" } } ?? [] }
        /// Opens one line-end pop-up and picks `want` ("None", "Simple arrow", …).
        func choose(_ which: Int, _ want: String) {
            let list = popups()
            guard list.count >= 2 else { return }
            let popup = list[which]
            _ = AXUIElementPerformAction(popup, kAXPressAction as CFString)
            pause(seconds: 0.5)
            var choice: AXUIElement?
            _ = waitUntil({
                let items = descendants(popup, depth: 4).filter { string($0, kAXRoleAttribute) == "AXMenuItem" }
                seen = items.map { string($0, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } ?? objectDescription($0) }
                choice = items.first { string($0, kAXTitleAttribute) == want || objectDescription($0) == want }
                // Item titles can stay blank until the menu renders; fall back to the observed fixed order.
                // The description check below rejects a wrong pick.
                if choice == nil, items.count == lineEndOrder.count, seen.allSatisfy({ $0.isEmpty }), let i = lineEndOrder.firstIndex(of: want) {
                    choice = items[i]
                }
                return choice != nil
            }, seconds: 3)
            structure = descendants(popup, depth: 4).map { "\(string($0, kAXRoleAttribute) ?? "?"):\(string($0, kAXTitleAttribute) ?? "")" }
            s.noteWindowOrder()
            if let choice { _ = AXUIElementPerformAction(choice, kAXPressAction as CFString) }
            pause(seconds: 0.4)
        }
        func current() -> String { objectDescription(board.fresh(line, index: index)) }
        guard popups().count >= 2 else { try closeInspector(board, s); throw BridgeError("ARROWHEAD_UNAVAILABLE") }
        // The two pop-ups are unlabeled, and which one controls the End depends on the line's on-screen direction
        // (an upward line put the arrow on its Start, Round 9). Try the second; if the arrow lands on the Start,
        // clear it there and use the first.
        choose(1, item)
        var applied = waitUntil({ current().contains("End: " + item) }, seconds: 2)
        if !applied, current().contains("Start: " + item) {
            choose(1, "None")
            choose(0, item)
            applied = waitUntil({ current().contains("End: " + item) && !current().contains("Start: ") }, seconds: 3)
        }
        try closeInspector(board, s)
        s.noteWindowOrder(); s.restoreWindowOrder()
        guard applied else { throw BridgeError("ARROWHEAD_UNVERIFIED: Connector attached; arrowhead not confirmed (\(current())). Menu items seen: \(seen). Pop-ups: \(popups().map { string($0, kAXValueAttribute) ?? "?" }). Under pressed pop-up: \(structure).") }
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
    if command != "wake" { _ = NSApplication.shared.setActivationPolicy(.prohibited) }
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
    let commands = ["wake", "listObjects", "screenshot", "openBoard", "createBoard", "renameBoard", "addShape", "updateObject", "connect", "deleteObject"]
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

    if command == "wake" {
        guard request["allowActivation"] as? Bool == true else { throw BridgeError("ACTIVATION_REQUIRED: Waking Freeform briefly activates it (about half a second) and then reactivates your app. Pass allowActivation: true.") }
        // Ready means a window actually on screen showing either a board canvas or the library (its New Board button).
        func onLibrary(_ w: AXUIElement) -> Bool { descendants(w).contains { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXTitleAttribute) == "New Board" || objectDescription($0) == "New Board") } }
        func ready() -> Bool { s.windowOnScreen && (focusedWindow(app).map { canvas($0) != nil || onLibrary($0) } ?? false) }
        if ready() { finish(["woke": false, "alreadyReady": true, "boardTitle": focusedWindow(app).flatMap { string($0, kAXTitleAttribute) } ?? NSNull()]) }
        // First without activation: enough whenever the window is already on screen.
        requestFullAccessibility(app)
        var method = "fullAccessibility"
        if !waitUntil(ready, seconds: 2) {
            method = "activation"
            guard s.wake(running) else { throw BridgeError("WAKE_FAILED: Freeform did not come to the front; macOS may have refused the activation.") }
            requestFullAccessibility(app)
            _ = waitUntil(ready, seconds: 4)
        }
        let window = focusedWindow(app)
        let readyNow = ready()
        finish(["woke": readyNow, "method": method, "boardTitle": window.flatMap { string($0, kAXTitleAttribute) } ?? NSNull(),
                "canvasReady": window.map { canvas($0) != nil } ?? false])
    }

    if command == "openBoard" || command == "createBoard" || command == "renameBoard" {
        guard let title = request["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BridgeError("BOARD_TITLE_REQUIRED") }
        guard let current = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
        func onBoard(_ window: AXUIElement) -> Bool {
            descendants(window).contains { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXTitleAttribute) == "Go Back" || objectDescription($0) == "Go Back") }
        }
        func cards(_ name: String) -> [AXUIElement] {
            guard let library = focusedWindow(app), !onBoard(library) else { return [] }
            return descendants(library).filter { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXDescriptionAttribute) ?? "").hasPrefix("Board: " + name + ", ") }
        }
        func toLibrary() throws {
            // A just-created board can ignore an immediate Go Back, so press again until the library appears.
            for _ in 0..<3 {
                guard let window = focusedWindow(app) else { throw BridgeError("NO_WINDOW") }
                if !onBoard(window) { return }
                try pressButton(window, title: "Go Back")
                if waitUntil({ focusedWindow(app).map { !onBoard($0) } ?? false }, seconds: 2) { return }
            }
            throw BridgeError("LIBRARY_UNAVAILABLE")
        }
        func open(_ name: String) throws {
            let matches = cards(name)
            guard matches.count == 1 else { throw BridgeError("BOARD_NOT_UNIQUE: Expected one visible board titled \"\(name)\"; found \(matches.count).") }
            _ = AXUIElementPerformAction(matches[0], kAXPressAction as CFString)
            guard waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == name && onBoard($0) } ?? false }, seconds: 10) else { throw BridgeError("OPEN_UNVERIFIED: Inspect Freeform; the board may still be opening.") }
        }
        if command == "openBoard" {
            if string(current, kAXTitleAttribute) == title, onBoard(current) { finish(["boardTitle": title, "opened": true]) }
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
        // The first context menu after a launch can fail to load, and closed menus linger in the AX tree with a
        // Rename item that does nothing; so the whole sequence is tried twice (Round 9).
        var field: AXUIElement?
        for attempt in 0..<2 where field == nil {
            guard let cardNow = cards(created).first else { break }
            var actions: CFArray?; AXUIElementCopyActionNames(cardNow, &actions)
            let show = ((actions as? [String]) ?? []).first { $0.hasPrefix("Name:Show Menu") } ?? (kAXShowMenuAction as String)
            _ = AXUIElementPerformAction(cardNow, show as CFString)
            // Context menus only: the menu bar's Edit ▸ Rename is disabled in the background and must not match.
            var rename: AXUIElement?
            _ = waitUntil({
                rename = children(app).filter { string($0, kAXRoleAttribute) != "AXMenuBar" }.flatMap { descendants($0, depth: 15) }
                    .filter { string($0, kAXRoleAttribute) == "AXMenu" }.flatMap { children($0) }
                    .first { string($0, kAXTitleAttribute) == "Rename" && attribute($0, kAXEnabledAttribute) as? Bool == true }
                return rename != nil
            }, seconds: 3)
            s.noteWindowOrder()
            if let rename {
                _ = AXUIElementPerformAction(rename, kAXPressAction as CFString)
                _ = waitUntil({ field = descendants(app, depth: 20).first { string($0, kAXRoleAttribute) == "AXTextField" && string($0, kAXValueAttribute) == created }; return field != nil }, seconds: 3)
            }
            if field == nil { try? s.key(53); pause(seconds: attempt == 0 ? 0.8 : 0) }
        }
        guard let field else { s.restoreWindowOrder(); throw BridgeError("RENAME_UNAVAILABLE: \"\(created)\" exists, but its Rename command or title editor did not appear after two tries.") }
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
    if ["addShape", "updateObject", "deleteObject", "connect"].contains(command) {
        guard s.windowOnScreen else { throw BridgeError("WINDOW_NOT_ON_SCREEN: Freeform's window is off screen (it does this a few seconds after a background launch), so its menus cannot open. Call freeform_bg_wake once, then retry. Nothing was changed.") }
        try board.dismissPopovers(s)
    }

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
        // Check the requested position before inserting anything: off-screen moves make Freeform scroll (Round 9).
        if request["x"] != nil || request["y"] != nil {
            let origin = board.areaFrame, visible = board.visibleFrame
            let x = (request["x"] as? Double).map { origin.minX + $0 } ?? visible.midX, y = (request["y"] as? Double).map { origin.minY + $0 } ?? visible.midY
            let size = CGSize(width: request["width"] as? Double ?? 10, height: request["height"] as? Double ?? 10)
            guard visible.contains(CGRect(origin: CGPoint(x: x, y: y), size: size)) else {
                throw BridgeError("TARGET_NOT_VISIBLE: x/y is outside the visible board area (\(Int(visible.minX - origin.minX)),\(Int(visible.minY - origin.minY)) to \(Int(visible.maxX - origin.minX)),\(Int(visible.maxY - origin.minY)) in list coordinates). Nothing was inserted.")
            }
        }
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
        if command == "updateObject" { try board.ensureVisible([item], s) }
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
        // Handles dropped on an off-screen object do not attach (Round 9).
        try board.ensureVisible([from, to], s)
        let style = request["style"] as? String ?? "straight"
        let head = request["arrowhead"] as? String ?? "none"
        guard let styleName = connectionStyles[style] else { throw BridgeError("UNSUPPORTED_STYLE") }
        guard head == "none" || arrowheads[head] != nil else { throw BridgeError("UNSUPPORTED_ARROWHEAD") }
        guard head == "none" || allowRaise else { throw BridgeError("WINDOW_RAISE_REQUIRED: Arrowheads are set through a pop-up menu that raises Freeform's window. Pass allowWindowRaise: true, or use arrowhead: \"none\".") }
        mayHaveChanged = true
        let line = try insertObject(board, s, kind: "connectionLine")
        let lineIndex = board.items.firstIndex { CFEqual($0, line) } ?? -1
        try s.key(53)
        try board.select([line])
        guard let handles = attribute(line, "AXHandles") as? [AXUIElement],
              let tail = handles.first(where: { objectDescription($0).hasPrefix("Tail") }), let headHandle = handles.first(where: { objectDescription($0).hasPrefix("Head") })
        else { throw BridgeError("CONNECTOR_UNAVAILABLE: Connection line handles not found; a loose line may remain on the board.") }
        // Attach to the facing edge, 10 points inside each object, unless another object covers that point: a
        // handle dropped there attaches to whatever is on top (Round 9). Then try the centre, the other edge
        // midpoints and the quarter points.
        let a = try frame(from), b = try frame(to)
        // Direction from how the boxes overlap, not their centres: a wide box's centre can sit far to one side of a
        // box directly above it (Round 9). Overlapping x-ranges = vertical; overlapping y-ranges = horizontal;
        // otherwise the larger edge-to-edge gap decides.
        let xOverlap = (max(a.minX, b.minX), min(a.maxX, b.maxX)), yOverlap = (max(a.minY, b.minY), min(a.maxY, b.maxY))
        let gapX = max(b.minX - a.maxX, a.minX - b.maxX), gapY = max(b.minY - a.maxY, a.minY - b.maxY)
        let horizontal = xOverlap.0 < xOverlap.1 ? false : yOverlap.0 < yOverlap.1 ? true : gapX >= gapY
        let shapes = board.items.filter { !CFEqual($0, line) && !objectDescription($0).hasPrefix("connection line") }
        func anchor(_ r: CGRect, toward other: CGRect) -> CGPoint {
            // Every other object counts as a neighbour, including the connector's other end: boxes 30 pt apart
            // at 50 % zoom made an end snap to the opposite target (Round 9).
            let others = shapes.compactMap { try? frame($0) }.filter { $0 != r }
            // Aim within the shared strip when the boxes overlap on the cross axis, so a wide target is entered right
            // across from the other box.
            let crossX = xOverlap.0 < xOverlap.1 ? (xOverlap.0 + xOverlap.1) / 2 : r.midX
            let crossY = yOverlap.0 < yOverlap.1 ? (yOverlap.0 + yOverlap.1) / 2 : r.midY
            let facing = horizontal ? CGPoint(x: other.midX > r.midX ? r.maxX - 10 : r.minX + 10, y: crossY)
                                    : CGPoint(x: crossX, y: other.midY > r.midY ? r.maxY - 10 : r.minY + 10)
            let inward = horizontal ? CGPoint(x: other.midX > r.midX ? r.maxX - r.width / 4 : r.minX + r.width / 4, y: crossY)
                                    : CGPoint(x: crossX, y: other.midY > r.midY ? r.maxY - r.height / 4 : r.minY + r.height / 4)
            let candidates = [facing, inward, CGPoint(x: r.midX, y: r.midY),
                              CGPoint(x: r.minX + r.width / 4, y: r.minY + r.height / 4), CGPoint(x: r.maxX - r.width / 4, y: r.minY + r.height / 4),
                              CGPoint(x: r.minX + r.width / 4, y: r.maxY - r.height / 4), CGPoint(x: r.maxX - r.width / 4, y: r.maxY - r.height / 4)]
            // Freeform snaps a dropped end to nearby objects too: at 50 % zoom an end 40 pt from a neighbour
            // attached to it. Use the facing point only with 60 pt of clearance, else the clearest candidate.
            func clearance(_ p: CGPoint) -> CGFloat {
                others.map { o in
                    if o.contains(p) { return 0 }
                    let dx = max(o.minX - p.x, 0, p.x - o.maxX), dy = max(o.minY - p.y, 0, p.y - o.maxY)
                    return (dx * dx + dy * dy).squareRoot()
                }.min() ?? .greatestFiniteMagnitude
            }
            if clearance(facing) >= 60 { return facing }
            return candidates.max { clearance($0) < clearance($1) } ?? facing
        }
        // The connector names its ends by their descriptions, with newlines shown as spaces.
        let flat = { (e: AXUIElement) in objectDescription(e).replacingOccurrences(of: "\n", with: " ") }
        let expectedEnds = "Connected from \(flat(from)) to \(flat(to))"
        for (handle, point) in [(tail, anchor(a, toward: b)), (headHandle, anchor(b, toward: a))] {
            dragHandle(handle, to: point)
            pause(seconds: 0.3)
        }
        _ = waitUntil({ objectDescription(line).contains("Connected from") && objectDescription(line).contains(" to ") }, seconds: 2)
        guard objectDescription(line).contains(expectedEnds) else {
            // Remove the loose or misattached line rather than leave it on the board.
            let observed = objectDescription(line)
            let count = board.items.count
            try? s.key(53)
            if (try? board.select([line])) != nil { try? s.key(51) }
            let removed = waitUntil({ board.items.count == count - 1 }, seconds: 2)
            let wrong = observed.contains("Connected from") && observed.contains(" to ")
            throw BridgeError("CONNECT_UNVERIFIED: The connection line \(wrong ? "attached to the wrong objects, probably because another object overlaps a target" : "did not attach to both objects") (\(observed)); \(removed ? "the line was removed" : "a stray line may remain"). List objects and retry\(wrong ? " after moving the overlapping object" : "").")
        }
        try s.key(53)
        try styleConnector(board, s, line, style: style, arrowhead: head)
        try s.key(53)
        // The line element can be replaced while inspectors are open; describe it fresh by index.
        finish(["boardTitle": title, "connector": describe(board, board.fresh(line, index: lineIndex)), "snapshotToken": try snapshot(board.area)])
    }
    throw BridgeError("UNKNOWN_COMMAND")
} catch {
    session?.restoreWindowOrder()
    var result: [String: Any] = ["ok": false, "error": String(describing: error), "mayHaveChanged": mayHaveChanged]
    if let session { result["background"] = session.report() }
    emit(result)
    exit(1)
}
