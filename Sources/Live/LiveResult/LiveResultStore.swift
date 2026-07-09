import Foundation
import os

/// 直播结果页状态机（对齐 H5 `views/liveEnds/index.vue`）。
///
/// 4 态：`.loading` / `.loaded(data)` / `.error(msg)` / `.emptyRange`（begin/end 缺失，不发接口）。
///
/// **数据缓存**：H5 用 `liveStore.liveEndData` 全局缓存避免重复拉；iOS 侧结果页 view 结束即销毁，
/// 无跨页返回需求，不做全局缓存。
enum LiveResultState: Equatable {
    case loading
    case loaded(LiveStatData)
    case error(String)
    case emptyRange              // begin/end 缺失（异常路径）

    var data: LiveStatData? {
        if case let .loaded(d) = self { return d }
        return nil
    }
}

@MainActor
final class LiveResultStore: ObservableObject {
    @Published private(set) var state: LiveResultState = .loading
    /// 关注操作 in-flight 集合，防止双击重复请求
    @Published private(set) var followInFlight: Set<String> = []
    /// 全局提示 toast（关注成功 / 关注失败 / 其它反馈）。View 层观察后弹 toastOverlay，2s auto-clear。
    @Published var toast: String? = nil
    /// toast 自动清空 task；每次 set 新 toast 时 cancel 旧 task 重置计时。
    private var toastClearTask: Task<Void, Never>?

    let range: (begin: Int64, end: Int64)?
    let endType: Int?

    /// 强制下播原因的红字提示文案。
    ///
    /// - H5 蓝本只显示弱网一种（`forceEndReason=='5'`）；iOS 侧扩展显示**所有强制下播原因**
    ///   （对齐 LiveState.ForceEndReason 5 种：2 违规 / 4 断连 / 5 相机 / 6 无权限 / 7 弱网），
    ///   与 H5 略有分歧但更完整。用户主动下播 endType=1 不显示（属正常下播非"强制"）。
    /// - 复用 [L10n.forceEnd*](../../L10n.swift) 5 个既有 key（LiveState.swift `ForceEndReason` 已定义映射）
    var forceEndNoticeText: String? {
        guard let endType else { return nil }
        switch endType {
        case 2: return L10n.forceEndBanned            // 心跳 1992/1006 / NIM attachType=62
        case 4: return L10n.forceEndDisconnected      // 心跳失败 >3 / 断连 / 后台超限
        case 5: return L10n.forceEndCameraFailure     // 相机采集失败 >20s
        case 6: return L10n.forceEndNoPermission      // 心跳 2001
        case 7: return L10n.forceEndWeakNetwork       // 弱网 ≥30 次
        default: return nil                            // endType=1 正常下播 / unknown
        }
    }

    /// 直播时长（毫秒）→ HH:mm:ss；range 缺失返空串
    var durationText: String {
        guard let range else { return "" }
        let diffMs = max(0, range.end - range.begin)
        return Self.formatHMS(seconds: Int(diffMs / 1000))
    }

    private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveResultStore")

    init(range: (begin: Int64, end: Int64)?, endType: Int?) {
        self.range = range
        self.endType = endType
        if range == nil {
            self.state = .emptyRange
        }
    }

    /// 拉取数据。range 为空时短路。
    func load() async {
        guard let range else {
            state = .emptyRange
            return
        }
        state = .loading
        do {
            let data = try await LiveResultService.queryLiveStat(begin: range.begin, end: range.end)
            state = .loaded(data)
        } catch let api as APIError {
            logger.error("load failed code=\(api.code) msg=\(api.message)")
            state = .error(api.message.isEmpty ? L10n.liveResultLoadFailed : api.message)
        } catch {
            logger.error("load failed: \(String(describing: error))")
            state = .error(L10n.liveResultLoadFailed)
        }
    }

    /// 关注/取关（复用 UserProfileService.follow）。乐观更新失败回滚。
    ///
    /// H5 只做关注（`v-if followFlag != 1` 未关注才显示按钮，无取关入口）。iOS 保持一致。
    func follow(userId: String) async {
        guard !followInFlight.contains(userId) else { return }
        guard let uidInt = Int(userId) else {
            logger.warning("follow: userId not Int-parsable \(userId, privacy: .private)")
            return
        }
        guard case var .loaded(data) = state else { return }
        // 乐观：先把 followFlag 打上
        for i in data.giftRanks.indices where data.giftRanks[i].userId == userId {
            data.giftRanks[i].followed = true
        }
        for i in data.privateCalls.indices where data.privateCalls[i].userId == userId {
            data.privateCalls[i].followed = true
        }
        state = .loaded(data)
        followInFlight.insert(userId)
        defer { followInFlight.remove(userId) }
        do {
            try await UserProfileService.shared.follow(
                request: FollowUserRequest(followUserId: uidInt, followType: 1)
            )
            logger.info("follow ok uid=\(userId, privacy: .private)")
            showToast(L10n.liveResultFollowSuccess)
        } catch {
            logger.error("follow failed uid=\(userId, privacy: .private) err=\(String(describing: error))")
            // 回滚
            guard case var .loaded(rollbackData) = state else { return }
            for i in rollbackData.giftRanks.indices where rollbackData.giftRanks[i].userId == userId {
                rollbackData.giftRanks[i].followed = false
            }
            for i in rollbackData.privateCalls.indices where rollbackData.privateCalls[i].userId == userId {
                rollbackData.privateCalls[i].followed = false
            }
            state = .loaded(rollbackData)
        }
    }

    /// 设置 toast 文案 + 2s auto-clear（旧 task cancel 后重启计时）。
    func showToast(_ text: String) {
        toast = text
        toastClearTask?.cancel()
        toastClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    /// 秒 → "HH:mm:ss"（H5 utils.formatTimestamp('HH:mm:ss') 对齐）。
    ///
    /// **走 `IntegerFormatStyle` + `Locale.current`**（review 202607071524 F2）：
    /// - `String(format: "%02d", ...)` 走 C locale 恒输拉丁数字 0-9
    /// - 与同页 `Text(value, format: .number)` 走 Locale.current 冲突：ar 用户会看到
    ///   "拉丁时长 00:12:34 + 东方数字礼物 ٠٠١٢٣" 分裂视觉
    /// - `IntegerFormatStyle().precision(.integerLength(2))` 按 Locale.current 渲染 + 至少 2 位补零
    static func formatHMS(seconds: Int) -> String {
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        let s = seconds % 60
        let fmt = IntegerFormatStyle<Int>().precision(.integerLength(2))
        return "\(fmt.format(h)):\(fmt.format(m)):\(fmt.format(s))"
    }
}
