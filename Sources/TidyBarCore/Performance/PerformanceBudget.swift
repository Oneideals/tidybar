import Foundation
import Darwin

/// 「占用小」的可验收定义（报告 §4.3 性能预算）。
/// 数值不达标即视为回归，scripts/perf-check.sh 会读取本文件里的同一套阈值判定失败。
public enum PerformanceBudget {
    /// 常驻内存上限（20 图标静置 1 小时）。
    /// 口径固定为 phys_footprint（`footprint` 工具 / task_vm_info.phys_footprint），
    /// 不是 ps 的 RSS —— RSS 会把 AppKit 等共享页算进来，菜单栏类工具实测虚高 2~3 倍，
    /// 用它当预算会把「省内存」这件事实拍成假象。本机骨架基线：phys_footprint 13MB ／ ps RSS 37MB。
    public static let maxResidentMemoryBytes: UInt64 = 40 * 1024 * 1024
    /// 空闲 CPU 占比上限
    public static let maxIdleCPUPercent: Double = 0.1
    /// 呼出/隐藏响应上限（毫秒）
    public static let maxRevealLatencyMS: Double = 100
    /// 冷启动到图标接管上限（秒）
    public static let maxColdStartSeconds: Double = 2
    /// 安装包体积上限
    public static let maxArtifactBytes: Int = 10 * 1024 * 1024
    /// 图标位图缓存硬上限（低于 Ice 的 50MB 默认值）
    public static let maxImageCacheBytes: Int = 20 * 1024 * 1024

    public struct Sample: Equatable, Sendable {
        public let residentMemoryBytes: UInt64
        public let idleCPUPercent: Double
        public let revealLatencyMS: Double
        public let coldStartSeconds: Double

        public init(residentMemoryBytes: UInt64, idleCPUPercent: Double, revealLatencyMS: Double, coldStartSeconds: Double) {
            self.residentMemoryBytes = residentMemoryBytes
            self.idleCPUPercent = idleCPUPercent
            self.revealLatencyMS = revealLatencyMS
            self.coldStartSeconds = coldStartSeconds
        }
    }

    public struct Verdict: Equatable, Sendable {
        public let failures: [String]
        public var isPassing: Bool { failures.isEmpty }
        public init(failures: [String]) { self.failures = failures }
    }

    /// 纯函数：把一次采样对照预算打分
    public static func assess(_ sample: Sample) -> Verdict {
        var failures: [String] = []
        if sample.residentMemoryBytes > maxResidentMemoryBytes {
            failures.append("内存 \(sample.residentMemoryBytes / 1024 / 1024)MB > 40MB")
        }
        if sample.idleCPUPercent > maxIdleCPUPercent {
            failures.append("空闲 CPU \(sample.idleCPUPercent)% > 0.1%")
        }
        if sample.revealLatencyMS > maxRevealLatencyMS {
            failures.append("呼出延迟 \(sample.revealLatencyMS)ms > 100ms")
        }
        if sample.coldStartSeconds > maxColdStartSeconds {
            failures.append("冷启动 \(sample.coldStartSeconds)s > 2s")
        }
        return Verdict(failures: failures)
    }
}

/// 运行时自测量（报告 F1 性能面板的数据源）
public enum ResourceProbe {
    /// 当前进程常驻内存字节数（mach_task_basic_info.phys_footprint 语义近似）
    public static func residentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.phys_footprint)
    }

    /// 当前进程线程数：菜单栏工具应保持极少线程，线程数增长通常意味着监听器泄漏
    public static func threadCount() -> Int {
        var list: thread_act_array_t?
        var count = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &list, &count) == KERN_SUCCESS, let pointer = list else { return 0 }
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: pointer), vm_size_t(count) * vm_size_t(MemoryLayout<thread_act_t>.size))
        return Int(count)
    }
}

/// 图标位图缓存：LRU + 硬字节上限 + 内存压力时主动清空（报告 §4.3）。
/// 键为 ManagedItem.id，值由调用方提供字节数，便于在无 AppKit 环境下测试。
public final class ImageCache<Value> {
    public struct Entry {
        public let value: Value
        public let byteCount: Int
    }

    private var storage: [String: Entry] = [:]
    private var order: [String] = []
    public let limitBytes: Int
    public private(set) var hitCount = 0
    public private(set) var missCount = 0

    public init(limitBytes: Int = PerformanceBudget.maxImageCacheBytes) {
        self.limitBytes = limitBytes
    }

    public var currentBytes: Int { storage.values.reduce(0) { $0 + $1.byteCount } }
    public var count: Int { storage.count }

    public func value(for key: String) -> Value? {
        guard let entry = storage[key] else {
            missCount += 1
            return nil
        }
        hitCount += 1
        touch(key)
        return entry.value
    }

    public func insert(_ value: Value, byteCount: Int, for key: String) {
        guard byteCount <= limitBytes else {
            // 单张超限：不缓存，避免为一个图标撑爆预算
            remove(key)
            return
        }
        storage[key] = Entry(value: value, byteCount: byteCount)
        touch(key)
        evictIfNeeded()
    }

    public func remove(_ key: String) {
        storage[key] = nil
        order.removeAll { $0 == key }
    }

    /// 收到系统内存警告时调用
    public func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        order.removeAll(keepingCapacity: keepingCapacity)
    }

    public var hitRate: Double {
        let total = hitCount + missCount
        return total == 0 ? 0 : Double(hitCount) / Double(total)
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    private func evictIfNeeded() {
        while currentBytes > limitBytes, let oldest = order.first {
            remove(oldest)
        }
    }
}
