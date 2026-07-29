import Foundation

/// Phase C —— 任务中心页数据模型。对齐 H5 [`api/taskCenter/index.ts`](../../../../Desktop/HN/anchor-livechat-h5/src/api/taskCenter/index.ts) 的 VO 声明。
///
/// **decode 策略**:所有数值字段用 `decodeFlexibleInt` 兼容后端 Int/String/Double 混发;
/// 字段名严格(CodingKeys 默认);首次真机拉取后按 Console log 校准
/// (对齐 [agent-recon-field-names-unverified](.claude/rules/agent-recon-field-names-unverified.md))。

// MARK: - 周期

enum TaskCycle: String, Codable, CaseIterable, Hashable {
    case daily = "DAILY"
    case weekly = "WEEKLY"
}

// MARK: - 单档奖励(TaskCenterTierVO)

/// 单个任务的一档奖励。
/// - tierStatus: 0=未达 / 1=可领 / 2=已领
struct TaskTierVO: Codable, Hashable {
    let tier: Int
    let threshold: Int
    let rewardType: Int
    let rewardValue: Int
    let propId: Int?
    let validHours: Int?
    let tierStatus: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.tier = c.decodeFlexibleInt(forKey: .tier) ?? 0
        self.threshold = c.decodeFlexibleInt(forKey: .threshold) ?? 0
        self.rewardType = c.decodeFlexibleInt(forKey: .rewardType) ?? 0
        self.rewardValue = c.decodeFlexibleInt(forKey: .rewardValue) ?? 0
        self.propId = c.decodeFlexibleInt(forKey: .propId)
        self.validHours = c.decodeFlexibleInt(forKey: .validHours)
        self.tierStatus = c.decodeFlexibleInt(forKey: .tierStatus) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case tier, threshold, rewardType, rewardValue, propId, validHours, tierStatus
    }

    /// 可领 = 1
    var isClaimable: Bool { tierStatus == 1 }
    /// 已领 = 2
    var isClaimed: Bool { tierStatus == 2 }
    /// 未达 = 0
    var isLocked: Bool { tierStatus == 0 }
}

// MARK: - 单个任务(TaskCenterItemVO)

struct TaskItemVO: Codable, Identifiable, Hashable {
    let taskId: Int
    let taskCode: String
    let taskName: String
    let taskDesc: String?
    let taskModule: String
    let taskCycle: String
    let targetType: String
    let taskIcon: String?
    let progress: Int
    let cycleKey: String
    let tiers: [TaskTierVO]
    let hasClaimable: Bool

    var id: Int { taskId }

    /// 前端派生:是否有可领档。与 H5 同样以各档 `tierStatus` 为准，避免后端汇总字段滞后。
    var derivedHasClaimable: Bool {
        tiers.contains { $0.isClaimable }
    }

    /// H5 红点规则：存在任一未领取档位（未达或可领）即显示，全部领取后才消失。
    var derivedHasRedDot: Bool {
        tiers.contains { !$0.isClaimed }
    }

    /// 前端派生:任务当前档进度(最大 threshold 与 progress 比较);nil 表示无档
    var currentTier: TaskTierVO? {
        let sorted = tiers.sorted { $0.tier < $1.tier }
        return sorted.first { !$0.isClaimed } ?? sorted.last
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = c.decodeFlexibleInt(forKey: .taskId) ?? 0
        self.taskCode = (try? c.decodeIfPresent(String.self, forKey: .taskCode)) ?? ""
        self.taskName = (try? c.decodeIfPresent(String.self, forKey: .taskName)) ?? ""
        self.taskDesc = try? c.decodeIfPresent(String.self, forKey: .taskDesc)
        self.taskModule = (try? c.decodeIfPresent(String.self, forKey: .taskModule)) ?? ""
        self.taskCycle = (try? c.decodeIfPresent(String.self, forKey: .taskCycle)) ?? ""
        self.targetType = (try? c.decodeIfPresent(String.self, forKey: .targetType)) ?? ""
        self.taskIcon = try? c.decodeIfPresent(String.self, forKey: .taskIcon)
        self.progress = c.decodeFlexibleInt(forKey: .progress) ?? 0
        self.cycleKey = (try? c.decodeIfPresent(String.self, forKey: .cycleKey)) ?? ""
        self.tiers = (try? c.decodeIfPresent([TaskTierVO].self, forKey: .tiers)) ?? []
        // hasClaimable 后端未 Guarantee,前端 fallback 计算
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .hasClaimable) {
            self.hasClaimable = b
        } else {
            self.hasClaimable = false
        }
    }

    enum CodingKeys: String, CodingKey {
        case taskId, taskCode, taskName, taskDesc, taskModule, taskCycle
        case targetType, taskIcon, progress, cycleKey, tiers, hasClaimable
    }
}

