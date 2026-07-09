import Foundation
import Combine

/// H-3 回复积分配置派生 bridge（对齐 H5 `chatStore.paidMessagePoints / freeMessagePoints`）。
///
/// **暴露 3 字段**：
/// - `payMsgPoints: Int?` — 用户付费消息单条积分
/// - `freeMsgPoints: Int?` — 用户免费消息单条积分
/// - `isLoaded: Bool` — 与 AppConfigStore.isLoaded 一致（用于 ReplyPointsStore 判"未 loaded 时不累加"）
///
/// **兜底**（rule async-state-fallback）：未 loaded 时 payMsgPoints/freeMsgPoints 保 nil；
/// ReplyPointsStore.onReceiveUserMsg 检测 nil 时**不累加进度**（下次 loaded 后重刷）。
///
/// **rule swiftui-keepalive-publisher-isolation**：不订阅 AppConfigStore 全部字段。
@MainActor
final class ReplyPointsConfigBridge: ObservableObject, ReplyPointsConfigBridging {
    @Published private(set) var payMsgPoints: Int?
    @Published private(set) var freeMsgPoints: Int?
    @Published private(set) var isLoaded: Bool = false

    init(config: AppConfigStore = .shared) {
        let source = Publishers.CombineLatest3(
            config.$payMsgPoints,
            config.$freeMsgPoints,
            config.$isLoaded
        )

        source
            .map { pay, _, _ in pay }
            .removeDuplicates()
            .assign(to: &$payMsgPoints)

        source
            .map { _, free, _ in free }
            .removeDuplicates()
            .assign(to: &$freeMsgPoints)

        source
            .map { _, _, loaded in loaded }
            .removeDuplicates()
            .assign(to: &$isLoaded)
    }
}
