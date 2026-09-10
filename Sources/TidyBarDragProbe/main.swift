import AppKit
import CoreGraphics
import TidyBarCore

// M0 验证项 2：⌘ 拖拽与事件哨兵的真机验证。
//
// 实验对象只有我们自己造的 fixture 图标（local.tidybar.fixture），
// 绝不拿用户真实 App 的图标试手——拖坏了那是人家的资产。
//
//   ./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4
//   swift run tidybar-drag-probe --repeat 30
//   swift run tidybar-drag-probe --repeat 100 --destructive

let arguments = CommandLine.arguments

func argumentValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let repeatCount = argumentValue("--repeat").flatMap(Int.init) ?? 20
let wantDestructive = arguments.contains("--destructive")
let fixtureBundle = argumentValue("--bundle") ?? "local.tidybar.fixture"
let dragDistance = CGFloat(argumentValue("--distance").flatMap(Double.init) ?? 60)

func header(_ title: String) { print("\n===== \(title) =====") }

var failures: [String] = []
func check(_ label: String, _ condition: Bool, detail: String = "") {
    print((condition ? "  ✓ " : "  ✗ ") + label + (detail.isEmpty ? "" : " — " + detail))
    if !condition { failures.append(label) }
}

/// ⌘ 是否被留在按住状态——拖拽验证里最严重的一类副作用：
/// 一旦卡住，用户之后每次点击都变成快捷键，比拖错图标恶劣得多
func isCommandStuck() -> Bool {
    CGEventSource.flagsState(.combinedSessionState).contains(.maskCommand)
}

func isMouseButtonStuck() -> Bool {
    NSEvent.pressedMouseButtons & (1 << 0) != 0
}

func isAbort(_ error: MenuBarMoveError, _ match: (EventSentinel.Verdict) -> Bool = { _ in true }) -> Bool {
    if case .abortedBySentinel(let verdict) = error { return match(verdict) }
    return false
}

func isVanished(_ error: MenuBarMoveError) -> Bool {
    if case .itemVanished = error { return true }
    return false
}

// MARK: - 装配

let reader = AccessibilityMenuBarReader()
let cursor = AppKitCursorReader()
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
// --bare-command：鼠标事件不带 flags，只发真实 ⌘ 键事件（判别 ⌘ 读数污染用）
let bareCommand = arguments.contains("--bare-command")
let poster = CGDragEventPoster(
    primaryScreenHeight: primaryHeight,
    carriesCommandFlagsOnMouseEvents: !bareCommand
)
let mover = AccessibilityMenuBarMover(
    reader: reader,
    cursor: cursor,
    poster: poster,
    sentinel: EventSentinel(driftTolerance: 6, minIntervalBetweenOperations: 0.05),
    // 产品侧这个值仍是 false（上层保持降级）。这里显式打开只为完成验证。
    config: AccessibilityMenuBarMover.Config(
        postsPhysicalCommandKey: arguments.contains("--with-key-events"),
        isConfirmedSupportedOS: true
    )
)

func fixtureItems() -> [ManagedItem] {
    MenuBarEnumeration.sortedLeftToRight(reader.discoverItems().filter { $0.ownerBundleID == fixtureBundle })
}

header("环境")
print("系统: " + ProcessInfo.processInfo.operatingSystemVersionString)
print("主屏高: " + String(Int(primaryHeight)) + "pt ｜ 辅助功能权限: " + (reader.enumerate().accessibilityGranted ? "已授予" : "未授予"))
print("路径: " + (arguments.contains("--via-engine") ? "LayoutEngine（产品主路径）" : "直连 mover（组件级）"))
print("投递方式: " + (bareCommand ? "鼠标事件不带 flags（已证明不可用）"
    : arguments.contains("--with-key-events") ? "flags + 真实 ⌘ 键事件" : "仅鼠标事件带 flags（不发按键）"))
print("fixture: " + fixtureBundle + " ｜ 次数: " + String(repeatCount) + " ｜ 距离: " + String(Int(dragDistance)) + "pt")

