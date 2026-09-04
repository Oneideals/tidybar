import AppKit
import CoreGraphics
import Foundation
import TidyBarCore

// M0 验证项 3：崩溃与强杀安全。
//
// 三个角色分工明确，关键是「读残留的必须是另一个进程」：
//   drag     受害者：发起一次真实 ⌘ 拖拽（故意拖得很长），等外部 kill -9
//   inspect  检查者：全新进程读取系统输入残留 + journal 状态 + 图标现状
//   recover  恢复者：走 recoverOnLaunch → 按未完成的意图重放，验证收敛
//
// 之所以要拖长：进程死在 mouseDown 与 mouseUp 之间时 defer 不会执行，
// 系统可能留下"按住的鼠标键/⌘"——这是比布局错乱更严重、也更难归因的残害，
// 必须用独立进程去量，不能自报清白。
//
//   ./scripts/build-fixture-app.sh && open dist/TidyBarFixture.app --args 4
//   ./scripts/m0-crash-test.sh

let arguments = CommandLine.arguments

func value(_ flag: String, _ fallback: String) -> String {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return fallback }
    return arguments[index + 1]
}

let role = value("--role", "inspect")
let fixtureBundle = value("--bundle", "local.tidybar.fixture")
let journalDirectory = URL(fileURLWithPath: value("--journal", AppPaths.journalDirectory.path))
let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

// 拖拽步数/间隔：把一次拖拽拉长到可被 kill 命中的窗口
let slowDragConfig = AccessibilityMenuBarMover.Config(
    stepCount: 80,
    settleInterval: 0.04,
    initialHoldInterval: 0.07,
    isConfirmedSupportedOS: true
)

func makeServices(poster: DragEventPosting? = nil) -> SystemServices {
    let reader = AccessibilityMenuBarReader()
    return SystemServices(
        reader: reader,
        mover: AccessibilityMenuBarMover(
            reader: reader,
            cursor: AppKitCursorReader(),
            poster: poster ?? CGDragEventPoster(primaryScreenHeight: primaryHeight),
            config: slowDragConfig
        ),
        cursor: AppKitCursorReader(),
        accessibility: AppKitAccessibilityTrust(),
        screens: AppKitScreenObserver()
    )
}

func fixtureOrder() -> [String] {
    MenuBarEnumeration.sortedLeftToRight(
        AccessibilityMenuBarReader().discoverItems(owning: fixtureBundle)
    ).map(\.title)
}

func printInputResidue(prefix: String = "  ") {
    let buttons = NSEvent.pressedMouseButtons
    let flags = CGEventSource.flagsState(.combinedSessionState)
    print(prefix + "RESIDUE mouseButtons=" + String(buttons) + " sessionFlags=" + String(flags.rawValue)
          + " commandHeld=" + (flags.contains(.maskCommand) ? "yes" : "no"))
}

func printJournalState(_ journal: LayoutJournal, prefix: String = "  ") {
    let pending = journal.readPendingIntent()
    let committed = journal.readCommittedLayout()
    print(prefix + "JOURNAL pending=" + (pending.map { "\($0.itemID)→\($0.targetZone.rawValue)" } ?? "none")
          + " committed=" + (committed.map { "\($0.occupiedCount)项/\($0.allItemIDs.count)总" } ?? "none"))
}

let journal = LayoutJournal(directory: journalDirectory)

