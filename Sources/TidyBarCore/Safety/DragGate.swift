import Foundation
import IOKit

/// 拖拽接管的"已确认名单"：只有**这台机器 + 这个系统版本**真跑过闸门，才允许真实搬动图标。
///
/// 为什么不写成常量、也不塞进 AppSettings：
///   · 常量一翻就等于对所有 macOS 26 用户宣布"我们验过了"，而实测只覆盖了一台机器一个版本；
///   · AppSettings 是合成 Codable，加字段会让老用户已存设置解码失败并被静默重置。
/// 所以单独一个文件，内容是一条条带版本与机器指纹的确认记录。
public struct DragConfirmation: Codable, Equatable, Sendable {
    public let osVersion: String
    public let machineID: String
    public let rounds: Int
    public let confirmedAt: Date

    public init(osVersion: String, machineID: String, rounds: Int, confirmedAt: Date) {
        self.osVersion = osVersion
        self.machineID = machineID
        self.rounds = rounds
        self.confirmedAt = confirmedAt
    }
}

public struct DragGate: Codable, Sendable {
    public var confirmations: [DragConfirmation]

    public init(confirmations: [DragConfirmation] = []) {
        self.confirmations = confirmations
    }

    /// 名单里是否有**完全匹配当前机器与系统版本**的记录。
    /// 版本要精确到小版本：26.6 与 26.6.2 在我们这儿不是同一个人（Tahoe 的小版本就改过事件行为）。
    public func allowsTakeover(os: String, machine: String) -> Bool {
        confirmations.contains { $0.osVersion == os && $0.machineID == machine }
    }

    public mutating func record(_ confirmation: DragConfirmation) {
        confirmations.removeAll { $0.osVersion == confirmation.osVersion && $0.machineID == confirmation.machineID }
        confirmations.append(confirmation)
    }
}

/// JSON 落盘。原子写，坏文件按空名单处理（宁可退回降级模式，也不要因为读不懂就当作"已确认"）。
public struct DragGateStore {
    public let url: URL
    public init(url: URL) {
        self.url = url
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    /// 读不出来就返回空名单——**宁可退回降级模式，也不能因为解码失败就当作"已确认"**。
    public func load() -> DragGate {
        guard let data = try? Data(contentsOf: url),
              let gate = try? decoder.decode(DragGate.self, from: data) else { return DragGate() }
        return gate
    }

    public func save(_ gate: DragGate) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(gate).write(to: url, options: .atomic)
    }
}

/// 机器指纹：优先硬件 UUID（重装系统不变），拿不到才退回主机名（并在版本串里注明是退化值，
/// 免得"改了主机名=换了台机器"这种误判把接管权限带过去）。
public enum MachineIdentity {
    public static func hardwareID() -> String {
        if let platform = platformUUID() { return "hw:" + platform }
        // 退化路径要在值里留痕：主机名可被用户改掉，不能让它成为接管权限的通行证
        return "host:" + ProcessInfo.processInfo.hostName
    }

    public static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }
}

private func platformUUID() -> String? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    guard let cf = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0) else {
        return nil
    }
    return cf.takeRetainedValue() as? String
}
