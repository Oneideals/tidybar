import AppKit

public enum DiagnosticExporter {
    public static func generateDiagnosticReport(controller: TidyBarController) -> String {
        var sections: [String] = []

        // 1. 系统与硬件环境
        let processInfo = ProcessInfo.processInfo
        let osVersion = processInfo.operatingSystemVersionString
        let arch = {
            #if arch(arm64)
            return "Apple Silicon (arm64)"
            #elseif arch(x86_64)
            return "Intel (x86_64)"
            #else
            return "Unknown"
            #endif
        }()
        let hostName = processInfo.hostName
        let screens = NSScreen.screens.enumerated().map { i, screen in
            "  Screen \(i): frame=\(screen.frame), visible=\(screen.visibleFrame)"
        }.joined(separator: "\n")

        sections.append("""
        === [1. 系统与硬件环境] ===
        macOS 版本: \(osVersion)
        系统架构: \(arch)
        主机标识: \(hostName)
        显示器状态:
        \(screens)
        """)

        // 2. TidyBar 应用版本与权限状态
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        let bundleID = bundle.bundleIdentifier ?? "com.oneideals.tidybar"
        let axTrusted = AXIsProcessTrusted()
        let memoryBytes = ResourceProbe.residentMemoryBytes()
        let memoryMB = Double(memoryBytes) / 1_048_576.0

        sections.append("""
        === [2. TidyBar 运行环境与权限] ===
        应用版本: v\(appVersion) (Build \(buildNumber))
        Bundle ID: \(bundleID)
        辅助功能权限 (Accessibility): \(axTrusted ? "已授予 (Trusted) ✓" : "未授予 (Untrusted) ✗")
        当前常驻物理内存 (phys_footprint): \(String(format: "%.2f MB", memoryMB))
        接管能力状态: \(controller.capability.displayName)
        """)

        // 3. 当前配置摘要 (AppSettings)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let settingsJSON = (try? encoder.encode(controller.settings)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        sections.append("""
        === [3. 用户偏好设置 (AppSettings)] ===
        \(settingsJSON)
        """)

        // 4. 当前菜单栏状态项快照
        let snapshot = controller.snapshot
        let itemsList = snapshot.items.enumerated().map { i, item in
            let zone = controller.layoutEngine.layout.zone(of: item.id) ?? .visible
            return "  [\(i)] id='\(item.id)' title='\(item.title)' owner='\(item.ownerBundleID ?? "none")' zone=\(zone) frame=\(item.frame)"
        }.joined(separator: "\n")

        sections.append("""
        === [4. 菜单栏状态项快照 (\(snapshot.items.count) 项)] ===
        \(itemsList.isEmpty ? "  (无状态项)" : itemsList)
        """)

        // 5. 最近系统日志
        let logs = controller.logs.joined(separator: "\n")
        sections.append("""
        === [5. 最近运行时事件日志] ===
        \(logs.isEmpty ? "  (暂无日志)" : logs)
        """)

        return sections.joined(separator: "\n\n")
    }

    /// 导出诊断报告文件到指定或默认路径，并展示在 Finder 中
    @MainActor
    public static func exportDiagnostics(controller: TidyBarController, presentingWindow: NSWindow? = nil) {
        let report = generateDiagnosticReport(controller: controller)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let defaultFileName = "TidyBar-Diagnostics-\(timestamp).txt"

        let savePanel = NSSavePanel()
        savePanel.nameFieldStringValue = defaultFileName
        savePanel.canCreateDirectories = true
        savePanel.title = L10n.tr("导出 TidyBar 系统诊断报告", "Export TidyBar Diagnostics")
        savePanel.message = L10n.tr("诊断报告包含系统环境与菜单栏布局快照，不含任何个人隐私数据。", "Diagnostic report contains system environment and layout snapshot, zero personal private data.")

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = savePanel.url else { return }
            do {
                try report.write(to: url, atomically: true, encoding: .utf8)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSLog("TidyBar: 导出诊断报告失败: \(error)")
            }
        }

        if let window = presentingWindow {
            savePanel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            let res = savePanel.runModal()
            completion(res)
        }
    }

    /// 打开 GitHub Issues 提交页面
    public static func openGitHubIssue() {
        let issueURLString = "https://github.com/Oneideals/tidybar/issues/new?template=bug_report.md"
        if let url = URL(string: issueURLString) {
            NSWorkspace.shared.open(url)
        }
    }

    /// 打开本地或线上隐私政策
    public static func openPrivacyPolicy() {
        let privacyURL = "https://github.com/Oneideals/tidybar/blob/main/PRIVACY.md"
        if let url = URL(string: privacyURL) {
            NSWorkspace.shared.open(url)
        }
    }
}
