import Foundation

/// Home 顶部 4 tab (对应 H5 `home.js currentTabName ∈ {live,list,match,circle}`)。
///
/// L10n key 由 `live.subTab.*` 迁移到 `home.topTab.*`（label 在 `HomeTopTab+Label.swift`）。
///
/// `availableOrder` 派生逻辑入 `HomeTopTabStore` 持有，按主播段位返回不同顺序；
/// 本 enum 仅描述"有哪些 tab"。**纯枚举，零 L10n / SwiftUI 依赖** —— 便于单测注入。
enum HomeTopTab: CaseIterable, Hashable {
    case live, list, match, circle
}
