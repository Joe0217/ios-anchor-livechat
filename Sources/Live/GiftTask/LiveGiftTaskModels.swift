import Foundation

// MARK: - GiftTaskProgress (对齐 H5 liveStore.giftTask)

/// 主播端礼物任务进度快照（GET /api/wallet/anchor/taskInfo/liveGiftTask 响应）。
///
/// 对齐 H5 `useLiveStore.giftTask`（stores/modules/live.js:33）：
/// - `giftTotal`:当前累计钻石数
/// - `taskAmount`:目标钻石数(nil / 0 均视为"无任务",顶部 Task icon 隐藏)
///
/// **字段名 preflight**：step 3 前真机 log 校对 —— H5 声明的 `giftTotal / taskAmount` 是后端真实字段名假设,
/// 若后端返 `giftValue / giftDiamond` 等别名需补 CodingKeys alias(对齐
/// [agent-recon-field-names-unverified](.claude/rules/agent-recon-field-names-unverified.md))。
struct GiftTaskProgress: Codable, Equatable {
    let giftTotal: Int64
    /// Optional:nil / 0 都视为"无任务",icon 隐藏(spec §2.1 R-26)
    let taskAmount: Int64?

    init(giftTotal: Int64, taskAmount: Int64?) {
        self.giftTotal = giftTotal
        self.taskAmount = taskAmount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // decodeFlexibleInt 兼容 Int/String/Double 混发(对齐 ios-decode-userid-compat)
        giftTotal = Int64(c.decodeFlexibleInt(forKey: .giftTotal) ?? 0)
        if let v = c.decodeFlexibleInt(forKey: .taskAmount) {
            taskAmount = Int64(v)
        } else {
            taskAmount = nil
        }
    }

    enum CodingKeys: String, CodingKey {
        case giftTotal, taskAmount
    }

    /// icon 显示条件:`(taskAmount ?? 0) > 0`(spec §0.2 首行 Swift 优先级修正:必须括号)
    var hasActiveTask: Bool { (taskAmount ?? 0) > 0 }

    /// 进度比 0~1 (除零保护;若 taskAmount 无 / 为 0 返 0;giftTotal 超过 taskAmount 也硬夹 1.0)
    var ratio: Double {
        guard let target = taskAmount, target > 0 else { return 0 }
        return min(1.0, Double(giftTotal) / Double(target))
    }
}

// MARK: - GiftHistoryItem (对齐 H5 apiReceiveHistoryRank 每项)

/// 送礼历史单条记录(receiveHistoryRankV2 响应数组每项)。
///
/// 对齐 H5 `liveGiftTaskTab.vue` 历史列表模板消费的字段:icon / nickname / headFrame / activeTycoon /
/// formattedTime / giftIcon / giftNum。
///
/// **id 稳定性**:H5 无显式 recordId;iOS 用 `IndexedGiftHistoryItem` 组合 (page, row) 保证 SwiftUI
/// ForEach Identifiable 稳定(spec §2.2 R-27),step 3 前若真机发现有 `recordId` 字段则替换。
struct GiftHistoryItem: Codable, Equatable {
    let userId: String
    let icon: String
    let nickname: String
    /// 头像框 URL(对齐 PublicChatRow.swift:337-353 headFrame 双态布局;可空)
    let headFrame: String?
    /// 大R 徽章标记(可空)
    let activeTycoon: Bool?
    /// 后端已格式化时间字符串
    let formattedTime: String
    let giftIcon: String
    let giftNum: Int

    init(userId: String, icon: String, nickname: String, headFrame: String? = nil,
         activeTycoon: Bool? = nil, formattedTime: String, giftIcon: String, giftNum: Int) {
        self.userId = userId
        self.icon = icon
        self.nickname = nickname
        self.headFrame = headFrame
        self.activeTycoon = activeTycoon
        self.formattedTime = formattedTime
        self.giftIcon = giftIcon
        self.giftNum = giftNum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // userId String/Int 双兼容(对齐 ios-decode-userid-compat.md)
        if let s = try? c.decodeIfPresent(String.self, forKey: .userId), !s.isEmpty {
            userId = s
        } else if let i = c.decodeFlexibleInt(forKey: .userId) {
            userId = "\(i)"
        } else {
            userId = ""
        }
        icon = (try? c.decodeIfPresent(String.self, forKey: .icon)) ?? ""
        nickname = (try? c.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        headFrame = try? c.decodeIfPresent(String.self, forKey: .headFrame)
        activeTycoon = try? c.decodeIfPresent(Bool.self, forKey: .activeTycoon)
        formattedTime = (try? c.decodeIfPresent(String.self, forKey: .formattedTime)) ?? ""
        giftIcon = (try? c.decodeIfPresent(String.self, forKey: .giftIcon)) ?? ""
        giftNum = c.decodeFlexibleInt(forKey: .giftNum) ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case userId, icon, nickname, headFrame, activeTycoon, formattedTime, giftIcon, giftNum
    }
}

/// SwiftUI ForEach Identifiable 包装,避免拼串 id 因分页重复 / 时间精度冲突。
struct IndexedGiftHistoryItem: Identifiable, Equatable {
    let page: Int
    let row: Int
    let item: GiftHistoryItem
    /// 复合 key:page-row(spec §2.2 R-27)
    var id: String { "p\(page)r\(row)" }
}

// MARK: - ActiveTycoonTaskVO 直接复用 Sources/Work/TaskCenter/TaskCenterModels.swift
//
// 复用理由(spec §0.4 preflight 通过):字段完全一致,commit a2bf80a 已真机验证 decode。
// 通过 import Foundation 同一 module 内直接可用,无需额外声明。若后续两 API schema 分裂再抽独立。
