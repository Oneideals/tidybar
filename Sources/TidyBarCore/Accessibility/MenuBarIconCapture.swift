import AppKit
import CoreGraphics
import ScreenCaptureKit

/// 图标位图：面板/搜索里要显示真实缩略图，只有一条路——把那块屏幕区域抓下来。
/// macOS 14+ 的正规 API 是 ScreenCaptureKit，代价是**屏幕录制授权**（多一个系统弹窗）。
///
/// 拿不到授权时返回 `.notAuthorized`，面板明确显示占位与权限提示。
public enum IconCaptureError: Error, Equatable, Sendable {
    /// 用户还没给屏幕录制权限（或明确拒绝）
    case notAuthorized
    /// 找不到包含该区域的屏幕（热插拔/睡眠唤醒的瞬间）
    case displayNotFound
    /// 系统抓图失败
    case failed(String)
}

public protocol MenuBarIconCapturing: AnyObject {
    /// 是否已具备抓图权限。只读，不弹窗。
    var isAuthorized: Bool { get }
    /// 请求权限（会弹系统框）。只在用户主动要缩略图时调，不在启动时偷袭。
    func requestAuthorization()
    /// 抓取一块区域（AppKit 坐标，左下原点）。完成回调可能在任意线程。
    func capture(frame: CGRect, scale: CGFloat, completion: @escaping (Result<CGImage, IconCaptureError>) -> Void)
    func capture(frame: CGRect, scale: CGFloat, excludingWindowNumbers: [CGWindowID], completion: @escaping (Result<CGImage, IconCaptureError>) -> Void)
    func capture(items: [ManagedItem]) -> [String: CGImage]
}

public extension MenuBarIconCapturing {
    func capture(frame: CGRect, scale: CGFloat, completion: @escaping (Result<CGImage, IconCaptureError>) -> Void) {
        capture(frame: frame, scale: scale, excludingWindowNumbers: [], completion: completion)
    }

    func capture(frame: CGRect, scale: CGFloat, excludingWindowNumbers: [CGWindowID], completion: @escaping (Result<CGImage, IconCaptureError>) -> Void) {
        capture(frame: frame, scale: scale, completion: completion)
    }

    func capture(items: [ManagedItem]) -> [String: CGImage] {
        [:]
    }
}

/// 未接通时的占位：永远回答"没权限"，不得伪造位图
public final class UnverifiedMenuBarIconCapturer: MenuBarIconCapturing {
    public init() {}
    public var isAuthorized: Bool { false }
    public func requestAuthorization() {}
    public func capture(frame: CGRect, scale: CGFloat, excludingWindowNumbers: [CGWindowID] = [], completion: @escaping (Result<CGImage, IconCaptureError>) -> Void) {
        completion(.failure(.notAuthorized))
    }
}

/// 坐标换算（纯函数，离线可测）。
///
/// 项目内部统一用 AppKit 坐标（左下原点、y 向上），而抓图与 AX 都是左上原点 y 向下。
/// 这一步算错的表现是"缩略图对但整体上下翻转/偏移"，肉眼很容易当成截图 API 的锅。
public enum IconCaptureGeometry {
    public static func isVisibleMenuBarFrame(_ frame: CGRect, on screen: ScreenInfo) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.minX.isFinite && frame.minY.isFinite
            && frame.width.isFinite && frame.height.isFinite && screen.frame.contains(frame)
            && ScreenCoordinateSpace.isWithinMenuBar(frame, screen: screen)
    }
    /// AppKit 矩形 → 所属屏幕内的左上原点矩形（抓图用的 cropRect 是"屏幕内坐标"，不是全局坐标）
    public static func rectInScreen(_ frame: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: frame.minX - screenFrame.minX,
            y: screenFrame.height - (frame.maxY - screenFrame.minY),
            width: frame.width,
            height: frame.height
        )
    }

    /// 已有整屏位图时按同一套坐标裁出目标区域（生产路径走 cropRect 不整屏抓，这里留给测试
    /// 与"外部送来整屏图"的场景）。越界不裁而是返回 nil：半张图标比没有图标更让人困惑。
    /// 目标区域在整屏位图里的**像素矩形**。单列成纯函数是因为"串位"这个失败模式
    /// 只能靠断言坐标发现——拿到 CGImage 后就没法证明它裁对了。
    public static func pixelRect(
        frame: CGRect,
        screenFrame: CGRect,
        displayPixelSize: CGSize
    ) -> CGRect? {
        let local = rectInScreen(frame, screenFrame: screenFrame)
        let scaleX = displayPixelSize.width / max(1, screenFrame.width)
        let scaleY = displayPixelSize.height / max(1, screenFrame.height)
        let rect = CGRect(
            x: local.minX * scaleX,
            y: local.minY * scaleY,
            width: local.width * scaleX,
            height: local.height * scaleY
        ).integral
        guard rect.minX >= 0, rect.minY >= 0 else { return nil }
        guard rect.maxX <= displayPixelSize.width, rect.maxY <= displayPixelSize.height else { return nil }
        return rect
    }

    public static func crop(from image: CGImage, frame: CGRect, screenFrame: CGRect, displayPixelSize: CGSize) -> CGImage? {
        guard let rect = pixelRect(frame: frame, screenFrame: screenFrame, displayPixelSize: displayPixelSize) else {
            return nil
        }
        guard let cropped = image.cropping(to: rect),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height,
                  bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // 每个缓存项持有自己的像素，避免一张小裁图长期保留整条截图的底层存储。
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        return context.makeImage()
    }

    /// 缓存字节估算：宽高像素 × 每像素字节。留一份"为什么要按像素而不是按点算"的说明——
    /// 按点算会让 5K 屏上的缓存实际用量翻倍，预算就形同虚设。
    public static func estimatedBytes(widthPixels: Int, heightPixels: Int, bytesPerPixel: Int = 4) -> Int {
        max(0, widthPixels) * max(0, heightPixels) * bytesPerPixel
    }
}

