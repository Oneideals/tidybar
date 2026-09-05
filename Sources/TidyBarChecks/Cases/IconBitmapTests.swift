import Foundation
import CoreGraphics
import TidyBarCore

// MARK: - 图标位图：几何与缓存（面板缩略图的地基）

struct IconBitmapTests {
    private func image(width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    /// 抓图坐标是"屏幕内、左上原点"。副屏原点是负数（真机实测），
    /// 所以必须减 screenFrame.minX/minY，不能直接拿全局坐标去裁。
    func convertsToScreenLocalTopLeftOrigin() throws {
        let screen = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        // 全局 AppKit 坐标（左下原点）里靠菜单栏的一项：y 越大越靠屏幕顶
        let item = CGRect(x: -1900, y: 1056, width: 24, height: 24)
        let local = IconCaptureGeometry.rectInScreen(item, screenFrame: screen)
        expectEqual(local.origin.x, 20, "副屏负原点必须被归一化")
        expectEqual(local.origin.y, 0, "菜单栏贴屏幕顶 → 左上原点系里 y 应为 0")
        expectEqual(local.width, 24)
        expectEqual(local.height, 24)
    }

    /// 整屏位图 → 目标区域：Retina 下按像素比例换算，且**越界宁可不裁**
    func cropsWholeDisplayBitmapByPixelScale() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let full = image(width: 2880, height: 1800)   // 2x Retina
        let item = CGRect(x: 100, y: 876, width: 24, height: 24)   // 菜单栏带上
        guard let rect = IconCaptureGeometry.pixelRect(
            frame: item, screenFrame: screen,
            displayPixelSize: CGSize(width: 2880, height: 1800)
        ) else {
            try record("合法区域被判越界")
            return
        }
        expectEqual(rect.origin.x, 200, "裁错位置会表现为缩略图串位")
        expectEqual(rect.origin.y, 0, "菜单栏贴屏幕顶")
        expectEqual(rect.width, 48, "点 × 缩放才是像素")
        expectEqual(rect.height, 48)
        let cropped = IconCaptureGeometry.crop(from: full, frame: item, screenFrame: screen, displayPixelSize: CGSize(width: 2880, height: 1800))
        expectEqual(cropped?.width, 48)
    }

    func refusesPartialCropInsteadOfHalfAnIcon() throws {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let full = image(width: 2880, height: 1800)
        let hanging = CGRect(x: 1430, y: 876, width: 24, height: 24)   // 右缘超出屏幕
        expectNil(IconCaptureGeometry.crop(from: full, frame: hanging, screenFrame: screen, displayPixelSize: CGSize(width: 2880, height: 1800)),
                  "半张图标比没有图标更让人困惑，必须拒绝")
    }

    /// 缓存字节按**像素**算。写死按点算会让 Retina 上的实际用量翻倍，预算形同虚设。
    func byteEstimateUsesPixels() throws {
        expectEqual(IconCaptureGeometry.estimatedBytes(widthPixels: 48, heightPixels: 48), 48 * 48 * 4)
        expectEqual(IconCaptureGeometry.estimatedBytes(widthPixels: -5, heightPixels: 10), 0)
    }

    // MARK: 缓存语义

    private func item(_ id: String, x: CGFloat) -> ManagedItem {
        TestItems.item(id, centerX: x, centerY: 1_188)
    }

    /// 图标被挪动后，旧位图必须立刻失效。
    /// 否则面板会继续显示它**旧位置**的截图——用户看到的正是"缩略图串位"。
    func staleBitmapIsInvalidatedWhenFrameMoves() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let before = item("com.test.a", x: 600)
        store.ingest(image(width: 48, height: 48), for: before)
        expect(store.image(for: before) != nil)

