import AppKit
import TidyBarCore

// M0 验证项 1 探针。输出全部写进 stdout，结论记 docs/findings/01-enumeration.md。
// 用法：
//   swift run tidybar-probe                 单次枚举 + 明细
//   swift run tidybar-probe --repeat 20     连测 20 次拿耗时分布（定节流值）
//   swift run tidybar-probe --fixture 8          额外造 8 个图标（只能肉眼确认，CLI 不发布 extras）
//   swift run tidybar-probe --expect-bundle <id>  断言某个已打包 App 的自有图标可被枚举（已知答案）
//   swift run tidybar-probe --lab                扫描参数 A/B：并发度 × 超时，只看覆盖率与耗时
//   swift run tidybar-probe --concurrency 4 --timeout 500   单点复测（覆盖率/耗时的某个具体配置）

let arguments = CommandLine.arguments
let repeatCount = arguments.firstIndex(of: "--repeat").flatMap { index in
    index + 1 < arguments.count ? Int(arguments[index + 1]) : nil
} ?? 1
let fixtureCount = arguments.firstIndex(of: "--fixture").flatMap { index in
    index + 1 < arguments.count ? Int(arguments[index + 1]) : nil
}
let expectBundle = arguments.firstIndex(of: "--expect-bundle").flatMap { index -> String? in
    index + 1 < arguments.count ? arguments[index + 1] : nil
}

// MARK: - 自建已知图标（可控性验证：这些图标的存在是已知答案）

// 纯 CLI 进程不是 GUI app：不先转成 accessory，NSStatusItem 根本挂不上，
// 进程也不会出现在 runningApplications 里 → 自建图标 0/6 就是这个原因。
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
RunLoop.current.run(until: Date().addingTimeInterval(0.2))

var fixtureItems: [NSStatusItem] = []
var expectedFixtureTitles: [String] = []
if let fixtureCount, fixtureCount > 0 {
    for index in 1...fixtureCount {
        let title = "M0\(index)"
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = title
        item.button?.toolTip = "TidyBar M0 fixture"
        fixtureItems.append(item)
        expectedFixtureTitles.append(title)
    }
    // 状态项要等若干次 runloop 才会真正挂到菜单栏上
    for _ in 0..<10 { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
}

/// 扫描节奏可以从命令行覆盖。`--lab` 用它做参数 A/B：
/// 覆盖率与耗时是一对真实矛盾（超时越短跑得越快、丢的图标越多），不实测就没资格选值。
func scanConfig(concurrency: Int?, timeoutMS: Int?) -> AccessibilityMenuBarReader.Config {
    var config = AccessibilityMenuBarReader.Config()
    if let concurrency { config.processConcurrency = concurrency }
    // --timeout -1 = 完全不设超时（A/B 的对照组）
    if let timeoutMS {
        config.processMessagingTimeout = timeoutMS < 0 ? .infinity : Double(timeoutMS) / 1000
    }
    return config
}

func intArgument(_ flag: String) -> Int? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return Int(arguments[index + 1])
}

/// 覆盖率的"已知答案"基准 = 本次运行里第一次串行无超时扫描。
/// 不能拿历史数字比：菜单栏图标本来就随 App 启停变化，那样测出来的是噪声不是回归。
func runScan(concurrency: Int, timeoutMS: Int?) -> (icons: Int, processes: Int, ms: Int) {
    let report = AccessibilityMenuBarReader(config: scanConfig(concurrency: concurrency, timeoutMS: timeoutMS)).enumerate()
    return (report.items.count, report.accessibleProcessCount, report.totalMicroseconds / 1000)
}

/// 只跑第一次枚举就打一行结论退出。冷启动成本必须在**全新进程**里量——
/// 同一个进程里的第二次扫描已经是热的，拿它当"启动到接管"是自欺。
if arguments.contains("--first-only") {
    let concurrency = intArgument("--concurrency") ?? AccessibilityMenuBarReader.Config().processConcurrency
    let timeoutMS = intArgument("--timeout")
    let result = runScan(concurrency: concurrency, timeoutMS: timeoutMS)
    // 打印"生效值"而不是"传了什么参数"：省略 --timeout 时打 t=0 会被读成"超时为 0"，
    // 而实际用的是默认 500ms——一张表里两个含义就等着被误读。
    let shownTimeout = timeoutMS.map(String.init)
        ?? "\(Int(AccessibilityMenuBarReader.Config().processMessagingTimeout * 1000))(默认)"
    print("FIRST c=\(concurrency) t=\(shownTimeout) icons=\(result.icons) processes=\(result.processes) ms=\(result.ms)")
    exit(0)
}

