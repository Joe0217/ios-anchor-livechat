import SwiftUI

// 顶部 tab 枚举 `HomeTopTab` 抽到 `Sources/Home/HomeTopTab.swift`。本文件保留 ViewModel 业务字段。

/// Live Tab 视图模型：排行入口计数。
///
/// **已删除**：`cards` / `banner` / `notice` 硬编码 mock —— 分别交给：
/// - `LiveStreamViewModel`（卡片列表，真接口）
/// - `AppPictureStore.shared`（Banner 跨模块单例）
/// - `GiftMarqueeStore.shared`（跑马灯真接口）
@MainActor
final class LiveTabViewModel: ObservableObject {
    @Published var rankCount: String = "+100K"
}
