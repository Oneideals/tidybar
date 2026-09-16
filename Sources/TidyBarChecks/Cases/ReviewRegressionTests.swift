import Foundation
import CoreGraphics
import AppKit
import TidyBarCore

@MainActor private func formViews(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(formViews)
}

/// 生命周期与异常路径：通过产品使用的公共入口验证，不调用私有实现。
struct ReviewRegressionTests {
    func manualClassificationUsesToggleAsVisibleBoundary() throws {
        let owner = Bundle.main.bundleIdentifier ?? "local.tidybar.app"
        let toggle = ManagedItem(id: "own-toggle", ownerBundleID: owner, title: "◀",
                                 frame: CGRect(x: 688, y: 1176, width: 24, height: 24))
        let reader = FakeMenuBarReader(items: [TestItems.item("left", centerX: 400),
            TestItems.item("right", centerX: 600), TestItems.item("between", centerX: 650),
            toggle, TestItems.item("visible", centerX: 750)])
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("manual-toggle-boundary"))
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["between", "visible"]]),
                                  services: makeServices(reader: reader, mover: nil), journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.dividerIDs = ["left", "right"]
        controller.applyScan(reader.items)
        controller.dividerCenters = (400, 600)
        expect((engine.targetProvider?("between", .visible) ?? 0) > toggle.centerX,
               "同步移动的常显落点同样必须越过按钮，不能把分隔符右侧误认为已到位")
        var requested = 0
        controller.onRequestPhysicalArrangement = { _ in requested += 1 }
        controller.realignToDividers()
        expectEqual(engine.layout.zone(of: "between"), .hidden, "按钮左侧必须归隐藏区，即使位于右分隔符右侧")
        expectEqual(engine.layout.zone(of: "visible"), .visible)
        expectEqual(requested, 1, "重算归属后仍需将隐藏分隔符移回按钮旁")
    }

    func confirmedRenameKeepsCommittedOrderAcrossRestart() throws {
        let directory = TestPaths.journalDirectory("rename-exit-order")
        let journal = LayoutJournal(directory: directory)
        let ledger = IdentityLedgerStore(url: directory.appendingPathComponent("identity.json"))
        let old = ManagedItem(id: "com.review.rename.old", ownerBundleID: "com.review.rename", title: "Old",
                              frame: CGRect(x: 588, y: 1176, width: 24, height: 24))
        let renamed = ManagedItem(id: "com.review.rename.new", ownerBundleID: old.ownerBundleID, title: "New", frame: old.frame)
        let peer = TestItems.item("peer", centerX: 640)
        let original = MenuBarLayout(zones: ["hidden": [old.id, peer.id]])
        try journal.writeCommitted(original)
        let engine = LayoutEngine(layout: original, services: makeServices(mover: nil), journal: journal, ledger: ledger)
        engine.fold(items: [old, peer], newItemZone: .visible)
        engine.fold(items: [renamed, peer], newItemZone: .visible)
        engine.prepareForTermination()
        expectEqual(journal.readCommittedLayout(), original, "被动改名不应覆写整份已提交布局")
        let restarted = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil), journal: journal, ledger: ledger)
        _ = restarted.recoverOnLaunch()
        restarted.fold(items: [renamed, peer], newItemZone: .visible)
        expectEqual(restarted.layout.items(in: .hidden), [renamed.id, peer.id], "历史名称应在原槽位恢复，不能追加到分区末尾")
        var latest = renamed
        for index in 0...IdentityLedger.maxAliases {
            latest = ManagedItem(id: "com.review.rename.version-\(index)", ownerBundleID: old.ownerBundleID,
                                 title: "Version \(index)", frame: CGRect(x: 688, y: 1176, width: 24, height: 24))
            engine.fold(items: [peer, latest], newItemZone: .visible)
        }
        expect(!(ledger.load().first { $0.ownerBundleID == old.ownerBundleID }?.aliases.contains(old.id) ?? true),
               "覆盖旧名称已超出台账别名上限的场景")
        let afterManyRenames = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                           journal: journal, ledger: ledger)
        _ = afterManyRenames.recoverOnLaunch()
        afterManyRenames.fold(items: [peer, latest], newItemZone: .visible)
        expectEqual(afterManyRenames.layout.items(in: .hidden), [latest.id, peer.id])
    }

    func ownerFallbackDoesNotOverrideAnotherLedgerAssignment() throws {
        let directory = TestPaths.journalDirectory("owner-order-ambiguity")
        let journal = LayoutJournal(directory: directory)
        let ledger = IdentityLedgerStore(url: directory.appendingPathComponent("identity.json"))
        let owner = "com.review.separate"
        let oldID = owner + ".retired"
        let active = ManagedItem(id: owner + ".active", ownerBundleID: owner, title: "Active",
                                 frame: CGRect(x: 588, y: 1176, width: 24, height: 24))
        try ledger.save([
            IdentityRecord(assignmentKey: "retired", ownerBundleID: owner, observedTitle: "Retired",
                           observedOrdinal: 0, ownerItemCount: 2, aliases: [oldID], zoneRaw: "hidden",
                           pinnedBy: .user, lastSeenAt: Date()),
            IdentityRecord(assignmentKey: "active", ownerBundleID: owner, observedTitle: "Active",
                           observedOrdinal: 1, ownerItemCount: 2, aliases: [active.id], zoneRaw: "alwaysHidden",
                           pinnedBy: .user, lastSeenAt: Date()),
        ])
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["hidden": [oldID]]),
                                  services: makeServices(mover: nil), journal: journal, ledger: ledger)
        engine.fold(items: [active], newItemZone: .visible)
        expectEqual(engine.layout.zone(of: active.id), .alwaysHidden, "同 owner 的另一条分配不能冒充当前图标的历史位置")

        for scenario in ["partial-owner", "multiple-live", "multiple-saved"] {
            let scoped = TestPaths.journalDirectory(scenario)
            let store = IdentityLedgerStore(url: scoped.appendingPathComponent("identity.json"))
            let item = ManagedItem(id: active.id, ownerBundleID: owner, title: active.title, frame: active.frame,
                                   ownerItemCount: scenario == "multiple-saved" ? 1 : 2)
            var observed = [item]
            if scenario == "multiple-live" {
                observed.append(ManagedItem(id: owner + ".second", ownerBundleID: owner, title: "Second",
                                            frame: CGRect(x: 628, y: 1176, width: 24, height: 24), ownerItemCount: 2))
            }
            let savedIDs = scenario == "multiple-saved" ? [oldID, owner + ".other-retired"] : [oldID]
            try store.save([IdentityRecord(assignmentKey: "active", ownerBundleID: owner, observedTitle: "Active",
                                           observedOrdinal: 0, ownerItemCount: item.ownerItemCount, aliases: [item.id],
                                           zoneRaw: "alwaysHidden", pinnedBy: .user, lastSeenAt: Date())])
            let candidate = LayoutEngine(layout: MenuBarLayout(zones: ["hidden": savedIDs]),
                                         services: makeServices(mover: nil), journal: LayoutJournal(directory: scoped), ledger: store)
            candidate.fold(items: observed, newItemZone: .visible)
            expectEqual(candidate.layout.zone(of: item.id), .alwaysHidden, "缺少唯一且完整的对应关系时不应认领旧槽位：\(scenario)")
        }
    }

    func passiveScansDoNotOverwriteCommittedLayoutOnExit() throws {
        for (trusted, ids) in [(false, [String]()), (true, []), (true, ["a"])] {
            let journal = LayoutJournal(directory: TestPaths.journalDirectory("empty-scan-exit"))
            let saved = MenuBarLayout(zones: ["visible": ["a", "b"], "hidden": ["c"]])
            try journal.writeCommitted(saved)
            let trust = FakeTrust(); trust.isTrusted = trusted
            let services = SystemServices(reader: FakeMenuBarReader(ids: ids), mover: nil, cursor: FakeCursor(),
                                          accessibility: trust, screens: FakeScreens())
            let engine = LayoutEngine(layout: MenuBarLayout(), services: services, journal: journal)
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.start()
            expectEqual(controller.snapshot.items.map(\.id), ids)
            controller.flushForTermination()
            expectEqual(journal.readCommittedLayout(), saved, "不完整观测不能清空已保存的分区和顺序")
            let restarted = LayoutEngine(layout: MenuBarLayout(), services: services, journal: journal)
            _ = restarted.recoverOnLaunch()
            expectEqual(restarted.layout, saved, "下一次有权限的启动仍须有完整恢复依据")
            controller.applyScan(["a", "b", "c"].map { TestItems.item($0) })
            expect(controller.reassignZone("a", to: .alwaysHidden))
            let assigned = try require(journal.readCommittedLayout())
            expectEqual(assigned.zone(of: "a"), .alwaysHidden, "明确分配已经即时提交")
            controller.applyScan(ids.map { TestItems.item($0) })
            controller.flushForTermination()
            expectEqual(journal.readCommittedLayout(), assigned, "退出不能用后续的不完整扫描覆盖用户新提交")
        }
    }

    func invalidatedScanCannotOverwriteManualChanges() throws {
        MainActor.assumeIsolated {
            let enumerator = BackgroundEnumerator()
            let firstScan = DispatchSemaphore(value: 0)
            firstScan.signal() // 一次性令牌；销毁时允许回到初始值 0。
            let started = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            let scan: @Sendable () -> [ManagedItem] = {
                if firstScan.wait(timeout: .now()) == .success {
                    started.signal()
                    _ = release.wait(timeout: .now() + 2)
                    return [TestItems.item("before-drag")]
                }
                return [TestItems.item("after-drag")]
            }
            var applied: [String] = []
            let apply: @MainActor @Sendable ([ManagedItem]) -> Void = { applied.append(contentsOf: $0.map(\.id)) }
            enumerator.request(reason: .itemAppeared, scan: scan, apply: apply)
            expectEqual(started.wait(timeout: .now() + 1), .success)
            enumerator.invalidatePendingResults()
            enumerator.request(reason: .userRequested, scan: scan, apply: apply)
            release.signal()
            let deadline = Date().addingTimeInterval(2)
            while !applied.contains("after-drag"), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            expectEqual(applied, ["after-drag"], "拖拽前已开始的扫描不能消费手动布局更新")
        }
    }

    func syntheticMouseEventsCannotChangePresentation() throws {
        try MainActor.assumeIsolated {
            let events = EventEngine(menuBarFrames: { [CGRect(x: -10000, y: -10000, width: 20000, height: 20000)] })
            var reveals = 0, conceals = 0, manualChanges = 0
            events.onEvent = { _ in reveals += 1 }
            events.onConcealRequest = { conceals += 1 }
            events.onManualLayoutChange = { manualChanges += 1 }
            for type in [CGEventType.leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .leftMouseUp] {
                let cgEvent = try require(CGEvent(mouseEventSource: nil, mouseType: type,
                                                 mouseCursorPosition: CGPoint(x: 600, y: 12), mouseButton: .left))
                cgEvent.flags = .maskCommand
                cgEvent.setIntegerValueField(.eventSourceUserData, value: CGDragEventPoster.syntheticEventTag)
                events.receive(try require(NSEvent(cgEvent: cgEvent)))
            }
            expectEqual(reveals, 0)
            expectEqual(conceals, 0)
            expectEqual(manualChanges, 0)
            let real = try require(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown,
                                          mouseCursorPosition: CGPoint(x: 600, y: 12), mouseButton: .right))
            events.receive(try require(NSEvent(cgEvent: real)))
            expectEqual(conceals, 1, "普通用户事件仍须正常到达控制器")
        }
    }

    func failedRecoveryCannotBeReplacedByAutomaticChanges() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("pending-auto-guard"))
        let original = MenuBarLayout(zones: ["visible": ["a"], "hidden": ["b"]])
        try journal.writeCommitted(original)
        let intent = LayoutJournal.LayoutIntent(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                               previousZone: .visible, previousPosition: 0)
        try journal.writeIntent(intent)
        let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("b", centerX: 640)])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        mover.injectedError = .dragInterrupted
        let engine = LayoutEngine(layout: original, services: makeServices(reader: reader, mover: mover), journal: journal)
        let rule = DisplayRule(name: "自动显示", conditions: [.batteryLow], actions: [.show("a")])
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(rules: [rule]), store: FakeSettingsStore())
        controller.start(scansSynchronously: false)
        controller.applyScan(reader.items)
        expectEqual(journal.readPendingIntent()?.replayFailures, 1)
        var preparations = 0
        controller.onBeginLayoutAdjustment = { preparations += 1; return reader.items }
        controller.onEndLayoutAdjustment = { preparations -= 1 }
        let context = SystemContext(batteryLevel: 0.1, isCharging: false, connectedWiFiSSID: nil,
                                    activeFocusMode: nil, frontmostAppBundleID: nil)
        expect(controller.evaluateRules(context: context).isEmpty, "失败后仍在磁盘上的恢复意图必须阻止自动规则")
        expect(!controller.move("b", to: .visible, targetX: 700, origin: .rule), "自动物理整理同样不能覆盖恢复意图")
        expectEqual(journal.readPendingIntent()?.id, intent.id)
        expectEqual(journal.readPendingIntent()?.replayFailures, 1)
        expectEqual(preparations, 0)
        mover.injectedError = nil
        expect(controller.move("a", to: .visible, targetX: 700), "明确的用户新选择可以替代旧意图")
        expectNil(journal.readPendingIntent())
        expectEqual(engine.layout.zone(of: "a"), .visible)
        expectEqual(preparations, 0, "准备与收尾必须配对")
    }

    func reassignmentWithoutPositionKeepsExistingOrder() throws {
        for physical in [false, true] {
            let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("b", centerX: 640)])
            let mover = FakeMenuBarMover(); mover.coupledReader = reader
            let journal = LayoutJournal(directory: TestPaths.journalDirectory("same-zone-order"))
            let original = MenuBarLayout(zones: ["visible": ["a", "b"]])
            let engine = LayoutEngine(layout: original, services: makeServices(reader: reader, mover: physical ? mover : nil),
                                      journal: journal, sentinel: EventSentinel(minIntervalBetweenOperations: 0))
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.applyScan(reader.items)
            controller.dividerCenters = (400, 500)
            expect(controller.reassignZone("a", to: .visible))
            expectEqual(engine.layout.items(in: .visible), ["a", "b"], "同区无位置请求不能隐式追加到末尾")
            expectEqual(journal.readCommittedLayout()?.items(in: .visible), ["a", "b"])
            expect(!engine.hasConfirmedDragSupport, "原地保持不能证明实际拖拽受支持")
            expect(controller.reassignZone("a", to: .visible, position: 1))
            expectEqual(engine.layout.items(in: .visible), ["b", "a"], "显式位置仍能重排")
            if physical { expect(engine.hasConfirmedDragSupport) }
        }
    }

    func profilesAndRulesExcludeProtectedControls() throws {
        let own = ManagedItem(id: "own-toggle", ownerBundleID: Bundle.main.bundleIdentifier ?? "local.tidybar.app",
                              title: "TidyBar", frame: CGRect(x: 500, y: 1176, width: 24, height: 24))
        let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("clock", isSystemOwned: true), own])
        let original = MenuBarLayout(zones: ["visible": ["a", "clock"]])
        let stored = MenuBarLayout(zones: ["hidden": ["clock", own.id, "a"]])
        let profileRule = DisplayRule(name: "旧档案", conditions: [.batteryLow], actions: [.applyProfile("legacy")])
        let directRule = DisplayRule(name: "旧单项规则", conditions: [.batteryLow], actions: [.hide("clock"), .hide(own.id)])
        let engine = LayoutEngine(layout: original, services: makeServices(reader: reader, mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("protected-profile")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(profiles: ["legacy": stored], rules: [profileRule, directRule]),
                                          store: FakeSettingsStore())
        controller.applyScan(reader.items)
        controller.saveProfile(named: "saved")
        expectEqual(controller.settings.profiles["saved"]?.allItemIDs, Set(["a"]))
        expect(controller.applyProfile(named: "legacy"))
        expectEqual(engine.layout.zone(of: "clock"), .visible)
        expectNil(engine.layout.zone(of: own.id))
        expectEqual(engine.layout.zone(of: "a"), .hidden)
        let context = SystemContext(batteryLevel: 0.1, isCharging: false, connectedWiFiSSID: nil,
                                    activeFocusMode: nil, frontmostAppBundleID: nil)
        controller.evaluateRules(context: context)
        expectEqual(engine.layout.zone(of: "clock"), .visible)
        expectNil(engine.layout.zone(of: own.id))
    }

    func overviewDoesNotReportRejectedMovesAsCompleted() throws {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let reader = FakeMenuBarReader(ids: ["utility"])
            let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["utility"]]),
                                      services: makeServices(reader: reader, mover: RejectingMover(.dragInterrupted)),
                                      journal: LayoutJournal(directory: TestPaths.journalDirectory("overview-failure")))
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.applyScan(reader.items)
            engine.targetProvider = { _, _ in 700 }
            let overview = IconOverviewView { id, zone in controller.reassignZone(id, to: zone) }
            overview.onZoneChanged = { [weak overview] in overview?.reload(rows: IconOverviewBuilder.rows(from: controller)) }
            overview.reload(rows: IconOverviewBuilder.rows(from: controller))
            expect(!overview.applySmartRecommendations(), "调用方必须知道本批次未完成")
            expectEqual(engine.layout.zone(of: "utility"), .visible)
            let messages = formViews(overview).compactMap { ($0 as? NSTextField)?.stringValue }
            expect(messages.contains { $0.contains("未完成") }, "失败结果必须到达真实界面")
        }
    }

    func twoDividersKeepIndependentZonesAndLegalLandingSlots() throws {
        let items = [TestItems.item("a", centerX: 300), TestItems.item("left", centerX: 500),
                     TestItems.item("right", centerX: 900), TestItems.item("toggle", centerX: 940),
                     TestItems.item("v", centerX: 1100), TestItems.item("system", centerX: 1200, isSystemOwned: true)]
        expectEqual(DividerGeometry.boundaryLandingX(for: "v", to: .hidden, ordered: items,
                                                      leftEdge: 500, rightEdge: 900, dividerIDs: ["left", "right"]), 900)
        expectEqual(DividerGeometry.boundaryLandingX(for: "a", to: .hidden, ordered: items,
                                                      leftEdge: 500, rightEdge: 900, dividerIDs: ["left", "right"]), 514)
        let layout = MenuBarLayout(zones: ["alwaysHidden": ["a"], "visible": ["v"]])
        expectEqual(DividerGeometry.arrangementOrder(items: items, layout: layout, leftDivider: "left",
                                                     rightDivider: "right", toggle: "toggle"),
                    ["a", "left", "right", "toggle", "v", "system"])
        let screen = ScreenInfo(identifier: 1, frame: CGRect(x: 0, y: 0, width: 3840, height: 2160),
                                menuBarHeight: 30, notchWidth: nil, isBuiltin: false)
        expectNil(MenuBarItemPolicy.rejection(frame: CGRect(x: -5000, y: 2130, width: 24, height: 24), screens: [screen]),
                  "双分隔符折叠后仍需识别始终隐藏项，供明确搜索访问")
    }

    private final class SequencedCursor: CursorReading {
        var currentLocation = CGPoint(x: 600, y: 1188)
        private var reads = 0
        var isPrimaryButtonPressed: Bool {
            reads += 1
            return reads >= 3
        }
    }

    func consecutiveProfileMovesWaitForTheSafetyInterval() throws {
        let reader = FakeMenuBarReader(ids: ["a", "b"])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        let profile = MenuBarLayout(zones: ["hidden": ["a", "b"]])
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a", "b"]]),
                                  services: makeServices(reader: reader, mover: mover),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("batch-cooldown")),
                                  sentinel: EventSentinel(minIntervalBetweenOperations: 0.02),
                                  clock: { Date(timeIntervalSince1970: 42) })
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(profiles: ["batch": profile]), store: FakeSettingsStore())
        controller.applyScan(reader.items)
        engine.targetProvider = { id, _ in id == "a" ? 700 : 740 }
        expect(controller.applyProfile(named: "batch"))
        expectEqual(mover.moved.count, 2)
        expectEqual(engine.layout, profile)
    }

    func userInputDuringCooldownStillAborts() throws {
        let reader = FakeMenuBarReader(ids: ["a", "b"])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a", "b"]]),
                                  services: makeServices(reader: reader, mover: mover, cursor: SequencedCursor()),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("cooldown-input")),
                                  sentinel: EventSentinel(minIntervalBetweenOperations: 0.02),
                                  clock: { Date(timeIntervalSince1970: 42) })
        try engine.apply(itemID: "a", to: .hidden, targetX: 700)
        expect(throws: LayoutEngine.EngineError.sentinelAborted(.userInteracting)) {
            try engine.apply(itemID: "b", to: .hidden, targetX: 740)
        }
        expectEqual(mover.moved.count, 1)
    }

    func abandonedRenamedRecoveryDoesNotReappearFromLedger() throws {
        let directory = TestPaths.journalDirectory("abandoned-rename")
        let journal = LayoutJournal(directory: directory)
        let ledger = IdentityLedgerStore(url: directory.appendingPathComponent("identity.json"))
        let old = ManagedItem(id: "com.review.app.old", ownerBundleID: "com.review.app", title: "Old",
                              frame: CGRect(x: 588, y: 1176, width: 24, height: 24))
        let new = ManagedItem(id: "com.review.app.new", ownerBundleID: old.ownerBundleID, title: "New", frame: old.frame)
        let peer = TestItems.item("peer", centerX: 640)
        let original = MenuBarLayout(zones: ["visible": [old.id], "hidden": [peer.id]])
        let seed = LayoutEngine(layout: original, services: makeServices(mover: nil), journal: journal, ledger: ledger)
        seed.fold(items: [old, peer], newItemZone: .visible)
        seed.pinAsUser(itemID: old.id)
        try journal.writeCommitted(original)
        try journal.writeIntent(.init(itemID: old.id, targetZone: .hidden, targetPosition: nil,
                                      previousZone: .visible, previousPosition: 0))
        var last: LayoutEngine?
        for _ in 0..<2 {
            let reader = FakeMenuBarReader(items: [new, peer])
            let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(reader: reader, mover: RejectingMover(.dragInterrupted)),
                                      journal: journal, ledger: ledger)
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.start(scansSynchronously: false)
            controller.applyScan(reader.items)
            last = engine
        }
        let engine = try require(last)
        engine.fold(items: [new, peer], newItemZone: .visible)
        expect(!journal.hasPendingIntent)
        expectEqual(engine.layout.zone(of: new.id), .visible, "放弃的目标不能从台账重新复活")
    }

    func profilePermutationCompletesInOneEvaluation() throws {
        let source = MenuBarLayout(zones: ["hidden": ["a", "b", "c", "d"]])
        let destination = MenuBarLayout(zones: ["hidden": ["c", "b", "d", "a"]])
        let rule = DisplayRule(name: "重排", conditions: [.batteryLow], actions: [.applyProfile("ordered")])
        let engine = LayoutEngine(layout: source, services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("profile-permutation")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(profiles: ["ordered": destination], rules: [rule]),
                                          store: FakeSettingsStore())
        controller.applyScan(["a", "b", "c", "d"].map { TestItems.item($0) })
        let context = SystemContext(batteryLevel: 0.1, isCharging: false, connectedWiFiSSID: nil,
                                    activeFocusMode: nil, frontmostAppBundleID: nil)
        controller.evaluateRules(context: context)
        expectEqual(engine.layout, destination)
        expect(controller.evaluateRules(context: context).isEmpty)
    }

    func ruleEditorKeepsSelectionAndUneditedActions() throws {
        try MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                      journal: LayoutJournal(directory: TestPaths.journalDirectory("rule-form")))
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.applyScan([TestItems.item("a"), TestItems.item("b")])
            let original = DisplayRule(name: "原规则", conditions: [.batteryLow], actions: [.hide("a"), .show("b")])
            var saved: DisplayRule?
            let editor = RuleEditorWindowController(controller: controller, editing: original) { saved = $0 }
            let views = formViews(try require(editor.window?.contentView))
            let action = try require(views.first { $0.identifier?.rawValue == "rule-action" } as? NSPopUpButton)
            let target = try require(views.first { $0.identifier?.rawValue == "rule-target" } as? NSPopUpButton)
            let name = try require(views.first { $0.identifier?.rawValue == "rule-name" } as? NSTextField)
            action.selectItem(at: 0)
            NSApp.sendAction(try require(action.action), to: action.target, from: action)
            expectEqual(target.selectedItem?.representedObject as? String, "a", "切换显示/隐藏应保留同一目标")
            target.selectItem(at: try require(target.itemArray.firstIndex { ($0.representedObject as? String) == "a" }))
            name.stringValue = "改名后的规则"
            let save = try require(views.compactMap { $0 as? NSButton }.first { $0.title == "保存" })
            NSApp.sendAction(try require(save.action), to: save.target, from: save)
            expectEqual(saved?.id, original.id)
            expectEqual(saved?.actions, [.show("a"), .show("b")], "编辑第一项不能删除其余动作")
        }
    }

    func targetlessRulesAreRejected() throws {
        let rule = DisplayRule(name: "未选目标", conditions: [.batteryLow], actions: [RuleAction.forZone(.hidden)])
        expect(!rule.isEvaluable, "未选目标不能保存成可执行规则")
    }

    func profileRulesApplyOnceAndRespectItemPriority() throws {
        let profile = MenuBarLayout(zones: ["hidden": ["a", "b"]])
        let rule = DisplayRule(name: "省电档案", conditions: [.batteryLow], actions: [.applyProfile("quiet")])
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a", "b"]]),
                                  services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("rule-profile")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(profiles: ["quiet": profile], rules: [rule]), store: FakeSettingsStore())
        controller.applyScan([TestItems.item("a"), TestItems.item("b")])
        let context = SystemContext(batteryLevel: 0.1, isCharging: false, connectedWiFiSSID: "Office",
                                    activeFocusMode: nil, frontmostAppBundleID: nil)
        controller.evaluateRules(context: context)
        expectEqual(engine.layout, profile)
        expectEqual(controller.settings.activeProfileName, "quiet")
        expect(controller.evaluateRules(context: context).isEmpty, "已应用的档案不得持续重排")
        controller.update {
            $0.rules.append(DisplayRule(name: "保留 a", conditions: [.batteryLow], actions: [.show("a")], priority: 1))
        }
        controller.evaluateRules(context: context)
        expectEqual(engine.layout.zone(of: "a"), .visible, "单项与档案动作也必须服从优先级")
        expectEqual(engine.layout.zone(of: "b"), .hidden)
        expect(controller.evaluateRules(context: context).isEmpty, "优先级覆盖后，档案顺序也必须收敛")
    }

    func unavailableWiFiStateIsNotTreatedAsDisconnected() throws {
        let rule = DisplayRule(name: "网络断开", conditions: [.wifiDisconnected], actions: [.hide("a")])
        let layout = MenuBarLayout(zones: ["visible": ["a"]])
        let engine = LayoutEngine(layout: layout, services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("unknown-wifi")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(rules: [rule]), store: FakeSettingsStore())
        controller.applyScan([TestItems.item("a")])
        let unknown = SystemContext(batteryLevel: nil, isCharging: false, connectedWiFiSSID: nil,
                                    activeFocusMode: nil, frontmostAppBundleID: nil)
        expect(controller.evaluateRules(context: unknown).isEmpty)
        expectEqual(engine.layout.zone(of: "a"), .visible)
        let knownDisconnected = RuleEngine().evaluate(rules: [rule], context: unknown, currentLayout: layout,
                                                      hasKnownWiFiState: true)
        expectEqual(knownDisconnected.changes.first?.to, .hidden, "明确断开时仍须触发规则")
    }

    func drawerAndMenuBarShareAutoHidePolicy() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("shared-reveal")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(rehideDelay: 2),
                                          settings: AppSettings(), store: FakeSettingsStore())
        let start = Date(timeIntervalSince1970: 10_000)
        controller.setMenuBarFolded(false, at: start)
        expect(controller.snapshot.isMenuBarExpanded)
        expect(!controller.snapshot.isRevealed, "原地展开不应同时打开抽屉")
        expect(controller.tick(at: start.addingTimeInterval(2)))
        expect(controller.isMenuBarFolded)
        controller.toggleDrawer(at: start.addingTimeInterval(4))
        controller.setInteractionActive(true, at: start.addingTimeInterval(5))
        expect(!controller.tick(at: start.addingTimeInterval(20)), "浏览抽屉时不自动关闭")
        controller.setInteractionActive(false, at: start.addingTimeInterval(20))
        expect(!controller.tick(at: start.addingTimeInterval(21)))
        expect(controller.tick(at: start.addingTimeInterval(22)))
    }

    func ordinaryDrawerExcludesAlwaysHiddenItems() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["hidden": ["a"], "alwaysHidden": ["b"]]),
                                  services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("drawer-filter")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan([TestItems.item("a"), TestItems.item("b")])
        expectEqual(controller.drawerItems.map(\.id), ["a"])
        expectEqual(controller.search("b").map(\.id), ["b"], "始终隐藏仍可经明确搜索访问")
    }

    func pointerTriggersAreRestrictedToTheMenuBar() throws {
        let events = EventEngine(menuBarFrames: { [CGRect(x: 0, y: 1176, width: 1440, height: 24)] })
        var received: [RevealTrigger] = []
        var outsideClicks = 0
        events.onEvent = { received.append($0.trigger) }
        events.onConcealRequest = { outsideClicks += 1 }
        events.receive(.init(trigger: .hover, location: CGPoint(x: 600, y: 100)), at: 1)
        events.receive(.init(trigger: .scrollOrSwipe, location: CGPoint(x: 600, y: 100)), at: 1)
        events.receive(.init(trigger: .hover, location: CGPoint(x: 600, y: 1188)), at: 1.01)
        events.receive(.init(trigger: .scrollOrSwipe, location: CGPoint(x: 600, y: 1188)), at: 1.01)
        events.receive(.init(trigger: .emptyBarClick, location: CGPoint(x: 2000, y: 1188)), at: 2)
        expectEqual(received, [.hover, .scrollOrSwipe])
        expectEqual(outsideClicks, 1)
    }

    func disabledEmptyBarTriggerDoesNotReveal() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("disabled-trigger")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(revealTriggers: [.dividerClick]), store: FakeSettingsStore())
        controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 600, y: 1188)))
        expect(!controller.snapshot.isRevealed)
    }

    func emptyBarClickAndScrollDispatchCustomActions() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("gesture-actions")))
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(),
            settings: AppSettings(revealTriggers: [.emptyBarClick, .scrollOrSwipe]),
            store: FakeSettingsStore()
        )
        var emptyBarClicks = 0
        var scrollEvents = 0
        controller.onEmptyBarClick = { emptyBarClicks += 1 }
        controller.onScrollOrSwipe = { scrollEvents += 1 }

        controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 600, y: 1188)))
        controller.handle(event: .init(trigger: .scrollOrSwipe, location: CGPoint(x: 600, y: 1188)))

        expectEqual(emptyBarClicks, 1, "空白区点击应成功调度外部 onEmptyBarClick")
        expectEqual(scrollEvents, 1, "滚轮轻扫应成功调度外部 onScrollOrSwipe")
    }

    func emptyBarClickPredicateFiltersNonEmptyAreas() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("predicate-filter")))
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(),
            settings: AppSettings(revealTriggers: [.emptyBarClick]),
            store: FakeSettingsStore()
        )
        var clicks = 0
        controller.onEmptyBarClick = { clicks += 1 }

        controller.emptySpacePredicate = { location in
            location.x > 500
        }

        // x = 200 (属于左侧文字菜单区)，谓词返回 false，被拦截
        controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 200, y: 1188)))
        expectEqual(clicks, 0, "谓词拦截的点击不应触发 onEmptyBarClick")

        // x = 600 (处于合法空白区)，谓词返回 true，正常放行
        controller.handle(event: .init(trigger: .emptyBarClick, location: CGPoint(x: 600, y: 1188)))
        expectEqual(clicks, 1, "谓词通过的点击应触发 onEmptyBarClick")
    }

    func applicationMenuGeometryEmptySpaceCalculations() throws {
        let screenNotched = ScreenInfo(
            identifier: 1,
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            menuBarHeight: 32,
            notchWidth: 160,
            isBuiltin: true
        )
        let screenExternalLeft = ScreenInfo(
            identifier: 2,
            frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            menuBarHeight: 24,
            notchWidth: nil,
            isBuiltin: false
        )

        let statusItem = ManagedItem(
            id: "com.apple.controlcenter",
            ownerBundleID: "com.apple.controlcenter",
            title: "Control Center",
            frame: CGRect(x: 1300, y: 868, width: 30, height: 32)
        )
        let statusItems = [statusItem]

        // 1. 刘海屏测试：
        // a. 垂直超出菜单栏高度带 (y < 868 - 2)
        expect(!ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: 600, y: 850), screen: screenNotched, statusItems: statusItems
        ), "垂直超出菜单栏高度带必须被拦截")

        // b. 水平落在左侧文字菜单区 (x < screen.minX + 280)
        expect(!ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: 200, y: 884), screen: screenNotched, statusItems: statusItems
        ), "左侧前台应用文字菜单区域必须被拦截")

        // c. 硬件刘海区避让 (midX = 720, notchWidth = 160 -> 640...800)
        expect(!ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: 720, y: 884), screen: screenNotched, statusItems: statusItems
        ), "硬件刘海正中区域必须被拦截")

        // d. 右侧状态项区避让 (x >= 1300 - 4)
        expect(!ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: 1305, y: 884), screen: screenNotched, statusItems: statusItems
        ), "右侧状态图标区域必须被拦截")

        // e. 真实空白区放行 (x = 550, 介于文字菜单 280 与 刘海 640 之间)
        expect(ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: 550, y: 884), screen: screenNotched, statusItems: statusItems
        ), "文字菜单与刘海之间的真实空白区必须放行")

        // 2. 外接负坐标无刘海屏测试：
        // a. 左侧文字菜单区 (x = -1800, 离 -1920 仅 120pt)
        expect(!ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: -1800, y: 1068), screen: screenExternalLeft, statusItems: []
        ), "负坐标外接屏的左侧文字菜单必须被拦截")

        // b. 中间有效空白区 (x = -1000, y = 1068, 菜单栏高 24 -> bottom 1056)
        expect(ApplicationMenuGeometry.isPointInsideEmptyMenuBarSpace(
            point: CGPoint(x: -1000, y: 1068), screen: screenExternalLeft, statusItems: []
        ), "负坐标外接屏的中间有效空白区必须放行")
    }

    func completedRecoveryReceiptPreventsDuplicateReplay() throws {
        let directory = TestPaths.journalDirectory("completed-recovery")
        let journal = LayoutJournal(directory: directory)
        try Data(#"{"zones":{"hidden":["a"]},"completedIntentID":"completed-a"}"#.utf8)
            .write(to: directory.appendingPathComponent("layout.committed.json"))
        try Data(#"{"id":"completed-a","itemID":"a","targetZone":"hidden","previousZone":"visible","previousPosition":0,"startedAt":"2026-09-08T00:00:00Z","replayFailures":0}"#.utf8)
            .write(to: directory.appendingPathComponent("layout.pending.json"))
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(), journal: journal)
        if case .interrupted = engine.recoverOnLaunch() {
            try record("提交已经完成，仅清理中断，不能再次重放")
        }
        expect(!journal.hasPendingIntent)
        expectEqual(engine.layout.zone(of: "a"), .hidden)
    }

    func newUserChoiceSupersedesDeferredRecovery() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("superseded-recovery"))
        let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("b", centerX: 640)])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        try journal.writeCommitted(MenuBarLayout(zones: ["visible": ["a"], "hidden": ["b"]]))
        try journal.writeIntent(.init(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                      previousZone: .visible, previousPosition: 0))
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(reader: reader, mover: mover),
                                  journal: journal, sentinel: EventSentinel(minIntervalBetweenOperations: 0))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.start(scansSynchronously: false)
        expect(controller.move("a", to: .visible, targetX: 700))
        engine.targetProvider = { _, _ in 600 }
        controller.applyScan(reader.items)
        expectEqual(engine.layout.zone(of: "a"), .visible, "旧恢复不能覆盖用户刚做的新选择")
        expectEqual(mover.moved.count, 1)
    }

    func deferredRecoveryFollowsConfirmedRename() throws {
        let directory = TestPaths.journalDirectory("renamed-recovery")
        let journal = LayoutJournal(directory: directory)
        let ledger = IdentityLedgerStore(url: directory.appendingPathComponent("identity.json"))
        let old = ManagedItem(id: "com.review.app.old", ownerBundleID: "com.review.app", title: "Old",
                              frame: CGRect(x: 588, y: 1176, width: 24, height: 24))
        let new = ManagedItem(id: "com.review.app.new", ownerBundleID: "com.review.app", title: "New", frame: old.frame)
        let peer = TestItems.item("peer", centerX: 640)
        let layout = MenuBarLayout(zones: ["visible": [old.id], "hidden": [peer.id]])
        let seed = LayoutEngine(layout: layout, services: makeServices(mover: nil), journal: journal, ledger: ledger)
        seed.fold(items: [old, peer], newItemZone: .visible)
        try journal.writeCommitted(layout)
        try journal.writeIntent(.init(itemID: old.id, targetZone: .hidden, targetPosition: nil,
                                      previousZone: .visible, previousPosition: 0))
        let reader = FakeMenuBarReader(items: [new, peer])
        let mover = FakeMenuBarMover(); mover.coupledReader = reader
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(reader: reader, mover: mover),
                                  journal: journal, ledger: ledger)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.start(scansSynchronously: false)
        controller.applyScan(reader.items)
        expectEqual(mover.moved.first?.itemID, new.id, "已确认改名后，应按当前 ID 恢复")
        expect(!journal.hasPendingIntent)
        expectEqual(journal.readCommittedLayout()?.zone(of: new.id), .hidden)
    }

    func autoHideSettingTakesEffectWithoutRestart() throws {
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("live-hide-setting")))
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(rehideDelay: 2),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.update { $0.rehideDelay = 0 }
        let now = Date(timeIntervalSince1970: 10_000)
        controller.handle(event: .init(trigger: .hotkey, location: .zero), at: now)
        expect(!controller.tick(at: now.addingTimeInterval(20)), "设为从不后，不应继续使用启动时的 2 秒")
        expect(controller.snapshot.isRevealed)
    }

    func demoModeRestoresLayoutWithoutPersistingTemporaryChoices() throws {
        let layout = MenuBarLayout(zones: ["visible": ["a", "clock"], "alwaysHidden": ["b"]])
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("temporary-demo"))
        try journal.writeCommitted(layout)
        let engine = LayoutEngine(layout: layout, services: makeServices(mover: nil), journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan([TestItems.item("a"), TestItems.item("b"), TestItems.item("clock", isSystemOwned: true)])
        controller.toggleDemoMode()
        expectEqual(controller.snapshot.layout.zone(of: "a"), .hidden)
        expectEqual(controller.snapshot.layout.zone(of: "clock"), .visible)
        controller.flushForTermination()
        expectEqual(journal.readCommittedLayout(), layout, "即使演示时退出，永久分配也不应改变")
        controller.toggleDemoMode()
        expectEqual(controller.snapshot.layout, layout, "演示退出必须恢复分区及顺序")
    }

    func rejectedReassignmentDoesNotBecomeLogicalSuccess() throws {
        for error in [MenuBarMoveError.dragInterrupted, .abortedBySentinel(.userInteracting), .itemVanished("a")] {
            let reader = FakeMenuBarReader(ids: ["a"])
            let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a"]]),
                                      services: makeServices(reader: reader, mover: RejectingMover(error)),
                                      journal: LayoutJournal(directory: TestPaths.journalDirectory("rejected-reassign")))
            let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                              settings: AppSettings(), store: FakeSettingsStore())
            controller.applyScan(reader.items)
            engine.targetProvider = { _, _ in 700 }
            expect(!controller.reassignZone("a", to: .hidden), "拒绝原因不能被缺落点回退掩盖：\(error)")
            expectEqual(engine.layout.zone(of: "a"), .visible)
        }
    }

    func queuedReassignmentDoesNotUseTheSynchronousDragPath() throws {
        let reader = FakeMenuBarReader(ids: ["a", "b"])
        let mover = RejectingMover(.targetNotInteractable)
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("queued-reassignment"))
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a", "b"]]),
                                  services: makeServices(reader: reader, mover: mover), journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan(reader.items)
        var preparations = 0, requests = 0
        controller.onBeginLayoutAdjustment = { preparations += 1; return reader.items }
        controller.onRequestPhysicalArrangement = { _ in requests += 1 }
        engine.targetProvider = { _, _ in 700 }
        expect(controller.reassignZone("a", to: .hidden), "已装配的异步整理入口必须接受保存成功的分区")
        expectEqual(journal.readCommittedLayout()?.zone(of: "a"), .hidden)
        expectEqual(mover.calls, 0, "不能在菜单动作栈里同步拖动")
        expectEqual(preparations, 0, "同步展开/重读也应交给后台整理的准备阶段")
        expectEqual(requests, 1)
    }

    func queuedUserChoiceDoesNotCommitAnotherPendingMove() throws {
        let directory = TestPaths.journalDirectory("queued-supersede")
        let journal = LayoutJournal(directory: directory)
        let committed = MenuBarLayout(zones: ["visible": ["a", "b", "c"]])
        try journal.writeCommitted(committed)
        let pending = LayoutJournal.LayoutIntent(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                                  previousZone: .visible, previousPosition: 0)
        try journal.writeIntent(pending)
        let reader = FakeMenuBarReader(ids: ["a", "b", "c"])
        let mover = RejectingMover(.targetNotInteractable)
        let engine = LayoutEngine(layout: committed, services: makeServices(reader: reader, mover: mover), journal: journal)
        _ = engine.recoverOnLaunch()
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan(reader.items)
        var requests = 0
        controller.onRequestPhysicalArrangement = { _ in requests += 1 }
        expect(controller.reassignZone("b", to: .hidden))
        expectEqual(engine.layout.items(in: .visible), ["a", "c"], "旧 pending 的 a 不能随 b 的新决定被提交")
        expectEqual(engine.layout.items(in: .hidden), ["b"])
        expectEqual(journal.readCommittedLayout(), engine.layout)
        expect(!journal.hasPendingIntent)
        expectEqual(requests, 1)
        expectEqual(mover.calls, 0)
    }

    func queuedSaveFailureKeepsThePreviousRecoveryState() throws {
        let directory = TestPaths.journalDirectory("queued-save-failure")
        let journal = LayoutJournal(directory: directory)
        let committed = MenuBarLayout(zones: ["visible": ["a", "b"]])
        try journal.writeCommitted(committed)
        let pending = LayoutJournal.LayoutIntent(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                                  previousZone: .visible, previousPosition: 0)
        try journal.writeIntent(pending)
        let reader = FakeMenuBarReader(ids: ["a", "b"])
        let mover = RejectingMover(.targetNotInteractable)
        let engine = LayoutEngine(layout: committed, services: makeServices(reader: reader, mover: mover), journal: journal)
        _ = engine.recoverOnLaunch()
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.applyScan(reader.items)
        let previous = engine.layout
        let savedPending = journal.readPendingIntent()
        var requests = 0
        controller.onRequestPhysicalArrangement = { _ in requests += 1 }
        let commitURL = directory.appendingPathComponent("layout.committed.json")
        try FileManager.default.removeItem(at: commitURL)
        try FileManager.default.createDirectory(at: commitURL, withIntermediateDirectories: false)
        expect(!controller.reassignZone("b", to: .hidden))
        expectEqual(engine.layout, previous)
        expectEqual(journal.readPendingIntent(), savedPending)
        expectEqual(requests, 0, "保存失败不能排队实际移动")
        expectEqual(mover.calls, 0)
        expect(controller.physicalLayoutState.isFailure)
    }

    func handledPendingReceiptSurvivesAnotherLogicalSave() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("handled-pending-save"))
        let pending = LayoutJournal.LayoutIntent(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                                  previousZone: .visible, previousPosition: 0)
        let committed = MenuBarLayout(zones: ["visible": ["a", "c"], "hidden": ["b"]])
        try journal.writeIntent(pending)
        try journal.writeCommitted(committed, completing: pending) // 模拟新提交成功、旧标记尚未清理。
        let engine = LayoutEngine(layout: committed, services: makeServices(), journal: journal)
        try engine.recordZoneOnly(itemID: "c", zone: .alwaysHidden)
        expect(journal.hasCommitted(pending), "后续保存不能使已结束的旧意图复活")
        let expected = engine.layout
        let restarted = LayoutEngine(layout: MenuBarLayout(), services: makeServices(), journal: journal)
        expectEqual(restarted.recoverOnLaunch(), .clean(expected))
        expectEqual(restarted.layout.zone(of: "a"), .visible)
    }

    func queuedProfileSavesTheBatchAndReportsPhysicalFailure() throws {
        let reader = FakeMenuBarReader(ids: ["a", "b"])
        let mover = RejectingMover(.targetNotInteractable)
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("queued-profile"))
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a", "b"]]),
                                  services: makeServices(reader: reader, mover: mover), journal: journal)
        var settings = AppSettings()
        settings.profiles["reverse"] = MenuBarLayout(zones: ["visible": ["b", "a"]])
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(), settings: settings, store: FakeSettingsStore())
        controller.applyScan(reader.items)
        var requests: [Bool] = [], preparations = 0
        controller.onRequestPhysicalArrangement = { requests.append($0) }
        controller.onBeginLayoutAdjustment = { preparations += 1; return reader.items }
        expect(controller.applyProfile(named: "reverse"))
        expectEqual(journal.readCommittedLayout()?.items(in: .visible), ["b", "a"])
        expectEqual(requests, [true, true], "整批保存后由装配层合并调度，保留显式次序要求")
        expectEqual(mover.calls, 0)
        expectEqual(preparations, 0)
        controller.reportPhysicalLayout(.arranging)
        expect(controller.isPhysicalLayoutBusy)
        controller.reportPhysicalLayout(.failed("菜单栏整理未完成：目标暂不可操作"))
        expect(!controller.isPhysicalLayoutBusy)
        expectEqual(journal.readCommittedLayout()?.items(in: .visible), ["b", "a"], "物理失败仍保留用户期望")
        MainActor.assumeIsolated {
            let overview = IconOverviewView { _, _ in false }
            overview.reload(rows: IconOverviewBuilder.rows(from: controller))
            overview.physicalLayoutState = controller.physicalLayoutState
            let messages = formViews(overview).compactMap { ($0 as? NSTextField)?.stringValue }
            expect(messages.contains { $0.contains("菜单栏整理未完成") }, "物理失败须在图标整理页直接可见")
        }
    }

    private final class RejectingMover: MenuBarMoving {
        let error: MenuBarMoveError
        var calls = 0
        init(_ error: MenuBarMoveError) { self.error = error }
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            calls += 1
            throw error
        }
    }

    func fallbackStopsCallingUnsupportedMover() throws {
        let mover = RejectingMover(.unsupportedOS)
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a"]]),
                                  services: makeServices(reader: FakeMenuBarReader(ids: ["a"]), mover: mover),
                                  journal: LayoutJournal(directory: TestPaths.journalDirectory("fallback-guard")))
        expectThrows { try engine.apply(itemID: "a", to: .hidden, targetX: 700) }
        expectEqual(engine.capability, .panelOnlyFallback)
        try engine.apply(itemID: "a", to: .hidden, targetX: 700)
        expectEqual(mover.calls, 1, "降级后只能保存面板分配，不得继续请求真实移动")
        expectEqual(engine.layout.zone(of: "a"), .hidden)
    }

    private final class DisappearingMover: MenuBarMoving {
        let reader: FakeMenuBarReader
        init(reader: FakeMenuBarReader) { self.reader = reader }
        func move(itemID: String, toX x: CGFloat) throws -> CGPoint {
            reader.items = []
            return CGPoint(x: x, y: 1188)
        }
    }

    func unavailableMoveResultIsNotConfirmed() throws {
        let reader = FakeMenuBarReader(ids: ["a"])
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("unknown-move"))
        let engine = LayoutEngine(layout: MenuBarLayout(zones: ["visible": ["a"]]),
                                  services: makeServices(reader: reader, mover: DisappearingMover(reader: reader)),
                                  journal: journal, verificationWindow: 0)
        expectThrows { try engine.apply(itemID: "a", to: .hidden, targetX: 700) }
        expect(!engine.hasConfirmedDragSupport, "无法读取结果不等于已确认成功")
        expectEqual(engine.layout.zone(of: "a"), .visible)
        expectNil(journal.readCommittedLayout(), "未知结果不能写成成功提交")
    }

    func startupWaitsForScanBeforeSpendingReplayAttempts() throws {
        let journal = LayoutJournal(directory: TestPaths.journalDirectory("deferred-recovery"))
        let reader = FakeMenuBarReader(items: [TestItems.item("a"), TestItems.item("b", centerX: 640)])
        let mover = FakeMenuBarMover()
        mover.coupledReader = reader
        try journal.writeCommitted(MenuBarLayout(zones: ["visible": ["a"], "hidden": ["b"]]))
        try journal.writeIntent(.init(itemID: "a", targetZone: .hidden, targetPosition: nil,
                                      previousZone: .visible, previousPosition: 0))
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(reader: reader, mover: mover),
                                  journal: journal)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(), store: FakeSettingsStore())
        controller.start(scansSynchronously: false)
        controller.start(scansSynchronously: false)
        expectEqual(journal.readPendingIntent()?.replayFailures, 0, "依赖未就绪不是重放失败")
        expect(mover.moved.isEmpty)
        controller.applyScan(reader.items)
        expectEqual(mover.moved.count, 1, "有效扫描给出落点后才执行重放")
        expect(!journal.hasPendingIntent)
        expectEqual(journal.readCommittedLayout()?.zone(of: "a"), .hidden)
    }

    func conflictingIdentityClaimsAreAllRejected() throws {
        let owner = "com.review.multi"
        let records = ["Sync", "Sync Status"].enumerated().map { index, title in
            IdentityRecord(assignmentKey: "assignment-\(index)", ownerBundleID: owner,
                           observedTitle: title, observedOrdinal: index, ownerItemCount: 2,
                           aliases: [ManagedItem.stableID(ownerBundleID: owner, title: title)],
                           zoneRaw: index == 0 ? "visible" : "hidden", pinnedBy: .user, lastSeenAt: Date())
        }
        let title = "Sync Status connected"
        let item = ManagedItem(id: ManagedItem.stableID(ownerBundleID: owner, title: title),
                               ownerBundleID: owner, title: title,
                               frame: CGRect(x: 600, y: 1188, width: 24, height: 24), ownerItemCount: 1)
        for ordered in [records, records.reversed().map { $0 }] {
            let result = IdentityLedger.resolve(records: ordered, observed: [item],
                                                staleIDs: Set(records.map(\.currentID)))
            expect(result.renames.isEmpty, "不能用记录顺序决定继承哪个用户分区")
            expectEqual(result.ambiguousOwners, [owner])
        }
        let oldCountChanged = records.map { entry -> IdentityRecord in
            var copy = entry; copy.ownerItemCount = 3; return copy
        }
        let observed = ["Sync Status connected", "Sync paused"].enumerated().map { index, title in
            ManagedItem(id: ManagedItem.stableID(ownerBundleID: owner, title: title),
                        ownerBundleID: owner, title: title, frame: item.frame,
                        ordinalInOwner: index, ownerItemCount: 2)
        }
        let ambiguous = IdentityLedger.resolve(records: oldCountChanged, observed: observed,
                                                staleIDs: Set(records.map(\.currentID)))
        expect(ambiguous.renames.isEmpty, "多候选旧记录也必须参与反向冲突检查")
    }

    func userAssignmentSurvivesAbsenceAndRestart() throws {
        let directory = TestPaths.journalDirectory("assignment-lifecycle")
        let ledger = IdentityLedgerStore(url: directory.appendingPathComponent("identity.json"))
        let journal = LayoutJournal(directory: directory)
        let item = TestItems.item("com.test.app.icon")
        let engine = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                  journal: journal, ledger: ledger)
        let controller = TidyBarController(engine: engine, reveal: RevealStateMachine(),
                                          settings: AppSettings(newItemZone: .visible), store: FakeSettingsStore())
        controller.applyScan([item])
        expect(controller.move(item.id, to: .hidden))
        controller.applyScan([])
        controller.applyScan([item])
        expectEqual(engine.layout.zone(of: item.id), .hidden, "所属 App 重开不能丢用户分区")

        let restarted = LayoutEngine(layout: MenuBarLayout(), services: makeServices(mover: nil),
                                     journal: journal, ledger: ledger)
        let renamed = ManagedItem(id: "com.test.app.icon-new", ownerBundleID: item.ownerBundleID,
                                  title: item.title + " new", frame: item.frame)
        restarted.fold(items: [], newItemZone: .visible)
        restarted.fold(items: [renamed], newItemZone: .visible)
        expectEqual(restarted.layout.zone(of: renamed.id), .hidden, "空首帧之后仍应恢复改名项")
        expectEqual(ledger.load().count, 1, "改名应更新原分配，不能新增一条失去用户标记的记录")
        expectEqual(ledger.load().first?.pinnedBy, .user)
        restarted.fold(items: [item], newItemZone: .visible)
        try restarted.apply(itemID: item.id, to: .alwaysHidden, targetX: nil)
        restarted.fold(items: [], newItemZone: .visible)
        restarted.fold(items: [item], newItemZone: .visible)
        expectEqual(restarted.layout.zone(of: item.id), .alwaysHidden, "标题往返后仍要保存当前 ID 的新分配")
    }

    func failedCommitKeepsRecoveryIntent() throws {
        let directory = TestPaths.journalDirectory("failed-commit")
        let journal = LayoutJournal(directory: directory)
        let engine = LayoutEngine(
            layout: MenuBarLayout(zones: ["visible": ["a"]]),
            services: makeServices(mover: nil), journal: journal
        )
        // 文件目标被目录占据，确定性模拟提交写入失败。
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("layout.committed.json"),
            withIntermediateDirectories: true
        )
        expectThrows { try engine.apply(itemID: "a", to: .hidden, targetX: nil) }
        expect(journal.hasPendingIntent, "保存失败必须保留恢复依据")
        expectEqual(engine.layout.zone(of: "a"), .visible, "保存失败不能对外发布新分区")
    }
}

