import AppKit
import CoreGraphics
import Foundation
import ImageIO
import TidyBarCore

// 真实菜单栏闸门：在**我们自己的 ☰ 图标**上跑 ⌘ 拖拽，邻居是用户真实的第三方图标。
//
// 为什么这样设计：M0 的 100/100 全部是在自造 fixture 图标上取得的，而 fixture 的邻居也是
// fixture——从没验证过"在真实的、别的 App 的图标之间落点"是什么行为。用我们自己的图标当被拖对象，
// 落点/邻居/系统路径全是真的，但用户不会有任何图标被我们主动搬走。
//
// 注意：把我们的图标挪到某个邻居的槽位，那个邻居会顺带位移一格，所以每一轮都成对反做，
// 结束时必须核对全局顺序回到初始状态；回不去就大声报错并留下现场顺序，绝不静默。
//
//   ./scripts/build-app.sh && open dist/TidyBar.app
//   swift run tidybar-self-drag --repeat 30
//   swift run tidybar-self-drag --repeat 100 --bundle local.tidybar.app
//
// 跑的时候**不要碰鼠标和键盘**：哨兵一旦读到真人动作就会正常让位，那会被记成拖拽失败。

let arguments = CommandLine.arguments

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let repeatCount = argumentValue("--repeat").flatMap(Int.init) ?? 30
let selfBundle = argumentValue("--bundle") ?? "local.tidybar.app"
// 默认走产品主路径（LayoutEngine.apply）。要看组件级数字得显式加 --direct-mover：
// 上一轮的教训就是"直连组件的绿灯"骗过了主路径。
let useEngine = !arguments.contains("--direct-mover")
// 挪几格。1 格是"最小可用位移"，真机发现它的落点就贴在邻居槽位边上（targetX 取 maxX+2）；
// 2 格才是 fixture 闸门里用的那种明显位移。默认 1，两种都能测。
let slotOffset = argumentValue("--offset").flatMap(Int.init) ?? 1
// 关键：绝不能写进 AppPaths.journalDirectory——那是正在运行的 TidyBar.app 自己的布局日志，
// 往里塞 pending 会让它在下次启动时去重放探针的拖拽意图。探针用自己的临时目录。
let journalDirectory = URL(fileURLWithPath: argumentValue("--journal")
    ?? NSTemporaryDirectory() + "tidybar-self-drag-journal", isDirectory: true)

func header(_ title: String) { print("\n===== \(title) =====") }
var failures: [String] = []
func check(_ label: String, _ condition: Bool, detail: String = "") {
    print((condition ? "  ✓ " : "  ✗ ") + label + (detail.isEmpty ? "" : " — " + detail))
    if !condition { failures.append(label) }
}

func isCommandStuck() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
}
func isButtonStuck() -> Bool {
    NSEvent.pressedMouseButtons & (1 << 0) != 0
}

// MARK: - 装配（与产品主路径同一套组件）

let reader = AccessibilityMenuBarReader()
let cursor = AppKitCursorReader()
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
let poster = CGDragEventPoster(primaryScreenHeight: primaryHeight)
let mover = AccessibilityMenuBarMover(
    reader: reader,
    cursor: cursor,
    poster: poster,
    sentinel: EventSentinel(driftTolerance: 6, minIntervalBetweenOperations: 0.05),
    // 产品侧闸门仍是 false，这里只为完成验证显式打开
    config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
)
let journal = LayoutJournal(directory: journalDirectory)
let engine = LayoutEngine(layout: MenuBarLayout(), services: SystemServices(
    reader: reader, mover: mover, cursor: cursor,
    accessibility: AppKitAccessibilityTrust(), screens: AppKitScreenObserver()
), journal: journal)

/// 全局菜单栏顺序（左→右），身份用 `id`，不用标题（88% 图标没有可读标题）
func globalOrder() -> [ManagedItem] {
    MenuBarEnumeration.sortedLeftToRight(reader.discoverItems())
}

/// 复原比对用位置指纹（见 `MenuBarEnumeration.positionSignature` 的注释）。
/// 上一轮就是拿 id 比对，把微信自己改未读数算成了"我们没放回原位"。
func snapshot(_ items: [ManagedItem]) -> [String] { MenuBarEnumeration.positionSignature(of: items) }

