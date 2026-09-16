import AppKit
import CoreGraphics

/// 已验证的菜单栏截图按图标身份保存；物理折叠后复用截图，不再读取屏外位置。
public final class IconBitmapStore {
    public struct Slot {
        let image: CGImage
        let item: ManagedItem
    }

    private let cache: ImageCache<Slot>
    private var knownIDs: Set<String> = []

    public init(limitBytes: Int = PerformanceBudget.maxImageCacheBytes) {
        cache = ImageCache<Slot>(limitBytes: limitBytes)
    }

    public var currentBytes: Int { cache.currentBytes }
    public var count: Int { cache.count }
    public var hitRate: Double { cache.hitRate }

    /// 坐标变化不改变截图归属；身份来源或多图标序号关系变化时才拒绝复用。
    public func image(for item: ManagedItem) -> CGImage? {
        if let slot = cache.value(for: item.id), slot.item.ownerBundleID == item.ownerBundleID,
           slot.item.identitySource == item.identitySource {
            if item.identitySource == .ownerOrdinal,
               (slot.item.ordinalInOwner != item.ordinalInOwner || slot.item.ownerItemCount != item.ownerItemCount) { return nil }
            return slot.image
        }
        // 兜底查找：若持久化 ID 与实时 ID 因序号后缀（#0）存在细微差异，支持通过 ownerBundleID 复用位图
        if let owner = item.ownerBundleID, !owner.isEmpty {
            for id in knownIDs {
                if let slot = cache.value(for: id), slot.item.ownerBundleID == owner {
                    return slot.image
                }
            }
        }
        return nil
    }

    /// 缺少可复用截图时才请求捕获；被 LRU 淘汰的项也必须重新进入此集合。
    public func needsCapture(_ items: [ManagedItem]) -> [ManagedItem] {
        items.filter { image(for: $0) == nil }
    }

    public func ingest(_ image: CGImage, for item: ManagedItem) {
        let bytes = IconCaptureGeometry.estimatedBytes(widthPixels: image.width, heightPixels: image.height)
        knownIDs.insert(item.id)
        cache.insert(Slot(image: image, item: item), byteCount: bytes, for: item.id)
    }

    /// 图标消失（App 退出/被卸载）时释放，否则缓存里会攒下永远用不到的位图。
    /// 存活集合之外的键由 `retain` 统一清理，调用方每次扫描后调一次即可。
    public func retain(alive itemIDs: Set<String>) {
        for id in knownIDs.subtracting(itemIDs) {
            cache.remove(id)
        }
        knownIDs.formIntersection(itemIDs)
    }

    /// 内存压力时调用：整张表丢掉，下次呼出面板再按需重抓
    public func purge() {
        knownIDs.removeAll()
        cache.removeAll()
    }

    public func contains(id: String) -> Bool { cache.value(for: id) != nil }
}
