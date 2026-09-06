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
public final class AccessibilityMenuBarReader: MenuBarReading, MenuBarActivating {
    public struct Config: Sendable {
        /// 跳过这些进程（默认跳掉 Dock/WindowServer 这类必然无 extras 的，省时间）
        public var skippedBundleIDs: Set<String>
        /// 单次枚举最多访问多少个进程，防御性上限
        public var maxProcesses: Int
        /// 单个进程的 AX 消息超时。健康的读取是毫秒级，但不响应的 App 能把整次扫描拖住几秒。
        /// 500ms 是实测折中：更短的 150ms 会**静默丢图标**（同一台机器同一时刻少 2~3 个，
        /// 进程数同步下降），"跑得快但看不见"比慢更糟，不给它留默认位。
        /// 传 `.infinity` 表示不设超时（仅用于 A/B 基线：量一下"关掉止损"值多少钱）。
        public var processMessagingTimeout: TimeInterval
        /// 进程级并发度。90 个进程串行是冷启动时延的主因，各进程互不依赖，
        /// 是唯一一处可以安心并发的地方（读的是别的进程，不碰我们的共享状态）。
        /// 真机 A/B：串行 4.2~13.3s → 并发 12 为 0.48~0.68s，覆盖率与串行基线逐轮一致；
        /// 再加到 20 没有收益，所以停在 12。
        public var processConcurrency: Int

        public init(
            skippedBundleIDs: Set<String> = [
                "com.apple.dock",
                "com.apple.WindowManager",
                "com.apple.windowmanager",
            ],
            maxProcesses: Int = 400,
            processMessagingTimeout: TimeInterval = 0.5,
            processConcurrency: Int = 12
        ) {
            self.skippedBundleIDs = skippedBundleIDs
            self.maxProcesses = maxProcesses
            self.processMessagingTimeout = processMessagingTimeout
            self.processConcurrency = max(1, processConcurrency)
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

    /// 单进程定向读取（几毫秒级），供结果复核等"只关心一个 App 的图标"的场景使用
    public func items(ownedBy bundleID: String) -> [ManagedItem] {
        discoverItems(owning: bundleID)
    }

    /// 只读某一个进程的图标。
    ///
    /// 全量枚举要遍历 90 个进程，实测 110~195ms（首次 2.6s）。用它给 mover 取一个图标帧
    /// 是纯浪费，用它看"拖拽进行中的位置"更是每看一眼就错过整个动作。
    /// 单进程读取只有几毫秒，是拖拽期间采样的唯一可行工具。
    public func discoverItems(owning bundleID: String) -> [ManagedItem] {
        guard let application = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) else {
            return []
        }
        return scan(
            application,
            screens: screensProvider(),
            primaryHeight: NSScreen.screens.first?.frame.height ?? 0
        ).accepted
    }

    // MARK: - MenuBarActivating（点击转发）

    /// 在面板里点一下 = 在菜单栏点一下。
    ///
    /// 找回元素靠的是 **(归属进程, 进程内序号)**：枚举时序号就是 `children` 的原始下标
    /// （策略过滤发生在映射之后），所以两边用的是同一把尺子。
    /// 不靠标题找回——88% 的图标根本没有可读标题。
    @discardableResult
    public func activate(itemID: String) -> ActivationOutcome {
        guard let item = discoverItems().first(where: { $0.id == itemID }) else {
            return .itemNotFound
        }
        guard let bundleID = item.ownerBundleID,
              let application = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
              let extras = extrasMenuBar(of: application.processIdentifier, messagingTimeout: config.processMessagingTimeout)
        else {
            // 图标刚被扫到、进程却已经没了：属于"顺序/存在性刚变"，不是我们的查找逻辑错
            return .elementNotFound
        }
        let children = self.children(of: extras)
        guard item.ordinalInOwner < children.count, item.ordinalInOwner >= 0 else { return .elementNotFound }
        let element = children[item.ordinalInOwner]

        var actions: CFArray?
        let listed = AXUIElementCopyActionNames(element, &actions)
        guard listed == .success, let raw = actions as? [AnyObject] else { return .actionUnsupported }
        // CFArray 里的元素是 CFStringRef，不能直接 as? [String] 指望桥接成功
        let names = raw.compactMap { $0 as? String }
        guard names.contains("AXPress") else { return .actionUnsupported }
        let result = AXUIElementPerformAction(element, "AXPress" as CFString)
        guard result == .success else {
        // kAXErrorCannotComplete：目标已经去吃这个事件了（弹菜单进入模态循环），没来得及回执。
        // 真机对照 fixture 的菜单日志确认过：返回 -25204 的那一次，菜单确实打开了。
        return result == .cannotComplete ? .pressedUnconfirmed(code: Int(result.rawValue))
                                        : .failed(code: Int(result.rawValue))
    }
    return .pressed
    }