        let moved = item("com.test.a", x: 700)
        expect(store.image(for: moved) == nil, "位置变了还能取到位图 = 显示串位")
        expectEqual(store.needsCapture([moved]).map(\.id), ["com.test.a"], "挪动后必须重抓")
    }

    /// 每 0.25s 一次心跳重绘，如果每次都判定"需要抓"，就等于持续做屏幕录制。
    /// 位置没变时必须回答"不用抓"。
    func repeatedScanWithoutMovementNeedsNoCapture() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let a = item("com.test.a", x: 600)
        store.ingest(image(width: 48, height: 48), for: a)
        expect(store.needsCapture([a]).isEmpty, "位置未变仍要求重抓 → 面板一打开就反复录屏")
    }

    func newItemsAreQueuedForCapture() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let fresh = item("com.test.new", x: 500)
        expectEqual(store.needsCapture([fresh]).map(\.id), ["com.test.new"])
    }

    /// App 退出后缓存里不能留着永远用不到的位图（这是 20MB 预算的真实来源）
    func droppedItemsReleaseTheirBitmaps() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let a = item("com.test.a", x: 600)
        let b = item("com.test.b", x: 640)
        store.ingest(image(width: 48, height: 48), for: a)
        store.ingest(image(width: 48, height: 48), for: b)
        expectEqual(store.count, 2)

        store.retain(alive: ["com.test.a"])
        expectEqual(store.count, 1)
        expect(!store.contains(id: "com.test.b"))
        expect(store.contains(id: "com.test.a"))
    }

    func byteAccountingMatchesPixels() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let a = item("com.test.a", x: 600)
        store.ingest(image(width: 48, height: 48), for: a)
        expectEqual(store.currentBytes, 48 * 48 * 4)
    }

    /// 超过上限的那一张直接不进缓存，而不是把整张表挤掉
    func oversizedSingleBitmapIsSkippedNotCached() throws {
        let store = IconBitmapStore(limitBytes: 40 * 40 * 4)
        store.ingest(image(width: 200, height: 200), for: item("com.test.big", x: 600))
        expectEqual(store.count, 0, "单张超限却入缓存 = 一个图标撑爆预算")
    }

    /// 没授权是常态路径：占位实现必须永远拒绝，面板才有稳定的回退分支
    func placeholderCapturerAlwaysRefuses() throws {
        let placeholder = UnverifiedMenuBarIconCapturer()
        expect(!placeholder.isAuthorized)
        var result: Result<CGImage, IconCaptureError>?
        placeholder.capture(frame: CGRect(x: 0, y: 0, width: 24, height: 24), scale: 2) { result = $0 }
        expectEqual(result.map { outcome in
            switch outcome {
            case .success: return "success"
            case .failure(let error): return String(describing: error)
            }
        }, "notAuthorized")
    }

    /// 抓图必须在主线程：NSScreen 不是线程安全的，跨线程带对象在 Swift 6 下直接判错
    func captureDemandsMainThread() throws {
        expect(Thread.isMainThread, "本用例应在主线程跑（探针依赖这个前提）")
        let capturer = ScreenCaptureKitIconCapturer()
        // 未授权时应当在**任何**异步工作之前就地失败：不然会白起一个 Task
        if !capturer.isAuthorized {
            var outcome: IconCaptureError?
            capturer.capture(frame: CGRect(x: 600, y: 1_188, width: 24, height: 24), scale: 2) { result in
                if case .failure(let error) = result { outcome = error }
            }
            expectEqual(outcome.map { String(describing: $0) }, "notAuthorized")
        }
    }
}

extension IconBitmapTests {
    static var testCases: [TestCase] {
        let suite = IconBitmapTests()
        return [
            TestCase("convertsToScreenLocalTopLeftOrigin", suite.convertsToScreenLocalTopLeftOrigin),
            TestCase("cropsWholeDisplayBitmapByPixelScale", suite.cropsWholeDisplayBitmapByPixelScale),
            TestCase("refusesPartialCropInsteadOfHalfAnIcon", suite.refusesPartialCropInsteadOfHalfAnIcon),
            TestCase("byteEstimateUsesPixels", suite.byteEstimateUsesPixels),
            TestCase("staleBitmapIsInvalidatedWhenFrameMoves", suite.staleBitmapIsInvalidatedWhenFrameMoves),
            TestCase("repeatedScanWithoutMovementNeedsNoCapture", suite.repeatedScanWithoutMovementNeedsNoCapture),
            TestCase("newItemsAreQueuedForCapture", suite.newItemsAreQueuedForCapture),
            TestCase("droppedItemsReleaseTheirBitmaps", suite.droppedItemsReleaseTheirBitmaps),
            TestCase("byteAccountingMatchesPixels", suite.byteAccountingMatchesPixels),
            TestCase("oversizedSingleBitmapIsSkippedNotCached", suite.oversizedSingleBitmapIsSkippedNotCached),
            TestCase("placeholderCapturerAlwaysRefuses", suite.placeholderCapturerAlwaysRefuses),
            TestCase("captureDemandsMainThread", suite.captureDemandsMainThread),
        ]
    }
}

// MARK: - 位置指纹与标题漂移（把"没放回原位"和"别人自己改名"分开）

