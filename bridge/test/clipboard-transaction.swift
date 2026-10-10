// Appended to the helper declarations by run-clipboard-tests.mjs.
// A unique pasteboard exercises real AppKit behavior without touching general.
let testBoard = NSPasteboard.withUniqueName()
defer { testBoard.releaseGlobally() }
let testType = NSPasteboard.PasteboardType("local.freeform.bridge.test")
func seed(_ text: String) {
    testBoard.clearContents()
    let item = NSPasteboardItem()
    item.setString(text, forType: .string)
    item.setData(Data([0, 1, 2, 255]), forType: testType)
    precondition(testBoard.writeObjects([item]))
}
seed("original")
let preserved = try ClipboardTransaction(board: testBoard)
try preserved.put(Data("[]".utf8))
precondition(preserved.restore())
precondition(testBoard.string(forType: .string) == "original")
precondition(testBoard.data(forType: testType) == Data([0, 1, 2, 255]))

let interrupted = try ClipboardTransaction(board: testBoard)
try interrupted.put(Data("[]".utf8))
seed("new user copy")
precondition(!interrupted.restore())
precondition(testBoard.string(forType: .string) == "new user copy")
do {
    try interrupted.put(Data("[]".utf8))
    fatalError("A changed clipboard must reject another bridge write")
} catch is BridgeError {}
precondition(testBoard.string(forType: .string) == "new user copy")

testBoard.clearContents()
let empty = try ClipboardTransaction(board: testBoard)
try empty.put(Data("[]".utf8))
precondition(empty.restore())
precondition(testBoard.pasteboardItems?.isEmpty ?? true)
print("PASS: multi-format restoration, concurrent-copy preservation, write conflict, empty restoration")