// MARK: - 模块分组(TaskCenterModuleGroupVO)

struct TaskModuleGroupVO: Codable, Identifiable, Hashable {
    let moduleCode: String
    let moduleName: String
    let moduleSort: Int
    let tasks: [TaskItemVO]
    let moduleHasClaimable: Bool

    var id: String { moduleCode }

    /// 前端派生红点:组内任一任务存在未领取档位(H5 utils/format.ts:moduleHasRedDot 逻辑)
    var derivedHasRedDot: Bool {
        tasks.contains { $0.derivedHasRedDot }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.moduleCode = (try? c.decodeIfPresent(String.self, forKey: .moduleCode)) ?? ""
        self.moduleName = (try? c.decodeIfPresent(String.self, forKey: .moduleName)) ?? ""
        self.moduleSort = c.decodeFlexibleInt(forKey: .moduleSort) ?? 0
        self.tasks = (try? c.decodeIfPresent([TaskItemVO].self, forKey: .tasks)) ?? []
        if let b = try? c.decodeIfPresent(Bool.self, forKey: .moduleHasClaimable) {
            self.moduleHasClaimable = b
        } else {
            self.moduleHasClaimable = false
        }
    }

    enum CodingKeys: String, CodingKey {
        case moduleCode, moduleName, moduleSort, tasks, moduleHasClaimable
    }
}

// MARK: - 领取返回

struct TaskClaimVO: Codable, Hashable {
    let taskId: Int
    let tier: Int
    let rewardType: Int
    let rewardValue: Int
    let propId: Int?
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = c.decodeFlexibleInt(forKey: .taskId) ?? 0
        self.tier = c.decodeFlexibleInt(forKey: .tier) ?? 0
        self.rewardType = c.decodeFlexibleInt(forKey: .rewardType) ?? 0
        self.rewardValue = c.decodeFlexibleInt(forKey: .rewardValue) ?? 0
        self.propId = c.decodeFlexibleInt(forKey: .propId)
        self.message = try? c.decodeIfPresent(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey {
        case taskId, tier, rewardType, rewardValue, propId, message
    }

    /// 已知 "grant_pending" 特殊分支:只 toast 不弹奖励弹窗(H5 index.vue L165 分支)
    var isGrantPending: Bool { message == "grant_pending" }
}

struct TaskClaimAllVO: Codable, Hashable {
    let taskId: Int
    let claimedCount: Int
    let claimed: [TaskClaimVO]
    let message: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = c.decodeFlexibleInt(forKey: .taskId) ?? 0
        self.claimedCount = c.decodeFlexibleInt(forKey: .claimedCount) ?? 0
        self.claimed = (try? c.decodeIfPresent([TaskClaimVO].self, forKey: .claimed)) ?? []
        self.message = try? c.decodeIfPresent(String.self, forKey: .message)
    }

    enum CodingKeys: String, CodingKey {
        case taskId, claimedCount, claimed, message
    }
}

// MARK: - 顶部排位快照(RankInfo)

/// Task 页顶部消费 anchorRanking 的字段。H5 仅用 `myIncome / myIntegral`;其他字段真机 log 后按需扩。
struct TaskRankInfoVO: Codable, Hashable {
    let myIncome: Int
    let myIntegral: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.myIncome = c.decodeFlexibleInt(forKey: .myIncome) ?? 0
        self.myIntegral = c.decodeFlexibleInt(forKey: .myIntegral) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case myIncome, myIntegral
    }
}

