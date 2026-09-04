import AppKit
import ApplicationServices

/// 用辅助功能 API 枚举全机器菜单栏图标。
///
/// 原理：状态项在 AX 树里挂在「归属进程的 AXExtrasMenuBar」下，所以必须按进程遍历，
/// 而不是从某个全局元素往下找。每个子项读出 AXTitle / AXDescription 与
/// AXPosition+AXSize（全局左上原点坐标），再换算成 AppKit 坐标。
///
/// 这是 M0 验证项 1 的实现，同时也是产品里的正式 reader。
/// 真机测得的四类脏数据（0×0 的不可见项、混进来的弹层、只有 roleDescription 的无名项、
/// 副屏负原点坐标）由 MenuBarItemPolicy 统一拦截，结论见 docs/findings/01-enumeration.md。
public final class AccessibilityMenuBarReader: MenuBarReading {
    public struct Config: Sendable {
        /// 跳过这些进程（默认跳掉 Dock/WindowServer 这类必然无 extras 的，省时间）
        public var skippedBundleIDs: Set<String>
        /// 单次枚举最多访问多少个进程，防御性上限
        public var maxProcesses: Int

        public init(
            skippedBundleIDs: Set<String> = [
                "com.apple.dock",
                "com.apple.WindowManager",
                "com.apple.windowmanager",
            ],
            maxProcesses: Int = 400
        ) {
            self.skippedBundleIDs = skippedBundleIDs
            self.maxProcesses = maxProcesses
        }
    }

    /// 枚举过程中值得记录的事实：哪个进程可读、读到几项、耗时多少
    public struct ProcessProbe: Sendable {
        public let pid: pid_t
        public let bundleID: String?
        public let localizedName: String
        public let hasExtrasMenuBar: Bool
        public let itemCount: Int
        public let microseconds: Int
    }

    public struct EnumerationReport: Sendable {
        public let items: [ManagedItem]
        public let probes: [ProcessProbe]
        /// 被策略拦下的项，按原因归类计数——probe 与日志都靠它解释「为什么少了几个」
        public let rejections: [MenuBarItemPolicy.Rejection: Int]
        /// 身份只靠序号成立的项数量：接受，但设置界面要标注"按位置认领"
        public let positionalIdentityCount: Int
        public let totalMicroseconds: Int
        public let primaryScreenHeight: CGFloat
        public let accessibilityGranted: Bool

        public var accessibleProcessCount: Int { probes.filter { $0.hasExtrasMenuBar }.count }
        public var failedProcessCount: Int { probes.filter { !$0.hasExtrasMenuBar }.count }
        public var rejectedCount: Int { rejections.values.reduce(0, +) }
    }

    public enum ReaderError: Error, Equatable {
        case accessibilityNotGranted
    }

    public let config: Config
    private let policyConfig: MenuBarItemPolicy.Config
    private let workspace: NSWorkspace
    private let screensProvider: () -> [ScreenInfo]

    public init(
        config: Config = Config(),
        policyConfig: MenuBarItemPolicy.Config = MenuBarItemPolicy.Config(),
        workspace: NSWorkspace = .shared,
        screensProvider: @escaping () -> [ScreenInfo] = { AppKitScreenObserver().screens }
    ) {
        self.config = config
        self.policyConfig = policyConfig
        self.workspace = workspace
        self.screensProvider = screensProvider
    }

    // MARK: - MenuBarReading

    public func discoverItems() -> [ManagedItem] {
        enumerate().items
    }

