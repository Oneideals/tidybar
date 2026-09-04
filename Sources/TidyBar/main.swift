import AppKit
import TidyBarCore

// 入口保持极简：所有逻辑在 TidyBarCore，便于 swift test 直接覆盖。
// 正式 .app 由 scripts/build-app.sh 组装（含 Info.plist 的 LSUIElement 声明）。
let app = NSApplication.shared
let delegate = TidyBarApplication()
app.delegate = delegate
app.run()
