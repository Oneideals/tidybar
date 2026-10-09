import Foundation
import AppKit

/// 在 macOS 27+ 上通过系统原生 MenuBarClientCore 私有框架管理菜单栏图标可见性。
/// 零特权、零越狱、完全本地且崩溃安全（进程退出或强杀后系统自动失效并恢复所有图标）。
public final class NativeMenuBarHider: @unchecked Sendable {
    public static let shared = NativeMenuBarHider()

    private let configClass: AnyObject?
    private let assertionClass: AnyObject?
    private var activeAssertion: AnyObject?
    private let lock = NSLock()

    public var isAvailable: Bool {
        guard configClass != nil && assertionClass != nil else { return false }
        // macOS 27 WindowServer 严格安全机制：MenuBarClientCore 的白名单机制强制要求 App 安装在 /Applications 目录下。
        // 若在开发构建目录直接运行，系统拒绝将其加入白名单，会导致 TidyBar 自身菜单项被系统屏蔽。
        return Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    private init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MenuBarClientCore.framework/MenuBarClientCore", RTLD_LAZY)
        if handle != nil {
            configClass = NSClassFromString("MBAssessmentModeConfiguration")
            assertionClass = NSClassFromString("MBAssessmentModeAssertion")
        } else {
            configClass = nil
            assertionClass = nil
        }
    }

    private var lastAllowedBundleIDs: Set<String>? = nil
    private var assertionGeneration: Int = 0

    /// 隐藏非白名单项。
    /// - Parameters:
    ///   - allowedBundleIDs: 允许在菜单栏保持可见的第三方应用 Bundle ID 集合
    ///   - allowedSystemItems: 允许保持可见的系统项 ID 集合（0...8 分别对应电池、蓝牙、时钟、显示器、键盘、音量、Wi-Fi、屏幕镜像、控制中心）
    public func hideItems(except allowedBundleIDs: Set<String>, allowedSystemItems: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
        lock.lock()
        defer { lock.unlock() }

        // 幂等保护：如果当前断言处于活跃状态且白名单未变更，直接保持，避免重复销毁重建立即造成图标闪烁或自动弹开
        if activeAssertion != nil && lastAllowedBundleIDs == allowedBundleIDs {
            return
        }

        guard let configClass = configClass as? NSObject.Type,
              let assertionClass = assertionClass as? NSObject.Type else { return }

        assertionGeneration += 1
        let thisGeneration = assertionGeneration
        let oldToInvalidate = activeAssertion
        lastAllowedBundleIDs = allowedBundleIDs

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard let allocated = (configClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return }

        typealias InitIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject
        guard let initMethod = class_getInstanceMethod(configClass, initSel) else { return }
        let initCallable = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)

        let config = initCallable(allocated, initSel, allowedSystemItems as NSArray, Array(allowedBundleIDs) as NSArray)

        let assertion = assertionClass.init()
        activeAssertion = assertion

        let activateSel = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        typealias ActivateBlock = @convention(block) (NSError?) -> Void
        let block: ActivateBlock = { [weak self, weak assertion] err in
            if let err {
                NSLog("TidyBar: NativeMenuBarHider activate error: %@", err.localizedDescription)
            }
            guard let self, let assertion else { return }
            self.lock.lock()
            defer { self.lock.unlock() }

            let invalSel = NSSelectorFromString("invalidate")
            if thisGeneration == self.assertionGeneration {
                // 关键无缝过渡：新断言已在系统 WindowServer 中完全生效后，才释放旧断言！
                // 绝不能在激活完成前同步调用 invalidate，否则会导致系统瞬间失去管控、所有隐藏图标全部弹出并与常显区重叠。
                if let oldToInvalidate {
                    _ = (oldToInvalidate as AnyObject).perform(invalSel)
                }
            } else {
                // 若在激活期间白名单已更新或调用了 unhideAll，说明当前断言已过时，立即失效本断言
                _ = (assertion as AnyObject).perform(invalSel)
                if let oldToInvalidate {
                    _ = (oldToInvalidate as AnyObject).perform(invalSel)
                }
            }
        }
        typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        guard let actMethod = class_getInstanceMethod(assertionClass, activateSel) else { return }
        let actCallable = unsafeBitCast(method_getImplementation(actMethod), to: ActivateIMP.self)

        actCallable(assertion, activateSel, config, unsafeBitCast(block, to: AnyObject.self))
    }

    /// 恢复所有菜单栏项目全部可见
    public func unhideAll() {
        lock.lock()
        defer { lock.unlock() }

        assertionGeneration += 1
        lastAllowedBundleIDs = nil
        if let assertion = activeAssertion {
            let invalSel = NSSelectorFromString("invalidate")
            _ = (assertion as AnyObject).perform(invalSel)
            activeAssertion = nil
        }
    }
}
