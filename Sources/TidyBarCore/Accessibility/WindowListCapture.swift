import AppKit
import CoreGraphics

private typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSGetWindowCount")
private func CGSGetWindowCount(_ cid: CGSConnectionID, _ targetCID: CGSConnectionID, _ count: UnsafeMutablePointer<Int32>) -> Int32

@_silgen_name("CGSGetProcessMenuBarWindowList")
private func CGSGetProcessMenuBarWindowList(
    _ cid: CGSConnectionID,
    _ targetCID: CGSConnectionID,
    _ count: Int32,
    _ list: UnsafeMutablePointer<CGWindowID>,
    _ realCount: UnsafeMutablePointer<Int32>
) -> Int32

private typealias CGWindowListCreateImageFromArrayFunc = @convention(c) (
    CGRect,
    CFArray,
    CGWindowImageOption
) -> Unmanaged<CGImage>?

private let cgWindowListCreateImageFromArray: CGWindowListCreateImageFromArrayFunc? = {
    guard let handle = dlopen(nil, RTLD_NOW),
          let sym = dlsym(handle, "CGWindowListCreateImageFromArray") else {
        return nil
    }
    return unsafeBitCast(sym, to: CGWindowListCreateImageFromArrayFunc.self)
}()

/// 菜单栏独立窗口描述符
public struct MenuBarWindowDescriptor: Sendable {
    public let index: Int
    public let windowID: CGWindowID
    public let title: String
    public let bounds: CGRect
}

/// 借鉴 Ice 与 Bartender 的原生独立窗口隔离捕获器。
///
/// 核心突破：
/// 1. **彻底消灭阴影**：通过 CGWindowListCreateImageFromArray 传入 [.boundsIgnoreFraming, .bestResolution]，
///    系统直接从 WindowServer 内存提取独立图层位图，剥离全部窗口外围投影，Alpha 通道纯净。
/// 2. **彻底消灭邻居残留**：指定目标窗口专属 CGWindowID，即便与邻近图标紧贴，其他窗口由于不在渲染名单内，绝不渗透。
/// 3. **屏外无感直截**：可直接捕获负坐标/隐藏推杆推至屏外的状态项窗口，无需展开推杆或拉起遮罩幕布。
/// 4. **1:1 原生尺寸**：按系统菜单栏高度（22pt）垂直对称修剪多余窗口上下边距，保证在抽屉内不缩水变形。
public enum WindowListIconCapturer {
    /// 获取系统菜单栏窗口列表
    public static func getMenuBarWindows() -> [MenuBarWindowDescriptor] {
        let cid = CGSMainConnectionID()
        var count: Int32 = 0
        _ = CGSGetWindowCount(cid, 0, &count)
        guard count > 0 else {
            return fallbackWindowsFromPublicAPI()
        }

        var list = [CGWindowID](repeating: 0, count: Int(count))
        var realCount: Int32 = 0
        let res = CGSGetProcessMenuBarWindowList(cid, 0, count, &list, &realCount)
        guard res == 0, realCount > 0 else {
            return fallbackWindowsFromPublicAPI()
        }

        let winIDs = Array(list[0..<Int(realCount)])
        let ptr = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: winIDs.count)
        defer { ptr.deallocate() }
        for (i, wid) in winIDs.enumerated() {
            ptr[i] = UnsafeRawPointer(bitPattern: UInt(wid))
        }

        guard let arr = CFArrayCreate(kCFAllocatorDefault, ptr, winIDs.count, nil),
              let infoList = CGWindowListCreateDescriptionFromArray(arr) as? [[String: Any]] else {
            return fallbackWindowsFromPublicAPI()
        }

