import AppKit

/// 统一的 App 原生高清图标与系统符号解析器。
///
/// 解决的核心问题：
/// 菜单栏应用通常不需要屏幕录制权限，通过应用包的 `ownerBundleID`
/// 即可通过 `NSWorkspace` 100% 零延迟精准读取出系统里安装的真实高清 App 图标。
/// 彻底告别粗暴的手绘首字母方块。
public enum AppIconResolver {
    private static var cache: [String: NSImage] = [:]
    private static let lock = NSLock()

    /// 解析指定图标条目的真实应用图标（带内存缓存与线程安全保护）
    public static func resolve(for item: ManagedItem) -> NSImage {
        lock.lock()
        if let cached = cache[item.id] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let image = resolveUncached(for: item)
        lock.lock()
        cache[item.id] = image
        lock.unlock()
        return image
    }

    private static func resolveUncached(for item: ManagedItem) -> NSImage {
        let lowerTitle = item.title.lowercased()
        let lowerOwner = (item.ownerBundleID ?? "").lowercased()
        let combined = lowerTitle + " " + lowerOwner

        // 1. 系统级菜单栏项优先匹配原生 SF Symbol 智能映射
        // 关键防护：com.apple.controlcenter 会解析到 ControlCenter.app，若先走 App 图标会导致时钟/声音/电池/WiFi全变成滑块图标
        if item.isSystemOwned || lowerOwner.contains("controlcenter") || lowerOwner.contains("systemuiserver") || lowerOwner.contains("spotlight") || lowerOwner.contains("weather") {
            let symbolName: String?
            if combined.contains("wifi") || combined.contains("airport") || combined.contains("wi-fi") {
                symbolName = "wifi"
            } else if combined.contains("battery") || combined.contains("power") || combined.contains("电池") {
                symbolName = "battery.100"
            } else if combined.contains("sound") || combined.contains("volume") || combined.contains("声音") || combined.contains("音频") {
                symbolName = "speaker.wave.3"
            } else if combined.contains("bluetooth") || combined.contains("蓝牙") {
                symbolName = "bonjour"
            } else if combined.contains("clock") || combined.contains("time") || combined.contains("时钟") || combined.contains("星期") || combined.contains("年") {
                symbolName = "clock"
            } else if combined.contains("search") || combined.contains("spotlight") || combined.contains("搜索") {
                symbolName = "magnifyingglass"
            } else if combined.contains("shortcut") || combined.contains("快捷指令") {
                symbolName = "square.2.layers.3d"
            } else if combined.contains("input") || combined.contains("textinput") || combined.contains("输入法") {
                symbolName = "keyboard"
            } else if combined.contains("weather") || combined.contains("天气") {
                symbolName = "cloud.sun"
            } else if combined.contains("mic") || combined.contains("麦克风") || combined.contains("录屏") {
                symbolName = "mic"
            } else if combined.contains("control") || combined.contains("控制中心") {
                symbolName = "switch.2"
            } else {
                symbolName = nil
            }

            if let symbolName, let symImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title) {
                return symImage
            }
        }

        // 2. 真实 App 原生高清图标（从应用包精准读取，零授权秒开）
        if let bundleID = item.ownerBundleID, !bundleID.isEmpty {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
        }

        // 3. 通用关键字 SF Symbol 匹配
        let fallbackSymbol: String?
        if combined.contains("terminal") || combined.contains("iterm") {
            fallbackSymbol = "terminal"
        } else if combined.contains("music") || combined.contains("音乐") {
            fallbackSymbol = "music.note"
        } else if combined.contains("code") {
            fallbackSymbol = "chevron.left.forwardslash.chevron.right"
        } else {
            fallbackSymbol = nil
        }
        if let fallbackSymbol, let symImage = NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: item.title) {
            return symImage
        }

        // 4. 兜底纯净通用图标（不带生硬边框与方格，纯图标展示）
        if let defaultSym = NSImage(systemSymbolName: "app.fill", accessibilityDescription: item.title) {
            return defaultSym
        }

        return NSImage()
    }

    /// 清空缓存（在应用重扫或内存压力时调用）
    public static func purge() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
