import Foundation

/// 图标搜索（报告 A8）：键入名称定位并激活图标。
/// 纯打分逻辑，无 UI 依赖，可完整单测。
public enum ItemSearch {
    /// 匹配得分：0 表示不匹配。分值语义：
    /// 前缀 > 全词前缀 > 子串 > 模糊子序列；得分相近时由调用方按使用频次兜底排序。
    public static func score(query: String, title: String) -> Int {
        let q = normalize(query)
        let t = normalize(title)
        guard !q.isEmpty else { return 0 }
        guard !t.isEmpty else { return 0 }

        if t == q { return 1000 }
        if t.hasPrefix(q) { return 800 }

        // 按非字母数字切词后逐词前缀匹配（"微信" / "WeChat" / "wechat_drive" 等场景）
        let tokens = t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        if tokens.contains(where: { $0.hasPrefix(q) }) { return 650 }
        if t.contains(q) { return 500 }

        // 模糊子序列：要求字符顺序一致，命中即给分，惩罚跳字
        var cursor = t.startIndex
        var matched = 0
        var gaps = 0
        for ch in q {
            guard let found = t[cursor...].firstIndex(of: ch) else { return 0 }
            if found != cursor { gaps += 1 }
            matched += 1
            cursor = t.index(after: found)
        }
        guard matched == q.count else { return 0 }
        return max(50, 300 - gaps * 20)
    }

    public static func rank<Item>(
        _ items: [Item],
        query: String,
        title: (Item) -> String,
        usageCount: (Item) -> Int = { _ in 0 }
    ) -> [Item] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        return items
            .compactMap { item -> (Int, Int, Item)? in
                let s = score(query: query, title: title(item))
                return s > 0 ? (s, usageCount(item), item) : nil
            }
            .sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return title(lhs.2) < title(rhs.2)
            }
            .map(\.2)
    }

    /// 归一化：去空白、转小写；中文无需分词，直接按字符匹配即可
    private static func normalize(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: " ", with: "")
    }
}
