_ = NSApplication.shared.setActivationPolicy(.prohibited)
let title = ProcessInfo.processInfo.environment["FREEFORM_PROBE_BOARD"] ?? "Background Bridge Probe — 2026-10-09"
var log: [[String: Any]] = []
var events: [[String: Any]] = []
var clip: ClipboardTransaction?
var sentinel = ""
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown" }
func state(_ area: AXUIElement) -> [[String: Any]] {
    layoutItems(area).map { item in
        let r = try? frame(item)
        return ["description": objectDescription(item), "selected": attribute(item, kAXSelectedAttribute) as? Bool ?? false,
                "frame": r.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? []]
    }
}
func probeWait(_ seconds: Double = 0.7) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
func targetedKey(_ pid: pid_t, _ code: CGKeyCode, flags: CGEventFlags = []) throws {
    guard front() != "com.apple.freeform" else { throw BridgeError("FOCUS_STOLEN: Stopping experiment") }
    let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!
    let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!
    down.flags = flags; up.flags = flags
    down.postToPid(pid); probeWait(0.05); up.postToPid(pid); probeWait()
}
func editItem(_ app: AXUIElement, _ name: String) throws -> AXUIElement {
    guard let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw BridgeError("NO_MENU") }
    let bar = unsafeBitCast(raw, to: AXUIElement.self)
    guard let edit = children(bar).first(where: { string($0, kAXTitleAttribute) == "Edit" }),
          let item = descendants(edit, depth: 3).first(where: { string($0, kAXTitleAttribute) == name }) else { throw BridgeError("NO_COMMAND") }
    return item
}
// Verifies a context-menu Paste from Accessibility: payload labels, sizes, a common translation, and unchanged baseline frames.
func verifyPaste(_ area: AXUIElement, baseline: [AXUIElement], baselineFrames: [CGRect?], payloadPath: String) throws -> [String: Any] {
    // Expected objects come from the payload itself: label, model position, and size.
    let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: payloadPath))) as? [[String: Any]] ?? []
    let expected: [(label: String, x: Double, y: Double, w: Double, h: Double)] = payload.compactMap { object in
        guard let text = (object["text"] as? [String: Any])?["attributed_string"] as? [Any], let label = text.first as? String,
              let geometry = object["geometry"] as? [String: Any], let position = geometry["position"] as? [String: Any],
              let size = geometry["size"] as? [String: Any], let x = position["x"] as? Double, let y = position["y"] as? Double,
              let w = size["width"] as? Double, let h = size["height"] as? Double else { return nil }
        return (label, x, y, w, h)
    }
    guard expected.count == payload.count, !expected.isEmpty, Set(expected.map(\.label)).count == expected.count else { throw BridgeError("PAYLOAD_NOT_UNIQUELY_LABELED") }
    let inserted = waitUntil({ layoutItems(area).count == baseline.count + expected.count }, seconds: 10)
    probeWait(1)
    let added = layoutItems(area).filter { item in !baseline.contains { CFEqual($0, item) } }
    var matches: [[String: Any]] = []
    var offsets: [(Double, Double)] = []
    for e in expected {
        let hits = added.filter { objectDescription($0).hasPrefix(e.label + ", ") }
        guard hits.count == 1, let f = try? frame(hits[0]) else { matches.append(["label": e.label, "hits": hits.count]); continue }
        offsets.append((Double(f.minX) - e.x, Double(f.minY) - e.y))
        matches.append(["label": e.label, "description": objectDescription(hits[0]), "frame": [f.minX, f.minY, f.width, f.height],
                        "sizeMatches": abs(Double(f.width) - e.w) < 0.5 && abs(Double(f.height) - e.h) < 0.5])
    }
    let commonOffset = offsets.count == expected.count && offsets.allSatisfy { abs($0.0 - offsets[0].0) < 0.5 && abs($0.1 - offsets[0].1) < 0.5 }
    let existingUnchanged = zip(baseline, baselineFrames).allSatisfy { item, old in old != nil && (try? frame(item)) == old }
    let verified = inserted && added.count == expected.count && commonOffset && existingUnchanged
        && matches.allSatisfy { $0["sizeMatches"] as? Bool == true }
    return ["inserted": inserted, "expectedCount": expected.count, "addedCount": added.count,
            "matches": matches, "translation": offsets.first.map { [$0.0, $0.1] } ?? [], "commonTranslation": commonOffset,
            "existingUnchanged": existingUnchanged, "verified": verified]
}
do {
    guard AXIsProcessTrusted(), let running = runningApp() else { throw BridgeError("UNAVAILABLE") }
    let app = AXUIElementCreateApplication(running.processIdentifier)
    AXUIElementSetMessagingTimeout(app, 3)
    let mode = CommandLine.arguments.dropFirst().first ?? "inspect"
    if mode == "inspectTitle" {
        // Read-only: title-related toolbar elements and menu-bar items that could rename a board.
        guard let board = focusedWindow(app), string(board, kAXTitleAttribute) == title else { throw BridgeError("BOARD_MISMATCH") }
        func describe(_ e: AXUIElement) -> [String: Any] {
            var names: CFArray?; var acts: CFArray?
            AXUIElementCopyAttributeNames(e, &names); AXUIElementCopyActionNames(e, &acts)
            var settable: [String] = []
            for name in (names as? [String]) ?? [] { var ok = DarwinBoolean(false); if AXUIElementIsAttributeSettable(e, name as CFString, &ok) == .success, ok.boolValue { settable.append(name) } }
            return ["role": string(e, kAXRoleAttribute) ?? "", "title": string(e, kAXTitleAttribute) ?? "", "value": string(e, kAXValueAttribute) ?? "",
                    "description": string(e, kAXDescriptionAttribute) ?? "", "identifier": string(e, kAXIdentifierAttribute) ?? "",
                    "actions": (acts as? [String]) ?? [], "settable": settable]
        }
        let toolbar = descendants(board).first(where: { string($0, kAXRoleAttribute) == "AXToolbar" })
        let toolbarItems = toolbar.map { descendants($0).filter { ["AXStaticText", "AXTextField", "AXButton", "AXMenuButton", "AXGroup"].contains(string($0, kAXRoleAttribute) ?? "") }.map(describe) } ?? []
        var menuItems: [[String: Any]] = []
        if let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            for top in children(unsafeBitCast(raw, to: AXUIElement.self)) where ["File", "Edit", "Board", "View"].contains(string(top, kAXTitleAttribute) ?? "") {
                for item in descendants(top, depth: 3) where string(item, kAXRoleAttribute) == "AXMenuItem" {
                    let name = string(item, kAXTitleAttribute) ?? ""
                    if name.localizedCaseInsensitiveContains("rename") || name.localizedCaseInsensitiveContains("title") || name.localizedCaseInsensitiveContains("name") {
                        menuItems.append(["menu": string(top, kAXTitleAttribute) ?? "", "title": name, "enabled": attribute(item, kAXEnabledAttribute) as? Bool ?? false])
                    }
                }
            }
        }
        emit(["ok": true, "mode": mode, "front": front(), "boardAttributes": describe(board), "toolbar": toolbarItems, "menuItems": menuItems]); exit(0)
    }
    if mode == "openBoard" {
        // Switch boards via the library: Go Back, then AXPress the uniquely matching card. No click fallback.
        let target = CommandLine.arguments[2]
        guard front() != "com.apple.freeform", let current = focusedWindow(app) else { throw BridgeError("UNAVAILABLE") }
        let start = front()
        var activations: [String] = []
        let watcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            activations.append((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "unknown")
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(watcher) }
        if canvas(current) != nil { try pressButton(current, title: "Go Back") }
        let atLibrary = waitUntil({ focusedWindow(app).map { canvas($0) == nil } ?? false }, seconds: 5)
        let cards = focusedWindow(app).map { descendants($0).filter { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXDescriptionAttribute) ?? "").hasPrefix("Board: " + target + ", ") } } ?? []
        guard atLibrary, cards.count == 1 else { throw BridgeError("CARD_NOT_UNIQUE: \(cards.count)") }
        let press = AXUIElementPerformAction(cards[0], kAXPressAction as CFString)
        let opened = waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == target && canvas($0) != nil } ?? false }, seconds: 5)
        emit(["ok": opened && front() == start && !activations.contains("com.apple.freeform"), "mode": mode, "axResult": press.rawValue, "opened": opened,
              "frontBefore": start, "frontAfter": front(), "activations": activations]); exit(opened ? 0 : 1)
    }
    if mode == "renameBoard" {
        // Library route: Go Back, board card context menu, Rename. No click or keyboard-activation fallbacks.
        let newTitle = CommandLine.arguments[2]
        guard newTitle.hasPrefix("Background "), title.hasPrefix("Untitled") || title.hasPrefix("Background ") else { throw BridgeError("DISPOSABLE_TITLE_REQUIRED") }
        let window = try? boardWindow(app, title: title).0
        guard window != nil || (focusedWindow(app).map { canvas($0) == nil } ?? false) else { throw BridgeError("BOARD_MISMATCH") }
        guard front() != "com.apple.freeform" else { throw BridgeError("FREEFORM_FRONTMOST") }
        let start = front()
        var activations: [String] = []
        let watcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            activations.append((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "unknown")
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(watcher) }
        var steps: [[String: Any]] = []
        var reopenTitle: String?
        func cards(_ name: String) -> [AXUIElement] {
            guard let library = focusedWindow(app) else { return [] }
            return descendants(library).filter { string($0, kAXRoleAttribute) == "AXButton" && (string($0, kAXDescriptionAttribute) ?? "").hasPrefix("Board: " + name + ", ") }
        }
        func finish(_ ok: Bool, _ error: String? = nil) -> Never {
            // Leave the board open again whether or not renaming succeeded.
            if let name = reopenTitle, let card = cards(name).first, focusedWindow(app).map({ canvas($0) == nil }) ?? false {
                let open = AXUIElementPerformAction(card, kAXPressAction as CFString)
                steps.append(["step": "Reopen board", "title": name, "axResult": open.rawValue,
                              "reopened": waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == name && canvas($0) != nil } ?? false }, seconds: 5)])
            }
            emit(["ok": ok, "mode": mode, "error": error as Any? ?? NSNull(), "steps": steps, "frontBefore": start, "frontAfter": front(),
                  "activations": activations, "focusedTitle": focusedWindow(app).flatMap { string($0, kAXTitleAttribute) } ?? ""])
            exit(ok ? 0 : 1)
        }
        reopenTitle = title
        if let window { try pressButton(window, title: "Go Back") }
        let atLibrary = waitUntil({ focusedWindow(app).map { canvas($0) == nil } ?? false }, seconds: 5)
        steps.append(["step": "Go Back", "library": atLibrary])
        guard atLibrary else { finish(false, "LIBRARY_UNVERIFIED") }
        let matches = cards(title)
        steps.append(["step": "Find card", "matches": matches.count, "actions": matches.first.map { card -> [String] in var a: CFArray?; AXUIElementCopyActionNames(card, &a); return (a as? [String]) ?? [] } ?? []])
        guard matches.count == 1 else { finish(false, "CARD_NOT_UNIQUE") }
        let card = matches[0]
        // Only menus that appear after showing the card menu count; the menu bar's own menus are excluded.
        let menusBefore = descendants(app, depth: 15).filter { string($0, kAXRoleAttribute) == "AXMenu" }
        var cardActions: CFArray?; AXUIElementCopyActionNames(card, &cardActions)
        let showMenu = ((cardActions as? [String]) ?? []).first { $0.hasPrefix("Name:Show Menu") } ?? (kAXShowMenuAction as String)
        steps.append(["step": "Show card menu", "action": showMenu, "axResult": AXUIElementPerformAction(card, showMenu as CFString).rawValue])
        probeWait()
        let menus = descendants(app, depth: 15).filter { menu in string(menu, kAXRoleAttribute) == "AXMenu" && !menusBefore.contains { CFEqual($0, menu) } }
        let titles = menus.flatMap { children($0).compactMap { string($0, kAXTitleAttribute) } }.filter { !$0.isEmpty }
        steps.append(["step": "Menu titles", "titles": titles])
        guard let rename = menus.lazy.flatMap({ children($0) }).first(where: { (string($0, kAXTitleAttribute) ?? "").hasPrefix("Rename") }),
              attribute(rename, kAXEnabledAttribute) as? Bool == true else {
            try targetedKey(running.processIdentifier, 53); finish(false, "NO_ENABLED_RENAME")
        }
        steps.append(["step": "Press Rename", "axResult": AXUIElementPerformAction(rename, kAXPressAction as CFString).rawValue])
        var field: AXUIElement?
        let editor = waitUntil({ field = descendants(app, depth: 20).first { string($0, kAXRoleAttribute) == "AXTextField" && (attribute($0, kAXFocusedAttribute) as? Bool == true || string($0, kAXValueAttribute) == title) }; return field != nil }, seconds: 3)
        steps.append(["step": "Find editor", "found": editor, "value": field.flatMap { string($0, kAXValueAttribute) } ?? ""])
        guard editor, let field else { try targetedKey(running.processIdentifier, 53); finish(false, "NO_RENAME_EDITOR") }
        steps.append(["step": "Set title", "axResult": AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, newTitle as CFString).rawValue])
        let confirm = AXUIElementPerformAction(field, "AXConfirm" as CFString)
        steps.append(["step": "AXConfirm", "axResult": confirm.rawValue])
        if confirm != .success { try targetedKey(running.processIdentifier, 36); steps.append(["step": "PID Return"]) }
        let renamed = waitUntil({ cards(newTitle).count == 1 && cards(title).isEmpty }, seconds: 5)
        steps.append(["step": "Verify card renamed", "renamed": renamed])
        guard renamed else { finish(false, "RENAME_UNVERIFIED") }
        reopenTitle = newTitle
        finish(front() == start && !activations.contains("com.apple.freeform"))
    }
    if mode == "createBoard" {
        // Production createBoard minus its click/keyboard fallbacks, which activate Freeform.
        let newTitle = CommandLine.arguments[2]
        guard newTitle.hasPrefix("Background ") else { throw BridgeError("DISPOSABLE_TITLE_REQUIRED") }
        let (window, _) = try boardWindow(app, title: title)
        guard front() != "com.apple.freeform" else { throw BridgeError("FREEFORM_FRONTMOST") }
        let start = front()
        var activations: [String] = []
        let watcher = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            activations.append((note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier ?? "unknown")
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(watcher) }
        var steps: [[String: Any]] = []
        func finish(_ ok: Bool, _ error: String? = nil) -> Never {
            emit(["ok": ok, "mode": mode, "error": error as Any? ?? NSNull(), "steps": steps, "frontBefore": start, "frontAfter": front(),
                  "activations": activations, "focusedTitle": focusedWindow(app).flatMap { string($0, kAXTitleAttribute) } ?? ""])
            exit(ok ? 0 : 1)
        }
        try pressButton(window, title: "New Board")
        let created = waitUntil({
            guard let current = focusedWindow(app), let area = canvas(current) else { return false }
            return string(current, kAXTitleAttribute) != title && layoutItems(area).isEmpty
        }, seconds: 5)
        steps.append(["step": "New Board", "emptyCanvas": created, "title": focusedWindow(app).flatMap { string($0, kAXTitleAttribute) } ?? ""])
        guard created, let board = focusedWindow(app),
              let toolbar = descendants(board).first(where: { string($0, kAXRoleAttribute) == "AXToolbar" }) else { finish(false, "CREATE_UNVERIFIED") }
        var field = descendants(toolbar).first { string($0, kAXRoleAttribute) == "AXTextField" }
        if field == nil, let name = descendants(toolbar).first(where: {
            string($0, kAXRoleAttribute) == "AXStaticText" && (string($0, kAXValueAttribute) == string(board, kAXTitleAttribute) || string($0, kAXTitleAttribute) == string(board, kAXTitleAttribute))
        }) {
            steps.append(["step": "Press title", "axResult": AXUIElementPerformAction(name, kAXPressAction as CFString).rawValue])
        }
        guard waitUntil({ field = descendants(toolbar).first { string($0, kAXRoleAttribute) == "AXTextField" }; return field != nil }, seconds: 2),
              let field else { finish(false, "TITLE_EDITOR_NEEDS_FOREGROUND") }
        steps.append(["step": "Set title", "axResult": AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, newTitle as CFString).rawValue])
        _ = AXUIElementSetAttributeValue(field, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let confirm = AXUIElementPerformAction(field, "AXConfirm" as CFString)
        steps.append(["step": "AXConfirm", "axResult": confirm.rawValue])
        if confirm != .success { try targetedKey(running.processIdentifier, 36); steps.append(["step": "PID Return"]) }
        let renamed = waitUntil({ focusedWindow(app).map { string($0, kAXTitleAttribute) == newTitle } ?? false }, seconds: 5)
        steps.append(["step": "Verify title", "renamed": renamed])
        finish(renamed && front() == start && !activations.contains("com.apple.freeform"), renamed ? nil : "RENAME_UNVERIFIED")
    }
    let (window, area) = try boardWindow(app, title: title)
    let initial = layoutItems(area)
    // Raised from 8 to 16 for multi-object paste tests; emptyPaste requires an empty board.
    if mode == "emptyPaste" {
        guard initial.isEmpty else { throw BridgeError("BOARD_NOT_EMPTY") }
    } else {
        guard initial.count >= 2 && initial.count <= 16 else { throw BridgeError("UNEXPECTED_DISPOSABLE_BOARD") }
    }
    let observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
        let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        events.append(["bundle": activated?.bundleIdentifier ?? "unknown", "time": Date().timeIntervalSince1970])
    }
    defer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { throw BridgeError("NO_FINDER") }
    if front() == "com.apple.freeform" {
        finder.activate(); guard waitUntil({ front() == "com.apple.finder" }) else { throw BridgeError("NO_BACKGROUND_SENTINEL") }
    }
    sentinel = front()
    probeWait(); events.removeAll()
    func record(_ name: String, allowContextMenu: Bool = false, _ operation: () throws -> [String: Any]) throws {
        guard front() == sentinel else { throw BridgeError("FOCUS_CHANGED") }
        if allowContextMenu {
            guard string(window, kAXTitleAttribute) == title else { throw BridgeError("BOARD_CHANGED") }
        } else { _ = try boardWindow(app, title: title) }
        let before = state(area); let start = front(); let startEvents = events.count
        let result = try operation(); probeWait()
        log.append(["operation": name, "result": result, "before": before, "after": state(area), "frontBefore": start, "frontAfter": front(), "activations": Array(events.dropFirst(startEvents))])
        guard front() == sentinel, !events.dropFirst(startEvents).contains(where: { $0["bundle"] as? String == "com.apple.freeform" }) else { throw BridgeError("FOCUS_CHANGED_DURING_PROBE") }
    }
    if mode == "contextCopy" || mode == "contextPaste" || mode == "emptyPaste" {
        try targetedKey(running.processIdentifier, 53)
        // An empty canvas exposes no context menu, so emptyPaste pastes from a temporary circle and then deletes it.
        var bootstrap: AXUIElement?
        if mode == "emptyPaste" {
            try record("Insert bootstrap circle", {
                try pressButton(window, title: "Insert Shape")
                guard waitUntil({ descendants(app, depth: 15).contains { string($0, kAXRoleAttribute) == "AXPopover" } }),
                      let popover = descendants(app, depth: 15).first(where: { string($0, kAXRoleAttribute) == "AXPopover" }) else { throw BridgeError("NO_PICKER") }
                try pressButton(popover, title: "Circle")
                return ["inserted": waitUntil({ layoutItems(area).count == 1 })]
            })
            guard layoutItems(area).count == 1 else { throw BridgeError("BOOTSTRAP_UNVERIFIED") }
            bootstrap = layoutItems(area)[0]
            try targetedKey(running.processIdentifier, 53)
        }
        let item = bootstrap ?? (CommandLine.arguments.contains("--last") ? initial.last! : initial[0])
        let baseline = bootstrap.map { [$0] } ?? initial
        _ = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray)
        guard selectionMatches(area, [item]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        let transaction = try ClipboardTransaction(); clip = transaction
        try transaction.put(mode == "contextCopy" ? Data("[]".utf8) : Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        try record("Open refreshed object context menu", { ["axResult": AXUIElementPerformAction(item, kAXShowMenuAction as CFString).rawValue] })
        let menus = descendants(app, depth: 15).filter { string($0, kAXRoleAttribute) == "AXMenu" }
        guard let menu = menus.first(where: { children($0).contains { string($0, kAXTitleAttribute) == "Change Shape" } }),
              let command = children(menu).first(where: { string($0, kAXTitleAttribute) == (mode == "contextCopy" ? "Copy" : "Paste") }),
              attribute(command, kAXEnabledAttribute) as? Bool == true else { throw BridgeError("NO_ENABLED_CONTEXT_COMMAND") }
        try record(mode, allowContextMenu: true, {
            let baselineFrames = baseline.map { try? frame($0) }
            let result = AXUIElementPerformAction(command, kAXPressAction as CFString)
            if mode == "contextCopy" {
                var objects: [[String: Any]] = []
                var lastCount = transaction.board.changeCount
                var lastData: Data?
                var stableSince = Date()
                // Timeline of clipboard transitions: type names, payload length/hash, and foreground only; never contents.
                let copyStart = Date()
                var timeline: [[String: Any]] = []
                func snapshot(_ count: Int, _ data: Data?) {
                    let types = (transaction.board.types ?? []).map(\.rawValue)
                    var entry: [String: Any] = ["t": Date().timeIntervalSince(copyStart), "changeCount": count, "types": types,
                                                "hasNativeJSON": data != nil, "front": front(),
                                                "selected": selectionMatches(area, [item]),
                                                "purePasteMarker": types.contains("com.sindresorhus.Pure-Paste.hasRun")]
                    if let data {
                        entry["nativeLength"] = data.count
                        entry["nativeSHA256"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        entry["nativeObjectCount"] = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? -1
                    }
                    timeline.append(entry)
                }
                snapshot(lastCount, transaction.board.data(forType: contentType))
                let ready = waitUntil({
                    let count = transaction.board.changeCount
                    let data = transaction.board.data(forType: contentType)
                    if count != lastCount || data != lastData {
                        lastCount = count; lastData = data; stableSince = Date()
                        snapshot(count, data)
                    }
                    guard let data, let copied = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], copied.count == 1,
                          transaction.board.changeCount == count, Date().timeIntervalSince(stableSince) >= 0.5 else { return false }
                    objects = copied; transaction.expected = count; return true
                }, seconds: 15)
                // Keep observing briefly to catch a later rewrite by another clipboard client.
                _ = waitUntil({
                    let count = transaction.board.changeCount
                    if count != lastCount { lastCount = count; snapshot(count, transaction.board.data(forType: contentType)) }
                    return false
                }, seconds: 3)
                return ["axResult": result.rawValue, "copied": ready, "objects": objects, "clipboardTimeline": timeline]
            }
            var verification = try verifyPaste(area, baseline: baseline, baselineFrames: baselineFrames, payloadPath: CommandLine.arguments[2])
            verification["axResult"] = result.rawValue
            return verification
        })
        try targetedKey(running.processIdentifier, 53)
        if let bootstrap {
            _ = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [bootstrap] as CFArray)
            guard selectionMatches(area, [bootstrap]) else { throw BridgeError("BOOTSTRAP_SELECTION_UNVERIFIED") }
            let pasted = layoutItems(area).filter { !CFEqual($0, bootstrap) }
            let pastedFrames = pasted.map { try? frame($0) }
            try record("Delete bootstrap circle", {
                try targetedKey(running.processIdentifier, 51)
                let removed = waitUntil({ !layoutItems(area).contains { CFEqual($0, bootstrap) } })
                let remaining = layoutItems(area)
                let pastedIntact = remaining.count == pasted.count && zip(pasted, pastedFrames).allSatisfy { item, old in
                    old != nil && remaining.contains { CFEqual($0, item) } && (try? frame(item)) == old
                }
                return ["bootstrapRemoved": removed, "remainingCount": remaining.count, "pastedIntact": pastedIntact]
            })
        }
    } else if mode == "resizeAny" {
        // resizeAny "<handle name>" dx dy: drags one handle of the last object via AXPosition and reports the size change.
        let item = initial.last!
        let name = CommandLine.arguments[2]
        let dx = Double(CommandLine.arguments[3])!, dy = Double(CommandLine.arguments[4])!
        try record("Select object", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        guard selectionMatches(area, [item]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        guard let handles = attribute(item, "AXHandles") as? [AXUIElement], let handle = handles.first(where: { objectDescription($0) == name }) else { throw BridgeError("NO_HANDLE") }
        try record("Drag " + name, {
            let old = try frame(item)
            var position = try frame(handle).origin; position.x += dx; position.y += dy
            let result = AXUIElementSetAttributeValue(handle, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!)
            probeWait()
            let new = try frame(item)
            return ["axResult": result.rawValue, "before": [old.minX, old.minY, old.width, old.height], "after": [new.minX, new.minY, new.width, new.height]]
        })
        try targetedKey(running.processIdentifier, 53)
    } else if mode == "formatOptions" {
        // Discovery: select the last object, invoke its "Show format options" custom action, and list what appears.
        let item = initial.last!
        try record("Select object", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        guard selectionMatches(area, [item]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        func summary(_ e: AXUIElement) -> [String: Any] {
            var acts: CFArray?; AXUIElementCopyActionNames(e, &acts)
            return ["role": string(e, kAXRoleAttribute) ?? "", "subrole": string(e, kAXSubroleAttribute) ?? "", "title": string(e, kAXTitleAttribute) ?? "",
                    "description": objectDescription(e), "value": attribute(e, kAXValueAttribute).map { "\($0)" } ?? "",
                    "actions": ((acts as? [String]) ?? []).map { $0.components(separatedBy: "\n").first ?? $0 }]
        }
        let before = descendants(app, depth: 20)
        var itemActions: CFArray?; AXUIElementCopyActionNames(item, &itemActions)
        guard let action = ((itemActions as? [String]) ?? []).first(where: { $0.hasPrefix("Name:Show format options") }) else { throw BridgeError("NO_FORMAT_ACTION") }
        try record("Show format options", {
            let result = AXUIElementPerformAction(item, action as CFString)
            probeWait(1)
            let appeared = descendants(app, depth: 20).filter { e in !before.contains { CFEqual($0, e) } }
            return ["axResult": result.rawValue, "appearedCount": appeared.count,
                    "appeared": appeared.filter { !["AXGroup", "AXUnknown", "AXScrollArea", "AXLayoutArea"].contains(string($0, kAXRoleAttribute) ?? "") }.prefix(150).map(summary)]
        })
        // Optional: open one inspector (e.g. "Fill Inspector") and list its controls.
        if CommandLine.arguments.count > 2 {
            let inspector = CommandLine.arguments[2]
            let beforeInspector = descendants(app, depth: 25)
            guard let button = beforeInspector.first(where: { string($0, kAXRoleAttribute) == "AXButton" && objectDescription($0) == inspector }) else { throw BridgeError("NO_INSPECTOR") }
            try record("Open " + inspector, {
                let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
                probeWait(1)
                let appeared = descendants(app, depth: 25).filter { e in !beforeInspector.contains { CFEqual($0, e) } }
                return ["axResult": result.rawValue, "appearedCount": appeared.count,
                        "appeared": appeared.filter { !["AXGroup", "AXUnknown", "AXScrollArea"].contains(string($0, kAXRoleAttribute) ?? "") }.prefix(200).map(summary)]
            })
            // Optional: press one swatch/control in the inspector popover, then read the inspector button's value back.
            if CommandLine.arguments.count > 3 {
                let choice = CommandLine.arguments[3]
                guard let popover = descendants(app, depth: 25).first(where: { string($0, kAXRoleAttribute) == "AXPopover" }),
                      let control = descendants(popover).first(where: { string($0, kAXRoleAttribute) == "AXButton" && (objectDescription($0) == choice || string($0, kAXTitleAttribute) == choice) }) else { throw BridgeError("NO_CHOICE") }
                try record("Choose " + choice, {
                    let before = attribute(button, kAXValueAttribute).map { "\($0)" } ?? ""
                    let result = AXUIElementPerformAction(control, kAXPressAction as CFString)
                    probeWait(1)
                    let after = attribute(button, kAXValueAttribute).map { "\($0)" } ?? ""
                    let windows = children(app).filter { string($0, kAXRoleAttribute) == "AXWindow" }.map { string($0, kAXTitleAttribute) ?? "" }
                    // A system Colors panel, if one opened: list its editable controls, then close it.
                    var panel: [[String: Any]] = []
                    if let colors = children(app).first(where: { string($0, kAXRoleAttribute) == "AXWindow" && string($0, kAXTitleAttribute) == "Colors" }) {
                        panel = descendants(colors, depth: 12).filter { ["AXTextField", "AXRadioButton", "AXPopUpButton", "AXSlider", "AXTabGroup"].contains(string($0, kAXRoleAttribute) ?? "") }.prefix(60).map(summary)
                        if let raw = attribute(colors, kAXCloseButtonAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
                            _ = AXUIElementPerformAction(unsafeBitCast(raw, to: AXUIElement.self), kAXPressAction as CFString)
                        }
                    }
                    let popoverNow = descendants(app, depth: 25).filter { string($0, kAXRoleAttribute) == "AXPopover" }.flatMap { descendants($0, depth: 15) }
                        .filter { !["AXGroup", "AXUnknown"].contains(string($0, kAXRoleAttribute) ?? "") }.prefix(120).map(summary)
                    return ["axResult": result.rawValue, "inspectorValueBefore": before, "inspectorValueAfter": after, "appWindows": windows, "colorsPanel": panel, "popoverAfter": popoverNow]
                })
                _ = AXUIElementPerformAction(popover, kAXCancelAction as CFString)
            }
        }
        try targetedKey(running.processIdentifier, 53)
    } else if mode == "replaceLabel" {
        let index = Int(CommandLine.arguments[2])!
        guard [0, 1].contains(index) else { throw BridgeError("CONTROL_ONLY") }
        let item = initial[index]
        let label = index == 0 ? "Background A" : "Background B edited without clipboard"
        try record("Select rectangle for label replacement", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        guard selectionMatches(area, [item]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        try record("Type replacement label directly to Freeform", {
            let text = Array(label.utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
            down.flags = []; up.flags = []
            text.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
            down.postToPid(running.processIdentifier); probeWait(0.05); up.postToPid(running.processIdentifier)
            probeWait(); try targetedKey(running.processIdentifier, 53)
            return ["description": objectDescription(item), "exactLabelVerified": objectDescription(item) == label + ", Rectangle"]
        })
    } else if mode == "chooseShape" {
        let name = CommandLine.arguments[2]
        guard ["Circle", "Diamond", "Rounded Rectangle", "Connection Line"].contains(name) else { throw BridgeError("UNSUPPORTED_SHAPE_PROBE") }
        if !descendants(app, depth: 15).contains(where: { string($0, kAXRoleAttribute) == "AXPopover" }) {
            try record("Open shape picker", { try pressButton(window, title: "Insert Shape"); return [:] })
        }
        guard let popover = descendants(app, depth: 15).first(where: { string($0, kAXRoleAttribute) == "AXPopover" }) else { throw BridgeError("NO_PICKER") }
        try record("Insert " + name, { try pressButton(popover, title: name); return [:] })
        let added = layoutItems(area).filter { item in !initial.contains { CFEqual($0, item) } }
        guard added.count == 1, layoutItems(area).count == initial.count + 1 else { throw BridgeError("INSERT_UNVERIFIED") }
        log.append(["newShape": objectDescription(added[0]), "newShapeFrame": state(area).last ?? [:]])
    } else if mode == "resizeHandle" || mode == "childText" {
        let item = initial[0]
        guard objectDescription(item) == "Background A, Rectangle" else { throw BridgeError("CONTROL_CHANGED") }
        try record("Select control rectangle", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        guard selectionMatches(area, [item]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        if mode == "resizeHandle" {
            guard let handles = attribute(item, "AXHandles") as? [AXUIElement], let handle = handles.first(where: { objectDescription($0) == "Middle right Shape handle" }) else { throw BridgeError("NO_HANDLE") }
            try record("Move right resize handle +40", {
                let old = try frame(item)
                var position = try frame(handle).origin; position.x += 40
                let result = AXUIElementSetAttributeValue(handle, kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &position)!)
                probeWait()
                let new = try frame(item)
                return ["axResult": result.rawValue, "widthDelta": new.width - old.width, "heightDelta": new.height - old.height]
            })
        } else {
            guard let text = descendants(item).first(where: { string($0, kAXRoleAttribute) == "AXTextArea" }) else { throw BridgeError("NO_TEXT_CHILD") }
            try record("Set child text directly", {
                let result = AXUIElementSetAttributeValue(text, kAXValueAttribute as CFString, "Edited background rectangle" as CFString)
                probeWait()
                return ["axResult": result.rawValue, "readValue": string(text, kAXValueAttribute) ?? "", "verified": string(text, kAXValueAttribute) == "Edited background rectangle"]
            })
        }
    } else if mode == "handles" {
        let item = initial[0]
        try record("Select control rectangle", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        func inspectElement(_ element: AXUIElement) -> [String: Any] {
            var attrs: CFArray?; var acts: CFArray?
            AXUIElementCopyAttributeNames(element, &attrs); AXUIElementCopyActionNames(element, &acts)
            var writable: [String: Bool] = [:]
            for name in attrs as? [String] ?? [] { var flag: DarwinBoolean = false; _ = AXUIElementIsAttributeSettable(element, name as CFString, &flag); writable[name] = flag.boolValue }
            return ["role": string(element, kAXRoleAttribute) ?? "", "description": objectDescription(element), "value": String(describing: attribute(element, kAXValueAttribute)), "attributes": writable, "actions": acts as? [String] ?? []]
        }
        if let handles = attribute(item, "AXHandles") as? [AXUIElement] { log.append(["handles": handles.map(inspectElement)]) }
        log.append(["children": descendants(item).map(inspectElement)])
    } else if mode == "shapePicker" {
        try record("Open shape picker", { try pressButton(window, title: "Insert Shape"); return [:] })
        let nodes = descendants(app, depth: 15).filter { ["AXButton", "AXTextField", "AXSearchField", "AXCollection", "AXCollectionView", "AXCell", "AXImage", "AXPopover"].contains(string($0, kAXRoleAttribute) ?? "") }
        log.append(["pickerNodes": nodes.prefix(220).map { ["role": string($0, kAXRoleAttribute) ?? "", "title": string($0, kAXTitleAttribute) ?? "", "description": objectDescription($0), "value": string($0, kAXValueAttribute) ?? ""] }])
    } else if mode == "contextMenu" {
        let item = initial[0]
        try record("Select control rectangle", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        try record("Show object context menu", { ["axResult": AXUIElementPerformAction(item, kAXShowMenuAction as CFString).rawValue] })
        let menus = descendants(app, depth: 15).filter { string($0, kAXRoleAttribute) == "AXMenu" && children($0).contains { string($0, kAXTitleAttribute) == "Change Shape" } }
        log.append(["menus": menus.map { menu in descendants(menu, depth: 3).map { ["title": string($0, kAXTitleAttribute) ?? "", "enabled": attribute($0, kAXEnabledAttribute) as? Bool ?? false] } }])
    } else if mode == "editExisting" {
        let item = initial[0]
        guard objectDescription(item) == "Background A, Rectangle" else { throw BridgeError("CONTROL_CHANGED") }
        try record("Select existing rectangle", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [item] as CFArray).rawValue] })
        try record("Enter label editor", { try targetedKey(running.processIdentifier, 36); return [:] })
        guard let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { throw BridgeError("NO_EDITOR") }
        let editor = unsafeBitCast(raw, to: AXUIElement.self)
        var attrs: CFArray?; AXUIElementCopyAttributeNames(editor, &attrs)
        var writable: [String: Bool] = [:]
        for name in attrs as? [String] ?? [] { var flag: DarwinBoolean = false; _ = AXUIElementIsAttributeSettable(editor, name as CFString, &flag); writable[name] = flag.boolValue }
        log.append(["editorRole": string(editor, kAXRoleAttribute) ?? "", "editorValue": string(editor, kAXValueAttribute) ?? "", "attributes": writable])
        if ["AXTextArea", "AXTextField"].contains(string(editor, kAXRoleAttribute) ?? ""), writable[kAXValueAttribute] == true {
            try record("Replace existing text through AX", { ["axResult": AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, "Edited background rectangle" as CFString).rawValue] })
        }
        try record("Finish edit", { try targetedKey(running.processIdentifier, 53); return [:] })
    } else
    if mode == "layout" {
        let origin = try frame(window).origin
        let destinations: [(String, Double, Double)] = [
            ("Background A, Rectangle", 340, 220), ("Background B, Rectangle", 580, 220),
            ("Created in background without clipboard, sticky note", 340, 380),
            ("Background text box — no clipboard, text box", 640, 410),
            ("Second background text — verified, text box", 640, 490)]
        guard initial.count == destinations.count else { throw BridgeError("UNEXPECTED_OBJECTS") }
        for (description, x, y) in destinations {
            let matches = layoutItems(area).filter { objectDescription($0) == description }
            guard matches.count == 1 else { throw BridgeError("AMBIGUOUS_TARGET") }
            try record("Position " + description, {
                _ = AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, matches as CFArray)
                guard selectionMatches(area, matches) else { throw BridgeError("SELECTION_UNVERIFIED") }
                var point = CGPoint(x: origin.x + x, y: origin.y + y)
                let rc = AXUIElementSetAttributeValue(matches[0], kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!)
                probeWait()
                let actual = try frame(matches[0]).origin
                guard rc == .success, abs(actual.x - point.x) < 0.01, abs(actual.y - point.y) < 0.01 else { throw BridgeError("POSITION_UNVERIFIED") }
                return ["axResult": rc.rawValue, "positionVerified": true]
            })
        }
    } else if mode == "createTextAndType" {
        let count = layoutItems(area).count
        try record("Create text box", { try pressButton(window, title: "Insert Text Box"); return [:] })
        let added = layoutItems(area).filter { item in !initial.contains { CFEqual($0, item) } }
        guard added.count == 1, layoutItems(area).count == count + 1, objectDescription(added[0]) == "text box", selectionMatches(area, added) else { throw BridgeError("INSERT_UNVERIFIED") }
        try record("Type text without clipboard", {
            let text = Array("Second background text — verified".utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
            down.flags = []; up.flags = []
            text.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
            down.postToPid(running.processIdentifier); probeWait(0.05); up.postToPid(running.processIdentifier)
            return [:]
        })
        try record("Finish text editing", { try targetedKey(running.processIdentifier, 53); return [:] })
        guard objectDescription(added[0]) == "Second background text — verified, text box" else { throw BridgeError("TEXT_UNVERIFIED") }
    } else if mode == "screenshot" {
        try record("Background window screenshot", {
            var result = try screenshot(app, window: window, title: title, pid: running.processIdentifier)
            let data = Data(base64Encoded: result.removeValue(forKey: "imageBase64") as! String)!
            try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            return result
        })
    } else if mode == "typeStickyPid" || mode == "typeTextPid" {
        let selected = layoutItems(area).filter { attribute($0, kAXSelectedAttribute) as? Bool == true }
        guard selected.count == 1, objectDescription(selected[0]) == (mode == "typeTextPid" ? "text box" : "sticky note") else { throw BridgeError("UNEXPECTED_SELECTION") }
        try record("Type sticky via PID", {
            let text = Array((mode == "typeTextPid" ? "Background text box — no clipboard" : "Created in background without clipboard").utf16)
            let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
            let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)!
            down.flags = []; up.flags = []
            text.withUnsafeBufferPointer { down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!) }
            down.postToPid(running.processIdentifier); probeWait(0.05); up.postToPid(running.processIdentifier)
            return [:]
        })
        try record("Finish typing", { try targetedKey(running.processIdentifier, 53); return [:] })
    } else if mode == "editTextAX" {
        let selected = layoutItems(area).filter { attribute($0, kAXSelectedAttribute) as? Bool == true }
        guard selected.count == 1, objectDescription(selected[0]) == "sticky note" else { throw BridgeError("UNEXPECTED_SELECTION") }
        var actions: CFArray?; AXUIElementCopyActionNames(selected[0], &actions)
        guard let action = (actions as? [String])?.first(where: { $0.contains("Name:Edit text") }) else { throw BridgeError("NO_EDIT_ACTION") }
        try record("Edit text AX action", { ["axResult": AXUIElementPerformAction(selected[0], action as CFString).rawValue] })
        if let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let editor = unsafeBitCast(raw, to: AXUIElement.self)
            var writable: DarwinBoolean = false
            _ = AXUIElementIsAttributeSettable(editor, kAXValueAttribute as CFString, &writable)
            log.append(["editorRole": string(editor, kAXRoleAttribute) ?? "", "valueSettable": writable.boolValue])
            if writable.boolValue, ["AXTextArea", "AXTextField"].contains(string(editor, kAXRoleAttribute) ?? "") {
                try record("Set sticky text", { ["axResult": AXUIElementSetAttributeValue(editor, kAXValueAttribute as CFString, "Created in the background without clipboard" as CFString).rawValue] })
                try record("Finish editing", { try targetedKey(running.processIdentifier, 53); return [:] })
            }
        }
    } else if mode == "focused" {
        if let raw = attribute(app, kAXFocusedUIElementAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            let element = unsafeBitCast(raw, to: AXUIElement.self)
            var attrs: CFArray?; AXUIElementCopyAttributeNames(element, &attrs)
            var writable: [String: Bool] = [:]
            for attr in attrs as? [String] ?? [] { var flag: DarwinBoolean = false; _ = AXUIElementIsAttributeSettable(element, attr as CFString, &flag); writable[attr] = flag.boolValue }
            log.append(["role": string(element, kAXRoleAttribute) ?? "", "value": string(element, kAXValueAttribute) ?? "", "attributes": writable])
        }
    } else if mode == "insertStickyAX" || mode == "insertTextAX" {
        try record(mode, {
            try pressButton(window, title: mode == "insertStickyAX" ? "Insert Sticky Note" : "Insert Text Box")
            return [:]
        })
    } else if mode == "toolbar" {
        for element in descendants(window).filter({ string($0, kAXRoleAttribute) == "AXButton" || string($0, kAXRoleAttribute) == "AXMenuButton" }) {
            log.append(["role": string(element, kAXRoleAttribute) ?? "", "title": string(element, kAXTitleAttribute) ?? "", "description": objectDescription(element), "help": string(element, kAXHelpAttribute) ?? "", "enabled": attribute(element, kAXEnabledAttribute) as? Bool ?? false])
        }
    } else if mode == "inspect" {
        for (name, element) in [("canvas", area), ("item", initial[0])] {
            var attrs: CFArray?; var actions: CFArray?
            AXUIElementCopyAttributeNames(element, &attrs); AXUIElementCopyActionNames(element, &actions)
            var writable: [String: Bool] = [:]
            for attr in attrs as? [String] ?? [] { var flag: DarwinBoolean = false; _ = AXUIElementIsAttributeSettable(element, attr as CFString, &flag); writable[attr] = flag.boolValue }
            log.append(["element": name, "attributes": writable, "actions": actions as? [String] ?? []])
        }
    } else if mode == "positionSelected" || mode == "resizeSelected" {
        try record("AX select one", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [initial[0]] as CFArray).rawValue] })
        guard selectionMatches(area, [initial[0]]) else { throw BridgeError("SELECTION_UNVERIFIED") }
        try record(mode, {
            if mode == "positionSelected" {
                var point = try frame(initial[0]).origin; point.x += 20
                return ["axResult": AXUIElementSetAttributeValue(initial[0], kAXPositionAttribute as CFString, AXValueCreate(.cgPoint, &point)!).rawValue]
            }
            var size = try frame(initial[0]).size; size.width += 20
            return ["axResult": AXUIElementSetAttributeValue(initial[0], kAXSizeAttribute as CFString, AXValueCreate(.cgSize, &size)!).rawValue]
        })
    } else if mode == "selectEach" {
        for item in initial {
            try record("AXSelected true", { ["axResult": AXUIElementSetAttributeValue(item, kAXSelectedAttribute as CFString, kCFBooleanTrue).rawValue] })
        }
    } else if mode == "position" {
        try record("AXPosition +20", {
            var point = try frame(initial[0]).origin; point.x += 20
            let value = AXValueCreate(.cgPoint, &point)!
            return ["axResult": AXUIElementSetAttributeValue(initial[0], kAXPositionAttribute as CFString, value).rawValue]
        })
    } else if mode == "nudge" {
        try record("AX select one", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, [initial[0]] as CFArray).rawValue] })
        try record("postToPid right", { try targetedKey(running.processIdentifier, 124); return [:] })
    } else if mode == "pasteAX" || mode == "pastePid" || mode == "pasteUnicode" {
        let transaction = try ClipboardTransaction(); clip = transaction
        try transaction.put(Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
        try record(mode, {
            if mode == "pasteUnicode" {
                let text = Array("v".utf16)
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)!
                down.flags = .maskCommand; up.flags = .maskCommand
                text.withUnsafeBufferPointer {
                    down.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!)
                    up.keyboardSetUnicodeString(stringLength: text.count, unicodeString: $0.baseAddress!)
                }
                down.postToPid(running.processIdentifier); probeWait(0.05); up.postToPid(running.processIdentifier); probeWait(1)
                return [:]
            }
            if mode == "pastePid" { try targetedKey(running.processIdentifier, 9, flags: .maskCommand); return [:] }
            let item = try editItem(app, "Paste")
            return ["enabled": attribute(item, kAXEnabledAttribute) as? Bool ?? false, "axResult": AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue]
        })
    } else if mode == "copyAX" || mode == "copyPid" {
        let transaction = try ClipboardTransaction(); clip = transaction
        try transaction.put(Data("[]".utf8))
        try record(mode, {
            if mode == "copyPid" { try targetedKey(running.processIdentifier, 8, flags: .maskCommand) }
            else { _ = AXUIElementPerformAction(try editItem(app, "Copy"), kAXPressAction as CFString) }
            probeWait(1)
            guard let data = transaction.board.data(forType: contentType),
                  let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]], !objects.isEmpty else { return ["copied": false] }
            transaction.expected = transaction.board.changeCount
            return ["copied": true, "objects": objects]
        })
    } else if mode == "groupAX" || mode == "alignAX" {
        try record("AX select all", { ["axResult": AXUIElementSetAttributeValue(area, kAXSelectedChildrenAttribute as CFString, initial as CFArray).rawValue] })
        try record(mode, {
            let item = try arrangementItem(app, action: mode == "groupAX" ? "group" : "left")
            return ["axResult": AXUIElementPerformAction(item, kAXPressAction as CFString).rawValue]
        })
    }
    if let clip { log.append(["clipboardExpectedCount": clip.expected, "clipboardActualCountBeforeRestore": clip.board.changeCount]) }
    let restored = clip?.restore(); clip = nil
    emit(["ok": true, "mode": mode, "boardTitle": title, "frontAfter": front(), "events": events, "log": log, "clipboardRestored": restored as Any? ?? NSNull()])
} catch {
    let restored = clip?.restore()
    emit(["ok": false, "error": String(describing: error), "frontAfter": front(), "events": events, "log": log, "clipboardRestored": restored as Any? ?? NSNull()])
    exit(1)
}
