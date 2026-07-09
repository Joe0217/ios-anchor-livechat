import Foundation
import Combine

/// H-3 视频通话权限派生 bridge（对齐 H5 `user.js:52-56` `anchortCallAuth`）。
///
/// **判定语义**（对齐 H5 `_auth.includes(state.myAnchorInfo.userLevel)`）：
/// - `achorHideButton` 是后端逗号/字符串拼接的段位白名单（如 `"S1S2SS"`）
/// - `mine.levelName` 是主播段位名字符串（如 `"S1"` / `"SS"` / `"NEW"`）；iOS 现有字段名 `levelName`，语义 == H5 `userLevel`
/// - `canCall` = `achorHideButton.contains(levelName)`（**子串匹配**，非 exact match）
///
/// **兜底策略**（rule async-state-fallback）：
/// - `AppConfigStore.isLoaded == false` → `canCall = false`（安全隐藏，避免 flash 允许通话）
/// - `achorHideButton == nil || .isEmpty` → `canCall = false`
/// - `mine.levelName == nil || .isEmpty` → `canCall = false`
///
/// **为何是 bridge**（rule swiftui-keepalive-publisher-isolation）：
/// `AppConfigStore` 是大单例含多个 @Published 字段；ChatDetailView 在 keep-alive tab 内，
/// 直接 `@ObservedObject config` 会因 payMsgPoints 更新等无关字段导致 body 重算。
/// Bridge 只暴露 `canCall / isLoaded` 两字段 + `removeDuplicates` 拦截无变化，view 只订阅 bridge。
@MainActor
final class CallAuthBridge: ObservableObject {
    @Published private(set) var canCall: Bool = false
    @Published private(set) var isLoaded: Bool = false

    init(config: AppConfigStore = .shared, anchor: AnchorInfoStore = .shared) {
        let source = Publishers.CombineLatest3(
            config.$achorHideButton,
            anchor.$mine,
            config.$isLoaded
        )

        source
            .map { _, _, loaded in loaded }
            .removeDuplicates()
            .assign(to: &$isLoaded)

        source
            .map { auth, mine, loaded in
                // 对齐 rule async-state-fallback：levelName 为空时从 level 数字派生兜底
                // H5 `myAnchorInfo.userLevel` 是段位字符串（"S"/"SS"/"NEW"...）；iOS 后端可能只返 level 数字（level=5→"S", 6→"SS"）
                let name = Self.effectiveLevelName(levelName: mine?.levelName, level: mine?.level)
                return CallAuthLogic.canCall(achorHideButton: auth, levelName: name, isLoaded: loaded)
            }
            .removeDuplicates()
            .assign(to: &$canCall)
    }

    /// levelName 优先 → level 数字 fallback → nil
    private static func effectiveLevelName(levelName: String?, level: Int?) -> String? {
        if let n = levelName, !n.isEmpty { return n }
        if let lvl = level { return AnchorInfoStore.tierName(forLevel: lvl) }
        return nil
    }
}
