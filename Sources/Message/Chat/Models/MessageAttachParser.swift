import Foundation

/// P2P 消息 custom attach 解析（H-2 spec §1.12 + §2.4）。
///
/// **对齐安卓 `CustomAttachParser`** 双分支模型 —— 避免 H5 里 attachType 散落 if 判断的可维护性坑：
/// - 分支 1: NIM 内置类型（text / audio / image / video）—— 由 NIM SDK 自身解析，本类不管
/// - 分支 2: `custom` attach，attachType 双语义：
///   - **字符串**：`SEND_GIFT` / `MISSED_CALLS_RECORD` → 特化 case
///   - **数字**：`-4` 关注 / `103` `104` 裂变 / `156` `157` 主播活动 → `.systemTip`
///
/// **H-2 范围**（spec §0.3 明示 + red team #11 分类）：
/// - 展示：SEND_GIFT / MISSED_CALLS_RECORD / weakTxtType 系统提示
/// - 保数据不展示：其他未识别 attachType → `.system(rawJSON:)`
enum MessageAttachParser {

    /// weakTxtType 数字系统提示白名单（对齐 H5 `stores/modules/message.js:130`）
    static let weakTxtTypes: Set<Int> = [-4, 103, 104, 156, 157]

    /// 主入口：从 attach dict + raw JSON 解析为 ChatMessageContent。
    /// - Parameters:
    ///   - attach: 反序列化后的 dict（NIMSDK rawAttachContent JSON 解析结果）
    ///   - rawJSON: 原始 JSON string（fallback 保数据用）
    static func parseCustom(_ attach: [String: Any], rawJSON: String) -> ChatMessageContent {
        guard let token = extractAttachType(attach) else {
            return .system(rawJSON: rawJSON)
        }
        switch token {
        case .string("SEND_GIFT"):
            return parseSendGift(attach) ?? .system(rawJSON: rawJSON)
        case .string("MISSED_CALLS_RECORD"):
            return parseMissedCall(attach) ?? .system(rawJSON: rawJSON)
        case .number(let n) where weakTxtTypes.contains(n):
            return parseSystemTip(attach, weakType: n) ?? .system(rawJSON: rawJSON)
        default:
            return .system(rawJSON: rawJSON)
        }
    }

