import Foundation
import ServiceManagement

/// 开机自启（报告 B2）。走 `SMAppService.mainApp`，不用早已废弃的
/// `SMLoginItemSetEnabled` / 拷贝到 LoginItems 那类老办法。
///
/// 状态是**读系统**而不是记在设置里：用户在系统设置里手动改过开关之后，
/// 我们自己记的那份就成了假状态，菜单勾会与真实行为不一致。
public enum LaunchAtLogin {
    /// 失败原因要能原样递给用户：ad-hoc 签名或未打包的进程被系统拒绝注册是常见情况，
    /// 只报"失败了"等于没报。
    public struct Failure: Error, Equatable, Sendable {
        public let reason: String
    }
    public enum State: Equatable, Sendable {
        case enabled, disabled, needsApproval, unknown(String)
    }

    public static func state() -> State {
        if #available(macOS 13.0, *) {
            switch SMAppService.mainApp.status {
            case .enabled: return .enabled
            case .notRegistered, .notFound: return .disabled
            case .requiresApproval: return .needsApproval
            @unknown default: return .unknown("status changed")
            }
        }
        return .unknown("macOS < 13")
    }

    /// 返回真实结果与原因。失败不静默：ad-hoc 签名或未打包的进程注册会被系统拒绝，
    /// 那种情况下必须告诉用户为什么开关没生效。
    public static func setEnabled(_ on: Bool) -> Result<Void, Failure> {
        guard #available(macOS 13.0, *) else { return .failure(Failure(reason: "需要 macOS 13 及以上")) }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return .success(())
        } catch {
            return .failure(Failure(reason: String(describing: error)))
        }
    }
}