/// 标题漂移只报告、不判失败：那是别人的行为，不是我们的副作用。
/// 但它必须被看见——标题型 id 会因此不稳定，分区归属可能跟着错位。
func reportTitleDrift() {
    let drift = MenuBarEnumeration.detectTitleDrift(before: opening, after: globalOrder())
    if drift.isEmpty {
        print("  ✓ 全程无第三方标题漂移（id 稳定）")
        return
    }
    let owners = MenuBarEnumeration.volatileTitleOwners(drift: drift)
    print("  ○ 检测到 \(drift.count) 处第三方自身改名，涉及 \(owners.count) 个进程：\(owners.sorted().joined(separator: ", "))")
    print("    → 这些进程的标题不可作身份依据，设置界面须标注为按位置认领")
}

/// 单发模式：只代点一次，把结论与现场打全。
/// 真机验证点击转发用它——配合 fixture 的事件日志，能拿到"确实被点了"的正面证据。
if let target = argumentValue("--activate") {
    let items = globalOrder().filter { $0.ownerBundleID == target }
    print("ACTIVATE target=\(target) 候选图标 \(items.count) 个")
    guard let first = items.first else {
        print("ACTIVATE outcome=itemNotFound（该 bundle 没有图标在栏）")
        exit(3)
    }
    let outcome = reader.activate(itemID: first.id)
    print("ACTIVATE \(first.id) → \(outcome) ｜ \(outcome.userReadable)")
    exit(outcome == .pressed ? 0 : 1)
}

/// 搜索面板 UI 自检：真实呼出一次，断言可见、能接键盘、查询确实执行。
/// 只断言"逻辑算出 N 条"不够——面板起不来或抢不到键盘焦点，用户看到的就是"按了没东西"。
if arguments.contains("--search-ui") {
    let items = globalOrder()
    let ui = TidyBarSearchUI(maxResults: 8)
    var queries = 0
    ui.queryHandler = { query in
        queries += 1
        return ItemSearch.rank(items, query: query, title: { $0.title })
    }
    ui.activateHandler = { _ in .pressed }
    ui.zoneLabel = { _ in "显示" }
    ui.present(anchorX: 600, screenHeight: NSScreen.screens.first?.frame.height ?? 900)
    let visible = ui.panel.isVisible
    let keyable = ui.panel.canBecomeKey
    let focused = (ui.panel.firstResponder as? NSTextField) != nil
    ui.panel.contentView?.subviews.compactMap { $0 as? NSTextField }.first?.stringValue = "f"
    ui.controlTextDidChange(Notification(name: Notification.Name("probe")))
    let rows = ui.resultRowCount
    print("SEARCHUI visible=\(visible ? "yes" : "no") canBecomeKey=\(keyable ? "yes" : "no") fieldFocused=\(focused ? "yes" : "no") queries=\(queries) rows=\(rows) 在栏图标=\(items.count)")
    check("面板真的显示出来", visible)
    check("面板能接键盘输入", keyable && focused)
    check("查询确实被执行", queries > 0)
    check("行数不超过上限", rows <= 8)
    ui.dismiss()
    check("关闭后面板隐藏", !ui.panel.isVisible)
    exit(failures.isEmpty ? 0 : 1)
}

/// 可点性普查：只读动作列表，不真的点任何图标。
if arguments.contains("--press-census") {
    let census = reader.pressCapabilityCensus()
    let total = census.reduce(0) { $0 + $1.total }
    let capable = census.reduce(0) { $0 + $1.pressCapable }
    print("CENSUS owners=\(census.count) 子项=\(total) 接受 AXPress=\(capable) 覆盖率=\(String(format: "%.0f%%", total > 0 ? Double(capable) / Double(total) * 100 : 0))")
    for entry in census.sorted(by: { $0.total > $1.total }) {
        let mark = entry.pressCapable == entry.total ? "✓" : (entry.pressCapable == 0 ? "✗" : "部分")
        print("  \(mark) \(entry.ownerBundleID) \(entry.pressCapable)/\(entry.total) ｜ \(entry.ownerName)")
    }
    exit(0)
}

