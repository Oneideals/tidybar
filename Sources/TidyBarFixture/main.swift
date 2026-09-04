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

final class FixtureApplication: NSObject, NSApplicationDelegate {
    private var items: [NSStatusItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        for index in 1...count {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.title = "FX" + String(index)
            item.button?.toolTip = "TidyBar M0 fixture " + String(index)
            items.append(item)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let message = "TidyBarFixture: 已创建 \(count) 个图标，pid=\(pid)"
        FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
    }
}

let app = NSApplication.shared
let delegate = FixtureApplication()
app.delegate = delegate
app.run()
