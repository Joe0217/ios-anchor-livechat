import Foundation
import Network
import CoreTelephony
import os

private let logger = Logger(subsystem: "com.hilly.anchor", category: "SystemNetworkMonitor")

/// 系统级网络状态监控器（补充声网 RTC 质量监控）。
///
/// **监控内容**：
/// - 网络连接类型（WiFi / 蜂窝 / 无网络）
/// - 蜂窝网络制式（4G / 5G / 3G）
/// - 网络路径状态（是否昂贵 / 是否受限）
///
/// **与声网监控的区别**：
/// - 声网监控：RTC 层面的**端到端质量**（丢包率、延迟等）
/// - 系统监控：设备层面的**网络连接状态**（WiFi/4G、信号强度等）
///
/// **使用场景**：
/// - 在埋点中补充系统网络信息，帮助分析弱网原因
/// - 例如：是 WiFi 信号差，还是蜂窝网络覆盖不好
@MainActor
final class SystemNetworkMonitor {
    /// 网络路径监控器
    private let pathMonitor = NWPathMonitor()
    private let monitorQueue = DispatchQueue(label: "com.hilly.network.monitor")

    /// 蜂窝网络信息
    private let telephonyInfo = CTTelephonyNetworkInfo()

    /// 当前网络状态
    private(set) var currentNetworkType: String = "unknown"
    private(set) var currentRadioTech: String = "unknown"
    private(set) var isExpensive: Bool = false
    private(set) var isConstrained: Bool = false

    init() {
        startMonitoring()
    }

    deinit {
        pathMonitor.cancel()
    }

    /// 开始监控网络状态
    private func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.updateNetworkState(path: path)
            }
        }
        pathMonitor.start(queue: monitorQueue)
    }

    /// 更新网络状态
    private func updateNetworkState(path: NWPath) {
        // 网络连接类型
        if path.usesInterfaceType(.wifi) {
            currentNetworkType = "wifi"
        } else if path.usesInterfaceType(.cellular) {
            currentNetworkType = "cellular"
            // 获取蜂窝网络制式
            updateRadioTech()
        } else if path.usesInterfaceType(.wiredEthernet) {
            currentNetworkType = "ethernet"
        } else {
            currentNetworkType = "none"
        }

        // 网络路径特性
        isExpensive = path.isExpensive  // 蜂窝网络通常为 true
        isConstrained = path.isConstrained  // 低数据模式

        logger.debug("[SystemNetwork] type=\(self.currentNetworkType) radio=\(self.currentRadioTech) expensive=\(self.isExpensive) constrained=\(self.isConstrained)")
    }

    /// 更新蜂窝网络制式（4G/5G/3G）
    private func updateRadioTech() {
        // iOS 12+ 使用 serviceCurrentRadioAccessTechnology
        if let radioTechDict = telephonyInfo.serviceCurrentRadioAccessTechnology,
           let firstRadioTech = radioTechDict.values.first {
            currentRadioTech = mapRadioTech(firstRadioTech)
        } else {
            currentRadioTech = "unknown"
        }
    }

    /// 映射蜂窝网络制式到可读字符串
    private func mapRadioTech(_ tech: String) -> String {
        switch tech {
        // 5G
        case CTRadioAccessTechnologyNRNSA, CTRadioAccessTechnologyNR:
            return "5G"
        // 4G LTE
        case CTRadioAccessTechnologyLTE:
            return "4G"
        // 3G
        case CTRadioAccessTechnologyWCDMA,
             CTRadioAccessTechnologyHSDPA,
             CTRadioAccessTechnologyHSUPA,
             CTRadioAccessTechnologyCDMA1x,
             CTRadioAccessTechnologyCDMAEVDORev0,
             CTRadioAccessTechnologyCDMAEVDORevA,
             CTRadioAccessTechnologyCDMAEVDORevB,
             CTRadioAccessTechnologyeHRPD:
            return "3G"
        // 2G
        case CTRadioAccessTechnologyGPRS,
             CTRadioAccessTechnologyEdge:
            return "2G"
        default:
            return "unknown"
        }
    }

    /// 获取当前网络信息（用于埋点）
    func getNetworkProperties() -> [String: Any] {
        return [
            "network_type": currentNetworkType,
            "radio_tech": currentRadioTech,
            "is_expensive": isExpensive,
            "is_constrained": isConstrained
        ]
    }

    /// 获取网络状态摘要（用于日志）
    func getNetworkSummary() -> String {
        if currentNetworkType == "cellular" {
            return "\(currentRadioTech)(\(currentNetworkType))"
        } else {
            return currentNetworkType
        }
    }
}