        var descriptors: [MenuBarWindowDescriptor] = []
        descriptors.reserveCapacity(infoList.count)
        for (i, info) in infoList.enumerated() {
            guard let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            descriptors.append(MenuBarWindowDescriptor(index: i, windowID: wid, title: title, bounds: bounds))
        }
        return descriptors
    }

    /// 公共 API 兜底（以防私有调用受限）
    private static func fallbackWindowsFromPublicAPI() -> [MenuBarWindowDescriptor] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        var descriptors: [MenuBarWindowDescriptor] = []
        var idx = 0
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 25,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { continue }
            let title = info[kCGWindowName as String] as? String ?? ""
            descriptors.append(MenuBarWindowDescriptor(index: idx, windowID: wid, title: title, bounds: bounds))
            idx += 1
        }
        return descriptors
    }

    /// 截取单个窗口（自动去除外边框投影并对齐菜单栏厚度）
    public static func captureWindow(_ wid: CGWindowID, trimToThickness: Bool = true) -> CGImage? {
        guard let fn = cgWindowListCreateImageFromArray else { return nil }
        let ptr = UnsafeMutablePointer<UnsafeRawPointer?>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        ptr[0] = UnsafeRawPointer(bitPattern: UInt(wid))
        guard let arr = CFArrayCreate(kCFAllocatorDefault, ptr, 1, nil),
              let unmanaged = fn(.null, arr, [.boundsIgnoreFraming, .bestResolution]) else {
            return nil
        }
        let rawImage = unmanaged.takeRetainedValue()
        guard hasVisiblePixels(rawImage) else { return nil }

        guard trimToThickness else { return rawImage }

        // 像 Ice 一样按 22pt 对齐修剪上下多余边距，确保抽屉渲染达到 1:1 原生质感
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let targetThickness = 22.0 * scale
        if CGFloat(rawImage.height) > targetThickness + 2 {
            let cropY = (CGFloat(rawImage.height) - targetThickness) / 2
            let cropRect = CGRect(x: 0, y: cropY, width: CGFloat(rawImage.width), height: targetThickness)
            if let cropped = rawImage.cropping(to: cropRect) {
                return cropped
            }
        }
        return rawImage
    }

    /// 高效采样检查图片是否包含有效非透明像素（耗时 < 0.5ms）
    public static func hasVisiblePixels(_ image: CGImage, minCount: Int = 10) -> Bool {
        guard let dataProvider = image.dataProvider,
              let data = dataProvider.data,
              let ptr = CFDataGetBytePtr(data) else { return false }
        let width = image.width
        let height = image.height
        let bytesPerRow = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard bpp == 4 else { return true }
        var count = 0
        let stepX = max(1, width / 16)
        let stepY = max(1, height / 16)
        for y in stride(from: 0, to: height, by: stepY) {
            let rowPtr = ptr + y * bytesPerRow
            for x in stride(from: 0, to: width, by: stepX) {
                let alpha = rowPtr[x * bpp + 3]
                if alpha > 15 {
                    count += 1
                    if count >= minCount { return true }
                }
            }
        }
        return count >= minCount
    }

    /// 为指定条目捕获高质量纯净位图
    public static func capture(for item: ManagedItem, in windows: [MenuBarWindowDescriptor]? = nil) -> CGImage? {
        let descriptors = windows ?? getMenuBarWindows()
        guard !descriptors.isEmpty else {
            return appIconFallback(for: item.ownerBundleID)
        }

        // 收集所有可能的候选窗口（按相关度排序）
        var candidates: [CGWindowID] = []

        // 1. Bundle ID 匹配
        if let bundleID = item.ownerBundleID, !bundleID.isEmpty {
            let matches = descriptors.filter { desc in
                let t = desc.title.lowercased()
                let b = bundleID.lowercased()
                return t == b || t.contains(b) || b.contains(t)
            }
            for match in matches {
                candidates.append(match.windowID)
                // Control Center 窗口对机制：Item-0 往往是邻居
                if match.index > 0 { candidates.append(descriptors[match.index - 1].windowID) }
                if match.index + 1 < descriptors.count { candidates.append(descriptors[match.index + 1].windowID) }
            }
        }

        // 2. 屏幕坐标与屏外坐标匹配
        let tolerance: CGFloat = 24.0
        let coordMatches = descriptors.filter { desc in
            // 屏内直接比对，屏外比对负坐标
            abs(desc.bounds.origin.x - item.frame.minX) < tolerance
                || abs(desc.bounds.midX - item.centerX) < tolerance
        }
        for match in coordMatches {
            if !candidates.contains(match.windowID) {
                candidates.append(match.windowID)
            }
        }

        // 3. 标题匹配
        if !item.title.isEmpty {
            let titleMatches = descriptors.filter {
                $0.title.localizedCaseInsensitiveContains(item.title)
            }
            for match in titleMatches where !candidates.contains(match.windowID) {
                candidates.append(match.windowID)
            }
        }

        // 遍历候选窗口，找到第一个具备真实绘制像素的独立图层
        for wid in candidates {
            if let img = captureWindow(wid) {
                return img
            }
        }

        // 若无有效窗口位图，使用高清 AppIcon 兜底
        return appIconFallback(for: item.ownerBundleID)
    }

    /// 批量抓取一批条目，返回 [itemID: CGImage] 字典
    public static func captureAll(items: [ManagedItem]) -> [String: CGImage] {
        guard !items.isEmpty else { return [:] }
        let descriptors = getMenuBarWindows()
        var results: [String: CGImage] = [:]
        results.reserveCapacity(items.count)

        for item in items {
            if let img = capture(for: item, in: descriptors) {
                results[item.id] = img
            }
        }
        return results
    }

    /// 高清应用图标兜底（保证视觉完整且绝无黑底脏边）
    public static func appIconFallback(for bundleID: String?) -> CGImage? {
        guard let bundleID, !bundleID.isEmpty,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        var proposed = CGRect(x: 0, y: 0, width: 44, height: 44)
        return icon.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
    }
}
