import AppKit

/// accessory 应用没有自己的应用菜单；临时提供短菜单，让左侧状态项获得真实鼠标命中。
/// 只能在输入队列排空后结束，且不覆盖用户途中主动切换的前台应用。
@MainActor
final class MenuBarAccessSession {
    private let application = NSApplication.shared
    private let previousApplication: NSRunningApplication?
    private let previousMenu: NSMenu?
    private let previousPolicy: NSApplication.ActivationPolicy
    private var ended = false
    private var restoresForeground = true
    private var activationStarted = false
    private var prepared = false
    private var preparationCallbacks: [@MainActor () -> Void] = []
    private(set) var isCancelled = false

    init?() {
        previousApplication = NSWorkspace.shared.frontmostApplication
        previousMenu = application.mainMenu
        previousPolicy = application.activationPolicy()
        let windows = application.windows.filter { $0.isVisible && $0.level == .normal }
        guard windows.isEmpty || windows.contains(where: \.isOnActiveSpace) else { return nil }
        guard application.setActivationPolicy(.regular) else { return nil }
        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "退出 TidyBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        application.mainMenu = menu
        // 激活策略通过系统异步发布，不能在切换 policy 的同一调用栈里立即激活。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.ended else { return }
            guard !self.isCancelled else { self.finishPreparation(); return }
            self.activationStarted = true
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.createsNewApplicationInstance = false
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { [weak self] _, error in
                if let error { NSLog("TidyBar 菜单激活失败：%@", error.localizedDescription) }
                DispatchQueue.main.async { self?.finishPreparation() }
            }
        }
    }

    func whenPrepared(_ completion: @escaping @MainActor () -> Void) {
        if prepared { completion() }
        else { preparationCallbacks.append(completion) }
    }

    private func finishPreparation() {
        guard !prepared else { return }
        prepared = true
        let callbacks = preparationCallbacks
        preparationCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    func cancel() {
        isCancelled = true
        if !activationStarted { finishPreparation() }
    }

    func end() {
        guard prepared else {
            cancel()
            whenPrepared { [self] in end() }
            return
        }
        guard !ended else { return }
        ended = true
        let stillOwnsForeground = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
        let restore = restoresForeground && stillOwnsForeground
            && previousApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            && previousApplication?.isTerminated == false
        if restore, let previousApplication { application.yieldActivation(to: previousApplication) }
        application.mainMenu = previousMenu
        application.setActivationPolicy(previousPolicy)
        if restore, let previousApplication {
            previousApplication.activate(from: .current, options: [])
        }
    }

    func preventForegroundRestoration(cancelling: Bool = true) {
        restoresForeground = false
        if cancelling { cancel() }
    }
}
