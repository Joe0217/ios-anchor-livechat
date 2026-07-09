import XCTest

/// H-3 Step 1a-2：ChatMessageContent 扩 3 case + MessageAttachParser remoteExt helper + 相关 enum 单测。
///
/// 覆盖 spec §F-2/F-3/F-4/F-5 + R-6/R-7 相关 + Critical-1（privateId 非 messageId）+ Critical-3（单源 remoteExt）
/// + Major-4（activeTycoon 透传）+ Major-6（tip tieBreaker 优先级）。
final class ChatH3ModelsTests: XCTestCase {

    // MARK: - PrivateLockStatus.init(rawInt:)

    func testPrivateLockStatus_FromRawInt_0_IsLocked() {
        XCTAssertEqual(PrivateLockStatus(rawInt: 0), .locked)
    }

    func testPrivateLockStatus_FromRawInt_1_IsUnlocked() {
        XCTAssertEqual(PrivateLockStatus(rawInt: 1), .unlocked)
    }

    func testPrivateLockStatus_FromRawInt_Nil_IsUnknown() {
        XCTAssertEqual(PrivateLockStatus(rawInt: nil), .unknown)
    }

    /// spec §R-7：checkPrivateInfo 返回不含某 privateId → 保 .unknown（不 dead-state）
    func testPrivateLockStatus_FromRawInt_OtherValues_IsUnknown() {
        XCTAssertEqual(PrivateLockStatus(rawInt: 2), .unknown)
        XCTAssertEqual(PrivateLockStatus(rawInt: -1), .unknown)
        XCTAssertEqual(PrivateLockStatus(rawInt: 99), .unknown)
    }

    // MARK: - ChatTipKind.tieBreaker（spec §F-42 tip 优先级）

    /// spec §F-42 + Minor-3：4 tip 优先级 guide=1 > replyPointGuide=2 > replyRemind=3 > stimulate=4
    func testChatTipKind_TieBreakerOrder() {
        XCTAssertEqual(ChatTipKind.guide.tieBreaker, 1)
        XCTAssertEqual(ChatTipKind.replyPointGuide.tieBreaker, 2)
        XCTAssertEqual(ChatTipKind.replyRemind.tieBreaker, 3)
        XCTAssertEqual(ChatTipKind.stimulate.tieBreaker, 4)

        // stableSortKey = timestamp * 100 + tieBreaker：同 timestamp 时 guide 先于其他
        let ts: Int64 = 1_720_000_000_000
        let guideKey = ts * 100 + Int64(ChatTipKind.guide.tieBreaker)
        let stimulateKey = ts * 100 + Int64(ChatTipKind.stimulate.tieBreaker)
        XCTAssertLessThan(guideKey, stimulateKey)
    }

    // MARK: - MessageAttachParser.extractPrivateInfo（spec Critical-1 / Critical-3）