    /// 供 probe / M0 记录使用的详细版
    public func enumerate() -> EnumerationReport {
        let started = DispatchTime.now()
        let granted = AXIsProcessTrusted()
        let screens = screensProvider()
        let primaryHeight = screens.first?.frame.height ?? NSScreen.screens.first?.frame.height ?? 0

        guard granted else {
            return EnumerationReport(
                items: [],
                probes: [],
                rejections: [:],
                positionalIdentityCount: 0,
                totalMicroseconds: 0,
                primaryScreenHeight: primaryHeight,
                accessibilityGranted: false
            )
        }

        var items: [ManagedItem] = []
        var probes: [ProcessProbe] = []
        var rejections: [MenuBarItemPolicy.Rejection: Int] = [:]

        let apps = workspace.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .filter { application in
                guard let id = application.bundleIdentifier else { return true }
                return !config.skippedBundleIDs.contains(id)
            }
            .prefix(config.maxProcesses)

        for application in apps {
            let pid = application.processIdentifier
            let processStarted = DispatchTime.now()
            let extras = extrasMenuBar(of: pid)
            let children: [AXUIElement] = extras.map { self.children(of: $0) } ?? []
            var accepted = 0

            for (ordinal, child) in children.enumerated() {
                switch mapChild(
                    child,
                    owner: application,
                    ordinal: ordinal,
                    ownerItemCount: children.count,
                    screens: screens,
                    primaryHeight: primaryHeight
                ) {
                case .accepted(let item):
                    items.append(item)
                    accepted += 1
                case .rejected(let reason):
                    rejections[reason, default: 0] += 1
                }
            }

            probes.append(
                ProcessProbe(
                    pid: pid,
                    bundleID: application.bundleIdentifier,
                    localizedName: application.localizedName ?? "?",
                    hasExtrasMenuBar: extras != nil,
                    // 记的是「被接受的项数」，与 items 总数一致；被拦掉的量在 rejections 里
                    itemCount: accepted,
                    microseconds: Int((DispatchTime.now().uptimeNanoseconds - processStarted.uptimeNanoseconds) / 1_000)
                )
            )
        }

        let uniqueItems = MenuBarEnumeration.deduplicatedIDs(from: items)
        return EnumerationReport(
            items: uniqueItems,
            probes: probes,
            rejections: rejections,
            positionalIdentityCount: uniqueItems.filter(\.isPositionalIdentity).count,
            totalMicroseconds: Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000),
            primaryScreenHeight: primaryHeight,
            accessibilityGranted: true
        )
    }

    // MARK: - AX 原子操作

    private func extrasMenuBar(of pid: pid_t) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            "AXExtrasMenuBar" as CFString,
            &value
        )
        guard result == .success, let value else { return nil }
        // 极少数进程会返回非 AXUIElement 的东西；类型不符就当没有，不能崩
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private func stringAttribute(from element: AXUIElement, name: String) -> String? {
        guard let value = attribute(element, name) else { return nil }
        return value as? String
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = attribute(element, kAXChildrenAttribute as String) else { return [] }
        // as? 对 CF 类型恒真，必须比 CFTypeID 才算真校验；
        // 且 Swift 把 AX 返回的 CFArray 桥接成 [AXUIElement] 并不可靠，故显式逐元素读，
        // 单个元素类型不符就跳过——reader 崩溃等于把用户的菜单栏一起搞挂。
        guard CFGetTypeID(value) == CFArrayGetTypeID() else { return [] }
        let cfArray = value as! CFArray
        return (0..<CFArrayGetCount(cfArray)).compactMap { index in
            guard let raw = CFArrayGetValueAtIndex(cfArray, index) else { return nil }
            // 元素归 CFArray 所有，用 takeUnretained 才不会过度释放
            let candidate = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
            guard CFGetTypeID(candidate) == AXUIElementGetTypeID() else { return nil }
            return (candidate as! AXUIElement)
        }
    }

    /// AX 原始坐标（左上原点，y 向下）
    private func cgFrame(of element: AXUIElement) -> CGRect? {
        guard
            let positionValue = attribute(element, kAXPositionAttribute as String),
            let sizeValue = attribute(element, kAXSizeAttribute as String),
            CFGetTypeID(positionValue) == AXValueGetTypeID(),
            CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        let position = positionValue as! AXValue
        let size = sizeValue as! AXValue
        var point = CGPoint.zero
        var axSize = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &point),
              AXValueGetValue(size, .cgSize, &axSize)
        else { return nil }

        return CGRect(origin: point, size: axSize)
    }

    // MARK: - 映射与准入

    enum ChildOutcome {
        case accepted(ManagedItem)
        case rejected(MenuBarItemPolicy.Rejection)
    }

    private func mapChild(
        _ child: AXUIElement,
        owner application: NSRunningApplication,
        ordinal: Int,
        ownerItemCount: Int,
        screens: [ScreenInfo],
        primaryHeight: CGFloat
    ) -> ChildOutcome {
        guard let cgRect = cgFrame(of: child) else {
            // 连坐标都读不到，等同于零尺寸脏数据
            return .rejected(.zeroSize)
        }
        let frame = ScreenCoordinateSpace.cgToAppKit(cgRect, primaryScreenHeight: primaryHeight)

        // 注意：不要用 roleDescription 兜底取名。实测它是"状态菜单"/"status menu"，
        // 全机器几十个图标都叫这个，等于把匿名项伪装成同名项，比承认匿名更糟。
        let axTitle = stringAttribute(from: child, name: kAXTitleAttribute as String)
        let axDescription = stringAttribute(from: child, name: kAXDescriptionAttribute as String)
        let identitySource: ItemIdentitySource
        if let axTitle, !ManagedItem.normalized(axTitle).isEmpty {
            identitySource = .axTitle
        } else if let axDescription, !ManagedItem.normalized(axDescription).isEmpty {
            identitySource = .axDescription
        } else {
            identitySource = .ownerOrdinal
        }

        if let rejection = MenuBarItemPolicy.rejection(
            frame: frame,
            screens: screens,
            config: policyConfig
        ) {
            return .rejected(rejection)
        }

        let isSystemOwned = systemOwnedBundleIDs.contains(application.bundleIdentifier ?? "")
        return .accepted(
            ManagedItem.Discovery(
                ownerBundleID: application.bundleIdentifier,
                ownerDisplayName: application.localizedName,
                axTitle: axTitle,
                axDescription: axDescription,
                frame: frame,
                isSystemOwned: isSystemOwned,
                ordinalInOwner: ordinal,
                identitySource: identitySource,
                ownerItemCount: ownerItemCount
            ).item
        )
    }

    /// 控制中心/系统 UI 托管的图标：默认不参与自动隐藏（报告 B3 之外的保守策略）
    private let systemOwnedBundleIDs: Set<String> = [
        "com.apple.controlcenter",
        "com.apple.systempreferences",
        "com.apple.coreaudio",
        "com.apple.TextInputMenuAgent",
    ]
}

