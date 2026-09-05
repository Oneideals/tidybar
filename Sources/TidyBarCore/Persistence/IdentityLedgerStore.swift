import Foundation

/// 台账落盘。独立文件、原子写、读不懂就当没有。
///
/// 为什么不塞进 `AppSettings`：它是合成 `Codable`，加一个存储字段会让老用户已存的设置
/// 解码失败，而 `load()` 里的 `try?` 会把失败静默变成"返回默认值"——
/// 用户看到的是"我更新了一下工具，收纳设置全没了"。
public struct IdentityLedgerStore {
    public let url: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(url: URL) {
        self.url = url
    }

    /// 读不出来（缺文件、半截写、旧版本格式）一律按空台账处理：
    /// 保守的代价是"这次没帮上忙"，激进的代价是把用户的设置接错人。
    public func load() -> [IdentityRecord] {
        guard let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([IdentityRecord].self, from: data) else { return [] }
        return records
    }

    public func save(_ records: [IdentityRecord]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: url, options: .atomic)
    }
}