/// 抓图验证：只抓目标那一小块，并做"有内容 vs 空白处"的对照。
/// 没有这个对照，"缩略图"三种错误尺寸（整屏、整屏缩放、裁错位置）都会看起来像成功。
if let target = argumentValue("--capture") {
    let items = globalOrder().filter { $0.ownerBundleID == target }
    guard let first = items.first else {
        print("CAPTURE outcome=itemNotFound（\(target) 没有图标在栏）")
        exit(3)
    }
    let capturer = ScreenCaptureKitIconCapturer()
    print("CAPTURE 权限预检 isAuthorized=\(capturer.isAuthorized)")
    if !capturer.isAuthorized {
        print("CAPTURE 未授予屏幕录制权限 → 面板必须回退到占位首字母（这条路径本身要能跑通）")
        capturer.requestAuthorization()
        exit(4)
    }
    let scale = NSScreen.screens.first?.backingScaleFactor ?? 1
    let group = DispatchGroup()
    var results: [(label: String, width: Int, height: Int, variance: Double, fingerprint: Int)] = []
    let resultsLock = NSLock()
    func record(_ entry: (label: String, width: Int, height: Int, variance: Double, fingerprint: Int)) {
        resultsLock.lock()
        results.append(entry)
        resultsLock.unlock()
    }

    func grab(_ label: String, _ rect: CGRect) {
        group.enter()
        capturer.capture(frame: rect, scale: scale) { outcome in
            switch outcome {
            case .success(let image):
                let stats = ImageStats.of(image)
                record((label, image.width, image.height, stats.variance, stats.fingerprint))
                if let path = argumentValue("--save"), path.contains(label) {
                    let url = URL(fileURLWithPath: path)
                    if let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, nil)
                        CGImageDestinationFinalize(destination)
                    }
                }
            case .failure(let error):
                print("CAPTURE \(label) 失败 \(error)")
            }
            group.leave()
        }
    }

    // 先只做静态对照，抓完再谈挪动——否则"挪走后"的抓取可能与"挪走前"的抓取交叠，
    // 两次指纹谁先谁后都不确定，比对就失去意义。
    grab("icon", first.frame)
    // 已知答案对照，不靠"哪里是空白"的猜测：
    // 36 个图标挤在约 1400pt 的带上、平均间隔才 40pt，往左 400pt 是**另一个图标**而不是空白，
    // 所以"空处方差应接近 0"这个前提本身就是错的（第一版就是这么误判的）。
    grab("icon-repeat", first.frame)                       // 同区域连抓两次 ⇒ 必须逐像素相同
    let other = items.first(where: { $0.id != first.id }) ?? first
    grab("other-icon", other.frame)                        // 不同图标 ⇒ 内容必须不同
    group.wait()

    print("CAPTURE scale=\(scale)")
    for r in results {
        print("  \(r.label): \(r.width)x\(r.height)px 方差=\(String(format: "%.1f", r.variance)) 指纹=\(r.fingerprint)")
    }
    // 因果验证（--causal，只对 fixture 图标开）：把目标挪走一格后抓**同一个位置**。
    // 尺寸/确定性/差异这三条只能证明"坐标参与裁剪"，证明不了"坐标一分不差"；
    // 只有让现场内容真的变化，才能把"抓对了这一格"与"抓了某块固定区域"区分开。
    if arguments.contains("--causal") {
        let rect = first.frame
        let current = globalOrder()
        if target != "local.tidybar.fixture" {
            print("  ○ 因果验证只在自造 fixture 图标上做（挪动会改动现场顺序），当前目标 \(target) 已跳过")
        } else if let from = current.firstIndex(where: { $0.id == first.id }),
                  from + 1 < current.count || from - 1 >= 0,
                  let moveTo = MenuBarDropTarget.targetX(
                      in: current, moving: from, to: from + 1 < current.count ? from + 1 : from - 1
                  ) {
            group.enter()
            capturer.capture(frame: rect, scale: scale) { outcome in
                if case .success(let image) = outcome {
                    record(("before-move", image.width, image.height, ImageStats.of(image).variance, ImageStats.of(image).fingerprint))
                }
                group.leave()
            }
            group.wait()
            let beforeFP = results.first(where: { $0.label == "before-move" })?.fingerprint ?? -1
            do {
                _ = try mover.move(itemID: first.id, toX: moveTo)
                usleep(320_000)
                grab("after-move", rect)
                group.wait()
                let afterFP = results.first(where: { $0.label == "after-move" })?.fingerprint ?? -2
                print("  \(afterFP != beforeFP ? "✓" : "✗") 因果验证：挪走该图标后抓同一位置，内容确实变了（\(beforeFP) → \(afterFP)）")
                // 复原，绝不把实验现场留给用户
                let restored = globalOrder()
                if let back = restored.firstIndex(where: { $0.id == first.id }),
                   let origin = MenuBarDropTarget.targetX(in: restored, moving: back, to: from) {
                    _ = try mover.move(itemID: first.id, toX: origin)
                    print("  ✓ 已把 fixture 图标挪回原位")
                } else {
                    print("  ✗ 无法计算原位落点，请手动检查 fixture 图标顺序")
                }
            } catch {
                print("  ✗ 因果验证中止：挪动失败 \(error)")
            }
        } else {
            print("  ○ 因果验证跳过：算不出合法落点或已在边界")
        }
    }

    let expectedWidth = max(1, Int(first.frame.width * scale))
    let expectedHeight = max(1, Int(first.frame.height * scale))
    func finding(_ label: String) -> (width: Int, height: Int, fingerprint: Int)? {
        results.first(where: { $0.label == label }).map { (width: $0.width, height: $0.height, fingerprint: $0.fingerprint) }
    }
    if let icon = finding("icon"), let repeat0 = finding("icon-repeat"), let otherHit = finding("other-icon") {
        let sizeOK = icon.width == expectedWidth && icon.height == expectedHeight
        print("  \(sizeOK ? "✓" : "✗") 抓的是局部：期望 \(expectedWidth)x\(expectedHeight)px，实际 \(icon.width)x\(icon.height)px（整屏或整屏缩放都对不上这个数）")
        print("  \(icon.fingerprint == repeat0.fingerprint ? "✓" : "✗") 同区域连抓两次逐像素相同（确定性）")
        print("  \(icon.fingerprint != otherHit.fingerprint ? "✓" : "✗") 不同图标抓出不同内容（坐标真的参与裁剪，不是恒定抓同一块）")
    }
    exit(0)
}