if arguments.contains("--lab") {
    let rounds = intArgument("--rounds") ?? 3
    let matrix: [(label: String, concurrency: Int, timeoutMS: Int?)] = [
        ("串行·无超时(基线)", 1, nil),
        ("串行·500ms", 1, 500),
        ("并发6·无超时", 6, nil),
        ("并发6·500ms", 6, 500),
        ("并发6·150ms", 6, 150),
        ("并发12·500ms", 12, 500),
    ]
    let baseline = runScan(concurrency: 1, timeoutMS: nil)
    print("LAB 基准（串行·无超时·第 0 次）icons=\(baseline.icons) processes=\(baseline.processes) ms=\(baseline.ms)")
    for entry in matrix {
        var iconDeltas: [String] = []
        var procDeltas: [String] = []
        var times: [String] = []
        var worstIconDelta = 0
        for _ in 1...rounds {
            let result = runScan(concurrency: entry.concurrency, timeoutMS: entry.timeoutMS)
            let iconDelta = result.icons - baseline.icons
            let procDelta = result.processes - baseline.processes
            worstIconDelta = min(worstIconDelta, iconDelta)
            iconDeltas.append("\(iconDelta >= 0 ? "+" : "")\(iconDelta)")
            procDeltas.append("\(procDelta >= 0 ? "+" : "")\(procDelta)")
            times.append("\(result.ms)")
        }
        print("\(entry.label) 最差图标Δ=\(worstIconDelta) 图标Δ=[\(iconDeltas.joined(separator: " "))] 进程Δ=[\(procDeltas.joined(separator: " "))] ms=[\(times.joined(separator: " "))]")
    }
    exit(0)
}

let reader = AccessibilityMenuBarReader(
    config: scanConfig(concurrency: intArgument("--concurrency"), timeoutMS: intArgument("--timeout"))
)

func printHeader(_ title: String) {
    print("\n===== \(title) =====")
}

// MARK: - 环境

printHeader("环境")
print("系统版本: \(ProcessInfo.processInfo.operatingSystemVersionString)")
print("屏幕:")
for screen in NSScreen.screens {
    let info = ScreenInfo(
        identifier: 0,
        frame: screen.frame,
        menuBarHeight: screen.frame.maxY - screen.visibleFrame.maxY,
        notchWidth: screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil
            ? screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? 0) - (screen.auxiliaryTopRightArea?.width ?? 0)
            : nil,
        isBuiltin: false
    )
    print("  \(info.frame) 菜单栏高 \(info.menuBarHeight) 刘海宽 \(info.notchWidth.map { String(format: "%.0f", $0) } ?? "无")")
}

let firstReport = reader.enumerate()
print("辅助功能权限: \(firstReport.accessibilityGranted ? "已授予" : "未授予 ← 先去系统设置授权，否则后面全是空结果")")
guard firstReport.accessibilityGranted else {
    print("\n⛔ 未授权，终止。授权后重跑：系统设置 → 隐私与安全性 → 辅助功能")
    exit(2)
}

// MARK: - 枚举明细

printHeader("图标明细（按 x 从右到左 = 真实菜单栏视觉顺序）")
let sorted = MenuBarEnumeration.sortedLeftToRight(firstReport.items).reversed()
print(String(format: "%-34@ %-22@ %-9@ %@", "owner", "title", "x", "y/宽/高"))
for item in sorted {
    print(String(
        format: "%-34@ %-22@ %-9@ %.0f/%.0f/%.0f",
        item.ownerBundleID ?? "(nil)",
        String(item.title.prefix(20)),
        String(format: "%.0f", item.frame.minX),
        item.frame.minY,
        item.frame.width,
        item.frame.height
    ))
}
print("共 \(firstReport.items.count) 个图标")

// MARK: - 覆盖率与耗时

printHeader("逐进程覆盖情况（只列有 extras 或名字可疑的）")
let interesting = firstReport.probes
    .filter { $0.itemCount > 0 || !$0.hasExtrasMenuBar }
    .sorted { $0.itemCount > $1.itemCount }
print("可访问进程: \(firstReport.accessibleProcessCount) / 探测 \(firstReport.probes.count) 个（无 extras 的 \(firstReport.failedProcessCount) 个属正常，多数 App 没有状态项）")
for probe in firstReport.probes where probe.itemCount > 0 {
    print(String(format: "  %-40@ items=%-3d extras=有  %6dµs  pid=%d",
                 probe.bundleID ?? "(nil)", probe.itemCount, probe.microseconds, probe.pid))
}

printHeader("耗时")
print(String(format: "单次全量枚举: %.2f ms", Double(firstReport.totalMicroseconds) / 1000))

