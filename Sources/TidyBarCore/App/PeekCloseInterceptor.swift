import Foundation
import CoreGraphics
import AppKit

/// 拦截并消费浮现图标在展开状态下的二次物理点击，
/// 从而防止目标 App（尤其是采用 NSPopover / 自定义弹出面板的应用）
/// 因 transient 瞬态关闭与 mouseUp 重新弹开产生闪烁。
public final class PeekCloseInterceptor {
    private var machPort: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isEnabled = false
    private var hitTest: ((CGPoint) -> Bool)?
    private var isStillOpen: (() -> Bool)?
    private var onClose: (() -> Void)?
    private var shouldConsumeMouseUp = false
    private var checkTimer: Timer?

    public init() {
        setupEventTap()
    }

    deinit {
        disable(force: true)
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let machPort {
            CFMachPortInvalidate(machPort)
        }
    }

    private func setupEventTap() {
        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let interceptor = Unmanaged<PeekCloseInterceptor>.fromOpaque(refcon).takeUnretainedValue()
            if type == .tapDisabledByTimeout, let port = interceptor.machPort {
                CGEvent.tapEnable(tap: port, enable: true)
                return Unmanaged.passRetained(event)
            }
            return interceptor.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            fprint("PeekCloseInterceptor: CGEvent.tapCreate 失败（可能缺少辅助功能权限）")
            return
        }
        machPort = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: false)
    }

    /// 启用拦截：当目标菜单已展开时调用
    public func enable(
        hitTest: @escaping (CGPoint) -> Bool,
        isStillOpen: @escaping () -> Bool,
        onClose: @escaping () -> Void
    ) {
        if machPort == nil {
            setupEventTap()
        }
        guard let machPort else { return }
        self.hitTest = hitTest
        self.isStillOpen = isStillOpen
        self.onClose = onClose
        self.shouldConsumeMouseUp = false
        self.isEnabled = true
        CGEvent.tapEnable(tap: machPort, enable: true)

        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            if self.isStillOpen?() == false {
                self.disable(force: true)
            }
        }
    }

    public func disable(force: Bool = false) {
        if !force && shouldConsumeMouseUp {
            return
        }
        checkTimer?.invalidate()
        checkTimer = nil
        guard isEnabled, let machPort else { return }
        isEnabled = false
        hitTest = nil
        isStillOpen = nil
        onClose = nil
        shouldConsumeMouseUp = false
        CGEvent.tapEnable(tap: machPort, enable: false)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isEnabled else { return Unmanaged.passRetained(event) }

        // 如果紧跟在被拦截的 mouseDown 之后的 mouseUp，必须同样吞掉，避免目标按钮触发 action
        if type == .leftMouseUp && shouldConsumeMouseUp {
            shouldConsumeMouseUp = false
            fprint("PeekCloseInterceptor: 拦截并消费二次点击 leftMouseUp")
            disable(force: true)
            return nil
        }

        if type == .leftMouseDown {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 1080
            // 转换为 AppKit 坐标系（y 轴向上）
            let appKitPoint = CGPoint(x: event.location.x, y: primaryHeight - event.location.y)
            let isHit = hitTest?(appKitPoint) ?? false

            if isHit {
                fprint("PeekCloseInterceptor: 命中浮现条目，拦截并消费物理 leftMouseDown, location=\(event.location), appKitPoint=\(appKitPoint)")
                shouldConsumeMouseUp = true
                // 启动 0.5s 兜底定时器，防止 mouseUp 丢失导致一直处于拦截状态
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    guard let self, self.shouldConsumeMouseUp else { return }
                    self.disable(force: true)
                }
                let closeAction = self.onClose
                // 立即触发收起逻辑
                DispatchQueue.main.async {
                    closeAction?()
                }
                return nil
            } else {
                // 点击了外部区域，稍后检查菜单是否已经因失去焦点而关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    guard let self, self.isEnabled else { return }
                    if self.isStillOpen?() == false {
                        self.disable(force: true)
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }
}
