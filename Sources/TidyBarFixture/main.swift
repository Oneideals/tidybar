import AppKit

// M0 验证项 2 的实验品：造 N 个我们自己的菜单栏图标。
//
// 为什么必须单独做一个打包 App 而不是在探针进程里造图标：
// M0 验证项 1 已实测——无 bundle 的 CLI 进程根本不发布 AXExtrasMenuBar，
// 自造图标读不到，拿它做拖拽实验会得出「机制不工作」的假结论。
//
// 由 scripts/build-fixture-app.sh 包成 Fixture.app（bundle id local.tidybar.fixture）。
// 用法：swift run tidybar-fixture 4   （或 open dist/TidyBarFixture.app --args 4）

let count = max(1, min(12, Int(CommandLine.arguments.dropFirst().first ?? "4") ?? 4))

final class FixtureApplication: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var items: [NSStatusItem] = []
    private var menus: [NSMenu] = []

    /// 事件日志。真机验证靠它拿"已知答案"：工具代点成功 → 这里必须多一行。
    /// 没有这行读数，"点击转发"就只能靠人盯屏幕，等于没验证。
    private func log(_ message: String) {
        let line = "FIXTURE-EVENT " + message + "\n"
        FileHandle.standardError.write(line.data(using: .utf8) ?? Data())
        if let path = ProcessInfo.processInfo.environment["TIDYBAR_FIXTURE_LOG"],
           let handle = FileHandle(forWritingAtPath: path) {
            handle.write(line.data(using: .utf8) ?? Data())
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        log("menu-open " + (menu.title))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for index in 1...count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            let title = "FX" + String(index)
            item.button?.title = title
            item.button?.toolTip = "TidyBar M0 fixture " + String(index)
            // 挂上菜单：AXPress 的真实效果就是"打开菜单"，这样代点成功与否是可观测的
            let menu = NSMenu(title: title)
            menu.delegate = self
            menu.addItem(NSMenuItem(title: "被代点过的菜单项", action: nil, keyEquivalent: ""))
            item.menu = menu
            items.append(item)
            menus.append(menu)
        }
        log("launched count=\(count) pid=\(ProcessInfo.processInfo.processIdentifier)")
        let pid = ProcessInfo.processInfo.processIdentifier
        let message = "TidyBarFixture: 已创建 \(count) 个图标，pid=\(pid)"
        FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    }
}

let app = NSApplication.shared
let delegate = FixtureApplication()
app.delegate = delegate
app.run()