    /// 右键菜单转发：在面板里右键 = 在真实图标上弹出上下文菜单。
    ///
    /// 优先使用 AXShowMenu（专为弹出右键菜单设计），
    /// 不支持时回退到 AXPress（至少能触发常规点击）。
    @discardableResult
    public func showMenu(itemID: String) -> ActivationOutcome {
        guard let item = discoverItems().first(where: { $0.id == itemID }) else {
            return .itemNotFound
        }
        guard let bundleID = item.ownerBundleID,
              let application = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
              let extras = extrasMenuBar(of: application.processIdentifier, messagingTimeout: config.processMessagingTimeout)
        else {
            return .elementNotFound
        }
        let children = self.children(of: extras)
        guard item.ordinalInOwner < children.count, item.ordinalInOwner >= 0 else { return .elementNotFound }
        let element = children[item.ordinalInOwner]

        var actions: CFArray?
        let listed = AXUIElementCopyActionNames(element, &actions)
        guard listed == .success, let raw = actions as? [AnyObject] else { return .actionUnsupported }
        let names = raw.compactMap { $0 as? String }

        // 优先 AXShowMenu，不支持则回退 AXPress
        let action: String = names.contains("AXShowMenu") ? "AXShowMenu" : (names.contains("AXPress") ? "AXPress" : "")
        guard !action.isEmpty else { return .actionUnsupported }
        let result = AXUIElementPerformAction(element, action as CFString)
        guard result == .success else {
            return result == .cannotComplete ? .pressedUnconfirmed(code: Int(result.rawValue))
                                            : .failed(code: Int(result.rawValue))
        }
        return .pressed
    }

    // MARK: - 可点性普查（只读，不真的点）

    /// 每个归属进程有多少图标接受 AXPress。
    ///
    /// 为什么单独要这个读数：A3/A8 的验收标准是"面板里点一下等效于点真实图标"，
    /// 而"能读到"不等于"能点到"。上线前必须知道有多少 App 点到、多少点不到，
    /// 否则就是拿用户的预期去试错。
    /// **只看动作列表，绝不 AXPress**——真去点会把每个 App 的菜单都弹一遍。
    public struct PressCensus: Sendable {
        public let ownerBundleID: String
        public let ownerName: String
        public let total: Int
        public let pressCapable: Int
    }

    public func pressCapabilityCensus() -> [PressCensus] {
        guard AXIsProcessTrusted() else { return [] }
        var result: [PressCensus] = []
        for application in candidateApplications() {
            guard let extras = extrasMenuBar(
                of: application.processIdentifier,
                messagingTimeout: config.processMessagingTimeout
            ) else { continue }
            let children = self.children(of: extras)
            guard !children.isEmpty else { continue }
            let capable = children.filter { element in
                var actions: CFArray?
                guard AXUIElementCopyActionNames(element, &actions) == .success,
                      let raw = actions as? [AnyObject] else { return false }
                return raw.compactMap { $0 as? String }.contains("AXPress")
            }.count
            result.append(PressCensus(
                ownerBundleID: application.bundleIdentifier ?? "?",
                ownerName: application.localizedName ?? "?",
                total: children.count,
                pressCapable: capable
            ))
        }
        return result
    }

    /// 扫描候选：过滤 + 截断 + **排序**。
    /// 排序不是为了好看：菜单栏图标几乎全部住在 accessory 进程里，
    /// 把 .regular 的大 App 排到后面，等于让"覆盖全部图标"这件事尽早发生——
    /// 之后即便还有进程没扫完，已知的那部分也已经可以用于隐藏/显示。
    /// Swift 的 sort 不保证稳定，所以拿原始下标当第二关键字，保证两次扫描顺序可复现。
    private func candidateApplications() -> [NSRunningApplication] {
        let filtered = workspace.runningApplications
            .filter { $0.activationPolicy != .prohibited }
            .filter { application in
                guard let id = application.bundleIdentifier else { return true }
                return !config.skippedBundleIDs.contains(id)
            }
            .prefix(config.maxProcesses)
        return filtered.enumerated()
            .sorted { lhs, rhs in
                let lp = lhs.element.activationPolicy == .regular ? 1 : 0
                let rp = rhs.element.activationPolicy == .regular ? 1 : 0
                if lp != rp { return lp < rp }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// 单个进程的采集结果（含被拒原因计数）
    private struct ProcessScan {
        var accepted: [ManagedItem] = []
        var rejections: [MenuBarItemPolicy.Rejection: Int] = [:]
        var hasExtrasMenuBar = false
        var microseconds = 0
    }

    private func scan(
        _ application: NSRunningApplication,
        screens: [ScreenInfo],
        primaryHeight: CGFloat
    ) -> ProcessScan {
        let started = DispatchTime.now()
        let pid = application.processIdentifier
        let timeout = config.processMessagingTimeout
        guard let extras = extrasMenuBar(
            of: pid,
            messagingTimeout: timeout.isFinite ? timeout : nil
        ) else {
            return ProcessScan(microseconds: elapsed(since: started))
        }
        let children = self.children(of: extras)
        var accepted: [ManagedItem] = []
        var rejections: [MenuBarItemPolicy.Rejection: Int] = [:]
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
                accepted.append(item)
            case .rejected(let reason):
                rejections[reason, default: 0] += 1
            }
        }
        return ProcessScan(
            accepted: MenuBarEnumeration.deduplicatedIDs(from: accepted),
            rejections: rejections,
            hasExtrasMenuBar: true,
            microseconds: elapsed(since: started)
        )
    }