extension ReviewRegressionTests {
    static var testCases: [TestCase] {
        let suite = ReviewRegressionTests()
        return [
            TestCase("manualClassificationUsesToggleAsVisibleBoundary", suite.manualClassificationUsesToggleAsVisibleBoundary),
            TestCase("confirmedRenameKeepsCommittedOrderAcrossRestart", suite.confirmedRenameKeepsCommittedOrderAcrossRestart),
            TestCase("ownerFallbackDoesNotOverrideAnotherLedgerAssignment", suite.ownerFallbackDoesNotOverrideAnotherLedgerAssignment),
            TestCase("passiveScansDoNotOverwriteCommittedLayoutOnExit", suite.passiveScansDoNotOverwriteCommittedLayoutOnExit),
            TestCase("invalidatedScanCannotOverwriteManualChanges", suite.invalidatedScanCannotOverwriteManualChanges),
            TestCase("syntheticMouseEventsCannotChangePresentation", suite.syntheticMouseEventsCannotChangePresentation),
            TestCase("failedRecoveryCannotBeReplacedByAutomaticChanges", suite.failedRecoveryCannotBeReplacedByAutomaticChanges),
            TestCase("reassignmentWithoutPositionKeepsExistingOrder", suite.reassignmentWithoutPositionKeepsExistingOrder),
            TestCase("profilesAndRulesExcludeProtectedControls", suite.profilesAndRulesExcludeProtectedControls),
            TestCase("failedCommitKeepsRecoveryIntent", suite.failedCommitKeepsRecoveryIntent),
            TestCase("userAssignmentSurvivesAbsenceAndRestart", suite.userAssignmentSurvivesAbsenceAndRestart),
            TestCase("conflictingIdentityClaimsAreAllRejected", suite.conflictingIdentityClaimsAreAllRejected),
            TestCase("startupWaitsForScanBeforeSpendingReplayAttempts", suite.startupWaitsForScanBeforeSpendingReplayAttempts),
            TestCase("unavailableMoveResultIsNotConfirmed", suite.unavailableMoveResultIsNotConfirmed),
            TestCase("fallbackStopsCallingUnsupportedMover", suite.fallbackStopsCallingUnsupportedMover),
            TestCase("rejectedReassignmentDoesNotBecomeLogicalSuccess", suite.rejectedReassignmentDoesNotBecomeLogicalSuccess),
            TestCase("queuedReassignmentDoesNotUseTheSynchronousDragPath", suite.queuedReassignmentDoesNotUseTheSynchronousDragPath),
            TestCase("queuedUserChoiceDoesNotCommitAnotherPendingMove", suite.queuedUserChoiceDoesNotCommitAnotherPendingMove),
            TestCase("queuedSaveFailureKeepsThePreviousRecoveryState", suite.queuedSaveFailureKeepsThePreviousRecoveryState),
            TestCase("handledPendingReceiptSurvivesAnotherLogicalSave", suite.handledPendingReceiptSurvivesAnotherLogicalSave),
            TestCase("queuedProfileSavesTheBatchAndReportsPhysicalFailure", suite.queuedProfileSavesTheBatchAndReportsPhysicalFailure),
            TestCase("demoModeRestoresLayoutWithoutPersistingTemporaryChoices", suite.demoModeRestoresLayoutWithoutPersistingTemporaryChoices),
            TestCase("autoHideSettingTakesEffectWithoutRestart", suite.autoHideSettingTakesEffectWithoutRestart),
            TestCase("completedRecoveryReceiptPreventsDuplicateReplay", suite.completedRecoveryReceiptPreventsDuplicateReplay),
            TestCase("newUserChoiceSupersedesDeferredRecovery", suite.newUserChoiceSupersedesDeferredRecovery),
            TestCase("deferredRecoveryFollowsConfirmedRename", suite.deferredRecoveryFollowsConfirmedRename),
            TestCase("disabledEmptyBarTriggerDoesNotReveal", suite.disabledEmptyBarTriggerDoesNotReveal),
            TestCase("emptyBarClickAndScrollDispatchCustomActions", suite.emptyBarClickAndScrollDispatchCustomActions),
            TestCase("emptyBarClickPredicateFiltersNonEmptyAreas", suite.emptyBarClickPredicateFiltersNonEmptyAreas),
            TestCase("applicationMenuGeometryEmptySpaceCalculations", suite.applicationMenuGeometryEmptySpaceCalculations),
            TestCase("drawerAndMenuBarShareAutoHidePolicy", suite.drawerAndMenuBarShareAutoHidePolicy),
            TestCase("ordinaryDrawerExcludesAlwaysHiddenItems", suite.ordinaryDrawerExcludesAlwaysHiddenItems),
            TestCase("pointerTriggersAreRestrictedToTheMenuBar", suite.pointerTriggersAreRestrictedToTheMenuBar),
            TestCase("unavailableWiFiStateIsNotTreatedAsDisconnected", suite.unavailableWiFiStateIsNotTreatedAsDisconnected),
            TestCase("targetlessRulesAreRejected", suite.targetlessRulesAreRejected),
            TestCase("profileRulesApplyOnceAndRespectItemPriority", suite.profileRulesApplyOnceAndRespectItemPriority),
            TestCase("profilePermutationCompletesInOneEvaluation", suite.profilePermutationCompletesInOneEvaluation),
            TestCase("ruleEditorKeepsSelectionAndUneditedActions", suite.ruleEditorKeepsSelectionAndUneditedActions),
            TestCase("consecutiveProfileMovesWaitForTheSafetyInterval", suite.consecutiveProfileMovesWaitForTheSafetyInterval),
            TestCase("userInputDuringCooldownStillAborts", suite.userInputDuringCooldownStillAborts),
            TestCase("abandonedRenamedRecoveryDoesNotReappearFromLedger", suite.abandonedRenamedRecoveryDoesNotReappearFromLedger),
            TestCase("twoDividersKeepIndependentZonesAndLegalLandingSlots", suite.twoDividersKeepIndependentZonesAndLegalLandingSlots),
            TestCase("overviewDoesNotReportRejectedMovesAsCompleted", suite.overviewDoesNotReportRejectedMovesAsCompleted),
        ]
    }
}
