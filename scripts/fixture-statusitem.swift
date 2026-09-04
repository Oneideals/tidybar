// M0 夹具：在菜单栏造 N 个可预期的图标，用来统计枚举/拖拽的成功率。
// 由 scripts/fixture-statusitem.sh 调用，也可单独运行：
//     swift scripts/fixture-statusitem.swift 6
import AppKit

let count = max(1, min(20, Int(CommandLine.arguments.dropFirst().first ?? "6") ?? 6))

final class Fixture: NSObject, NSApplicationDelegate {
    private var items: [NSStatusItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for index in 1...count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "F\(index)"
            item.button?.toolTip = "TidyBar fixture \(index)"
            items.append(item)
        }
        print("已创建 \(count) 个菜单栏图标，Ctrl+C 退出")
    }
}

let app = NSApplication.shared
let fixture = Fixture()
app.delegate = fixture
app.run()
