import SwiftUI

/// H-3 ChatType EnvironmentKey 注入（spec §3.2 / §4.2.2）。
///
/// ChatDetailContainer 从 NIMSession.ext / 用户资料解析后通过 `.environment(\.chatType, ...)` 注入；
/// 子 view（ChatInputBar / BottomActionBar）用 `@Environment(\.chatType)` 消费。
///
/// **拆分原因**：`EnvironmentKey` 是 SwiftUI 依赖；`ChatType` enum 保持纯 Foundation
/// 便于 test target 引用（对齐 `ChatMessageContent+Preview.swift` 拆分模式）。
private struct ChatTypeKey: EnvironmentKey {
    static let defaultValue: ChatType = .regular
}

extension EnvironmentValues {
    var chatType: ChatType {
        get { self[ChatTypeKey.self] }
        set { self[ChatTypeKey.self] = newValue }
    }
}
