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
        // 1. 优先从 ownerBundleID 获取真实应用高清原生图标
        if let bundleID = item.ownerBundleID, !bundleID.isEmpty {
            if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: appURL.path)
            }
        }

        // 2. 针对系统级菜单栏项目的原生 SF Symbol 智能映射
        let lowerTitle = item.title.lowercased()
        let lowerOwner = (item.ownerBundleID ?? "").lowercased()
        let combined = lowerTitle + " " + lowerOwner

        let symbolName: String?
        if combined.contains("wifi") || combined.contains("airport") {
            symbolName = "wifi"
        } else if combined.contains("battery") || combined.contains("power") {
            symbolName = "battery.100"
        } else if combined.contains("sound") || combined.contains("volume") {
            symbolName = "speaker.wave.3"
        } else if combined.contains("bluetooth") {
            symbolName = "bonjour"
        } else if combined.contains("clock") || combined.contains("time") {
            symbolName = "clock"
        } else if combined.contains("search") || combined.contains("spotlight") {
            symbolName = "magnifyingglass"
        } else if combined.contains("control") {
            symbolName = "switch.2"
        } else if combined.contains("weather") {
            symbolName = "cloud.sun"
        } else {
            symbolName = nil
        }

        if let symbolName, let symImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: item.title) {
            return symImage
        }

        // 3. 兜底拟物双字符精致微标
        let image = NSImage(size: NSSize(width: 28, height: 28))
        image.lockFocus()
        NSColor.labelColor.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: NSRect(x: 1, y: 1, width: 26, height: 26), xRadius: 6, yRadius: 6).fill()

        let letter: String
        if !item.title.isEmpty {
            letter = String(item.title.prefix(2)).uppercased()
        } else if let bID = item.ownerBundleID, let lastPart = bID.split(separator: ".").last {
            letter = String(lastPart.prefix(2)).uppercased()
        } else {
            letter = "•"
        }

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let str = NSAttributedString(string: letter, attributes: attrs)
        let s = str.size()
        str.draw(at: NSPoint(x: (28 - s.width) / 2, y: (28 - s.height) / 2))
        image.unlockFocus()
        return image
    }

    /// 清空缓存（在应用重扫或内存压力时调用）
    public static func purge() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
    }
}
