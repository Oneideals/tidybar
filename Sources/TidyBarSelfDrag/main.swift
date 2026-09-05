import AppKit
import CoreGraphics
import Foundation
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

func snapshot(_ items: [ManagedItem]) -> [String] { items.map(\.id) }

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

header("结论")
if failures.isEmpty && totals.moved == repeatCount {
    print("  ✓ 真实菜单栏环境下的闸门通过 \(repeatCount) 轮（双向往返 = \(totals.moved * 2) 次拖拽）")
    exit(0)
}
print("  ✗ 未通过：\(failures.joined(separator: "，")) ｜ 完成轮次 \(totals.moved)/\(repeatCount)")
exit(1)
