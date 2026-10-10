import AppKit
import Foundation

// Hold the original clipboard only in memory during this controlled experiment.
let board = NSPasteboard.general
let original: [[(NSPasteboard.PasteboardType, Data)]] = (board.pasteboardItems ?? []).map { item in
    item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
}
var expectedChange = board.changeCount
func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
    fflush(stdout)
}
emit(["ready": true])
while let line = readLine() {
    do {
        let request = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: String]
        switch request["command"] {
        case "capture":
            let items = board.pasteboardItems ?? []
            guard items.contains(where: { $0.types.contains(where: { $0.rawValue.hasPrefix("com.apple.freeform.") || $0.rawValue.hasPrefix("com.apple.apps.content-language.") }) }) else {
                emit(["error": "Clipboard is not a Freeform test object; nothing captured"])
                continue
            }
            let directory = URL(fileURLWithPath: request["directory"]!, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest: [[String: Any]] = []
            for (i, item) in items.enumerated() {
                for (j, type) in item.types.enumerated() {
                    guard let data = item.data(forType: type) else { continue }
                    let name = "item-\(i)-type-\(j).bin"
                    try data.write(to: directory.appendingPathComponent(name))
                    manifest.append(["item": i, "type": type.rawValue, "file": name, "bytes": data.count])
                }
            }
            try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("manifest.json"))
            expectedChange = board.changeCount
            emit(["captured": manifest, "changeCount": expectedChange])
        case "write":
            guard board.changeCount == expectedChange else { emit(["error": "Clipboard changed externally; refusing overwrite"]); continue }
            let data = try Data(contentsOf: URL(fileURLWithPath: request["path"]!))
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(request["type"]!))
            board.clearContents()
            let success = board.writeObjects([item])
            expectedChange = board.changeCount
            emit(["written": success, "bytes": data.count, "types": board.types?.map(\.rawValue) ?? [], "changeCount": expectedChange])
        case "restore":
            guard board.changeCount == expectedChange else { emit(["error": "Clipboard changed externally; original not restored"]); continue }
            let items = original.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            board.clearContents()
            let success = items.isEmpty || board.writeObjects(items)
            expectedChange = board.changeCount
            emit(["restored": success])
        case "exit":
            exit(0)
        default:
            emit(["error": "Unknown command"])
        }
    } catch {
        emit(["error": String(describing: error)])
    }
}
