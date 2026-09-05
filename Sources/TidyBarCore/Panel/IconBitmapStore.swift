import AppKit
import CoreGraphics

/// 图标位图仓库：LRU 缓存 + "位置变了就作废"。
///
/// 为什么必须记帧位置：缓存键只有图标 id 时，一旦图标被（用户或我们）挪动，
/// 面板会继续显示它**旧位置**的截图——看起来就是"缩略图串位"，比没图更糟。
public final class IconBitmapStore {
    public struct Slot {
        let image: CGImage
        let frame: CGRect
        let bytes: Int
    }

    private let cache: ImageCache<Slot>
    private var frames: [String: CGRect] = [:]

    public init(limitBytes: Int = PerformanceBudget.maxImageCacheBytes) {
        cache = ImageCache<Slot>(limitBytes: limitBytes)
    }

    public var currentBytes: Int { cache.currentBytes }
    public var count: Int { cache.count }
    public var hitRate: Double { cache.hitRate }

    /// 命中条件：id 对得上**且**帧位置没变。
    public func image(for item: ManagedItem) -> CGImage? {
        guard let slot = cache.value(for: item.id), slot.frame == item.frame else { return nil }
        return slot.image
    }

    /// 需要抓图的项：没缓存、或位置已变。调用方据此决定要不要发起抓图，
    /// 避免每次呼出面板都把几十个图标重抓一遍（那是持续的屏幕录制活动，很费电）。
    /// 这里用只读探测，不把"是否要抓"计入命中率统计。
    public func needsCapture(_ items: [ManagedItem]) -> [ManagedItem] {
        items.filter { item in
            guard let known = frames[item.id] else { return true }
            return known != item.frame
        }
    }

    public func ingest(_ image: CGImage, for item: ManagedItem) {
        let bytes = IconCaptureGeometry.estimatedBytes(widthPixels: image.width, heightPixels: image.height)
        frames[item.id] = item.frame
        cache.insert(Slot(image: image, frame: item.frame, bytes: bytes), byteCount: bytes, for: item.id)
    }

    /// 图标消失（App 退出/被卸载）时释放，否则缓存里会攒下永远用不到的位图。
    /// 存活集合之外的键由 `retain` 统一清理，调用方每次扫描后调一次即可。
    public func retain(alive itemIDs: Set<String>) {
        for id in frames.keys where !itemIDs.contains(id) {
            frames[id] = nil
            cache.remove(id)
        }
    }

    /// 内存压力时调用：整张表丢掉，下次呼出面板再按需重抓
    public func purge() {
        frames.removeAll()
        cache.removeAll()
    }

    public func contains(id: String) -> Bool { frames[id] != nil }
}
