import CoreGraphics
import AppKit
// Samples every 100 ms: frontmost app and Freeform's index among on-screen layer-0 windows (0 = topmost).
setbuf(stdout, nil)
let start = Date()
while true {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    let normal = list.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
    let idx = normal.firstIndex { ($0[kCGWindowOwnerName as String] as? String) == "Freeform" } ?? -1
    let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
    print(String(format: "%.2f", Date().timeIntervalSince(start)), idx, front)
    usleep(100_000)
}
