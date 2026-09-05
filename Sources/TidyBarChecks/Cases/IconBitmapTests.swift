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
