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
        configClass != nil && assertionClass != nil
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

    /// 隐藏非白名单项。
    /// - Parameters:
    ///   - allowedBundleIDs: 允许在菜单栏保持可见的第三方应用 Bundle ID 集合
    ///   - allowedSystemItems: 允许保持可见的系统项 ID 集合（0...8 分别对应电池、蓝牙、时钟、显示器、键盘、音量、Wi-Fi、屏幕镜像、控制中心）
    public func hideItems(except allowedBundleIDs: Set<String>, allowedSystemItems: [Int] = [0, 1, 2, 3, 4, 5, 6, 7, 8]) {
        lock.lock()
        defer { lock.unlock() }

        guard let configClass = configClass as? NSObject.Type,
              let assertionClass = assertionClass as? NSObject.Type else { return }

        // 释放旧断言
        if let old = activeAssertion {
            let invalSel = NSSelectorFromString("invalidate")
            _ = (old as AnyObject).perform(invalSel)
            activeAssertion = nil
        }

        let allocSel = NSSelectorFromString("alloc")
        let initSel = NSSelectorFromString("initWithAllowedSystemItems:allowedBundleIdentifiers:")
        guard let allocated = (configClass as AnyObject).perform(allocSel)?.takeUnretainedValue() else { return }

        typealias InitIMP = @convention(c) (AnyObject, Selector, NSArray, NSArray) -> AnyObject
        guard let initMethod = class_getInstanceMethod(configClass, initSel) else { return }
        let initCallable = unsafeBitCast(method_getImplementation(initMethod), to: InitIMP.self)

        let config = initCallable(allocated, initSel, allowedSystemItems as NSArray, Array(allowedBundleIDs) as NSArray)

        let assertion = assertionClass.init()
        let activateSel = NSSelectorFromString("activateWithConfiguration:completionHandler:")
        typealias ActivateBlock = @convention(block) (NSError?) -> Void
        let block: ActivateBlock = { err in
            if let err {
                NSLog("TidyBar: NativeMenuBarHider activate error: %@", err.localizedDescription)
            }
        }
        typealias ActivateIMP = @convention(c) (AnyObject, Selector, AnyObject, AnyObject) -> Void
        guard let actMethod = class_getInstanceMethod(assertionClass, activateSel) else { return }
        let actCallable = unsafeBitCast(method_getImplementation(actMethod), to: ActivateIMP.self)

        actCallable(assertion, activateSel, config, unsafeBitCast(block, to: AnyObject.self))
        activeAssertion = assertion
    }

    /// 恢复所有菜单栏项目全部可见
    public func unhideAll() {
        lock.lock()
        defer { lock.unlock() }

        if let assertion = activeAssertion {
            let invalSel = NSSelectorFromString("invalidate")
            _ = (assertion as AnyObject).perform(invalSel)
            activeAssertion = nil
        }
    }
}
