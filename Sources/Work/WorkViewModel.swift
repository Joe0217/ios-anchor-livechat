import SwiftUI

/// Work（工作台）页数据源。
///
/// 当前为还原设计稿的占位数据，数值取自设计稿。后续里程碑接入真实接口时，
/// 副作用（拉取 / 刷新 / 在线态切换）收敛进此处或对应 Store，View 只读 @Published。
@MainActor
final class WorkViewModel: ObservableObject {

    // MARK: - 周等级
    @Published var avatarURL: URL?                 // 占位：暂无头像资源，渲染默认环
    @Published var weeklyLevel: String = "SS"
    @Published var score: Int = 9999
    @Published var scoreToNextLevel: Int = 999
    /// 当前等级在光谱中的进度（0…1），SS 接近满
    @Published var levelProgress: Double = 0.92

    // MARK: - 三项概览
    @Published var callsToday: Int = 128
    @Published var positiveRating: Int = 98        // 百分比
    @Published var weeklyRevenue: Int = 999999

    // MARK: - 今日收益
    @Published var callIncomes: Int = 222
    @Published var giftIncomes: Int = 1280
    @Published var taskIncomes: Int = 1280
    @Published var inviteIncomes: Int = 128
    @Published var managedIncomes: Int = 950
    @Published var totalIncomes: Int = 99999

    // MARK: - 在线开关
    @Published var isOnline: Bool = true

    /// 段位刻度（与设计稿一致）
    let tiers: [String] = ["D", "C", "NEW", "B", "A", "S", "SS"]

    func toggleOnline() {
        isOnline.toggle()
    }
}
