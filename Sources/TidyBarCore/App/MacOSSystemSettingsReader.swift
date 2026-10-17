import Foundation
import AppKit

/// 表示在 macOS 27+ 系统设置「控制中心 / 菜单栏」中登记的第三方应用。
public struct SystemTrackedApp: Sendable, Equatable, Hashable {
    /// 主应用 Bundle ID（例如 com.nektony.App-Cleaner-SIII）
    public let bundleID: String
    /// 伴随的辅助进程/状态项 Bundle ID 列表（例如 com.nektony.App-Cleaner-SIII-UIHelper）
    public let secondaryBundleIDs: [String]
    /// 人类可读的应用显示名称（例如 App Cleaner & Uninstaller）
    public let displayName: String
    /// 系统是否允许其在菜单栏展示（true: 允许展示；false: 被系统设置强制隐藏/禁用）
    public let isAllowed: Bool
    /// 本地 App 的磁盘 URL（如能定位）
    public let appURL: URL?

    public init(
        bundleID: String,
        secondaryBundleIDs: [String] = [],
        displayName: String,
        isAllowed: Bool,
        appURL: URL? = nil
    ) {
        self.bundleID = bundleID
        self.secondaryBundleIDs = secondaryBundleIDs
        self.displayName = displayName
        self.isAllowed = isAllowed
        self.appURL = appURL
    }

    /// 包含主 ID 及所有伴随辅助 ID 的集合
    public var allBundleIDs: Set<String> {
        var set = Set([bundleID])
        for sec in secondaryBundleIDs {
            set.insert(sec)
        }
        return set
    }
}

/// 系统菜单栏设置读取协议（便于单元测试注入 Mock）
public protocol MacOSSystemSettingsReading: Sendable {
    /// 读取系统登记的所有状态栏应用配置
    func readTrackedApplications() -> [SystemTrackedApp]
    /// 获取所有被系统设置隐藏（isAllowed == false）的应用 Bundle ID 集合
    func systemHiddenBundleIDs() -> Set<String>
    /// 判断特定 Bundle ID 是否被系统设置隐藏
    func isAppHiddenBySystem(bundleID: String) -> Bool
    /// 唤起系统设置对应的控制中心/菜单栏管理页
    func openSystemSettingsControlCenter() -> Bool
}

/// macOS 27+ 系统设置控制中心/菜单栏偏好读取服务。
///
/// macOS 27 将菜单栏第三方应用的显示控制存储在：
/// `~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist`
/// 内含 `trackedApplications` 键（内嵌二进制 bplist 数据），记录每个 App 的 `isAllowed` 许可状态。
/// 当用户在系统设置关闭某 App 的菜单栏显示时，`MenuBarAgent` 直接拒绝为该 App 创建 NSStatusItem。
public final class MacOSSystemSettingsReader: MacOSSystemSettingsReading, @unchecked Sendable {
    public static let shared = MacOSSystemSettingsReader()

    /// 默认系统偏好文件路径
    public static var defaultPlistURL: URL {
        let path = ("~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist" as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path)
    }

    /// 可注入的自定义 Plist URL（用于自动化测试）
    public var customPlistURL: URL?

    private let lock = NSLock()

    public init(customPlistURL: URL? = nil) {
        self.customPlistURL = customPlistURL
    }

    private var targetPlistURL: URL {
        customPlistURL ?? Self.defaultPlistURL
    }

    /// 读取系统设置中登记的状态栏应用列表
    public func readTrackedApplications() -> [SystemTrackedApp] {
        lock.lock()
        defer { lock.unlock() }

        let url = targetPlistURL
        guard let data = try? Data(contentsOf: url) else {
            return []
        }

        return parseEntries(from: data)
    }

    /// 获取所有被系统设置完全隐藏/禁用的 Bundle ID 集合（包含伴随的 Helper 进程）
    public func systemHiddenBundleIDs() -> Set<String> {
        let apps = readTrackedApplications()
        var hiddenSet = Set<String>()
        for app in apps where !app.isAllowed {
            hiddenSet.formUnion(app.allBundleIDs)
        }
        return hiddenSet
    }

    /// 判断指定 Bundle ID 是否已被 macOS 27 系统设置彻底隐藏
    public func isAppHiddenBySystem(bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        let hidden = systemHiddenBundleIDs()
        if hidden.contains(bundleID) { return true }
        let lower = bundleID.lowercased()
        return hidden.contains { $0.lowercased() == lower }
    }

    /// 一键唤起 macOS 27 系统设置的「控制中心 / 菜单栏」管理面板
    @discardableResult
    public func openSystemSettingsControlCenter() -> Bool {
        // macOS 27 控制中心扩展 URL Scheme
        if let url = URL(string: "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension") {
            if NSWorkspace.shared.open(url) {
                return true
            }
        }
        // 兜底降级：直接打开通用系统设置面板
        if let fallbackURL = URL(string: "x-apple.systempreferences:") {
            return NSWorkspace.shared.open(fallbackURL)
        }
        return false
    }