    /// nil remoteExt → 非私密
    func testExtractPrivateInfo_NilRemoteExt_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractPrivateInfo(remoteExt: nil))
    }

    /// remoteExt 缺 extensionType → 非私密
    func testExtractPrivateInfo_MissingExtensionType_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractPrivateInfo(remoteExt: [
            "data": ["iconType": 1, "privateId": "abc"]
        ]))
    }

    /// extensionType 不是 privateMsg → 非私密（如是 chatBubble 独立字段）
    func testExtractPrivateInfo_ExtensionTypeNotPrivateMsg_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractPrivateInfo(remoteExt: [
            "extensionType": "otherType",
            "data": ["iconType": 1, "privateId": "abc"]
        ]))
    }

    /// F-2：完整私密图片消息 remoteExt → PrivateMsgInfo(iconType=1, lockStatus=.locked)
    func testExtractPrivateInfo_ValidPrivateImage_ReturnsInfo() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 1, "privateId": "abc-123", "lockStatus": 0],
        ]
        let info = MessageAttachParser.extractPrivateInfo(remoteExt: ext)
        XCTAssertEqual(info?.privateId, "abc-123")
        XCTAssertEqual(info?.iconType, 1)
        XCTAssertEqual(info?.lockStatus, .locked)
    }

    /// F-3：私密视频（iconType=2 + unlocked）
    func testExtractPrivateInfo_ValidPrivateVideoUnlocked_ReturnsInfo() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 2, "privateId": "vid-456", "lockStatus": 1],
        ]
        let info = MessageAttachParser.extractPrivateInfo(remoteExt: ext)
        XCTAssertEqual(info?.privateId, "vid-456")
        XCTAssertEqual(info?.iconType, 2)
        XCTAssertEqual(info?.lockStatus, .unlocked)
    }

    /// Critical-1：privateId 是 Int 时兼容转 String（rule ios-decode-userid-compat）
    func testExtractPrivateInfo_PrivateIdAsInt_ReturnsAsString() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 1, "privateId": 12345, "lockStatus": 0] as [String: Any],
        ]
        let info = MessageAttachParser.extractPrivateInfo(remoteExt: ext)
        XCTAssertEqual(info?.privateId, "12345")
    }

    /// privateId 缺失 → 非私密（不 fallback）
    func testExtractPrivateInfo_MissingPrivateId_ReturnsNil() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 1, "lockStatus": 0],
        ]
        XCTAssertNil(MessageAttachParser.extractPrivateInfo(remoteExt: ext))
    }

    /// iconType 非 1/2 → 非私密（跳过该项）
    func testExtractPrivateInfo_InvalidIconType_ReturnsNil() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 3, "privateId": "abc"],
        ]
        XCTAssertNil(MessageAttachParser.extractPrivateInfo(remoteExt: ext))
    }

    /// spec §R-7 lockStatus 缺失 → .unknown
    func testExtractPrivateInfo_MissingLockStatus_IsUnknown() {
        let ext: [String: Any] = [
            "extensionType": "privateMsg",
            "data": ["iconType": 1, "privateId": "abc"],
        ]
        let info = MessageAttachParser.extractPrivateInfo(remoteExt: ext)
        XCTAssertEqual(info?.lockStatus, .unknown)
    }

    // MARK: - MessageAttachParser.extractActiveTycoon（spec Major-4）

    /// 主播透传 activeTycoon=true → 对端 nav 显徽章
    func testExtractActiveTycoon_True() {
        XCTAssertEqual(
            MessageAttachParser.extractActiveTycoon(remoteExt: ["activeTycoon": true]),
            true
        )
    }

    func testExtractActiveTycoon_False() {
        XCTAssertEqual(
            MessageAttachParser.extractActiveTycoon(remoteExt: ["activeTycoon": false]),
            false
        )
    }

    /// spec §1.5.4 三级 fallback 之三：nil 时 → 三级 fallback 兜底
    func testExtractActiveTycoon_NilRemoteExt_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractActiveTycoon(remoteExt: nil))
    }

    func testExtractActiveTycoon_MissingField_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractActiveTycoon(remoteExt: ["other": "value"]))
    }

    // MARK: - MessageAttachParser.extractChatBubble（spec Critical-3 单源）

    func testExtractChatBubble_ValidURL() {
        let ext = ["chatBubble": "https://cdn.example.com/bubble.png"]
        XCTAssertEqual(
            MessageAttachParser.extractChatBubble(remoteExt: ext),
            URL(string: "https://cdn.example.com/bubble.png")
        )
    }

    /// spec §R-26：chatBubble URL "无效"由 UI 层 NinePatchImageView 加载失败兜底（fallback 默认圆角）
    /// —— iOS `URL(string:)` 对多数字符串会 auto-percent-encode（如空格），Model 层难制造真正 return nil 的 URL 字符串
    /// —— 本层单测覆盖 nil / 空字符串两大兜底路径；"非法字符"路径留 UI 集成测试（Step 3 真机 R-25）

    /// spec §R-27：主播 chatBubble nil 时不塞该 key；接收侧解出 nil → 走默认气泡
    func testExtractChatBubble_EmptyString_ReturnsNil() {
        let ext = ["chatBubble": ""]
        XCTAssertNil(MessageAttachParser.extractChatBubble(remoteExt: ext))
    }

    func testExtractChatBubble_NilRemoteExt_ReturnsNil() {
        XCTAssertNil(MessageAttachParser.extractChatBubble(remoteExt: nil))
    }

    // MARK: - ChatMessage 新字段默认值（spec §3.2）

    /// 加字段 chatBubble/privateId 均带 nil 默认；不炸多处现有 ChatMessage 显式构造点
    func testChatMessage_DefaultValues_ChatBubbleAndPrivateIdNil() {
        let msg = ChatMessage(
            id: "id-1",
            clientMsgId: "c-1",
            from: "self",
            to: "peer",
            content: .text("hello"),
            status: .sending,
            timestamp: 1_720_000_000_000,
            isOutgoing: true
        )
        XCTAssertNil(msg.chatBubble)
        XCTAssertNil(msg.privateId)
    }

    /// 完整构造：chatBubble / privateId 可注入
    func testChatMessage_ExplicitChatBubbleAndPrivateId() {
        var msg = ChatMessage(
            id: "id-2",
            clientMsgId: nil,
            from: "peer",
            to: "self",
            content: .privateImage(url: URL(string: "https://example.com/x.jpg")!, lockStatus: .locked),
            status: .sent,
            timestamp: 1_720_000_000_100,
            isOutgoing: false
        )
        msg.chatBubble = URL(string: "https://cdn.example.com/bubble.png")
        msg.privateId = "priv-999"
        XCTAssertEqual(msg.chatBubble?.absoluteString, "https://cdn.example.com/bubble.png")
        XCTAssertEqual(msg.privateId, "priv-999")
    }
}