// MARK: - 纯映射函数（可离线验证，不碰 AX）

public enum MenuBarEnumeration {
    /// children(of:) 的顺序在系统里可能变（App 重启、图标增删），
    /// 所以 id 只能用 owner+title，绝不能带序号。这里把这条约束写成可测函数。
    public static func stableID(ownerBundleID: String?, title: String) -> String {
        ManagedItem.stableID(ownerBundleID: ownerBundleID, title: title)
    }

    /// 同一进程内 title 重复时（多个同名图标），必须可区分，否则两个图标会互相顶替。
    public static func deduplicatedIDs(from items: [ManagedItem]) -> [ManagedItem] {
        var seen: [String: Int] = [:]
        return items.map { item in
            let count = seen[item.id, default: 0]
            seen[item.id] = count + 1
            guard count > 0 else { return item }
            let suffix = "#\(count)"
            return ManagedItem(
                id: item.id + suffix,
                ownerBundleID: item.ownerBundleID,
                title: item.title + suffix,
                frame: item.frame,
                isSystemOwned: item.isSystemOwned,
                lastActivatedAt: item.lastActivatedAt,
                // 身份字段必须原样带过去：否则序号型身份会被"升级"成命名型，
                // 本该提示「按位置认领」的项被当成可持久化，用户配置会静默错位
                identitySource: item.identitySource,
                ordinalInOwner: item.ordinalInOwner,
                ownerItemCount: item.ownerItemCount
            )
        }
    }

    /// 枚举结果按 x 排序，用于与真实菜单栏视觉顺序对照
    public static func sortedLeftToRight(_ items: [ManagedItem]) -> [ManagedItem] {
        items.sorted { $0.frame.minX < $1.frame.minX }
    }
}