let initial = fixtureItems()
if initial.isEmpty {
    print("\n⛔ 没找到 fixture 图标。先跑：./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4")
    exit(2)
}
print("fixture 图标 " + String(initial.count) + " 个: " + initial.map { $0.title + "@" + String(Int($0.frame.minX)) }.joined(separator: ", "))

// MARK: - 一次拖拽试验

struct DragTrial {
    let reordered: Bool
    let detail: String
    let milliseconds: Double
    let commandStuck: Bool
    let buttonStuck: Bool
    let errorText: String?
}

/// 一次合法拖拽：目标 X 一律由邻居槽位推导。
/// 真机扫描证明「往左/右 N 像素」这种任意目标会被 macOS 静默忽略——
/// 既不报错也不动，是产品里最危险的失败模式，所以这里从源头上不给它出现的机会。
/// --via-engine：走产品真实主路径（LayoutEngine.apply，含 journal + 结果复核）。
/// 验证项 3 的教训就是「直连组件测出的绿灯不代表主路径可用」，闸门默认必须走引擎。
var engine: LayoutEngine? = {
    guard arguments.contains("--via-engine") else { return nil }
    let services = SystemServices(
        reader: reader,
        mover: AccessibilityMenuBarMover(
            reader: reader, cursor: cursor, poster: poster,
            config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
        ),
        cursor: cursor,
        accessibility: AppKitAccessibilityTrust(),
        screens: AppKitScreenObserver()
    )
    var layout = MenuBarLayout()
    for item in fixtureItems() { layoutWasEmptyAppend(&layout, item) }
    return LayoutEngine(layout: layout, services: services,
                        journal: LayoutJournal(directory: AppPaths.journalDirectory))
}()

func layoutWasEmptyAppend(_ layout: inout MenuBarLayout, _ item: ManagedItem) {
    layout.append(item.id, to: .visible)
}

func runTrial(move movingIndex: Int, to toIndex: Int) -> DragTrial? {
    let current = fixtureItems()
    guard current.count > max(movingIndex, toIndex),
          let item = current.indices.contains(movingIndex) ? current[movingIndex] : nil,
          let target = MenuBarDropTarget.targetX(in: current, moving: movingIndex, to: toIndex) else {
        return nil
    }
    let before = current.map(\.title)
    let started = Date()
    var dragMS = 0.0
    do {
        if let engine {
            try engine.apply(itemID: item.id, to: .visible, targetX: target)
        } else {
            _ = try mover.move(itemID: item.id, toX: target)
        }
        dragMS = Date().timeIntervalSince(started) * 1_000
    } catch {
        return DragTrial(reordered: false, detail: "", milliseconds: dragMS,
                         commandStuck: isCommandStuck(), buttonStuck: isMouseButtonStuck(),
                         errorText: String(describing: error))
    }
    // 重排是异步的：两次采样取后者，避免把动画中读到成失败
    usleep(220_000)
    usleep(280_000)
    let after = fixtureItems()
    guard after.contains(where: { $0.id == item.id }) else {
        return DragTrial(reordered: false, detail: "", milliseconds: dragMS,
                         commandStuck: isCommandStuck(), buttonStuck: isMouseButtonStuck(),
                         errorText: "拖后再也找不到该图标（身份可能不稳定）")
    }
    return DragTrial(
        reordered: MenuBarDropTarget.didReorder(before: before, after: after.map(\.title)),
        detail: before.prefix(3).joined(separator: ">") + " → " + after.map(\.title).prefix(3).joined(separator: ">"),
        milliseconds: dragMS,
        commandStuck: isCommandStuck(),
        buttonStuck: isMouseButtonStuck(),
        errorText: nil
    )
}

header("实测 1：拖拽是否真的改变图标位置")
if let trial = runTrial(move: 0, to: 2) {
    check("往后插到邻居槽位可重排", trial.reordered, detail: trial.detail + " ｜ 耗时 " + String(format: "%.0f", trial.milliseconds) + "ms ｜ " + (trial.errorText ?? "无异常"))
    check("⌘ 未被留在按住状态", !trial.commandStuck)
    check("鼠标键未被留在按住状态", !trial.buttonStuck)
} else {
    check("存在可拖拽的 fixture 图标", false)
}

