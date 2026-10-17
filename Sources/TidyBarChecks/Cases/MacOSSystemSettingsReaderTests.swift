import Foundation
import TidyBarCore

// MARK: - macOS 27 系统设置已隐藏应用感知与豁免测试

struct MacOSSystemSettingsReaderTests {
    /// 验证二进制 Plist 数据中的 trackedApplications 解析
    func parsingTrackedApplicationsData() throws {
        let innerList: [[String: Any]] = [
            [
                "location": ["bundle": ["_0": "com.test.allowedApp"]],
                "menuItemLocations": [["bundle": ["_0": "com.test.allowedApp"]]],
                "isAllowed": true
            ],
            [
                "location": ["bundle": ["_0": "com.test.disallowedApp"]],
                "menuItemLocations": [["bundle": ["_0": "com.test.disallowedHelper"]]],
                "isAllowed": false
            ],
            [
                // 没有 isAllowed 的注册桩，应被静默过滤
                "bundle": ["_0": "com.test.stubOnly"]
            ]
        ]

        let innerData = try PropertyListSerialization.data(fromPropertyList: innerList, format: .binary, options: 0)
        let rootDict: [String: Any] = ["trackedApplications": innerData]
        let rootData = try PropertyListSerialization.data(fromPropertyList: rootDict, format: .binary, options: 0)

        let reader = MacOSSystemSettingsReader()
        let parsed = reader.parseEntries(from: rootData)

        expectEqual(parsed.count, 2, "纯注册桩应被过滤，仅保留有 isAllowed 状态项")
        let allowed = parsed.first { $0.bundleID == "com.test.allowedApp" }
        expect(allowed != nil, "必须解析到 allowedApp")
        expectEqual(allowed?.isAllowed, true)

        let disallowed = parsed.first { $0.bundleID == "com.test.disallowedApp" }
        expect(disallowed != nil, "必须解析到 disallowedApp")
        expectEqual(disallowed?.isAllowed, false)
        expectEqual(disallowed?.secondaryBundleIDs, ["com.test.disallowedHelper"])
    }

    /// 验证 systemHiddenBundleIDs 及大小写不敏感判断
    func systemHiddenBundleIDsFiltering() throws {
        let innerList: [[String: Any]] = [
            [
                "location": ["bundle": ["_0": "com.example.one"]],
                "isAllowed": true
            ],
            [
                "location": ["bundle": ["_0": "com.example.hidden"]],
                "menuItemLocations": [["bundle": ["_0": "com.example.hidden.helper"]]],
                "isAllowed": false
            ]
        ]
        let innerData = try PropertyListSerialization.data(fromPropertyList: innerList, format: .binary, options: 0)
        let rootDict: [String: Any] = ["trackedApplications": innerData]
        let rootData = try PropertyListSerialization.data(fromPropertyList: rootDict, format: .binary, options: 0)

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_controlcenter_\(UUID().uuidString).plist")
        try rootData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let reader = MacOSSystemSettingsReader(customPlistURL: tempURL)
        let hiddenIDs = reader.systemHiddenBundleIDs()

        expect(hiddenIDs.contains("com.example.hidden"), "主 Bundle ID 必须在隐藏集合中")
        expect(hiddenIDs.contains("com.example.hidden.helper"), "伴随 Helper 必须在隐藏集合中")
        expect(!hiddenIDs.contains("com.example.one"), "允许的 App 严禁进入隐藏集合")

        expect(reader.isAppHiddenBySystem(bundleID: "com.example.hidden"))
        expect(reader.isAppHiddenBySystem(bundleID: "COM.EXAMPLE.HIDDEN"), "判断必须支持大小写宽容匹配")
        expect(reader.isAppHiddenBySystem(bundleID: "com.example.hidden.helper"))
        expect(!reader.isAppHiddenBySystem(bundleID: "com.example.one"))
    }

    /// 验证 TidyBarController 对系统设置已隐藏 App 的自动豁免（不进入 assignableItems / drawerItems / visibleItems）
    func tidyBarControllerExemptsSystemHiddenApp() throws {
        let fakeReader = FakeSystemSettingsReader(
            trackedApps: [
                SystemTrackedApp(bundleID: "com.test.systemDisabled", secondaryBundleIDs: ["com.test.systemDisabledHelper"], displayName: "Disabled App", isAllowed: false),
                SystemTrackedApp(bundleID: "com.test.normalApp", displayName: "Normal App", isAllowed: true)
            ],
            hiddenBundleIDs: ["com.test.systemdisabled", "com.test.systemdisabledhelper"]
        )

        let itemDisabled = TestItems.item("com.test.systemDisabled", centerX: 300, centerY: 1_188)
        let itemNormal = TestItems.item("com.test.normalApp", centerX: 400, centerY: 1_188)

        let reader = FakeMenuBarReader(items: [itemDisabled, itemNormal])
        let engine = LayoutEngine(
            layout: MenuBarLayout(),
            services: makeServices(reader: reader, mover: UnverifiedMenuBarMover()),
            journal: LayoutJournal(directory: TestPaths.journalDirectory("sys-exempt"))
        )
        let controller = TidyBarController(
            engine: engine,
            reveal: RevealStateMachine(rehideDelay: 2),
            settings: AppSettings(),
            store: FakeSettingsStore()
        )
        controller.systemSettingsReader = fakeReader
        controller.start(scansSynchronously: true)

        let assignableIDs = controller.assignableItems.map(\.id)
        expect(!assignableIDs.contains("com.test.systemDisabled"), "被系统设置隐藏的应用必须被 TidyBar 自动豁免，严禁进入 assignableItems")
        expect(assignableIDs.contains("com.test.normalApp"), "正常应用必须保留在 assignableItems")

        let drawerIDs = controller.drawerItems.map(\.id)
        expect(!drawerIDs.contains("com.test.systemDisabled"), "被系统隐藏的应用严禁进入抽屉")

        let visibleIDs = controller.visibleItems.map(\.id)
        expect(!visibleIDs.contains("com.test.systemDisabled"), "被系统隐藏的应用严禁进入常显区")

        let overviewRows = IconOverviewBuilder.rows(from: controller)
        expect(!overviewRows.contains(where: { $0.item.id == "com.test.systemDisabled" }), "总览三行拟态托盘不呈现被系统设置已禁用的 App")
    }

    /// 验证真实系统偏好读取（如当前 macOS 存在该文件，验证其健壮解析不崩溃）
    func liveSystemPlistSmokeTest() throws {
        let reader = MacOSSystemSettingsReader.shared
        let apps = reader.readTrackedApplications()
        // 只要读取不崩溃即符合健壮性要求；若有读取项，验证 BundleID 格式健全
        for app in apps {
            expect(!app.bundleID.isEmpty, "BundleID 不能为空")
            expect(!app.displayName.isEmpty, "应用显示名不能为空")
        }
    }
}

extension MacOSSystemSettingsReaderTests {
    static var testCases: [TestCase] {
        let suite = MacOSSystemSettingsReaderTests()
        return [
            TestCase("parsingTrackedApplicationsData", suite.parsingTrackedApplicationsData),
            TestCase("systemHiddenBundleIDsFiltering", suite.systemHiddenBundleIDsFiltering),
            TestCase("tidyBarControllerExemptsSystemHiddenApp", suite.tidyBarControllerExemptsSystemHiddenApp),
            TestCase("liveSystemPlistSmokeTest", suite.liveSystemPlistSmokeTest),
        ]
    }
}