    // MARK: - 底层解析实现

    public func parseEntries(from data: Data) -> [SystemTrackedApp] {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return []
        }

        var rawEntries: [[String: Any]] = []

        if let dict = plist as? [String: Any] {
            if let trackedData = dict["trackedApplications"] as? Data {
                if let array = try? PropertyListSerialization.propertyList(from: trackedData, options: [], format: nil) as? [[String: Any]] {
                    rawEntries = array
                }
            } else if let trackedArray = dict["trackedApplications"] as? [[String: Any]] {
                rawEntries = trackedArray
            }
        } else if let directArray = plist as? [[String: Any]] {
            rawEntries = directArray
        }

        var results: [SystemTrackedApp] = []
        var seenBundleIDs = Set<String>()

        for entry in rawEntries {
            guard let isAllowed = entry["isAllowed"] as? Bool else {
                // 没有 isAllowed 字段的纯注册占位项，跳过
                continue
            }

            var primaryBundleID: String?
            var appURL: URL?
            var secondaryBundleIDs: [String] = []

            // 1. 解析 location
            if let loc = entry["location"] as? [String: Any] {
                if let bundleDict = loc["bundle"] as? [String: Any],
                   let bID = bundleDict["_0"] as? String {
                    primaryBundleID = bID
                } else if let adhoc = loc["adhocBinary"] as? [String: Any],
                          let adhoc0 = adhoc["_0"] as? [String: Any],
                          let rel = adhoc0["relative"] as? String,
                          let url = URL(string: rel) {
                    appURL = url
                    if let found = resolveAppBundle(fromBinaryURL: url),
                       let bID = found.bundleIdentifier {
                        primaryBundleID = bID
                    }
                }
            }

            // 2. 兜底直接 bundle 属性
            if primaryBundleID == nil,
               let bundleDict = entry["bundle"] as? [String: Any],
               let bID = bundleDict["_0"] as? String {
                primaryBundleID = bID
            }

            // 3. 解析 menuItemLocations (例如伴随的 UIHelper)
            if let menuLocations = entry["menuItemLocations"] as? [[String: Any]] {
                for mItem in menuLocations {
                    if let bundleDict = mItem["bundle"] as? [String: Any],
                       let bID = bundleDict["_0"] as? String {
                        if primaryBundleID == nil {
                            primaryBundleID = bID
                        } else if bID != primaryBundleID && !secondaryBundleIDs.contains(bID) {
                            secondaryBundleIDs.append(bID)
                        }
                    } else if let adhoc = mItem["adhocBinary"] as? [String: Any],
                              let adhoc0 = adhoc["_0"] as? [String: Any],
                              let rel = adhoc0["relative"] as? String,
                              let url = URL(string: rel) {
                        if appURL == nil { appURL = url }
                        if let found = resolveAppBundle(fromBinaryURL: url),
                           let bID = found.bundleIdentifier {
                            if primaryBundleID == nil {
                                primaryBundleID = bID
                            } else if bID != primaryBundleID && !secondaryBundleIDs.contains(bID) {
                                secondaryBundleIDs.append(bID)
                            }
                        }
                    }
                }
            }

            guard let resolvedBundleID = primaryBundleID ?? appURL?.lastPathComponent else {
                continue
            }

            if seenBundleIDs.contains(resolvedBundleID) {
                continue
            }
            seenBundleIDs.insert(resolvedBundleID)

            // 解析应用名称和最终 App URL
            let (resolvedName, resolvedURL) = resolveAppIdentity(bundleID: resolvedBundleID, fallbackURL: appURL)

            results.append(SystemTrackedApp(
                bundleID: resolvedBundleID,
                secondaryBundleIDs: secondaryBundleIDs,
                displayName: resolvedName,
                isAllowed: isAllowed,
                appURL: resolvedURL
            ))
        }

        return results
    }

    private func resolveAppBundle(fromBinaryURL binaryURL: URL) -> Bundle? {
        var current = binaryURL.standardizedFileURL
        while current.path != "/" {
            if current.pathExtension == "app" {
                return Bundle(url: current)
            }
            current.deleteLastPathComponent()
        }
        return nil
    }

    private func resolveAppIdentity(bundleID: String, fallbackURL: URL?) -> (name: String, appURL: URL?) {
        let ws = NSWorkspace.shared
        let appURL = ws.urlForApplication(withBundleIdentifier: bundleID) ?? fallbackURL

        if let appURL {
            let path = appURL.path
            let rawName = FileManager.default.displayName(atPath: path)
            let cleanedName = rawName.hasSuffix(".app") ? String(rawName.dropLast(4)) : rawName
            return (cleanedName, appURL)
        }

        // 降级：从 BundleID 截取最后一段有意义的名称
        let components = bundleID.split(separator: ".")
        let fallbackName = components.last.map(String.init) ?? bundleID
        return (fallbackName, nil)
    }
}