/// 真实抓图只使用菜单栏的 sourceRect。多图标由调用方按显示器合并区域后本地裁切。
public final class ScreenCaptureKitIconCapturer: MenuBarIconCapturing {
    public init() {}

    public var isAuthorized: Bool { CGPreflightScreenCaptureAccess() }

    public func requestAuthorization() {
        CGRequestScreenCaptureAccess()
    }

    /// 必须在**主线程**调用：`NSScreen` 不是线程安全的，而且它一旦被捕获进后台 Task，
    /// Swift 6 的并发检查会直接判错。所以这里一次性把需要的值读出来，Task 里只带值不带对象。
    public func capture(
        frame: CGRect,
        scale: CGFloat,
        excludingWindowNumbers: [CGWindowID] = [],
        completion: @escaping (Result<CGImage, IconCaptureError>) -> Void
    ) {
        precondition(Thread.isMainThread, "capture 必须在主线程调用（面板/搜索路径本来就是主线程）")
        guard isAuthorized else {
            completion(.failure(.notAuthorized))
            return
        }
        guard scale.isFinite, scale > 0,
              let screen = NSScreen.screens.first(where: {
                  guard let info = ScreenInfo(from: $0) else { return false }
                  return IconCaptureGeometry.isVisibleMenuBarFrame(frame, on: info)
              }),
              let displayID = screen.displayID else {
            completion(.failure(.displayNotFound))
            return
        }
        let screenFrame = screen.frame
        Task { @Sendable in
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                    completion(.failure(.displayNotFound))
                    return
                }
                let local = IconCaptureGeometry.rectInScreen(frame, screenFrame: screenFrame)
                // 不设 scalingMode：实测它会把 cropRect 的语义一起缩放掉，抓出来位置偏一半
                // 用 cropRect 只抓目标那一小块。**不**走"抓整屏再本地裁"：整屏位图哪怕只是瞬时，
                // 也等于在我们进程里装下整个桌面（包含别人正打开的窗口内容），这个代价不该默认承担。
                let configuration = SCStreamConfiguration()
                configuration.width = max(1, Int(local.width * scale))
                configuration.height = max(1, Int(local.height * scale))
                configuration.sourceRect = local  // 本 SDK 里的裁剪框属性名（cropRect 不存在）
                configuration.showsCursor = false
                configuration.queueDepth = 1
                // 输出与裁剪框都用同一套"屏幕内左上原点"坐标，缩放比例交给 width/height 表达

                let excludedWindows = content.windows.filter { excludingWindowNumbers.contains($0.windowID) }
                let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                completion(.success(image))
            } catch {
                // 借鉴 Ice 架构设计：若 ScreenCaptureKit 异步服务异常，降级尝试 CGWindowListCreateImage 兜底
                let displayBounds = CGDisplayBounds(displayID)
                let cgRect = CGRect(x: frame.minX, y: displayBounds.height - frame.maxY, width: frame.width, height: frame.height)
                if let cgImage = CGWindowListCreateImage(cgRect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution, .boundsIgnoreFraming]) {
                    completion(.success(cgImage))
                    return
                }
                completion(.failure(.failed(String(describing: error))))
            }
        }
    }

    public func capture(items: [ManagedItem]) -> [String: CGImage] {
        WindowListIconCapturer.captureAll(items: items)
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}
