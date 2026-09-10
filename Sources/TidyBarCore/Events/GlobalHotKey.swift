import Carbon.HIToolbox
import Foundation

/// 全局快捷键（报告 A4 的第四种呼出方式）。
///
/// 为什么必须用 Carbon 而不是 `NSEvent.addGlobalMonitorForEvents`：
/// 全局监视器只能**观察**、吞不掉按键——用 ⌥Space 呼出面板的同时，
/// 那个空格还会打进用户正在输入的文本框。那不是快捷键，那是捣乱。
/// `RegisterEventHotKey` 会消费掉组合键，这才是品类通行且唯一正确的做法。
public final class GlobalHotKey {
    public struct Spec: Equatable, Sendable {
        public let keyCode: UInt32
        public let modifiers: UInt32     // Carbon modifier flags

        /// 默认 ⌥Space（报告 A8）
        public static let defaultReveal = Spec(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
    }

    public private(set) var isRegistered = false
    /// 注册失败的原因。失败时装配层必须把 `.hotkey` 从生效呼出集合里摘掉——
    /// 挂着"已支持"却不干活，比没有这个功能更糟。
    public private(set) var failureReason: String?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onPress: () -> Void

    /// Carbon 的 C 回调拿不到 self，只能经进程内登记表转一手。
    /// 全局长度 = 同时注册的热键数（本工具只有一个）。
    nonisolated(unsafe) private static var handlers: [UInt32: () -> Void] = [:]
    private static let lock = NSLock()

    public init(onPress: @escaping () -> Void) {
        self.onPress = onPress
    }

    deinit { unregister() }

    @discardableResult
    public func register(_ spec: Spec = .defaultReveal, id: UInt32 = 1) -> Bool {
        unregister()

        Self.lock.lock()
        Self.handlers[id] = onPress
        Self.lock.unlock()

        if handlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                         eventKind: UInt32(kEventHotKeyPressed))
            let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
                guard let event else { return noErr }
                var hkID = EventHotKeyID()
                guard GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &hkID) == noErr else {
                    return OSStatus(paramErr)
                }
                GlobalHotKey.lock.lock()
                let callback = GlobalHotKey.handlers[hkID.id]
                GlobalHotKey.lock.unlock()
                DispatchQueue.main.async { callback?() }
                return OSStatus(noErr)
            }, 1, &eventType, nil, &handlerRef)
            if installed != noErr {
                failureReason = "InstallEventHandler 返回 \(installed)"
                isRegistered = false
                return false
            }
        }

        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers,
                                        EventHotKeyID(signature: OSType(0x5442_4152) /* 'TBAR' */, id: id),
                                        GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            failureReason = "RegisterEventHotKey 返回 \(status)（多半是辅助功能/输入监控权限不足）"
            isRegistered = false
            return false
        }
        hotKeyRef = ref
        isRegistered = true
        failureReason = nil
        return true
    }

    public func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        // handlerRef 复用，不随反注册卸掉；登记表里的回调必须清，
        // 否则闭包会一直握着已废弃的装配对象。
        Self.lock.lock()
        Self.handlers[1] = nil
        Self.lock.unlock()
        isRegistered = false
    }
}