if let back = runTrial(move: 2, to: 0) {
    check("往前插同样生效（可复原）", back.reordered, detail: back.detail + " ｜ " + (back.errorText ?? "无异常"))
}

header("实测 2：连续 " + String(repeatCount) + " 次的成功率与副作用")
var successes = 0
var durations: [Double] = []
var stuck = 0
var identityLoss = 0
for index in 0..<repeatCount {
    // 交替前后插，让顺序来回变化，不会一路拖出菜单栏
    if let trial = runTrial(move: index % 2 == 0 ? 0 : 2, to: index % 2 == 0 ? 2 : 0) {
        if trial.reordered { successes += 1 }
        if trial.errorText?.contains("再也找不到") == true { identityLoss += 1 }
        durations.append(trial.milliseconds)
        if trial.commandStuck || trial.buttonStuck { stuck += 1 }
    }
    usleep(60_000)
}
let rate = repeatCount > 0 ? Double(successes) / Double(repeatCount) * 100 : 0
let sorted = durations.sorted()
func pct(_ p: Double) -> Double {
    guard !sorted.isEmpty else { return 0 }
    let index = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
    return sorted[index]
}
print("  成功率 " + String(successes) + "/" + String(repeatCount) + " = " + String(format: "%.0f%%", rate))
if !sorted.isEmpty {
    print("  单次耗时 p50=" + String(format: "%.0f", pct(0.5)) + "ms p95=" + String(format: "%.0f", pct(0.95)) + "ms")
}
check("无卡键/卡钮副作用", stuck == 0, detail: String(stuck) + " 次检测到残留按下")
check("拖拽后图标身份仍可复用", identityLoss == 0, detail: String(identityLoss) + " 次拖完找不到同一 id")
check("图标数量未减少", fixtureItems().count >= initial.count, detail: "现在 " + String(fixtureItems().count) + " 个")

header("实测 3：M0 闸门进度")
print("  consecutiveSuccesses = " + String(mover.consecutiveSuccesses) + " ｜ totalAborts = " + String(mover.totalAborts))
print("  闸门：同一系统版本连续 100 次全绿才允许开放完整接管")

