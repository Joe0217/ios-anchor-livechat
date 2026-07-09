import Foundation
import Combine

/// H-3 消息翻译 key/area 派生 bridge（对齐 H5 `homeStore.microsoftTranslatorConfig`）。
///
/// **暴露 3 字段**给 view 层订阅：
/// - `key: String?` — 微软 API key（从 `AppConfigStore.microsoftTranslatorKey` 派生；未 loaded 时 nil）
/// - `area: String?` — 微软 API region（用作 HTTP header `Ocp-Apim-Subscription-Region`；后端字段名叫 area）
/// - `canTranslate: Bool` — `isLoaded && key != nil`；view 用它判 Translate 按钮显隐（rule async-state-fallback：未 loaded 时按钮隐藏 flash <300ms 可接受）
///
/// **rule swiftui-keepalive-publisher-isolation**：不订阅 AppConfigStore 全部字段。
@MainActor
final class TranslateConfigBridge: ObservableObject {
    @Published private(set) var key: String?
    @Published private(set) var area: String?
    @Published private(set) var canTranslate: Bool = false

    init(config: AppConfigStore = .shared) {
        let source = Publishers.CombineLatest3(
            config.$microsoftTranslatorKey,
            config.$microsoftTranslatorArea,
            config.$isLoaded
        )

        source
            .map { key, _, _ in key }
            .removeDuplicates()
            .assign(to: &$key)

        source
            .map { _, area, _ in area }
            .removeDuplicates()
            .assign(to: &$area)

        source
            .map { key, _, loaded in loaded && key != nil && !(key ?? "").isEmpty }
            .removeDuplicates()
            .assign(to: &$canTranslate)
    }
}
