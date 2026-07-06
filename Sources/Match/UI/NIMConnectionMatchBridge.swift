import Combine
import Foundation

/// U4：NIMService.$connectionState → MatchStore.handleIMOffline 桥接。
///
/// **在 UI/ 层**：本 bridge 引 `NIMService.shared` + NIMConnectionState 具体类型（依赖 NIMSDK），
/// 不入 test target 独立 module。
///
/// 触发条件：`connectionState = .disconnected / .idle` → 发一次 Void 事件；MatchStore 在 .matching 时关匹配。
/// **不发** `.connecting`（重连中不算掉线，避免抖动误关）。
@MainActor
enum NIMConnectionMatchBridge {

    /// 发出 IM 掉线（disconnected/idle）事件的 publisher。
    static var disconnectedPublisher: AnyPublisher<Void, Never> {
        NIMService.shared.$connectionState
            .compactMap { state -> Void? in
                (state == .disconnected || state == .idle) ? () : nil
            }
            .dropFirst()  // 跳过冷启动 .idle 初始值
            .eraseToAnyPublisher()
    }
}
