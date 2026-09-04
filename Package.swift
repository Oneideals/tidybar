// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TidyBar",
    platforms: [
        // 与 Ice 同策略：只支持新系统，用新 API 换可靠性（见 docs/软件开发计划.md §4.1）
        .macOS(.v14)
    ],
    products: [
        .executable(name: "tidybar", targets: ["TidyBar"]),
        .executable(name: "tidybar-checks", targets: ["TidyBarChecks"]),
        .library(name: "TidyBarCore", targets: ["TidyBarCore"]),
        .executable(name: "tidybar-probe", targets: ["TidyBarProbe"]),
        .executable(name: "tidybar-attr-dump", targets: ["TidyBarAttrDump"]),
    ],
    targets: [
        // 薄入口层：仅负责 NSApplication 启动与生命周期装配
        .executableTarget(
            name: "TidyBar",
            dependencies: ["TidyBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 全部逻辑放在库里，公开接口即测试面
        .target(
            name: "TidyBarCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // M0 探索工具：dump 子项的全部 AX 属性名与取值（找稳定标识用）
        .executableTarget(
            name: "TidyBarAttrDump",
            dependencies: ["TidyBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // M0 真机探针：枚举结果 / 耗时 / 覆盖率 / 坐标自检
        .executableTarget(
            name: "TidyBarProbe",
            dependencies: ["TidyBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // 回归用例：零依赖 runner（详见 Sources/TidyBarChecks/Harness.swift 顶部说明）
        .executableTarget(
            name: "TidyBarChecks",
            dependencies: ["TidyBarCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