// MARK: - Daily legacy fallback (/api/task/v2/get)

/// 新任务中心灰度不可用时的日任务数据。H5 在 `taskCenter/list` 无可展示分组时仍使用
/// `/api/task/v2/get` 的 `isLimitTask` 和 `allDayTask`，原生端保持相同的可用兜底。
struct LegacyDailyTasksVO: Decodable, Hashable {
    let allDayTasks: [LegacyTaskVO]
    let limitedTimeTasks: [LegacyTaskVO]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.allDayTasks = (try? c.decodeIfPresent([LegacyTaskVO].self, forKey: .allDayTask)) ?? []
        self.limitedTimeTasks = (try? c.decodeIfPresent([LegacyTaskVO].self, forKey: .isLimitTask)) ?? []
    }

    enum CodingKeys: String, CodingKey {
        case allDayTask, isLimitTask
    }
}

/// 旧版日任务行。字段与 H5 `taskItem.vue` 保持一致，数值继续兼容 Int/String/Double 混发。
struct LegacyTaskVO: Decodable, Identifiable, Hashable {
    let taskId: Int
    let taskName: String
    let taskType: String?
    let curScore: Int
    let targetScore: Int
    let effectiveTime: String?
    let rewardType: Int?
    let taskReward: Int?
    let taskScore: Int?
    let rewardStatus: Int

    var id: Int { taskId }
    var rewardValue: Int { taskReward ?? taskScore ?? 0 }
    var isClaimable: Bool { rewardStatus == 1 }
    var isClaimed: Bool { rewardStatus == 3 }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = c.decodeFlexibleInt(forKey: .taskId) ?? 0
        self.taskName = c.decodeFlexibleString(forKey: .taskName) ?? ""
        self.taskType = c.decodeFlexibleString(forKey: .taskType)
        self.curScore = c.decodeFlexibleInt(forKey: .curScore) ?? 0
        self.targetScore = c.decodeFlexibleInt(forKey: .targetScore) ?? 0
        self.effectiveTime = c.decodeFlexibleString(forKey: .effectiveTime)
        self.rewardType = c.decodeFlexibleInt(forKey: .rewardType)
        self.taskReward = c.decodeFlexibleInt(forKey: .taskReward)
        self.taskScore = c.decodeFlexibleInt(forKey: .taskScore)
        self.rewardStatus = c.decodeFlexibleInt(forKey: .rewardStatus) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case taskId, taskName, taskType, curScore, targetScore, effectiveTime
        case rewardType, taskReward, taskScore, rewardStatus
    }
}

// MARK: - Weekly Overview

struct WeeklyOverviewVO: Codable, Hashable {
    let moduleGroups: [TaskModuleGroupVO]
    let tycoonTasks: [ActiveTycoonTaskVO]
    let pointsInfo: WeeklyPointsInfoVO?
    let weeklyResetRemainSeconds: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.moduleGroups = (try? c.decodeIfPresent([TaskModuleGroupVO].self, forKey: .moduleGroups)) ?? []
        self.tycoonTasks = (try? c.decodeIfPresent([ActiveTycoonTaskVO].self, forKey: .tycoonTasks)) ?? []
        self.pointsInfo = try? c.decodeIfPresent(WeeklyPointsInfoVO.self, forKey: .pointsInfo)
        self.weeklyResetRemainSeconds = c.decodeFlexibleInt(forKey: .weeklyResetRemainSeconds) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case moduleGroups, tycoonTasks, pointsInfo, weeklyResetRemainSeconds
    }
}

// MARK: - Weekly 独有 · 大 R 任务(ActiveTycoonTaskVO)

struct ActiveTycoonTaskVO: Codable, Identifiable, Hashable {
    let taskId: Int
    let taskTitle: String
    let taskDesc: String?
    let targetValue: Int
    let progressValue: Int
    let rewardAmount: Int
    let rewardKind: Int?
    let taskRuleText: String?
    let secondsRemaining: Int?
    let reachFlag: Int?
    let settleFlag: Int?

