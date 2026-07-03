import Foundation

/// Circle (朋友圈) 内部 3 个子 tab。
///
/// 对应 H5 `src/views/circle/topTabList.ts` 的 `official / moment / me`，
/// 以及后端 `officalType` 编码：
/// - `.official` ≡ 后端 `officalType = 1`（官方圈）
/// - `.moment`   ≡ 后端 `officalType = 2`（**全站圈**，不是"我的"）
/// - `.me`       ≡ 后端 `officalType = 3`（我的）
///
/// trial #1 (A-spec §2.1) 初始选中 `.official` 对齐 H5 `circle/index.vue:25 tabActive='official'`。
/// trial #1 范围内仅 `.moment` 子 tab 接真实业务（读 + 乐观点赞成功路径）；
/// `.official` / `.me` 是 placeholder。
///
/// 纯枚举 + `officalType` 编码，**零 L10n / SwiftUI 依赖** —— label 在 `CircleSubTab+Label.swift`。
enum CircleSubTab: CaseIterable, Hashable {
    case official, moment, me

    /// 后端 `officalType` 数字编码。
    var officalType: Int {
        switch self {
        case .official: return 1
        case .moment:   return 2
        case .me:       return 3
        }
    }
}