/// 像素统计：只回答"抓到的到底是哪一块"，不做画质评价。
/// 指纹用 FNV-1a：同区域两次必须同指纹、不同图标必须不同指纹。
/// 这两条不依赖"哪里算空白"的猜测，所以不会被菜单栏有多挤带偏（第一版就是那么误判的）。
enum ImageStats {
    struct Value {
        var variance: Double
        var fingerprint: Int
    }

    static func of(_ image: CGImage) -> Value {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return Value(variance: 0, fingerprint: 0) }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Value(variance: 0, fingerprint: 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var sum = 0.0
        var sumSquare = 0.0
        var count = 0
        var hash: UInt64 = 0xcbf29ce484222325
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let luminance = 0.299 * Double(pixels[offset])
                + 0.587 * Double(pixels[offset + 1])
                + 0.114 * Double(pixels[offset + 2])
            sum += luminance
            sumSquare += luminance * luminance
            count += 1
            hash = (hash ^ UInt64(pixels[offset])) &* 0x100000001b3
            hash = (hash ^ UInt64(pixels[offset + 1])) &* 0x100000001b3
            hash = (hash ^ UInt64(pixels[offset + 2])) &* 0x100000001b3
        }
        guard count > 0 else { return Value(variance: 0, fingerprint: 0) }
        let mean = sum / Double(count)
        return Value(
            variance: max(0, sumSquare / Double(count) - mean * mean),
            fingerprint: Int(hash & 0x7fffffff)
        )
    }
}