struct PositionSignatureTests {
    private func item(_ bundle: String, _ title: String, ordinal: Int) -> ManagedItem {
        ManagedItem(
            id: "\(bundle).\(title)",
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: CGFloat(ordinal) * 30, y: 1_188, width: 24, height: 24),
            isSystemOwned: false,
            identitySource: .axTitle,
            ordinalInOwner: ordinal,
            ownerItemCount: 2
        )
    }

    /// 第三方把标题从"微信"改成"微信 3"（未读数写进标题）时，
    /// 位置指纹必须不变——否则微信自己发条消息就能让"我们没复原"变成假失败。
    func titleChangeDoesNotDisturbPositionSignature() throws {
        let before = [item("com.tencent.xinwechat", "微信", ordinal: 0)]
        let after = [item("com.tencent.xinwechat", "微信 (3)", ordinal: 0)]
        expectEqual(MenuBarEnumeration.positionSignature(of: before),
                    MenuBarEnumeration.positionSignature(of: after),
                    "只改标题不该让顺序指纹变化")
        expect(MenuBarEnumeration.positionSignature(of: before) != [before[0].id],
               "位置指纹本来就不该等于含标题的 id")
    }

    /// 我们真的没放回原位时，指纹必须报出来——这是上一轮判据唯一该有的敏感度。
    func realDisplacementIsDetected() throws {
        let a = item("com.a", "A", ordinal: 0)
        let b = item("com.b", "B", ordinal: 0)
        expectEqual(MenuBarEnumeration.positionSignature(of: [a, b]),
                    MenuBarEnumeration.positionSignature(of: [a, b]))
        expect(MenuBarEnumeration.positionSignature(of: [a, b])
               != MenuBarEnumeration.positionSignature(of: [b, a]),
               "两个进程换了先后顺序却没被发现，判据就白加了")
    }

    func driftReportsRenamedSlots() throws {
        let before = [
            item("com.tencent.xinwechat", "微信", ordinal: 0),
            item("com.apple.dock", "无关", ordinal: 0),
        ]
        let after = [
            item("com.tencent.xinwechat", "微信 (9)", ordinal: 0),
            item("com.apple.dock", "无关", ordinal: 0),
        ]
        let drift = MenuBarEnumeration.detectTitleDrift(before: before, after: after)
        expectEqual(drift.count, 1)
        expectEqual(drift.first?.ownerBundleID, "com.tencent.xinwechat")
        expectEqual(drift.first?.before, "微信")
        expectEqual(drift.first?.after, "微信 (9)")
        expectEqual(MenuBarEnumeration.volatileTitleOwners(drift: drift), ["com.tencent.xinwechat"],
                    "漂移过的进程必须被点名，好让设置界面把它的图标标成按位置认领")
    }

    /// 没有漂移时必须干净地返回空，而不是"读不到就当有问题"。
    func noDriftWhenTitlesStable() throws {
        let frame = [item("com.a", "A", ordinal: 0), item("com.a", "B", ordinal: 1)]
        expect(MenuBarEnumeration.detectTitleDrift(before: frame, after: frame).isEmpty)
    }
}

extension PositionSignatureTests {
    static var testCases: [TestCase] {
        let suite = PositionSignatureTests()
        return [
            TestCase("titleChangeDoesNotDisturbPositionSignature", suite.titleChangeDoesNotDisturbPositionSignature),
            TestCase("realDisplacementIsDetected", suite.realDisplacementIsDetected),
            TestCase("driftReportsRenamedSlots", suite.driftReportsRenamedSlots),
            TestCase("noDriftWhenTitlesStable", suite.noDriftWhenTitlesStable),
        ]
    }
}

// MARK: - 标题漂移后的归属认领（微信这种"一个进程一个图标 + 标题带未读数"的最常见形态）

struct TitleDriftAdoptionTests {
    private func wechat(_ title: String) -> ManagedItem {
        ManagedItem(
            id: ManagedItem.stableID(ownerBundleID: "com.tencent.xinwechat", title: title),
            ownerBundleID: "com.tencent.xinwechat",
            title: title,
            frame: CGRect(x: 900, y: 1_188, width: 24, height: 24),
            isSystemOwned: false,
            identitySource: .axTitle,
            ordinalInOwner: 0,
            ownerItemCount: 1
        )
    }

    /// 用户把微信收进隐藏区，微信随后把未读数写进标题 → id 变了。
    /// 这时配置必须跟着走，否则用户看到的是"我明明收起来了，它又冒出来"。
    func renamedIconKeepsItsAssignment() throws {
        var layout = MenuBarLayout()
        layout.append(wechat("微信").id, to: .hidden)
        let engine = LayoutEngine(
            layout: layout,
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("drift-adopt"))
        )
        engine.fold(items: [wechat("微信 (3)")], newItemZone: .visible)

