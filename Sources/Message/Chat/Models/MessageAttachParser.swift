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

    /// 主入口：从 attach dict + raw JSON + remoteExt 解析为 ChatMessageContent。
    /// - Parameters:
    ///   - attach: 反序列化后的 dict（NIMSDK rawAttachContent JSON 解析结果）
    ///   - rawJSON: 原始 JSON string（fallback 保数据用）
    ///   - remoteExt: NIM message.remoteExt（H5 systemMsg.vue 里 `item.ext`）—— viewFlag / penaltyUserId 判定用
    static func parseCustom(_ attach: [String: Any], rawJSON: String, remoteExt: [String: Any]? = nil) -> ChatMessageContent {
        // 判定优先级对齐 H5 `systemMsg.vue` v-if 链 + `msgItem.vue`:
        // 1. attach.attachType 字符串特化 (CP_RANK / ITEM_NOTICE / SEND_GIFT / MISSED_CALLS_RECORD)
        // 2. ext.viewFlag == 8 (rewardDiamond) —— 属兜底分支内特化,但从 attach 无 attachType 分辨
        // 3. ext.penaltyUserId 非空 (punishmentAppeal)
        // 4. attach.attachType == 35 (rechargeNotify)
        // 5. attach.attachType 数字 weakTxtType 白名单 (systemTip)
        // 6. 兜底 textContentFallback → .systemFallback
        let token = extractAttachType(attach)

        // 优先级 1: 字符串 attachType 特化
        if case .string(let s) = token {
            switch s {
            case "CP_RANK_REWARD_NOTIFY":
                if let msg = parseCpRankReward(attach) { return msg }
            case "ITEM_GET_NOTICE":
                if let msg = parseItemNotice(attach, kind: .get) { return msg }
            case "ITEM_EXPIRED_NOTICE":
                if let msg = parseItemNotice(attach, kind: .expired) { return msg }
            case "SEND_GIFT":
                if let msg = parseSendGift(attach) { return msg }
            case "MISSED_CALLS_RECORD":
                if let msg = parseMissedCall(attach) { return msg }
            default:
                break
            }
        }

        // 优先级 2-3: ext 特化（H5 里 item.ext == remoteExt）
        if let ext = remoteExt {
            if extractInt(ext["viewFlag"]) == 8 {
                let demo = (ext["demoContent"] as? String) ?? ""
                return .rewardDiamond(demoContent: demo)
            }
            if let penaltyId = extractPenaltyUserId(ext) {
                let body = textContentFallbackString(attach) ?? ""
                return .punishmentAppeal(text: body, penaltyUserId: penaltyId)
            }
        }

        // 优先级 4: attachType == 35 充值通知
        if case .number(35) = token {
            let content = (attach["content"] as? String) ?? textContentFallbackString(attach) ?? ""
            let targetUserId = extractStringOrNumberAsString(attach["userId"])
            let targetYxAccId = attach["yxAccid"] as? String
            return .rechargeNotify(content: content, targetUserId: targetUserId, targetYxAccId: targetYxAccId)
        }

        // 优先级 5: weakTxtType 白名单
        if case .number(let n) = token, weakTxtTypes.contains(n) {
            return parseSystemTip(attach, weakType: n) ?? .system(rawJSON: rawJSON)
        }

        // 优先级 6: 兜底 —— 有 content/text/body 用 .systemFallback（不再 .text 混淆）；否则 .system 保 raw
        if let text = textContentFallbackString(attach) {
            return .systemFallback(text: text)
        }
        return .system(rawJSON: rawJSON)
    }

    /// unknown attachType 兜底：attach.content/text/msg/body 任一非空 → 转 .text case 显示（对齐 H5 msgObj.body 语义）
    /// **保留**用于兼容旧调用点；新调用点用 `textContentFallbackString` + `.systemFallback`
    private static func textContentFallback(_ attach: [String: Any]) -> ChatMessageContent? {
        textContentFallbackString(attach).map { .text($0) }
    }

    /// 提取 attach 内的兜底文本字段（对齐 H5 handleXxxNotification `msgObj.body = attach.content`）。
    private static func textContentFallbackString(_ attach: [String: Any]) -> String? {
        let text = (attach["content"] as? String)
            ?? (attach["text"] as? String)
            ?? (attach["msg"] as? String)
            ?? (attach["body"] as? String)
            ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Int/NSNumber 双兼容抽取（用于 ext.viewFlag 判定 —— 后端可能返 8 或 "8"）
    private static func extractInt(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" { return n.intValue }
        }
        if let s = any as? String { return Int(s) }
        return nil
    }

    /// ext.penaltyUserId 双兼容抽取（可能是 Int 或 String）
    private static func extractPenaltyUserId(_ ext: [String: Any]) -> String? {
        guard let raw = ext["penaltyUserId"] else { return nil }
        return extractStringOrNumberAsString(raw)
    }

    /// String / NSNumber / Int 兼容转 String（rule ios-decode-userid-compat 精神）
    private static func extractStringOrNumberAsString(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let n = any as? NSNumber {
            let cType = String(cString: n.objCType)
            if cType != "c" && cType != "B" { return n.stringValue }
        }
        if let i = any as? Int { return String(i) }
        return nil
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

    // MARK: - 系统通知会话消息类型（对齐 H5 `views/news/message/systemMsg.vue` + `cpRankRewardMsg.vue`）

    /// CP 榜奖励卡片 —— attachType == "CP_RANK_REWARD_NOTIFY"
    /// H5 `cpRankRewardMsg.vue:27` 取 `data.value?.rankNo`,`data.value?.items[]`。
    /// 但 H5 里 `data` = `props.item`(整个 message),`items` 与 `rankNo` 可能是 attach 直连字段或嵌套 —— 双兼容取。
    private static func parseCpRankReward(_ attach: [String: Any]) -> ChatMessageContent? {
        let rankNo: Int = extractInt(attach["rankNo"]) ?? 1
        let rawItems = (attach["items"] as? [[String: Any]]) ?? []
        let items: [CpRankRewardItem] = rawItems.compactMap { dict in
            let name = (dict["itemName"] as? String) ?? ""
            guard !name.isEmpty else { return nil }
            return CpRankRewardItem(
                itemIcon: dict["itemIcon"] as? String,
                itemName: name,
                itemType: extractInt(dict["itemType"]) ?? 0,
                quantity: extractInt(dict["quantity"]) ?? 1,
                durationDays: extractInt(dict["durationDays"]) ?? 0
            )
        }
        return .cpRankReward(rankNo: rankNo, items: items)
    }

    /// 虚拟道具通知 —— attachType == "ITEM_GET_NOTICE" / "ITEM_EXPIRED_NOTICE"
    /// H5 `systemMsg.vue:173-200`:`attachment.itemName / itemType / addTime`
    private static func parseItemNotice(_ attach: [String: Any], kind: ItemNoticeKind) -> ChatMessageContent? {
        let itemName = (attach["itemName"] as? String) ?? ""
        let itemType = extractInt(attach["itemType"]) ?? 0
        let addTime: Int64? = {
            if kind == .get {
                if let n = extractInt(attach["addTime"]) { return Int64(n) }
            }
            return nil
        }()
        return .itemNotice(kind: kind, itemName: itemName, itemType: itemType, addTime: addTime)
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

    /// 从 NIM `remoteExt` 解出用户消息 `msgType`（`"pay"` / `"free"`）—— 对齐 H5 `msg.ext?.msgType || 'pay'`
    /// （`message.js:1076` / `chat/index.vue:802`）。用于 ReplyPointsStore 结算前累加 payMsgPoints / freeMsgPoints。
    /// nil = 后端未派发，caller 走 "pay" 兜底。
    static func extractMsgType(remoteExt: [String: Any]?) -> String? {
        guard let ext = remoteExt,
              let s = ext["msgType"] as? String, !s.isEmpty
        else { return nil }
        return s
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