// MARK: - 主闸门流程（恢复自 4cb1164：一次删尾部代码的脚本把它连带截掉了）
/// 真机因果验证：漂移是自己造的，因此"配置跟不跟着走"有了确定的因果，而不是碰运气观测。
///
/// 前提：fixture 以 TIDYBAR_MUTATE_TITLE=1 启动，其中一个图标每 2.5s 自改标题。
/// 断言链：认下当前 id 的隐藏区归属 → 等它改名 → 重新折叠 → 新 id 必须在隐藏区、
/// 旧 id 必须迁净，且漂移确实被 detectTitleDrift 报出来。
if arguments.contains("--drift-e2e") {
    let bundle = argumentValue("--bundle") ?? "local.tidybar.fixture"
    let probe = globalOrder().filter {
        $0.ownerBundleID == bundle && ($0.title.hasPrefix("MX") || $0.title.hasPrefix("MY"))
    }
    guard let original = probe.first else {
        print("DRIFT 没找到会自改标题的图标。先跑：TIDYBAR_MUTATE_TITLE=1 open dist/TidyBarFixture.app --args 4")
        exit(3)
    }
    print("DRIFT 起点 id=\(original.id) 标题=\(original.title) ownerItemCount=\(original.ownerItemCount)")

    var seeded = MenuBarLayout()
    seeded.append(original.id, to: .hidden)
    let frameA = globalOrder().filter { $0.ownerBundleID == bundle }
    let gateReader = AccessibilityMenuBarReader()
    let driftEngine = LayoutEngine(
        layout: seeded,
        services: SystemServices(
            reader: gateReader, mover: UnverifiedMenuBarMover(), cursor: cursor,
            accessibility: AppKitAccessibilityTrust(), screens: AppKitScreenObserver()
        ),
        journal: LayoutJournal(directory: URL(fileURLWithPath: NSTemporaryDirectory() + "tidybar-drift-e2e"))
    )

    driftEngine.fold(items: frameA, newItemZone: .visible)
    // 折叠会把未登记的项按默认分区放进来，所以要在这之后再把目标项归到隐藏区
    driftEngine.assignForChecks(original.id, to: .hidden)
    print("  登记现场后：" + MenuBarZone.allCases
        .map { $0.rawValue + "=[" + driftEngine.layout.items(in: $0).joined(separator: ",") + "]" }
        .joined(separator: " "))

    // 轮询到标题**真的变了**为止。上一版是睡固定 6 秒，正好落在标题复位的那一帧，
    // 于是漂移记数为 0——把"没观测到"误当成"没有漂移"，这是同一类错误。
    let requiredNewIDs = argumentValue("--need-new").flatMap(Int.init) ?? 1
    var later: [ManagedItem] = frameA
    var drifted: [ManagedItem] = []
    for _ in 0..<14 {
        usleep(1_000_000)
        let frame = globalOrder().filter { $0.ownerBundleID == bundle }
        let changed = frame.filter { $0.id != original.id && ($0.title.hasPrefix("MX") || $0.title.hasPrefix("MY")) }
        // 反例要求同进程一次出现 ≥2 个新 id（两个图标同时改名）——配对不再唯一。
        // 早先版本"看到第一个变化就停"，于是反例其实测的是正例，假绿。
        if changed.count >= requiredNewIDs {
            later = frame
            drifted = changed
            break
        }
    }
    let drift = MenuBarEnumeration.detectTitleDrift(before: frameA, after: later)
    print("DRIFT 漂移记录 \(drift.count) 处；新 id \(drifted.map { $0.id }.joined(separator: ", "))")
    check("漂移确实被观测到", !drift.isEmpty)

    driftEngine.fold(items: later, newItemZone: .visible)
    let adopted = drifted.first.map { driftEngine.layout.zone(of: $0.id) } ?? nil
    let stale = driftEngine.layout.zone(of: original.id)
    if arguments.contains("--expect-no-adopt") {
        // 反例：同进程一次冒出两个新 id 时，"哪个旧配置属于哪个新图标"没有唯一答案。
        // 此时必须**什么都不迁**——把 A 的设置安到 B 头上比丢一次配置难查得多。
        check("多对多时拒绝认领（没有任何新 id 被安上隐藏区）",
              drifted.allSatisfy { driftEngine.layout.zone(of: $0.id) != .hidden },
              detail: drifted.map { $0.id + "=" + String(describing: driftEngine.layout.zone(of: $0.id)) }.joined(separator: ", "))
        check("原配置没被偷偷接到别人身上（旧 id 要么仍在、要么随消失项清掉）",
              stale == nil || stale == .hidden, detail: "旧 id 归属 \(String(describing: stale))")
    } else {
        check("改名后的图标仍留在隐藏区（配置跟过去了）", adopted == .hidden,
              detail: "实际 \(String(describing: adopted))")
        check("旧 id 已迁净，不会同占两坑", stale == nil,
              detail: "旧 id 仍指向 \(String(describing: stale))")
    }
    check("旧 id 已迁净，不会同占两坑", driftEngine.layout.zone(of: original.id) == nil || drifted.isEmpty,
          detail: "旧 id 仍指向 \(String(describing: driftEngine.layout.zone(of: original.id)))")
    print("  折叠后：" + MenuBarZone.allCases
        .map { $0.rawValue + "=[" + driftEngine.layout.items(in: $0).joined(separator: ",") + "]" }
        .joined(separator: " "))
    exit(failures.isEmpty ? 0 : 1)
}