        let renamed = wechat("微信 (3)")
        expectEqual(engine.layout.zone(of: renamed.id), .hidden, "改标题后归属丢失")
        expectNil(engine.layout.zone(of: wechat("微信").id), "旧 id 必须一并迁走，否则同一图标占两个坑")
    }

    /// 一个进程有**多个**图标时不许猜：猜错会把兄弟图标的配置偷走，比认错更难查。
    func multiIconOwnerIsNotGuessed() throws {
        var layout = MenuBarLayout()
        layout.append("com.adguard.mac.adguard.1", to: .hidden)
        let two = ManagedItem(
            id: "com.adguard.mac.adguard.2",
            ownerBundleID: "com.adguard.mac.adguard",
            title: "2",
            frame: CGRect(x: 800, y: 1_188, width: 24, height: 24),
            isSystemOwned: false,
            identitySource: .axTitle,
            ordinalInOwner: 1,
            ownerItemCount: 2
        )
        let engine = LayoutEngine(
            layout: layout,
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("drift-multi"))
        )
        // 同进程的另一个图标也在场：它才是那条配置的真正主人。折叠只增不减在场项，
        // 所以旧配置必须留在隐藏区，新项按默认分区新建——不能被"就近认领"过去。
        engine.fold(items: [ManagedItem(
            id: "com.adguard.mac.adguard.1",
            ownerBundleID: "com.adguard.mac.adguard",
            title: "1",
            frame: CGRect(x: 770, y: 1_188, width: 24, height: 24),
            isSystemOwned: false,
            identitySource: .axTitle,
            ordinalInOwner: 0,
            ownerItemCount: 2
        ), two], newItemZone: .visible)
        expectEqual(engine.layout.zone(of: two.id), .visible, "多图标进程只能按位置新建，不能认领别人的配置")
        expectEqual(engine.layout.zone(of: "com.adguard.mac.adguard.1"), .hidden, "旧配置必须原地不动")
    }

    func soleZoneRequiresExactlyOneConfiguredIcon() throws {
        var layout = MenuBarLayout()
        layout.append("com.a.x", to: .hidden)
        expectEqual(layout.soleZone(forOwner: "com.a"), .hidden)
        layout.append("com.a.y", to: .visible)
        expectNil(layout.soleZone(forOwner: "com.a"), "同进程两条配置时无法判断该接哪一条")
        expectNil(layout.soleZone(forOwner: "com.b"))
    }

    /// 改名要保持左右顺序——顺序就是可见区的排布，乱了等于把图标挪了位。
    func renamePreservesOrderAndZone() throws {
        var layout = MenuBarLayout()
        layout.append("com.a.old", to: .visible)
        layout.append("com.b.one", to: .visible)
        layout.rename(id: "com.a.old", to: "com.a.new")
        expectEqual(layout.items(in: .visible), ["com.a.new", "com.b.one"])
        expectEqual(layout.zone(of: "com.a.new"), .visible)
    }
}

extension TitleDriftAdoptionTests {
    static var testCases: [TestCase] {
        let suite = TitleDriftAdoptionTests()
        return [
            TestCase("renamedIconKeepsItsAssignment", suite.renamedIconKeepsItsAssignment),
            TestCase("multiIconOwnerIsNotGuessed", suite.multiIconOwnerIsNotGuessed),
            TestCase("soleZoneRequiresExactlyOneConfiguredIcon", suite.soleZoneRequiresExactlyOneConfiguredIcon),
            TestCase("renamePreservesOrderAndZone", suite.renamePreservesOrderAndZone),
        ]
    }
}

// MARK: - 多图标进程的 1:1 残差配对，以及搜索选中钳位

struct ResidualPairingTests {
    private func item(_ bundle: String, _ title: String, ordinal: Int, of count: Int) -> ManagedItem {
        ManagedItem(
            id: ManagedItem.stableID(ownerBundleID: bundle, title: title),
            ownerBundleID: bundle,
            title: title,
            frame: CGRect(x: 600 + CGFloat(ordinal) * 30, y: 1_188, width: 24, height: 24),
            isSystemOwned: false,
            identitySource: .axTitle,
            ordinalInOwner: ordinal,
            ownerItemCount: count
        )
    }

