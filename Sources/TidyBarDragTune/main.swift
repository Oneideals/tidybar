import AppKit
import CoreGraphics
import TidyBarCore

// M0 验证项 2：验证「⌘ 拖拽只在落到邻居槽位时生效」这一假设。
//
// 前一轮参数扫描已证明 hold/步数无关，只有距离有关；且失败固定发生在"向左拖"那一次。
// 本工具用三种落点各跑若干次，把假设证伪或坐实：
//   A 往后插（拖到右边邻居的右缘）      → 预期生效
//   B 往前插（拖到左边邻居的中心）      → 预期生效
//   C 拖进空隙（左移 100pt，无邻居）    → 预期被系统静默忽略
// 如果 C 也生效，说明假设错了，失败另有原因。
//
//   ./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4
//   swift run tidybar-drag-tune --runs 6
//   swift run tidybar-drag-tune --sweep        # 回看旧的全参数扫描

let arguments = CommandLine.arguments

func value(_ flag: String, _ fallback: String) -> String {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

let fixtureBundle = value("--bundle", "local.tidybar.fixture")
let reader = AccessibilityMenuBarReader()
let cursor = AppKitCursorReader()
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
let mover = AccessibilityMenuBarMover(
    reader: reader,
    cursor: cursor,
    poster: CGDragEventPoster(primaryScreenHeight: primaryHeight),
    config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
)

func orderedFixtures() -> [ManagedItem] {
    MenuBarEnumeration.sortedLeftToRight(reader.discoverItems().filter { $0.ownerBundleID == fixtureBundle })
}

func drag(_ item: ManagedItem, toX target: CGFloat) {
    do {
        _ = try mover.move(itemID: item.id, toX: target)
    } catch {
        print("    （拖拽抛错：" + String(describing: error) + "）")
    }
    usleep(250_000)   // 等重排动画与落位
}

if arguments.contains("--sweep") {
    print("旧的全参数扫描已移交给 --sweep，结论已记录在 docs/findings/02-drag.md，这里不再重复。")
    exit(0)
}

let runs = max(1, Int(value("--runs", "6")) ?? 6)

var inventory = orderedFixtures()
guard inventory.count >= 3 else {
    print("⛔ fixture 图标不足 3 个，无法构造三种落点。先跑：./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4")
    exit(2)
}
print("fixture 顺序（左→右）: " + inventory.map { $0.title + "@" + String(Int($0.frame.minX)) }.joined(separator: " "))
print("每种落点跑 " + String(runs) + " 次\n")

var results: [(name: String, reordered: Int, total: Int, expected: Bool)] = []

func runCase(_ name: String, expectedReorder: Bool, body: @escaping (Int) -> Void) {
    var hit = 0
    for index in 0..<runs {
        body(index)
        let now = orderedFixtures()
        if MenuBarDropTarget.didReorder(before: inventory.map(\.title), after: now.map(\.title)) { hit += 1 }
        inventory = now
    }
    results.append((name, hit, runs, expectedReorder))
    let rate = Double(hit) / Double(runs) * 100
    print("  " + name + ": " + String(hit) + "/" + String(runs) + " 发生重排（" + String(format: "%.0f%%", rate) + "）｜预期" + (expectedReorder ? "会重排" : "不重排"))
}

// A 往后插：把最左边的图标拖到第 3 个图标的右缘
runCase("A 往后插到邻居右缘", expectedReorder: true) { _ in
    let items = orderedFixtures()
    guard items.count >= 3,
          let target = MenuBarDropTarget.targetX(in: items, moving: 0, to: 2) else { return }
    drag(items[0], toX: target)
}

// B 往前插：把第 3 个图标拖到最左边图标的中心
runCase("B 往前插到邻居中心", expectedReorder: true) { _ in
    let items = orderedFixtures()
    guard items.count >= 3,
          let target = MenuBarDropTarget.targetX(in: items, moving: 2, to: 0) else { return }
    drag(items[2], toX: target)
}

// C 拖进空隙：左移 100pt，那里没有任何图标可踩
runCase("C 拖进左侧空隙", expectedReorder: false) { _ in
    let items = orderedFixtures()
    guard let first = items.first else { return }
    drag(first, toX: first.frame.minX - 100)
}

// MARK: - 决定性诊断：拖拽进行中，图标有没有跟着光标走？
//
// 「A/B 全 0」有两种完全不同的成因，处理方式南辕北辙：
//   · 图标中途跟着走、松手后弹回 → 事件进到了菜单栏，是落点/flags 问题；
//   · 图标全程不动 → 我们的事件压根没被菜单栏接受，属于投递层问题。
// 有了单进程定向读取（几毫秒），就能在第 6 步拖动之后就地采样。

print("\n===== 拖拽中途采样 =====")

final class MidDragSampler: DragEventPosting {
    private let inner: DragEventPosting
    private let sample: () -> [ManagedItem]
    private(set) var draggedCount = 0
    private(set) var samples: [(step: Int, x: CGFloat)] = []
    /// 第几步采样
    let at: Int

    init(inner: DragEventPosting, at: Int, sample: @escaping () -> [ManagedItem]) {
        self.inner = inner
        self.at = at
        self.sample = sample
    }

    @discardableResult
    func post(_ event: DragEvent) -> Bool {
        let result = inner.post(event)
        if case .mouseDragged = event {
            draggedCount += 1
            if draggedCount == at {
                if let item = sample().first {
                    samples.append((draggedCount, item.frame.midX))
                }
            }
        }
        return result
    }
}

func sampleOnce(_ label: String, moving: Int, to toIndex: Int) {
    let current = orderedFixtures()
    guard current.count > max(moving, toIndex),
          let item = current.indices.contains(moving) ? current[moving] : nil,
          let target = MenuBarDropTarget.targetX(in: current, moving: moving, to: toIndex) else {
        print("  " + label + ": 无法构造（图标不足或无合法落点）")
        return
    }
    let sampler = MidDragSampler(inner: CGDragEventPoster(primaryScreenHeight: primaryHeight), at: 6) {
        reader.discoverItems(owning: fixtureBundle)
    }
    let probe = AccessibilityMenuBarMover(
        reader: reader,
        cursor: cursor,
        poster: sampler,
        config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
    )
    let beforeX = item.frame.midX
    do {
        _ = try probe.move(itemID: item.id, toX: target)
    } catch {
        print("  " + label + ": 抛错 " + String(describing: error))
        return
    }
    let afterX = (orderedFixtures().first { $0.id == item.id }?.frame.midX) ?? -1
    let mid = sampler.samples.first?.x
    let midText = mid.map { String(Int($0)) } ?? "未采样"
    let followText = mid.map { abs($0 - beforeX) > 4 ? "⟶ 中途有跟随" : "⟶ 中途未跟随" } ?? "⟶ 无采样数据"
    var line = "  " + label
    line += " 起点 " + String(Int(beforeX))
    line += " 中途 " + midText
    line += " 终点 " + String(Int(afterX))
    line += " 目标 " + String(Int(target))
    line += " " + followText
    print(line)
    usleep(250_000)
}

sampleOnce("往后插", moving: 0, to: 2)
sampleOnce("往前插", moving: 2, to: 0)

print("\n===== 判定 =====")
let aOK = results[0].reordered == results[0].total
let bOK = results[1].reordered == results[1].total
let cOK = results[2].reordered == 0
print("  邻居槽位落点稳定生效: " + (aOK && bOK ? "是" : "否"))
print("  空隙落点被系统静默忽略: " + (cOK ? "是" : "否"))
if aOK && bOK && cOK {
    print("\n✓ 假设成立：目标 X 必须由邻居位置推导，任意像素值会静默失败")
    print("  → LayoutEngine 的 targetProvider 必须走 MenuBarDropTarget，不得用「往左 N pt」这类算法")
    exit(0)
}
print("\n✗ 假设不完全成立，需要回到数据重新提假设（结果见上）")
exit(1)