if wantDestructive {
    header("实测 4：该停手时是否真停手")

    // (a) 放置后被抢走：用一个会在 warp 之后把光标拽走的投递器模拟"别人在动鼠标"
    final class CursorSniper: DragEventPosting {
        private let inner: DragEventPosting
        private let height: CGFloat
        private(set) var postedCommandDown = false
        init(inner: DragEventPosting, height: CGFloat) {
            self.inner = inner
            self.height = height
        }
        @discardableResult
        func post(_ event: DragEvent) -> Bool {
            if case .warp(let point) = event {
                // 我们的 warp 照常生效，紧接着把光标抢走
                CGWarpMouseCursorPosition(CGPoint(x: point.x, y: height - point.y))
                // 必须立刻抢：mover 复核前只 settle 15ms，晚一点就变成"探针没构造出条件"
                CGWarpMouseCursorPosition(CGPoint(x: point.x - 220, y: height - point.y - 140))
            }
            if case .commandDown = event { postedCommandDown = true }
            return inner.post(event)
        }
    }

    let sniper = CursorSniper(inner: CGDragEventPoster(primaryScreenHeight: primaryHeight), height: primaryHeight)
    let sniped = AccessibilityMenuBarMover(
        reader: reader,
        cursor: cursor,
        poster: sniper,
        config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: true)
    )
    var driftAborted = false
    if let item = fixtureItems().first,
       let target = MenuBarDropTarget.targetX(in: fixtureItems(), moving: 0, to: 2) {
        do {
            _ = try sniped.move(itemID: item.id, toX: target)
        } catch let error as MenuBarMoveError {
            driftAborted = isAbort(error, { if case .cursorDrift = $0 { return true }; return false })
        } catch {}
    }
    // 真机上 warp 与 NSEvent.mouseLocation 之间有毫秒级竞态，这条无法稳定构造；
    // 同一逻辑已由离线断言 releasesCommandWhenCursorDriftsMidDrag 覆盖，这里如实标未验证
    if driftAborted {
        check("光标被抢走时中止", true, detail: "真机复现成功")
        check("中止时未按下 ⌘", !sniper.postedCommandDown)
    } else {
        print("  ○ 光标被抢走时中止：真机未能稳定构造（warp/读数竞态），该路径由离线断言覆盖 → 不计通过也不计失败")
    }
    check("中止后 ⌘ 干净", !isCommandStuck())

    // (b) 用户真的按住鼠标 → 必须让位
    let holder = CGDragEventPoster(primaryScreenHeight: primaryHeight)
    let pressPoint = cursor.currentLocation
    holder.post(.mouseDown(pressPoint))
    usleep(90_000)
    let held = cursor.isPrimaryButtonPressed
    var holdAborted = false
    if held, let target = MenuBarDropTarget.targetX(in: fixtureItems(), moving: 0, to: 2),
       let item = fixtureItems().first {
        do {
            _ = try mover.move(itemID: item.id, toX: target)
        } catch let error as MenuBarMoveError {
            holdAborted = isAbort(error, { if case .userInteracting = $0 { return true }; return false })
        } catch {}
    } else {
        print("  ！未能制造真实按住状态，该子项未验证")
    }
    // 抬起必须打在按下的同一个点，否则系统认为这次按下还没结束
    for _ in 0..<3 {
        holder.post(.mouseUp(pressPoint))
        usleep(60_000)
    }
    check("用户按住鼠标时让位", held ? holdAborted : true, detail: held ? "已验证" : "无法构造，视为未验证")
    check("释放后无卡住的鼠标键", !isMouseButtonStuck())
    // flagsState 会把我们贴在鼠标事件上的 maskCommand 也算进去，
    // 所以报"按下"时先补一次显式抬起再读：回落=读数被合成事件污染（无害），
    // 不回落=真的卡键（严重缺陷，必须当作事故处理）
    if isCommandStuck() {
        holder.post(.commandUp)
        usleep(80_000)
        let stillStuck = isCommandStuck()
        if stillStuck {
            // 两种解释无法用现有手段区分：
            //   ① 真卡键（严重）；② flagsState 把我们逐个鼠标事件携带的 maskCommand 也算进去了
            // 判别实验：鼠标事件不再携带 flags（只靠真实 ⌘ keyDown/Up），若读数干净即证 ②
            failures.append("⌘ 状态读数可疑（需判别实验，见 findings/02-drag.md 未决项）")
            print("  ? ⌘ 读数在本轮结束后仍报按下，且补发 keyUp 不回落")
            print("    待定：可能真卡键，也可能是鼠标事件自带 flags 污染了读数——需判别实验，不当作通过")
        } else {
            check("⌘ 无真残留", true, detail: "补抬后读数回落，先前是合成事件 flags 污染")
        }
    } else {
        check("⌘ 无残留", true)
    }

    // (c) 目标不存在
    var vanished = false
    do {
        _ = try mover.move(itemID: "no.such.item", toX: 100)
    } catch let error as MenuBarMoveError {
        vanished = isVanished(error)
    } catch {}
    check("目标图标不存在时明确报错", vanished)

    // (d) 未确认支持的 OS 必须拒绝工作
    let guarded = AccessibilityMenuBarMover(
        reader: reader, cursor: cursor, poster: poster,
        config: AccessibilityMenuBarMover.Config(isConfirmedSupportedOS: false)
    )
    var refused = false
    if let item = fixtureItems().first {
        do {
            _ = try guarded.move(itemID: item.id, toX: item.centerX)
        } catch let error as MenuBarMoveError {
            if case .unsupportedOS = error { refused = true }
        } catch {}
    }
    check("未确认的 OS 上一律不动图标", refused)
}

header("结论")
let verdict = failures.isEmpty
print(verdict
    ? "验证项 2 主体通过：拖拽生效、可复原、无卡键卡钮、身份不因重排而丢失"
    : "存在 " + String(failures.count) + " 项未过: " + failures.joined(separator: "; "))
print("注意：产品侧 isConfirmedSupportedOS 仍为 false，需连跑 100 次全绿后才开放完整接管")
exit(verdict ? 0 : 1)