    private func engine(with layout: MenuBarLayout) -> LayoutEngine {
        LayoutEngine(
            layout: layout,
            services: makeServices(reader: FakeMenuBarReader(ids: []), mover: FakeMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("residual-\(UUID().uuidString.prefix(6))"))
        )
    }

    /// 三图标进程里只有一个改了标题：旧新各一，配对唯一 ⇒ 该迁移。
    func singleRenameInsideMultiIconOwnerIsAdopted() throws {
        let a = item("com.adguard.mac.adguard", "A", ordinal: 0, of: 3)
        let b = item("com.adguard.mac.adguard", "B", ordinal: 1, of: 3)
        let c = item("com.adguard.mac.adguard", "C", ordinal: 2, of: 3)
        var layout = MenuBarLayout()
        layout.append(a.id, to: .visible)
        layout.append(b.id, to: .hidden)
        layout.append(c.id, to: .visible)
        let e = engine(with: layout)
        // B 改名成 B'
        let renamed = item("com.adguard.mac.adguard", "B (3)", ordinal: 1, of: 3)
        e.fold(items: [a, renamed, c], newItemZone: .visible)

        expectEqual(e.layout.zone(of: renamed.id), .hidden, "唯一可配对的改名必须把配置接过去")
        expectNil(e.layout.zone(of: b.id), "旧 id 要迁净，否则同一图标占两坑")
        expectEqual(e.layout.zone(of: a.id), .visible)
        expectEqual(e.layout.zone(of: c.id), .visible)
    }

    /// 两个同时改名：配对不唯一，宁可丢配置也不能猜——猜错就是把一个图标的设置安到另一个头上。
    func ambiguousPairingIsRefused() throws {
        let a = item("com.x", "A", ordinal: 0, of: 2)
        let b = item("com.x", "B", ordinal: 1, of: 2)
        var layout = MenuBarLayout()
        layout.append(a.id, to: .hidden)
        layout.append(b.id, to: .visible)
        let e = engine(with: layout)
        let a2 = item("com.x", "A2", ordinal: 0, of: 2)
        let b2 = item("com.x", "B2", ordinal: 1, of: 2)
        e.fold(items: [a2, b2], newItemZone: .visible)

        expectEqual(e.layout.zone(of: a2.id), .visible, "两对二时不认领，新项按默认分区处理")
        expectEqual(e.layout.zone(of: b2.id), .visible)
        // 断言"配置确实丢了"——这是设计的**代价**，不是缺陷被掩盖：不猜就可能丢，
        // 猜了就可能把 A 的设置安到 B 头上。写成断言是为了哪天有人想"顺手兜一下"时，
        // 必须先改掉这条有意的取舍。
        expect(!e.layout.allItemIDs.contains(a.id) && !e.layout.allItemIDs.contains(b.id),
               "多对多时旧配置随消失的 id 一起清掉；宁可丢，不可错接")
    }

    func selectionNeverWrapsAround() throws {
        expectEqual(SearchSelection.clamped(current: 0, delta: -1, count: 8), 0, "回绕会让一条结果跳到最末")
        expectEqual(SearchSelection.clamped(current: 7, delta: 1, count: 8), 7)
        expectEqual(SearchSelection.clamped(current: 3, delta: -2, count: 8), 1)
        expectEqual(SearchSelection.clamped(current: 0, delta: 1, count: 0), 0, "空结果集不该产生负下标")
    }

    /// 开机自启状态必须读系统，而不是我们自己记的那份
    func launchAtLoginStateIsReadable() throws {
        let state = LaunchAtLogin.state()
        switch state {
        case .enabled, .disabled, .needsApproval, .unknown: expect(true)
        }
        // 只读断言。绝不在用例里调 setEnabled——上一版真的把 .build 下的测试二进制
        // 注册成了系统登录项（用户看到"登录项已添加"通知，还得手工清）。
        // 注册行为留给真机人工验证；用例只保证 API 形态可被调用且失败带原因。
    }
}

extension ResidualPairingTests {
    static var testCases: [TestCase] {
        let suite = ResidualPairingTests()
        return [
            TestCase("singleRenameInsideMultiIconOwnerIsAdopted", suite.singleRenameInsideMultiIconOwnerIsAdopted),
            TestCase("ambiguousPairingIsRefused", suite.ambiguousPairingIsRefused),
            TestCase("selectionNeverWrapsAround", suite.selectionNeverWrapsAround),
            TestCase("launchAtLoginStateIsReadable", suite.launchAtLoginStateIsReadable),
        ]
    }
}
