import Foundation
import AppKit
import IOKit.ps
import CoreWLAN

/// 系统上下文提供者协议：为规则引擎提供当前硬件与环境快照。
public protocol SystemContextProviding: Sendable {
    func currentContext() -> SystemContext
}

/// 真实环境下的系统上下文采集器。
///
/// 硬件读取遵循以下设计契约：
/// 1. 零第三方依赖；
/// 2. 纯 C / 系统级只读 API（IOKit.ps），无弹窗、不申请多余隐私权限；
/// 3. 台式 Mac（Mac mini / Studio / Mac Pro / iMac 无内置电池）安全返回 nil，不误触发电量规则；
/// 4. 采集耗时 < 1ms，可在规则求值时同步调用。
public struct LiveSystemContextProvider: SystemContextProviding {
    public init() {}

    public func currentContext() -> SystemContext {
        let (battery, charging) = readBatteryState()
        let wifi = readWiFiState()
        let frontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        return SystemContext(
            batteryLevel: battery,
            isCharging: charging,
            connectedWiFiSSID: wifi.ssid,
            activeFocusMode: nil,
            frontmostAppBundleID: frontmost,
            now: Date(),
            calendar: .current,
            hasKnownWiFiState: wifi.known
        )
    }

    private func readWiFiState() -> (ssid: String?, known: Bool) {
        guard let interface = CWWiFiClient.shared().interface() else { return (nil, false) }
        if !interface.powerOn() { return (nil, true) }
        if let ssid = interface.ssid() { return (ssid, true) }
        // 新版 macOS 可能隐去 SSID；不申请权限，也不把隐去误判为断网。
        return (nil, false)
    }

    private func readBatteryState() -> (level: Double?, isCharging: Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return (nil, false)
        }
        guard let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (nil, false)
        }
        for ps in sources {
            guard let desc = IOPSGetPowerSourceDescription(snapshot, ps)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            if let isPresent = desc[kIOPSIsPresentKey] as? Bool, !isPresent {
                continue
            }
            let isCharging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            if let current = desc[kIOPSCurrentCapacityKey] as? Int,
               let max = desc[kIOPSMaxCapacityKey] as? Int, max > 0 {
                let level = Double(current) / Double(max)
                return (level, isCharging)
            }
        }
        return (nil, false)
    }
}
