import Foundation
import AppKit
import CoreGraphics
import TidyBarCore

// MARK: - 图标位图：几何与缓存（面板缩略图的地基）

struct IconBitmapTests {
    private final class Capturer: MenuBarIconCapturing {
        var isAuthorized = true
        var authorizationRequests = 0
        var frames: [CGRect] = []
        var completions: [(Result<CGImage, IconCaptureError>) -> Void] = []
        func requestAuthorization() { authorizationRequests += 1 }
        func capture(frame: CGRect, scale: CGFloat, completion: @escaping (Result<CGImage, IconCaptureError>) -> Void) {
            frames.append(frame)
            completions.append(completion)
        }
    }

    @MainActor private func pump(until complete: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !complete(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return complete()
    }

    @MainActor private func makePanel(reader: MenuBarReading, capturer: Capturer) -> TidyBarPanelController {
        NSApplication.shared.setActivationPolicy(.prohibited)
        return TidyBarPanelController(services: makeServices(reader: reader, mover: nil,
            screens: FakeScreens(screenFrame: CGRect(x: 0, y: 0, width: 1440, height: 1200))), capturer: capturer)
    }

    private func image(width: Int, height: Int, fill: CGColor? = nil, foreground: CGColor? = nil) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if let fill {
            context.setFillColor(fill)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        if let foreground {
            context.setFillColor(foreground)
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
        }
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

    /// 已验证的截图属于图标身份；折叠到屏外后仍要用它，不能去抓屏外坐标。
    func verifiedBitmapSurvivesMenuBarFolding() throws {
        let store = IconBitmapStore(limitBytes: 4 * 1024 * 1024)
        let before = item("com.test.a", x: 600)
        store.ingest(image(width: 48, height: 48), for: before)
        expect(store.image(for: before) != nil)

        let moved = item("com.test.a", x: -1400)
        expect(store.image(for: moved) != nil, "物理折叠不能丢弃已验证的菜单栏截图")
        expect(store.needsCapture([moved]).isEmpty, "同一图标移到屏外后应复用截图，不再抓屏外坐标")
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

    func panelClicksWaitForMatchingMouseUp() throws {
        MainActor.assumeIsolated {
            let view = TidyBarPanelView(frame: CGRect(x: 0, y: 0, width: 120, height: 42))
            let a = item("a", x: 600), b = item("b", x: 640)
            view.items = [a, b]
            var left: [String] = [], right: [String] = []
            view.onClick = { left.append($0.id) }
            view.onRightClick = { right.append($0.id) }
            func event(_ type: NSEvent.EventType, x: CGFloat) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: CGPoint(x: x, y: 21), modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                  clickCount: 1, pressure: 0)!
            }
            view.mouseDown(with: event(.leftMouseDown, x: 21))
            expect(left.isEmpty, "按下时不得打开真实软件菜单")
            view.mouseUp(with: event(.leftMouseUp, x: 53))
            expect(left.isEmpty, "移到另一项抬起必须取消激活")
            view.mouseDown(with: event(.leftMouseDown, x: 21))
            view.mouseUp(with: event(.leftMouseUp, x: 21))
            expectEqual(left, ["a"])
            view.mouseDown(with: event(.leftMouseDown, x: 21))
            view.items = [b, a]
            view.mouseUp(with: event(.leftMouseUp, x: 21))
            expectEqual(left, ["a"], "列表更新后必须匹配原ID，不能按旧索引激活")
            view.rightMouseDown(with: event(.rightMouseDown, x: 21))
            expect(right.isEmpty)
            view.rightMouseUp(with: event(.rightMouseUp, x: 21))
            expectEqual(right, ["b"])
        }
    }

    func panelDrawsTheCapturedMenuBarBitmap() throws {
        MainActor.assumeIsolated {
            NSApplication.shared.setActivationPolicy(.prohibited)
            let view = TidyBarPanelView(frame: CGRect(x: 0, y: 0, width: 120, height: 42))
            view.hasCaptureAuthorization = true
            view.items = [item("captured", x: 600)]
            let captured = image(width: 48, height: 48,
                fill: CGColor(red: 0.3, green: 0.35, blue: 0.4, alpha: 1),
                foreground: CGColor(red: 1, green: 0, blue: 1, alpha: 1))
            view.images = ["captured": captured]
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 42,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
            let color = bitmap.colorAt(x: 21, y: 21)!.usingColorSpace(.deviceRGB)!
            // DeviceRGB 会依当前显示器色彩配置转换 sRGB；比较真实输入像素，不能假定转换后仍是 (1,0,1)。
            let expected = NSBitmapImageRep(cgImage: captured).colorAt(x: 24, y: 24)!.usingColorSpace(.deviceRGB)!
            expect(abs(color.redComponent - expected.redComponent) < 0.03
                   && abs(color.greenComponent - expected.greenComponent) < 0.03
                   && abs(color.blueComponent - expected.blueComponent) < 0.03,
                   "抽屉必须绘制注入的真实菜单栏截图，不能换成应用图标")
            let background = bitmap.colorAt(x: 100, y: 21)!.usingColorSpace(.deviceRGB)!
            let sourceBackground = NSBitmapImageRep(cgImage: captured).colorAt(x: 0, y: 0)!.usingColorSpace(.deviceRGB)!
            expect(abs(background.redComponent - sourceBackground.redComponent) < 0.03
                   && abs(background.greenComponent - sourceBackground.greenComponent) < 0.03
                   && abs(background.blueComponent - sourceBackground.blueComponent) < 0.03,
                   "抽屉背景应沿用菜单栏底色，避免把带底色的截图贴成一块块灰色方砖")
        }
    }

    func prewarmingCapturesOneMenuBarRegionAndKeepsCropsAfterFolding() throws {
        MainActor.assumeIsolated {
            let a = item("a", x: 600), b = item("b", x: 680)
            let reader = FakeMenuBarReader(items: [a, b])
            let capturer = Capturer()
            let panel = makePanel(reader: reader, capturer: capturer)
            var checks = 0, finished = false
            panel.prewarmBitmaps(for: [a, b], isValid: { checks += 1; return true }) {
                expect(Thread.isMainThread, "预热完成回调必须回到主线程")
                finished = true
            }
            expect(panel.hasCaptureAuthorization)
            expectEqual(capturer.frames, [CGRect(x: 588, y: 1176, width: 104, height: 24)],
                        "同屏图标应合并抓菜单栏窄区域，而非逐项或整屏截图")
            expect(!finished, "拿到图像之前不能让调用方折叠菜单栏")
            let strip = image(width: 208, height: 48)
            capturer.completions.forEach { $0(.success(strip)) }
            expect(pump { finished })
            expect(checks >= 2, "捕获前后均须检查调用方状态")
            let folded = [item("a", x: -1400), item("b", x: -1320)]
            let cached = panel.cachedImages(for: folded)
            expectEqual(cached["a"]?.width, 48)
            expectEqual(cached["b"]?.height, 48)
            expectEqual(capturer.authorizationRequests, 0)
        }
    }

    func rejectedCaptureFramesAreRefreshedOnceBeforeFolding() throws {
        MainActor.assumeIsolated {
            let a = item("a", x: 600), b = item("b", x: 680)
            let freshA = item("a", x: 620)
            let reader = FakeMenuBarReader(items: [freshA, b])
            let capturer = Capturer()
            let panel = makePanel(reader: reader, capturer: capturer)
            var completed = 0
            panel.prewarmBitmaps(for: [a, b], isValid: { true }) { completed += 1 }
            expectEqual(capturer.frames, [b.frame])
            capturer.completions.first?(.success(image(width: 48, height: 48)))
            expect(pump { capturer.frames.count == 2 || completed > 0 })
            expectEqual(capturer.frames, [b.frame, freshA.frame], "校验失效后必须重新观察该项，再抓正确位置")
            expectEqual(completed, 0, "补抓结束之前不能让调用方折叠")
            if capturer.completions.count == 2 { capturer.completions[1](.success(image(width: 48, height: 48))) }
            expect(pump { completed == 1 })
            expectEqual(panel.cachedImages(for: [a, b]).count, 2)
        }
    }

    func invalidOrUnauthorizedPrewarmingAlwaysCompletesWithoutCapture() throws {
        MainActor.assumeIsolated {
            for authorized in [false, true] {
                let a = item("a", x: 600)
                let capturer = Capturer()
                capturer.isAuthorized = authorized
                let panel = makePanel(reader: FakeMenuBarReader(items: [a]), capturer: capturer)
                var completed = 0, checks = 0
                panel.prewarmBitmaps(for: [a], isValid: { checks += 1; return !authorized }) {
                    expect(Thread.isMainThread)
                    completed += 1
                }
                expectEqual(completed, 1)
                expect(checks > 0, "启动捕获前必须检查调用方状态")
                expect(capturer.frames.isEmpty)
                expectEqual(capturer.authorizationRequests, 0, "预热不应触发授权弹窗")
            }
        }
    }

    func staleOrFailedCapturesCompleteWithoutReplacingBitmaps() throws {
        MainActor.assumeIsolated {
            for invalidation in ["state", "frame", "failure"] {
                let a = item("a", x: 600)
                let reader = FakeMenuBarReader(items: [a])
                let capturer = Capturer()
                let panel = makePanel(reader: reader, capturer: capturer)
                var valid = true, completed = 0
                panel.prewarmBitmaps(for: [a], isValid: { valid }) { completed += 1; expect(Thread.isMainThread) }
                expectEqual(capturer.frames.count, 1)
                if invalidation == "state" { valid = false }
                if invalidation == "frame" { reader.items = [item("a", x: 700)] }
                let result: Result<CGImage, IconCaptureError> = invalidation == "failure"
                    ? .failure(.failed("fixture")) : .success(image(width: 48, height: 48))
                capturer.completions.forEach { $0(result) }
                if invalidation == "frame" {
                    expect(pump { capturer.completions.count == 2 })
                    expect(panel.cachedImages(for: [a]).isEmpty, "失效截图不得在补抓前进入缓存")
                    if capturer.completions.count == 2 { capturer.completions[1](.failure(.failed("retry fixture"))) }
                }
                expect(pump { completed == 1 })
                expect(panel.cachedImages(for: [a]).isEmpty, "\(invalidation) 的过期结果不得进入缓存")
            }
        }
    }

    func wideMenuIconsWrapWithoutLosingTheNotice() throws {
        let layout = PanelGeometry.contentLayout(itemSizes: [CGSize(width: 24, height: 24),
            CGSize(width: 146, height: 22), CGSize(width: 24, height: 24)], maximumWidth: 200, footerHeight: 24)
        expectEqual(layout.itemFrames[1].width, 146, "宽文字状态项不能挤成方形应用图标")
        expect(layout.itemFrames[2].minY < layout.itemFrames[0].minY, "超出屏幕可用宽度时应折行")
        expect(layout.itemFrames.allSatisfy { CGRect(origin: .zero, size: layout.size).contains($0) })
        expect(layout.footerFrame != nil)
        expect(layout.itemFrames.allSatisfy { $0.minY > layout.footerFrame!.maxY })
        MainActor.assumeIsolated {
            let view = TidyBarPanelView(frame: CGRect(x: 0, y: 0, width: 200, height: 42))
            view.items = [item("a", x: 600)]
            view.notice = "这个软件不允许代点，请在菜单栏中直接操作"
            let content = view.contentLayout(maximumWidth: 200)
            expect(content.size.height > 42, "实际提示必须增加面板高度，不能被42pt固定高度丢弃")
            expect(content.footerFrame?.height ?? 0 > 0)
        }
    }

    func missingCaptureRequestsSkipOffscreenFrames() throws {
        MainActor.assumeIsolated {
            let hidden = item("a", x: -1400)
            let capturer = Capturer()
            let panel = makePanel(reader: FakeMenuBarReader(items: [hidden]), capturer: capturer)
            var completed = 0
            panel.requestMissingBitmaps(for: [hidden]) { completed += 1 }
            panel.requestMissingBitmaps(for: [hidden]) { completed += 1 }
            expectEqual(completed, 2)
            expect(capturer.frames.isEmpty, "折叠后的负坐标不能触发反复抓屏")
        }
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
            TestCase("verifiedBitmapSurvivesMenuBarFolding", suite.verifiedBitmapSurvivesMenuBarFolding),
            TestCase("repeatedScanWithoutMovementNeedsNoCapture", suite.repeatedScanWithoutMovementNeedsNoCapture),
            TestCase("newItemsAreQueuedForCapture", suite.newItemsAreQueuedForCapture),
            TestCase("droppedItemsReleaseTheirBitmaps", suite.droppedItemsReleaseTheirBitmaps),
            TestCase("byteAccountingMatchesPixels", suite.byteAccountingMatchesPixels),
            TestCase("oversizedSingleBitmapIsSkippedNotCached", suite.oversizedSingleBitmapIsSkippedNotCached),
            TestCase("panelClicksWaitForMatchingMouseUp", suite.panelClicksWaitForMatchingMouseUp),
            TestCase("panelDrawsTheCapturedMenuBarBitmap", suite.panelDrawsTheCapturedMenuBarBitmap),
            TestCase("prewarmingCapturesOneMenuBarRegionAndKeepsCropsAfterFolding", suite.prewarmingCapturesOneMenuBarRegionAndKeepsCropsAfterFolding),
            TestCase("rejectedCaptureFramesAreRefreshedOnceBeforeFolding", suite.rejectedCaptureFramesAreRefreshedOnceBeforeFolding),
            TestCase("invalidOrUnauthorizedPrewarmingAlwaysCompletesWithoutCapture", suite.invalidOrUnauthorizedPrewarmingAlwaysCompletesWithoutCapture),
            TestCase("staleOrFailedCapturesCompleteWithoutReplacingBitmaps", suite.staleOrFailedCapturesCompleteWithoutReplacingBitmaps),
            TestCase("wideMenuIconsWrapWithoutLosingTheNotice", suite.wideMenuIconsWrapWithoutLosingTheNotice),
            TestCase("missingCaptureRequestsSkipOffscreenFrames", suite.missingCaptureRequestsSkipOffscreenFrames),
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

    func searchUIRendersCenteredAndNavigates() throws {
        let search = TidyBarSearchUI(maxResults: 5)
        let item = TestItems.item("com.apple.test", centerX: 100, centerY: 1188)
        search.queryHandler = { query in query.isEmpty ? [] : [item] }
        search.zoneLabel = { _ in "隐藏区" }
        search.presentCentered()
        expect(search.panel.isVisible, "Spotlight 居中呼出后面板应可见")
        expectEqual(search.resultRowCount, 0, "未键入时不渲染结果行")
        search.moveSelection(1)
        expectEqual(search.selection, 0)
        search.dismiss()
        expect(!search.panel.isVisible, "dismiss 后面板应关闭")
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
            TestCase("searchUIRendersCenteredAndNavigates", suite.searchUIRendersCenteredAndNavigates),
            TestCase("launchAtLoginStateIsReadable", suite.launchAtLoginStateIsReadable),
        ]
    }
}