header("环境")
print("系统: " + ProcessInfo.processInfo.operatingSystemVersionString)
print("路径: " + (useEngine ? "LayoutEngine（产品主路径）" : "直连 mover（组件级，默认不走）"))
print("被拖对象: \(selfBundle) 自有图标 ｜ 邻居: 用户真实图标 ｜ 计划次数: \(repeatCount)")

let opening = globalOrder()
guard let selfIndex = opening.firstIndex(where: { $0.ownerBundleID == selfBundle }) else {
    print("⛔ 没找到 \(selfBundle) 的图标。先跑：./scripts/build-app.sh && open dist/TidyBar.app")
    exit(2)
}
guard opening.count >= 3 else {
    print("⛔ 菜单栏图标太少（\(opening.count)），没有真实邻居可当落点")
    exit(2)
}
let initialOrder = snapshot(opening)
print("在栏图标 \(opening.count) 个，我方图标序号 \(selfIndex)（\(opening[selfIndex].title)）")
print("初始顺序: " + initialOrder.joined(separator: ">"))

// MARK: - 单轮：挪一格再挪回来

struct Round {
    var moved = 0
    var restored = 0
    var stuck = 0
    var identityLost = 0
    var milliseconds: [Double] = []
    var lastError = ""
}

func dragToSlot(of itemID: String, offset: Int) -> (ok: Bool, ms: Double, error: String) {
    let current = globalOrder()
    guard let from = current.firstIndex(where: { $0.id == itemID }) else {
        return (false, 0, "图标身份丢失：全局顺序里找不到 \(itemID)")
    }
    let to = max(0, min(current.count - 1, from + offset))
    if to == from { return (false, 0, "已到边界（\(from)→\(to)），没有该方向的邻居槽位") }
    guard let target = MenuBarDropTarget.targetX(in: current, moving: from, to: to) else {
        return (false, 0, "算不出合法落点，拒绝硬拖")
    }
    let started = Date()
    do {
        if useEngine {
            try engine.apply(itemID: itemID, to: .visible, targetX: target)
        } else {
            _ = try mover.move(itemID: itemID, toX: target)
        }
    } catch {
        return (false, Date().timeIntervalSince(started) * 1000, String(describing: error))
    }
    let ms = Date().timeIntervalSince(started) * 1000
    // 重排是异步的，采样取后者
    usleep(240_000)
    let after = globalOrder()
    let movedOK = after.firstIndex(where: { $0.id == itemID }) == to
    if movedOK { return (true, ms, "") }
    // 失败必须自带现场：没有前后帧与落点，归因就只能靠猜（这一轮就先猜错了两次）
    let landed = after.firstIndex(where: { $0.id == itemID }) ?? -1
    let frameText: (CGRect?) -> String = { frame in
        guard let frame else { return "读不到" }
        return "x=\(Int(frame.origin.x)) 宽=\(Int(frame.width))"
    }
    return (false, ms, "顺序未按预期 \(from)→\(to)，实际落在 \(landed)"
        + " ｜ 落点 x=\(Int(target))"
        + " ｜ 拖前帧 " + frameText(current.first(where: { $0.id == itemID })?.frame)
        + " ｜ 拖后帧 " + frameText(after.first(where: { $0.id == itemID })?.frame))
}

