import Foundation
import AppKit
import ApplicationServices

// MARK: - 真实实现：光标 / 权限 / 屏幕（低风险，可立即使用）

/// 读取真实光标状态。EventSentinel 的输入源。
public final class AppKitCursorReader: CursorReading {
    public init() {}

    public var currentLocation: CGPoint {
        let point = CGEvent(source: nil)?.location ?? .zero
        return CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
    }

    public var isPrimaryButtonPressed: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .left)
    }

    public var isSecondaryButtonPressed: Bool {
        CGEventSource.buttonState(.combinedSessionState, button: .right)
    }

    public var userIdleTime: TimeInterval {
        [CGEventType.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? 0
    }

    public var isSessionInteractive: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session[kCGSessionOnConsoleKey as String] as? Bool == true
            && session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    public var displayConfiguration: [CGDirectDisplayID: CGRect]? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [:] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [:] }
        return Dictionary(uniqueKeysWithValues: displays.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) })
    }
}

/// 辅助功能权限。缺权限时上层走降级模式（报告 §4.4）。
public final class AppKitAccessibilityTrust: AccessibilityTrustReading {
    public init() {}

    public var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    public func requestTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// 屏幕与刘海信息。刘海检测用 auxiliaryTopLeft/RightArea：
/// 二者不同时为空即存在刘海，空隙宽度即刘海宽度。
public final class AppKitScreenObserver: ScreenObserving {
    private var observers: [@Sendable () -> Void] = []

    public init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    public var screens: [ScreenInfo] {
        NSScreen.screens.compactMap { ScreenInfo(from: $0) }
    }

    public var primaryScreen: ScreenInfo? {
        (NSScreen.main ?? NSScreen.screens.first).flatMap { ScreenInfo(from: $0) }
    }

    public func addObserver(_ observer: @escaping @Sendable () -> Void) {
        observers.append(observer)
    }

    @objc private func screenParametersChanged() {
        observers.forEach { $0() }
    }
}

extension ScreenInfo {
    /// 从 NSScreen 读取。菜单栏高度 = 全屏高度 - 可见高度 - 底部 Dock 占位。
    init?(from screen: NSScreen) {
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let displayID else { return nil }

        let fullFrame = screen.frame
        let visible = screen.visibleFrame

        // 非刘海屏上 auxiliaryTop*Area 为 nil；存在刘海时它们分别描述刘海左右两侧的顶部可用区，
        // 因此「整宽 - 左右可用宽」即刘海宽度。
        let notchWidth: CGFloat?
        if let leftArea = screen.auxiliaryTopLeftArea, let rightArea = screen.auxiliaryTopRightArea {
            let inferred = fullFrame.width - (leftArea.width + rightArea.width)
            notchWidth = inferred > 0 ? inferred : nil
        } else {
            notchWidth = nil
        }

        // 菜单栏占据屏幕顶部：整屏高度与可见区顶边之差（Dock 只影响底部/左右，无需扣除）
        let measuredMenuBarHeight = max(0, fullFrame.maxY - visible.maxY)

        self.init(
            identifier: CGDirectDisplayID(displayID),
            frame: fullFrame,
            menuBarHeight: measuredMenuBarHeight > 0 ? measuredMenuBarHeight : AppKitScreenConstants.fallbackMenuBarHeight,
            notchWidth: notchWidth,
            isBuiltin: Self.isBuiltinDisplay(displayID),
            // 抓图与缓存都按像素算。写死 2 在外接非 Retina 屏上会多要一倍的像素，
            // 在混合缩放的多屏上则会裁偏——缩放必须由这块屏自己报告。
            scaleFactor: Double(screen.backingScaleFactor)
        )
    }

    private static func isBuiltinDisplay(_ id: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(id) != 0
    }
}

private enum AppKitScreenConstants {
    /// 读取失败时的保守值：菜单栏按 24pt 预留，避免面板压住图标
    static let fallbackMenuBarHeight: CGFloat = 24
}

// MARK: - 占位实现：图标枚举 / ⌘ 拖拽（M0 待验证，见 docs/M0-技术验证清单.md）

/// ⚠️ 占位读取器。真实实现需经辅助功能 API 枚举菜单栏项，属于本品类最脆弱的一环，
/// 必须在 M0 里程碑于本机（macOS 26）实测通过后才接入，不在骨架里赌它可用。
public final class PlaceholderMenuBarReader: MenuBarReading {
    public init() {}
    public func discoverItems() -> [ManagedItem] { [] }
}

/// ⚠️ 占位移动器：一律上报「机制未验证」，驱动上层走收纳面板降级模式。
/// 真实实现 = 合成 ⌘ 拖拽事件 + 前后光标复核，须先通过 EventSentinel 预检。
/// 未接通时的点击转发占位。刻意"什么都不做但给出原因"，
/// 而不是静默成功——面板点了没反应又不说为什么，是这类工具最常见的差评来源。
public final class UnverifiedMenuBarActivator: MenuBarActivating {
    public init() {}
    @discardableResult
    public func activate(itemID: String) -> ActivationOutcome { .actionUnsupported }
}

public final class UnverifiedMenuBarMover: MenuBarMoving {
    public init() {}

    public func move(itemID: String, toX targetX: CGFloat) throws -> CGPoint {
        throw MenuBarMoveError.unsupportedOS
    }
}