    private func elapsed(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000)
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

        let apps = candidateApplications()
        // 每个进程独占一格输出：并发只用来消掉串行等待，汇总仍按固定顺序读回来。
        // 直接往同一个 Array 的不同下标并发写会踩 Swift 的独占访问检查，
        // 所以这里用裸缓冲区，写权限天然按格子划分。
        let slots = UnsafeMutablePointer<ProcessScan>.allocate(capacity: apps.count)
        slots.initialize(repeating: ProcessScan(), count: apps.count)
        let gate = DispatchSemaphore(value: config.processConcurrency)
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            gate.wait()
            defer { gate.signal() }
            slots[index] = scan(apps[index], screens: screens, primaryHeight: primaryHeight)
        }

        for (index, application) in apps.enumerated() {
            let result = slots[index]
            items.append(contentsOf: result.accepted)
            for (reason, count) in result.rejections {
                rejections[reason, default: 0] += count
            }
            probes.append(
                ProcessProbe(
                    pid: application.processIdentifier,
                    bundleID: application.bundleIdentifier,
                    localizedName: application.localizedName ?? "?",
                    hasExtrasMenuBar: result.hasExtrasMenuBar,
                    // 记的是「被接受的项数」，与 items 总数一致；被拦掉的量在 rejections 里
                    itemCount: result.accepted.count,
                    microseconds: result.microseconds
                )
            )
        }
        slots.deinitialize(count: apps.count)
        slots.deallocate()

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

    private func extrasMenuBar(of pid: pid_t, messagingTimeout: TimeInterval? = nil) -> AXUIElement? {
        guard pid > 0 else { return nil }
        let appElement = AXUIElementCreateApplication(pid)
        // 不给超时就会退化成"等对方 App 心情"：一个卡住的前台 App 能把整次冷启动拖住几秒
        if let messagingTimeout {
            AXUIElementSetMessagingTimeout(appElement, Float(messagingTimeout))
        }
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
    /// 位置键：`归属进程 + 进程内序号`。
    /// 序号会随我们挪动而变化、放回后又变回来，所以它对"是否回到原位"敏感；
    /// 而第三方只改标题（微信把未读数写进标题）时它不动，所以对"别人改名"免疫。
    public static func positionKey(_ item: ManagedItem) -> String {
        let owner = item.ownerBundleID ?? "nil"
        return owner + "[" + String(item.ordinalInOwner) + "]"
    }

    /// 顺序指纹序列。
    ///
    /// 为什么不能用 id 做"有没有放回原位"的比对：id 含标题，第三方自己改标题就会让 id 漂移，
    /// 于是"别人改名"被算成"我们没复原"——上一轮就是这么误判的。
    public static func positionSignature(of items: [ManagedItem]) -> [String] {
        items.map(positionKey)
    }

    /// 同一位置键在两帧之间标题变了 → 该进程的标题不能当身份用。
    /// 这是"标题漂移"的最小可观测形态：先能量出来、能报数，再谈换身份方案。
    public struct TitleDrift: Equatable, Sendable {
        public let ownerBundleID: String
        public let ordinal: Int
        public let before: String
        public let after: String
    }

    public static func detectTitleDrift(before: [ManagedItem], after: [ManagedItem]) -> [TitleDrift] {
        var keyed: [String: ManagedItem] = [:]
        for item in before where keyed[positionKey(item)] == nil {
            keyed[positionKey(item)] = item
        }
        var changes: [TitleDrift] = []
        for item in after {
            guard let old = keyed[positionKey(item)], old.title != item.title else { continue }
            changes.append(TitleDrift(
                ownerBundleID: item.ownerBundleID ?? "nil",
                ordinal: item.ordinalInOwner,
                before: old.title,
                after: item.title
            ))
        }
        return changes
    }

    /// 出现过漂移的进程：设置界面要把这些图标的归属标成"按位置认领、可能失准"，
    /// 而不是继续假装它们的标题型 id 稳定。
    public static func volatileTitleOwners(drift: [TitleDrift]) -> Set<String> {
        Set(drift.map(\.ownerBundleID))
    }

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
