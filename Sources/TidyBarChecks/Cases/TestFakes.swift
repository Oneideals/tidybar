import Foundation
import CoreGraphics
import TidyBarCore

// MARK: - 测试替身：把系统能力挡在协议边界外，保证逻辑可离线验证

final class FakeMenuBarReader: MenuBarReading {
    var items: [ManagedItem]
    private(set) var discoverCallCount = 0

    init(items: [ManagedItem] = []) {
        self.items = items
    }

    /// 便捷构造：只给 id 列表，图标统一 24pt 见方、中心与 FakeCursor 默认位置对齐，
    /// 这样「干净执行」路径无需在每道题里重算坐标。
    convenience init(ids: [String], centerX: CGFloat = 600, centerY: CGFloat = 1_188) {
        self.init(items: ids.map { TestItems.item($0, centerX: centerX, centerY: centerY) })
    }

    func discoverItems() -> [ManagedItem] {
        discoverCallCount += 1
        return items
    }
}

final class FakeMenuBarMover: MenuBarMoving {
    /// 真实落点（哨兵复核对象）；默认等于请求的目标位置，模拟干净执行
    var landingY: CGFloat = 1_188
    var injectedError: MenuBarMoveError?
    private(set) var moved: [(itemID: String, x: CGFloat)] = []

    init(landingY: CGFloat = 1_188) {
        self.landingY = landingY
    }

    func move(itemID: String, toX targetX: CGFloat) throws -> CGPoint {
        if let injectedError { throw injectedError }
        moved.append((itemID, targetX))
        return CGPoint(x: targetX, y: landingY)
    }
}

final class FakeCursor: CursorReading {
    var currentLocation: CGPoint
    var isPrimaryButtonPressed: Bool

    init(location: CGPoint = CGPoint(x: 600, y: 1_188), pressed: Bool = false) {
        currentLocation = location
        isPrimaryButtonPressed = pressed
    }
}

final class FakeTrust: AccessibilityTrustReading {
    var isTrusted = true
    private(set) var requestCount = 0
    init() {}
    func requestTrust() { requestCount += 1 }
}

final class FakeScreens: ScreenObserving {
    var screens: [ScreenInfo]
    var primaryScreen: ScreenInfo? { screens.first }
    var notifications = 0

    init(notchWidth: CGFloat? = nil, screenFrame: CGRect = CGRect(x: 0, y: 0, width: 1_440, height: 900), menuBarHeight: CGFloat = 24) {
        screens = [
            ScreenInfo(
                identifier: 1,
                frame: screenFrame,
                menuBarHeight: menuBarHeight,
                notchWidth: notchWidth,
                isBuiltin: true
            )
        ]
    }

    func addObserver(_ observer: @escaping @Sendable () -> Void) {
        notifications += 1
        observer()
    }
}

final class FakeSettingsStore: SettingsStoring {
    private(set) var stored: AppSettings?
    private let initial: AppSettings

    init(_ initial: AppSettings = AppSettings()) {
        self.initial = initial
    }

    func load() -> AppSettings { stored ?? initial }
    func save(_ settings: AppSettings) { stored = settings }
}

enum TestPaths {
    /// 每个用例独立目录，避免日志互相污染
    static func journalDirectory(_ label: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tidybar-tests", isDirectory: true)
            .appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

enum TestItems {
    /// 构造一个位于菜单栏带内的图标
    static func item(
        _ id: String,
        centerX: CGFloat = 600,
        centerY: CGFloat = 1_188,
        side: CGFloat = 24,
        isSystemOwned: Bool = false
    ) -> ManagedItem {
        ManagedItem(
            id: id,
            ownerBundleID: "com.test.\(id)",
            title: id,
            frame: CGRect(x: centerX - side / 2, y: centerY - side / 2, width: side, height: side),
            isSystemOwned: isSystemOwned
        )
    }
}

func makeServices(
    reader: MenuBarReading = FakeMenuBarReader(ids: []),
    mover: MenuBarMoving? = FakeMenuBarMover(),
    cursor: CursorReading = FakeCursor(),
    screens: ScreenObserving = FakeScreens()
) -> SystemServices {
    SystemServices(
        reader: reader,
        mover: mover,
        cursor: cursor,
        accessibility: FakeTrust(),
        screens: screens
    )
}

func fixedCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    return calendar
}

/// 固定的测试时间工厂。星期相关断言一律走 onWeekday/onWeekend，
/// 不依赖「某年某月某日是周几」这类记忆，避免日历假设出错。
enum TestDates {
    static func at(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return fixedCalendar().date(from: components)!
    }

    /// weekday: 1 = 周日 ... 7 = 周六（Calendar.component(.weekday)）
    static func on(weekday target: Int, hour: Int = 11, minute: Int = 0) -> Date {
        var day = at(2026, 1, 1, hour, minute)
        for _ in 0..<14 {
            if fixedCalendar().component(.weekday, from: day) == target { return day }
            day = fixedCalendar().date(byAdding: .day, value: 1, to: day)!
        }
        fatalError("未能在两周内找到目标星期，测试夹具异常")
    }

    static func onWeekday(hour: Int = 11, minute: Int = 0) -> Date { on(weekday: 2, hour: hour, minute: minute) }
    static func onWeekend(hour: Int = 11, minute: Int = 0) -> Date { on(weekday: 7, hour: hour, minute: minute) }
}
