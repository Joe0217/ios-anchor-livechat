import Foundation

/// `PartyGiftSendService` 默认实作 —— 直连 `PartyAPI.sendGift`。
///
/// Protocol 声明在 [PartyGiftSendServiceProtocol.swift](PartyGiftSendServiceProtocol.swift)（单独文件承载
/// 供 HilyTests 白名单可见；本文件含 PartyAPI 依赖不入白名单）。
///
/// - roomId 由 factory 层通过 init capture
/// - `giftId: Int64 → Int` 转换在此层（iOS Int 在 64bit 下等宽 Int64 无损）
struct DefaultPartyGiftSendService: PartyGiftSendService {
    private let roomId: String

    init(roomId: String) {
        self.roomId = roomId
    }

    func send(giftId: Int64, num: Int, yxAccidList: [String]) async throws -> PartySendGiftResult {
        guard SelfPermissionBridge.shared.gate(.giftSending, action: "partySendGift") else {
            throw GiftSendError.generic(message: "Gift sending is unavailable")
        }
        do {
            return try await PartyAPI.sendGift(
                roomId: roomId,
                giftId: Int(giftId),
                num: num,
                yxAccidList: yxAccidList
            )
        } catch let e as PartyAPIError {
            // 转 GiftSendError sentinel（Store 层依赖此 sentinel，不依赖网络栈类型 · spec §2.3 rework）
            // PA-5（对齐 H5 usePartyHooks.js L1699）：code==1019 OR msg 含 diamond not enough 双兜底
            //   H5 双条件："error.code === '1019' || message.includes('diamond not enough')"
            //   防后端某些 gateway 返回 code!="1019" 但 msg 显式声明余额不足的场景
            if case .business(let code, let msg) = e {
                if code == "1019" || msg.lowercased().contains("diamond not enough") {
                    throw GiftSendError.insufficientBalance
                }
            }
            throw GiftSendError.generic(message: e.errorDescription ?? "send failed")
        } catch let e as APIError {
            if e.code == "1019" || e.message.lowercased().contains("diamond not enough") {
                throw GiftSendError.insufficientBalance
            }
            throw GiftSendError.generic(message: e.message)
        }
    }
}