func runRound() -> Round? {
    let current = globalOrder()
    guard let index = current.firstIndex(where: { $0.ownerBundleID == selfBundle }) else {
        print("  ✗ 我方图标在轮次开始前已不可见，停止后续轮次")
        return nil
    }
    // 优先往右挪；贴右边界则往左。下一半轮反向，保证成对抵消
    let direction = index < current.count - slotOffset ? slotOffset : -slotOffset

    var round = Round()
    let there = dragToSlot(of: current[index].id, offset: direction)
    if there.ok {
        round.moved = 1
    } else {
        round.lastError = "去程：" + there.error
        print("  ✗ 去程失败 " + round.lastError)
        if isCommandStuck() || isButtonStuck() { round.stuck = 1 }
        return round
    }
    let back = dragToSlot(of: current[index].id, offset: -direction)
    if back.ok {
        round.restored = 1
    } else {
        round.lastError = "回程：" + back.error
        print("  ✗ 回程失败 " + round.lastError)
    }
    round.milliseconds = [there.ms, back.ms]
    if isCommandStuck() { round.stuck += 1; print("  ✗ ⌘ 被留在按住状态") }
    else if isButtonStuck() { round.stuck += 1; print("  ✗ 鼠标键被留在按住状态") }
    let check = globalOrder().contains { $0.id == current[index].id }
    if !check { round.identityLost = 1; print("  ✗ 拖完找不到同一个图标（身份不稳定）") }
    return round
}

header("真机闸门：我方图标 × 真实邻居，共 \(repeatCount) 轮")
var totals = Round()
var roundIndex = 0
while roundIndex < repeatCount {
    roundIndex += 1
    guard let round = runRound() else { break }
    totals.moved += round.moved
    totals.restored += round.restored
    totals.stuck += round.stuck
    totals.identityLost += round.identityLost
    totals.milliseconds.append(contentsOf: round.milliseconds)
    print("  第 \(roundIndex) 轮 去程=\(round.moved) 回程=\(round.restored) ｜ 累计 挪动\(totals.moved) 复原\(totals.restored) 残留\(totals.stuck) 身份丢失\(totals.identityLost)")
    if roundIndex < repeatCount { usleep(250_000) }
}

header("收尾：全局顺序是否回到初始")
let sorted = totals.milliseconds.sorted()
func pct(_ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))]
}
print("  单次拖拽 p50=" + String(format: "%.0f", pct(0.5)) + "ms p95=" + String(format: "%.0f", pct(0.95)) + "ms")

reportTitleDrift()
let closing = snapshot(globalOrder())
if closing == initialOrder {
    print("  ✓ 顺序与初始完全一致（\(closing.count) 项）")
} else {
    let diff = zip(initialOrder, closing).enumerated().filter { $0.element.0 != $0.element.1 }.map { "第\($0.offset): \($0.element.0)→\($0.element.1)" }
    print("  ✗ 顺序未复原，差异 \(diff.count) 处: " + diff.prefix(8).joined(separator: " ｜ "))
    failures.append("顺序未复原")
}
check("每一次挪动都复原", totals.moved == totals.restored, detail: "挪动 \(totals.moved) ／ 复原 \(totals.restored)")
check("无卡键/卡钮残留", totals.stuck == 0, detail: "\(totals.stuck) 次检测到残留")
check("图标身份全程可复用", totals.identityLost == 0, detail: "\(totals.identityLost) 次拖完找不到同一 id")
check("零失败轮次", failures.isEmpty, detail: totals.lastError)

if failures.isEmpty && totals.moved == repeatCount && arguments.contains("--confirm-this-machine") {
    // 确认记录只能由"真跑过并通过的闸门"自己写，不能手改常量、也不能凭口头声明。
    var gate = DragGateStore(url: AppPaths.dragGateFile).load()
    gate.record(DragConfirmation(
        osVersion: MachineIdentity.osVersion(),
        machineID: MachineIdentity.hardwareID(),
        rounds: totals.moved,
        confirmedAt: Date()
    ))
    do {
        try DragGateStore(url: AppPaths.dragGateFile).save(gate)
        print("  已记录接管确认：\(MachineIdentity.osVersion()) @ \(MachineIdentity.hardwareID().prefix(12))… 共 \(totals.moved) 轮")
    } catch {
        print("  ✗ 确认记录写入失败：\(error)")
        failures.append("确认记录写入失败")
    }
}

header("结论")
if failures.isEmpty && totals.moved == repeatCount {
    print("  ✓ 真实菜单栏环境下的闸门通过 \(repeatCount) 轮（双向往返 = \(totals.moved * 2) 次拖拽）")
    exit(0)
}
print("  ✗ 未通过：\(failures.joined(separator: "，")) ｜ 完成轮次 \(totals.moved)/\(repeatCount)")
exit(1)
