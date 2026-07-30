import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "Party.GiftBridge")

/// 派对房礼物面板 Bridge（H-5 spec §4.2）——从 `PartyStore` 派生 `ReceiversConfig`。
///
/// **纯函数式转换**（无 UI / 无副作用）：`seatList + selfYxAccid → ReceiversConfig`。
///
/// **对齐 H5 recipientList**（party-gift-popup.vue L146–159）:
/// - `seat.yxAccid` 非空 + 非 `"0"` + 非本人 yxAccid
/// - **不要求 userId 非空**（H5 只依赖 yxAccid，不看 userId）—— iOS 2026-07-14 修订：去掉 userId 非空要求 + self 匹配改 yxAccid
/// - 按 seatIndex 升序
/// - **默认接受者单选**：owner 优先（`roomRoleType == 1`），否则第一个有效 yxAccid
/// - `allowMultiSelect: true`（H5 支持多选）
/// - `showAllButton: true`（H5 右侧 "All" 滑块开关）
enum PartyGiftPanelBridge {

    /// 从 seatList 构造 `ReceiversConfig`。
    ///
    /// - Parameters:
    ///   - seatList: `PartyStore.seatList`
    ///   - selfYxAccid: 当前用户云信 accid（`SessionStore.shared.user?.yxAccid`）；对齐 H5 用 yxAccid 匹配 self
    ///   - battlingUids: PK RUNNING 期红/蓝队参战 uid 集合；非 nil 时**只保留命中 uid 的 seat**
    ///     （对齐 H5 giftPanelTabs.vue "父级 party-gift-popup 用同一份 recipientList 按当前 team 过滤"）
    ///     · nil = 不做 PK 过滤（非 PK 期或 SELECTING 期传 nil）
    /// - Returns: `ReceiversConfig`；`items` 可能为空（seat 全空/全是自己/全 yxAccid 空 → spec R8 empty state）
    static func makeReceiversConfig(
        seatList: [PartyRoomSeat],
        selfYxAccid: String?,
        battlingUids: Set<Int64>? = nil,
        recipientOverride: ReceiverItem? = nil,
        selectionState: GiftRecipientSelectionState? = nil
    ) -> ReceiversConfig {
        // 从用户名片卡进入礼物架时必须锁定目标用户，不能退化成房主/首个麦位。
        if let recipientOverride {
            return ReceiversConfig(
                items: [recipientOverride],
                allowMultiSelect: false,
                initialSelection: [recipientOverride.id],
                showAllButton: false,
                selectionState: selectionState
            )
        }
        // R14 · seat.yxAccid nil/空串 过滤
        // 对齐 H5 party-gift-popup.vue L149 filter 字面：
        //   `seat?.yxAccid && seat.yxAccid !== '0' && seat.yxAccid !== userStore.mineInfo?.yxAccid`
        // H5 完全依赖 yxAccid，**不看 userId**；iOS 对齐（去掉 userId 非空硬约束 + self 匹配改 yxAccid）
        let validSeats: [PartyRoomSeat] = seatList
            .filter { seat in
                guard let accid = seat.yxAccid, !accid.isEmpty, accid != "0" else { return false }
                // 用 yxAccid 匹配 self（对齐 H5）—— session 与 seat 同源云信 accid，格式一致
                if let me = selfYxAccid, !me.isEmpty, accid == me { return false }
                // PK RUNNING 期按 team 过滤（对齐 H5 giftPanelTabs 父级 recipientList filter）
                if let uids = battlingUids {
                    guard let uidStr = seat.userId, let uid = Int64(uidStr), uids.contains(uid) else {
                        return false
                    }
                }
                return true
            }
            .sorted { (a, b) in
                let ai = a.seatIndex ?? Int.max
                let bi = b.seatIndex ?? Int.max
                return ai < bi
            }

        // 转 ReceiverItem
        let items: [ReceiverItem] = validSeats.compactMap { seat in
            guard let accid = seat.yxAccid else { return nil }
            return ReceiverItem(
                id: accid,
                avatarURL: seat.avatar.flatMap { URL(string: $0) },
                seatIndex: seat.seatIndex,
                userId: seat.userId,
                userType: seat.userType
            )
        }

        // 默认单选：owner 优先，否则第一个
        let ownerAccid: String? = validSeats.first { $0.roomRoleType == 1 }?.yxAccid
        let firstAccid: String? = validSeats.first?.yxAccid
        let defaultAccid = ownerAccid ?? firstAccid
        let initialSelection: Set<String> = defaultAccid.map { [$0] } ?? []

        // debug log · 真机排查"麦上收礼人未显示"（对齐 [im-payload-real-log-over-code-assumption] 精神）
        logger.info("[PartyGiftBridge] seatList=\(seatList.count, privacy: .public) validSeats=\(validSeats.count, privacy: .public) items=\(items.count, privacy: .public) selfYxAccid=\(selfYxAccid ?? "nil", privacy: .private)")
        return ReceiversConfig(
            items: items,
            allowMultiSelect: true,
            initialSelection: initialSelection,
            showAllButton: true,
            selectionState: selectionState
        )
    }
}