    var id: Int { taskId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.taskId = c.decodeFlexibleInt(forKey: .taskId) ?? 0
        self.taskTitle = (try? c.decodeIfPresent(String.self, forKey: .taskTitle)) ?? ""
        self.taskDesc = try? c.decodeIfPresent(String.self, forKey: .taskDesc)
        self.targetValue = c.decodeFlexibleInt(forKey: .targetValue) ?? 0
        self.progressValue = c.decodeFlexibleInt(forKey: .progressValue) ?? 0
        self.rewardAmount = c.decodeFlexibleInt(forKey: .rewardAmount) ?? 0
        self.rewardKind = c.decodeFlexibleInt(forKey: .rewardKind)
        self.taskRuleText = try? c.decodeIfPresent(String.self, forKey: .taskRuleText)
        self.secondsRemaining = c.decodeFlexibleInt(forKey: .secondsRemaining)
        self.reachFlag = c.decodeFlexibleInt(forKey: .reachFlag)
        self.settleFlag = c.decodeFlexibleInt(forKey: .settleFlag)
    }

    enum CodingKeys: String, CodingKey {
        case taskId, taskTitle, taskDesc, targetValue, progressValue
        case rewardAmount, rewardKind, taskRuleText
        case secondsRemaining, reachFlag, settleFlag
    }
}

// MARK: - Weekly 独有 · 积分任务(WeeklyPointsInfoVO / WeeklyPointsTaskVO)

struct WeeklyPointsInfoVO: Codable, Hashable {
    let anchorCurScore: Int?
    let reachScore: Int?
    let reachReward: Int?
    let taskVos: [WeeklyPointsTaskVO]
    let taskRules: String?
    let myIntegral: Int?
    let rewardType: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.anchorCurScore = c.decodeFlexibleInt(forKey: .anchorCurScore)
        self.reachScore = c.decodeFlexibleInt(forKey: .reachScore)
        self.reachReward = c.decodeFlexibleInt(forKey: .reachReward)
        self.taskVos = (try? c.decodeIfPresent([WeeklyPointsTaskVO].self, forKey: .taskVos)) ?? []
        self.taskRules = try? c.decodeIfPresent(String.self, forKey: .taskRules)
        self.myIntegral = c.decodeFlexibleInt(forKey: .myIntegral)
        self.rewardType = c.decodeFlexibleInt(forKey: .rewardType)
    }

    enum CodingKeys: String, CodingKey {
        case anchorCurScore, reachScore, reachReward, taskVos
        case taskRules, myIntegral, rewardType
    }
}

struct WeeklyPointsTaskVO: Codable, Identifiable, Hashable {
    let id: Int
    let curScore: Int
    let targetScore: Int
    let icon: String?
    let description: String?
    let taskName: String?
    let taskType: String?
    let taskScore: Int?
    let rewardType: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.decodeFlexibleInt(forKey: .id) ?? 0
        self.curScore = c.decodeFlexibleInt(forKey: .curScore) ?? 0
        self.targetScore = c.decodeFlexibleInt(forKey: .targetScore) ?? 0
        self.icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        self.description = try? c.decodeIfPresent(String.self, forKey: .description)
        self.taskName = try? c.decodeIfPresent(String.self, forKey: .taskName)
        self.taskType = try? c.decodeIfPresent(String.self, forKey: .taskType)
        self.taskScore = c.decodeFlexibleInt(forKey: .taskScore)
        self.rewardType = c.decodeFlexibleInt(forKey: .rewardType)
    }

    enum CodingKeys: String, CodingKey {
        case id, curScore, targetScore, icon, description
        case taskName, taskType, taskScore, rewardType
    }
}

// MARK: - 领奖弹窗承载(前端派生)

/// 领奖成功后 View 层的 popup payload。合并同类奖励后由 Store 构造并 assign 给 pendingReward。
struct PendingReward: Equatable {
    /// 奖励类型码(rewardType)
    let rewardType: Int
    /// 总数量(单档 = rewardValue;一键领同类合并 = sum)
    let totalValue: Int
    /// 是否是合并(用于 UI 显示"合计"或单档"×N")
    let isMerged: Bool
}