    /// 提取 attachType（双分支：字符串 or 数字）
    static func extractAttachType(_ attach: [String: Any]) -> AttachTypeToken? {
        if let s = attach["attachType"] as? String, !s.isEmpty {
            return .string(s)
        }
        if let n = attach["attachType"] as? NSNumber {
            // NSNumber 桥接 Bool（objCType 'c'/'B'）排除，避免 true → 1 误判为 number attachType
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" {
                return .number(n.intValue)
            }
        }
        return nil
    }

    // MARK: - 内部：特化解析

    /// H5 `msgItem.vue:272-288`：`attach.smallImg` + `attach.giftNum`
    private static func parseSendGift(_ attach: [String: Any]) -> ChatMessageContent? {
        let smallImgURL = (attach["smallImg"] as? String).flatMap { URL(string: $0) }
        // giftNum 后端可能 Int/String（保守双兼容，对齐 ios-decode-userid-compat.md 精神）
        let giftNum: Int = {
            if let n = attach["giftNum"] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType != "c" && cType != "B" { return n.intValue }
            }
            if let s = attach["giftNum"] as? String, let n = Int(s) { return n }
            return 1
        }()
        return .systemGift(smallImg: smallImgURL, giftNum: max(1, giftNum))
    }

    /// H5 `msgItem.vue:297-314`：`attach.status`（nil/undefined = missed / 2 = canceled / 3 = rejected）
    private static func parseMissedCall(_ attach: [String: Any]) -> ChatMessageContent? {
        let status = (attach["status"] as? NSNumber)?.intValue
        let kind: MissedCallKind = {
            switch status {
            case 2: return .canceled
            case 3: return .rejected
            default: return .missed
            }
        }()
        return .missedCall(kind: kind)
    }

    /// weakTxtType 系统提示：文案由 H-3 阶段扩 L10n 映射；本 spec 直接取 attach 里可能的 text 字段兜底
    private static func parseSystemTip(_ attach: [String: Any], weakType: Int) -> ChatMessageContent? {
        // 常见字段：`text` / `content` / `msg` —— 后端多变，多路兜底
        let text = (attach["text"] as? String)
            ?? (attach["content"] as? String)
            ?? (attach["msg"] as? String)
            ?? ""
        return .systemTip(text: text, weakType: weakType)
    }

    // MARK: - H-3 新增：私密消息 remoteExt 解析（spec §1.1 / §3.4 / Critical-3 单源 remoteExt）

    /// 从 NIM `remoteExt` 判定是否私密消息，并抽出业务字段。
    ///
    /// **来源约定**（H5 `msgItem.vue:236-241` + `chat/index.vue:624-641`）：
    /// - `ext.extensionType == "privateMsg"` 是唯一私密标识（不是 attachType 数字）
    /// - `ext.data.iconType` 1=图片 / 2=视频
    /// - `ext.data.privateId` 后端派发业务 ID（**不是** NIM messageId）；`checkPrivateInfo` 入参
    /// - `ext.data.lockStatus` 0/1 or nil（`checkPrivateInfo` 后填；发送时 H5 从不写）
    ///
    /// **决策**（v2 Critical-3）：iOS NIMSDK_LITE 10.10.0 只有 `remoteExt` 单源；H5 Web SDK `serverExtension` quirk 不迁移。
    /// **decode 兼容**（rule ios-decode-userid-compat）：privateId String/Int/NSNumber 三路兜底。
    ///
    /// - Returns: nil = 非私密（走标准 image/video）；非 nil = 私密（NIMChatAdapter mapper 转 `.privateImage/.privateVideo`）
    static func extractPrivateInfo(remoteExt: [String: Any]?) -> PrivateMsgInfo? {
        guard let ext = remoteExt,
              (ext["extensionType"] as? String) == "privateMsg",
              let data = ext["data"] as? [String: Any],
              let iconTypeRaw = data["iconType"] as? Int,
              (iconTypeRaw == 1 || iconTypeRaw == 2)
        else { return nil }

        let privateId: String? = {
            if let s = data["privateId"] as? String, !s.isEmpty { return s }
            if let n = data["privateId"] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType != "c" && cType != "B" { return n.stringValue }
            }
            return nil
        }()
        guard let pid = privateId, !pid.isEmpty else { return nil }

        let lockStatus = PrivateLockStatus(rawInt: data["lockStatus"] as? Int)

        return PrivateMsgInfo(privateId: pid, iconType: iconTypeRaw, lockStatus: lockStatus)
    }

    /// 从 NIM `remoteExt` 解出主播透传的 `activeTycoon`（H-3 spec §1.5.6 / Major-4）。
    /// nil 表示对端未透传（三级 fallback 由 view 层组装）。
    static func extractActiveTycoon(remoteExt: [String: Any]?) -> Bool? {
        guard let ext = remoteExt else { return nil }
        return ext["activeTycoon"] as? Bool
    }

    /// 从 NIM `remoteExt` 解出对端穿戴的 `chatBubble` URL（H-3 spec §3.3 / Critical-3 单源）。
    /// 空字符串 / 非法 URL 返 nil；view 走默认圆角气泡兜底。
    static func extractChatBubble(remoteExt: [String: Any]?) -> URL? {
        guard let ext = remoteExt,
              let s = ext["chatBubble"] as? String, !s.isEmpty
        else { return nil }
        return URL(string: s)
    }
}

/// H-3 私密消息 remoteExt 解析结果（spec §1.1 / §3.4）
struct PrivateMsgInfo: Equatable, Hashable {
    let privateId: String
    let iconType: Int          // 1=图片 / 2=视频
    let lockStatus: PrivateLockStatus
}

/// attachType 双分支 token（H-2 spec §1.12 对齐安卓 CustomAttachmentType 枚举模型）
enum AttachTypeToken: Equatable, Hashable {
    case string(String)
    case number(Int)
}