switch role {
case "drag":
    // 受害者：发起一次真实拖拽，中途会被 kill -9
    let services = makeServices()
    let engine = LayoutEngine(layout: journal.readCommittedLayout() ?? MenuBarLayout(), services: services, journal: journal)
    _ = engine.recoverOnLaunch()
    let current = MenuBarEnumeration.sortedLeftToRight(AccessibilityMenuBarReader().discoverItems(owning: fixtureBundle))
    guard current.count >= 3,
          let target = MenuBarDropTarget.targetX(in: current, moving: 0, to: 2) else {
        print("VICTIM abort: fixture 图标不足")
        exit(3)
    }
    print("VICTIM pid=\(ProcessInfo.processInfo.processIdentifier) order=\(current.map(\.title).joined(separator: ">"))")
    fflush(stdout)
    do {
        try engine.apply(itemID: current[0].id, to: .visible, targetX: target)
        print("VICTIM completed order=\(fixtureOrder().joined(separator: ">"))")
        fflush(stdout)
    } catch {
        print("VICTIM error \(error)")
        fflush(stdout)
    }

case "terminate":
    // 受害者（优雅退出版）：同样拉长一次拖拽，但外部发的是 SIGTERM 而不是 kill -9
    let services = makeServices()
    let engine = LayoutEngine(layout: journal.readCommittedLayout() ?? MenuBarLayout(), services: services, journal: journal)
    _ = engine.recoverOnLaunch()
    let shutdown = GracefulShutdown()
    shutdown.arm { sig in
        // 收尾跑在信号队列上：这里只做 mover/引擎允许的线程安全动作，不再回到主队列
        let inFlight = (services.mover as? DragReleasing)?.isDragInFlight ?? false
        engine.prepareForTermination()
        print("GRACEFUL signal=\(sig) wasInFlight=\(inFlight ? "yes" : "no") pending=\(journal.hasPendingIntent)")
        fflush(stdout)
        exit(0)
    }
    let current = MenuBarEnumeration.sortedLeftToRight(AccessibilityMenuBarReader().discoverItems(owning: fixtureBundle))
    guard current.count >= 3,
          let target = MenuBarDropTarget.targetX(in: current, moving: 0, to: 2) else {
        print("TERMVICTIM abort: fixture 图标不足")
        exit(3)
    }
    print("TERMVICTIM pid=\(ProcessInfo.processInfo.processIdentifier) order=\(current.map(\.title).joined(separator: ">"))")
    fflush(stdout)
    // 监视线程：把"真的进入按下状态"打成一行。脚本据此发信号，而不是靠固定 sleep 猜窗口——
    // 上一版就是因此打在了枚举阶段（冷启动全量扫描要 2 秒多），测到的 wasInFlight 永远是 no。
    Thread.detachNewThread {
        let releasing = services.mover as? DragReleasing
        while true {
            if releasing?.isDragInFlight == true {
                print("TERMVICTIM inflight=yes")
                fflush(stdout)
                return
            }
            usleep(10_000)
        }
    }
    do {
        try engine.apply(itemID: current[0].id, to: .visible, targetX: target)
        print("TERMVICTIM completed（没被 SIGTERM 命中，本例无效）")
        fflush(stdout)
    } catch {
        print("TERMVICTIM error \(error)")
        fflush(stdout)
    }

case "recover":
    // 恢复者：模拟下次启动，验证孤儿意图被识别并重放
    let services = makeServices()
    let engine = LayoutEngine(layout: MenuBarLayout(), services: services, journal: journal)
    let before = fixtureOrder()
    let recovery = engine.recoverOnLaunch()

    if case .clean = recovery {
        print("RECOVER clean（无孤儿意图 → kill 没落在窗口内，本例无效）")
    } else if case .interrupted(let intent, _) = recovery {
        print("RECOVER detected intent \(intent.itemID) → \(intent.targetZone.rawValue) failures=\(intent.replayFailures)")
        // 中止原因分两种，读数不留白就永远分不清"哨兵正常让位"与"实现有 bug"：
        // 真人在动鼠标 → 应该中止；warp 本身失效 → 才是问题。
        print("RECOVER preflight cursor=\(NSEvent.mouseLocation) leftButtonPressed=\(NSEvent.pressedMouseButtons & 1 != 0)")
        // 与产品装配层同一条路：只经 engine.replay，不再自己拼 apply
        engine.targetProvider = { itemID, _ in
            let items = MenuBarEnumeration.sortedLeftToRight(
                AccessibilityMenuBarReader().discoverItems(owning: fixtureBundle)
            )
            guard items.count >= 3,
                  let from = items.firstIndex(where: { $0.id == itemID }) else { return nil }
            return MenuBarDropTarget.targetX(in: items, moving: from, to: 2)
        }
        do {
            try engine.replay(intent)
            print("RECOVER replayed ok pendingCleared=\(!journal.hasPendingIntent)")
        } catch {
            let outcome = engine.noteReplayFailure()
            print("RECOVER replay failed \(error) outcome=\(outcome) pending=\(journal.hasPendingIntent)")
        }
    }
    print("RECOVER order \(before.joined(separator: ">")) → \(fixtureOrder().joined(separator: ">"))")

case "inspect":
    print("INSPECT pid=\(ProcessInfo.processInfo.processIdentifier)（未投递任何输入事件的全新进程）")
    printInputResidue()
    printJournalState(journal)
    let order = fixtureOrder()
    print("  ICONS count=\(order.count) order=\(order.joined(separator: ">"))")

case "poison":
    // 埋一个"永远做不成"的孤儿意图（itemID 指向已不存在的图标），并且故意用**旧格式**写盘：
    // 一次覆盖两件事——升级前留下的文件仍要能读出来，以及重放两次后必须放弃而不是每次开机都撞墙。
    let dead = LayoutJournal.LayoutIntent(
        itemID: "local.tidybar.gone", targetZone: .hidden, targetPosition: nil,
        previousZone: .visible, previousPosition: 0
    )
    try journal.writeIntent(dead)
    let pendingURL = journalDirectory.appendingPathComponent("layout.pending.json")
    var object = (try? JSONSerialization.jsonObject(with: Data(contentsOf: pendingURL))) as? [String: Any] ?? [:]
    object.removeValue(forKey: "replayFailures")
    try JSONSerialization.data(withJSONObject: object).write(to: pendingURL, options: .atomic)
    print("POISON planted legacy-format intent itemID=\(dead.itemID) readable=\(journal.readPendingIntent() != nil)")
    printJournalState(journal)

default:
    print("未知角色 \(role)")
    exit(2)
}