if repeatCount > 1 {
    var samples: [Double] = []
    for _ in 0..<repeatCount {
        samples.append(Double(reader.enumerate().totalMicroseconds) / 1000)
    }
    let sortedSamples = samples.sorted()
    func percentile(_ p: Double) -> Double {
        let index = min(sortedSamples.count - 1, max(0, Int(Double(sortedSamples.count - 1) * p)))
        return sortedSamples[index]
    }
    print(String(format: "连测 %d 次: p50=%.2fms p95=%.2fms max=%.2fms",
                 repeatCount, percentile(0.5), percentile(0.95), sortedSamples.last ?? 0))
    print("→ 节流值应 ≥ p95，且只在图标增删/前台切换时触发，不做定时轮询")
}

// MARK: - 稳定性：同一进程内同名图标

printHeader("稳定性检查")
let grouped = Dictionary(grouping: firstReport.items, by: \.id)
let collisions = grouped.filter { $0.value.count > 1 }
print(collisions.isEmpty
    ? "✓ id 唯一（重名图标已加 #n 后缀区分）"
    : "✗ 仍有 \(collisions.count) 组 id 冲突，说明去重逻辑没覆盖这种形态")

printHeader("身份来源分布（决定设置界面里「按位置认领」标注的覆盖面）")
for source in ItemIdentitySource.allCases {
    let matched = firstReport.items.filter { $0.identitySource == source }
    let example = matched.first?.ownerBundleID ?? "-"
    print("  " + source.rawValue + ": " + String(matched.count) + " 个   例: " + example)
}
let positional = firstReport.items.filter(\.isPositionalIdentity).count
let positionalRatio = Double(positional) / Double(max(1, firstReport.items.count)) * 100
print("→ 只能靠进程内序号识别的占 " + String(format: "%.0f%%", positionalRatio))

let systemItems = firstReport.items.filter(\.isSystemOwned)
print("系统托管图标 \(systemItems.count) 个（默认不参与自动隐藏）")

printHeader("策略拦截明细（为何比 AX 原始子项数少）")
if firstReport.rejections.isEmpty {
    print("无拦截项")
} else {
    for reason in MenuBarItemPolicy.Rejection.allCases {
        if let count = firstReport.rejections[reason], count > 0 {
            print("  \(reason.rawValue): \(count) — \(reason.explanation)")
        }
    }
    print("合计拦截 \(firstReport.rejectedCount) 项，接受 \(firstReport.items.count) 项")
}

let zeroWidth = firstReport.items.filter { $0.frame.width <= 0 || $0.frame.height <= 0 }
print(zeroWidth.isEmpty ? "✓ 无零尺寸图标" : "✗ \(zeroWidth.count) 个零尺寸图标（AX 返回脏数据，需过滤）")

let offScreen = firstReport.items.filter { item in
    !NSScreen.screens.contains { $0.frame.intersects(item.frame) }
}
print(offScreen.isEmpty ? "✓ 所有图标坐标都落在某块屏幕内" : "✗ \(offScreen.count) 个图标坐标越界 ← 坐标换算有 bug")

// MARK: - 自建图标核对

// MARK: - 已知答案核对

// 关键事实：无 bundle 的 CLI 进程根本不发布 AXExtrasMenuBar，所以「探针自己造的图标」
// 枚举不到是预期的，不能用它判定 reader 好坏。真正可复现的判定必须针对一个已打包 App。
if !expectedFixtureTitles.isEmpty {
    printHeader("探针自建图标（仅用于肉眼确认菜单栏可见）")
    let found = firstReport.items.filter { expectedFixtureTitles.contains($0.title) }
    print("CLI 进程不发布 AXExtrasMenuBar，读到 \(found.count)/\(expectedFixtureTitles.count) 属预期；")
    print("判定 reader 请用：swift run tidybar-probe --expect-bundle local.tidybar.app")
}

if let expectBundle {
    printHeader("已知答案核对：\(expectBundle) 的自有图标是否可枚举")
    let owned = firstReport.items.filter { $0.ownerBundleID == expectBundle }
    if owned.isEmpty {
        print("✗ 一个都没读到 —— reader 或权限有问题（该 App 是否真的在菜单栏有图标？）")
        exit(1)
    }
    for item in owned {
        print("  ✓ 读到 \"\(item.title)\" @ \(Int(item.frame.minX)),\(Int(item.frame.minY)) \(Int(item.frame.width))x\(Int(item.frame.height)) 身份=\(item.identitySource.rawValue)")
    }
    print("✓ 通路可用：归属→图标→坐标 全链路读通")
}
