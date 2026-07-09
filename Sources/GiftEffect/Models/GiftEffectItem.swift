import Foundation

/// 一次礼物发送事件，对应特效队列中的一个播放单元
public struct GiftEffectItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let sceneKey: GiftEffectSceneKey
    public let senderYxAccid: String
    public let senderNickname: String
    public let senderAvatarUrl: String?
    /// 礼物 ID（对齐 ios-decode-userid-compat：后端可能发 Int 或 String，统一存 Int64）
    public let giftId: Int64
    public let giftName: String
    public let giftCount: Int
    public let giftPrice: Int64
    /// 动画资源 URL（仅 .svga / .mp4 后缀有效；其他后缀或空白归一为 nil）
    public let animationUrl: String?
    /// 静态兜底图 URL
    public let staticImgUrl: String?
    /// 事件时间戳（毫秒）
    public let timestamp: Int64
    /// 是否由本端账号发出（用于 isSelfSent 判断方向）
    public let isSelfSent: Bool

    public init(
        id: UUID = UUID(),
        sceneKey: GiftEffectSceneKey,
        senderYxAccid: String,
        senderNickname: String,
        senderAvatarUrl: String?,
        giftId: Int64,
        giftName: String,
        giftCount: Int,
        giftPrice: Int64,
        animationUrl: String?,
        staticImgUrl: String?,
        timestamp: Int64,
        isSelfSent: Bool
    ) {
        self.id = id
        self.sceneKey = sceneKey
        self.senderYxAccid = senderYxAccid
        self.senderNickname = senderNickname
        self.senderAvatarUrl = senderAvatarUrl
        self.giftId = giftId
        self.giftName = giftName
        self.giftCount = giftCount
        self.giftPrice = giftPrice
        self.animationUrl = animationUrl
        self.staticImgUrl = staticImgUrl
        self.timestamp = timestamp
        self.isSelfSent = isSelfSent
    }
}

// MARK: - Payload Decoder

/// 从 NIM 自定义消息字典 payload 解析 GiftEffectItem
///
/// 字段兼容策略（对齐 .claude/rules/ios-decode-userid-compat.md）：
/// - giftId / giftNum / giftPrice：String 或 Int 混发，均兼容
/// - senderYxAccid：优先 payload["senderYxAccid"]，其次 senderInfo.yxAccid，兜底 fromAccid
/// - animationUrl：只接受 .svga / .mp4 后缀；空白字符串归一为 nil
public enum GiftEffectPayloadDecoder {

    /// - Parameters:
    ///   - sceneKey: 当前业务场景 key
    ///   - payload: NIM 自定义消息 attach 字典
    ///   - mineYxAccid: 本端云信 accid（用于判断 isSelfSent）
    ///   - now: 时间戳生成闭包，默认取当前毫秒时间戳（方便测试注入）
    /// - Returns: 解析成功返回 GiftEffectItem，giftId 为 0 或缺失返回 nil
    public static func decode(
        sceneKey: GiftEffectSceneKey,
        payload: [String: Any],
        mineYxAccid: String,
        now: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    ) -> GiftEffectItem? {
        let giftId = decodeInt64(payload["giftId"]) ?? 0
        guard giftId != 0 else { return nil }

        let giftCount = decodeInt(payload["giftNum"] ?? payload["giftCount"]) ?? 1
        let giftPrice = decodeInt64(payload["giftPrice"]) ?? 0

        let senderYxAccid = decodeSender(payload) ?? ""
        let senderNickname = decodeString(payload["senderNickname"] ?? payload["nickname"]) ?? ""
        let senderAvatar = decodeString(payload["senderAvatar"] ?? payload["avatar"])?.nilIfEmpty

        let giftName = decodeString(payload["giftName"]) ?? ""

        // animationUrl：优先 giftIcon（对应 SVGA/MP4 动画），后缀校验
        let rawIconUrl = decodeString(payload["giftIcon"] ?? payload["giftImg"])?.nilIfEmpty
        let animationUrl = normalizeAnimationUrl(rawIconUrl)

        // staticImgUrl：优先小图（兼容后端字段 giftSmallImg / smallImg / giftImg）
        let staticImg = decodeString(
            payload["giftSmallImg"] ?? payload["smallImg"] ?? payload["giftImg"]
        )?.nilIfEmpty

        return GiftEffectItem(
            sceneKey: sceneKey,
            senderYxAccid: senderYxAccid,
            senderNickname: senderNickname,
            senderAvatarUrl: senderAvatar,
            giftId: giftId,
            giftName: giftName,
            giftCount: giftCount,
            giftPrice: giftPrice,
            animationUrl: animationUrl,
            staticImgUrl: staticImg,
            timestamp: now(),
            isSelfSent: !senderYxAccid.isEmpty && senderYxAccid == mineYxAccid
        )
    }

    // MARK: - Private helpers

    /// 只允许 .svga / .mp4 后缀通过；否则返回 nil
    private static func normalizeAnimationUrl(_ url: String?) -> String? {
        guard let u = url,
              let parsed = URL(string: u) else { return nil }
        let ext = parsed.pathExtension.lowercased()
        return ["svga", "mp4"].contains(ext) ? u : nil
    }

    /// 多字段 fallback 解析 senderYxAccid
    private static func decodeSender(_ payload: [String: Any]) -> String? {
        // 兼容后端多种字段名（真机实测 attachType=50 payload 里是 sendYxAccid）
        if let s = payload["senderYxAccid"] as? String, !s.isEmpty { return s }
        if let s = payload["sendYxAccid"] as? String, !s.isEmpty { return s }
        // Party 场景 2049 payload 结构 sender 可能嵌在 sendUser 里（待真机验证；见
        // .claude/rules/im-payload-real-log-over-code-assumption 精神——防御性 fallback，
        // 若真机 party me-sent 插队不生效需按 log 补 sendUser 里的实际字段名）
        if let dict = payload["sendUser"] as? [String: Any],
           let s = dict["yxAccid"] as? String, !s.isEmpty { return s }
        if let dict = payload["senderInfo"] as? [String: Any],
           let s = dict["yxAccid"] as? String, !s.isEmpty { return s }
        if let s = payload["fromAccid"] as? String, !s.isEmpty { return s }
        return nil
    }

    /// String / Int / Int64 / NSNumber 全兼容解析为 Int64（规则 ios-decode-userid-compat）
    private static func decodeInt64(_ any: Any?) -> Int64? {
        if let i = any as? Int64 { return i }
        if let i = any as? Int { return Int64(i) }
        if let n = any as? NSNumber { return n.int64Value }
        if let s = any as? String, let i = Int64(s) { return i }
        return nil
    }

    /// String / Int / NSNumber 全兼容解析为 Int
    private static func decodeInt(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let n = any as? NSNumber { return n.intValue }
        if let s = any as? String, let i = Int(s) { return i }
        return nil
    }

    /// 安全取字符串并 trim 空白
    private static func decodeString(_ any: Any?) -> String? {
        guard let s = any as? String else { return nil }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - String extension

private extension String {
    /// trim 后为空则返回 nil
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
