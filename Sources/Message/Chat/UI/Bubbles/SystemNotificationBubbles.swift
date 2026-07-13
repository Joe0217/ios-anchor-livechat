import SwiftUI

/// 系统通知会话专属气泡组件集（对齐 H5 `views/news/message/systemMsg.vue` + `cpRankRewardMsg.vue`）。
///
/// 5 类系统消息 UI 汇总在此文件,便于集中维护:
/// - `CpRankRewardBubbleView` — CP 榜奖励卡片
/// - `ItemNoticeBubbleView` — 虚拟道具收到/过期通知
/// - `RewardDiamondBubbleView` — 钻石到账
/// - `PunishmentAppealBubbleView` — 惩罚申诉("click here" attributed link)
/// - `RechargeNotifyBubbleView` — 充值通知("ID 12345" attributed link)
///
/// **交互降级**:H5 tap 卡片跳 `/rank` / `/virtualProps` / 调 `getPunishmentAppeal` iOS 未实装 →
/// 通过 `onComingSoon` 回调让 caller 弹 toast 提示"Coming soon"。真接入后替换回调即可。

// MARK: - 共享气泡基线样式（对齐 H5 `.msg-bubble`: 深色 #2B213E, 圆角 12, padding 8×12）

private struct SystemBubbleContainer<Content: View>: View {
    let maxWidth: CGFloat
    @ViewBuilder let content: () -> Content

    init(maxWidth: CGFloat = 260, @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        content()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(.white)
    }
}

// MARK: - 翻译 footer(对齐 H5 systemMsg.vue v-else CTranslate + border-t-1-gary translateText 分隔)

/// 系统消息翻译 footer:未翻译显示 Translate 按钮,已翻译显示分隔线 + 译文。
private struct SystemBubbleTranslateFooter: View {
    let translatedText: String?
    let onTranslate: (() -> Void)?

    var body: some View {
        Group {
            if let translated = translatedText {
                // 已翻译:分隔线 + 译文(对齐 H5 border-t-1-gary + mt-4 pt4)
                VStack(alignment: .leading, spacing: 2) {
                    Rectangle()
                        .fill(.white.opacity(0.2))
                        .frame(height: 0.5)
                        .padding(.top, 4)
                    Text(translated)
                        .font(.system(size: 14))
                        .lineSpacing(4)
                        .foregroundStyle(.white)
                        .padding(.top, 2)
                }
            } else if let onTap = onTranslate {
                // 未翻译:Translate 按钮
                Button(action: onTap) {
                    Text(L10n.chatTranslate)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(hex: 0xC49BFF))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - CP 榜奖励卡片（对齐 H5 cpRankRewardMsg.vue）

/// CP 榜奖励到账卡片 —— 顶图 + 主文案 + 道具横向滚 + Check Cp ranking CTA。
///
/// **交互**:tap 整卡 → onCheckCpRanking(降级 toast)。
/// **样式**:H5 用 #D5D5D5 亮底 + `0 16px 16px 16px` 圆角(左上直角);iOS 简化为通用深底,保留 CP 榜识别度靠顶图。
struct CpRankRewardBubbleView: View {
    let rankNo: Int
    let items: [CpRankRewardItem]
    let onCheckCpRanking: () -> Void
    var translatedText: String? = nil
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 主文案(非 Button,tap 不触发 comingSoon)
            Text(L10n.chatSystemCpRankRewardMsg(rank: rankNo))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            // 道具横向滚动列表
            if !items.isEmpty {
                Divider().background(Color.white.opacity(0.15))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            rewardItemCell(item)
                        }
                    }
                }
            }

            // 底部 CTA (独立 Button,tap 走 onCheckCpRanking;不影响外层其他区域)
            Button(action: onCheckCpRanking) {
                HStack(spacing: 2) {
                    Spacer()
                    Text(L10n.chatSystemCheckCpRanking)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: 0x8A9EE0))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(hex: 0x8A9EE0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 翻译 footer(独立于 comingSoon CTA,tap 走 handleTranslate)
            SystemBubbleTranslateFooter(translatedText: translatedText, onTranslate: onTranslate)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: 260, alignment: .leading)
        .background(Color(hex: 0x2B213E), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// 单个道具展示:icon + 名字 + 数量/时长
    private func rewardItemCell(_ item: CpRankRewardItem) -> some View {
        VStack(spacing: 4) {
            if let iconURLStr = item.itemIcon, let url = URL(string: iconURLStr) {
                CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                    Color.white.opacity(0.05)
                }
                .frame(width: 32, height: 32)
            } else {
                Color.white.opacity(0.05).frame(width: 32, height: 32)
            }
            Text(item.itemName)
                .font(.system(size: 9))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: 56)
            Text(quantityLabel(for: item))
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color(hex: 0xE9A65B))
        }
    }

    /// itemType 7/8 (钻石/聊天卡) 显示 × N;其他显示 × Nd(时限型)。对齐 H5 QUANTITY_ITEM_TYPES = {7,8}
    private func quantityLabel(for item: CpRankRewardItem) -> String {
        if item.itemType == 7 || item.itemType == 8 {
            return "× \(item.quantity)"
        }
        return "× \(item.durationDays)d"
    }
}

// MARK: - 虚拟道具通知（对齐 H5 systemMsg.vue ITEM_GET_NOTICE / ITEM_EXPIRED_NOTICE）

/// 虚拟道具收到 / 过期通知 —— 深气泡 + 文案 + View Now CTA(仅 get 类显示)。
struct ItemNoticeBubbleView: View {
    let kind: ItemNoticeKind
    let itemName: String
    let itemType: Int
    let addTime: Int64?
    let onViewNow: () -> Void
    var translatedText: String? = nil
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        SystemBubbleContainer {
            VStack(alignment: .leading, spacing: 4) {
                Text(fullText)
                    .font(.system(size: 14))
                    .lineSpacing(4)

                // 只有 GET 类才有 View Now CTA(EXPIRED 是已过期,无跳转意义)
                if kind == .get {
                    Button(action: onViewNow) {
                        Text(L10n.chatSystemViewNow)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color(hex: 0xC49BFF))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // 翻译 footer(iOS 补齐,H5 line 270-279 注释掉了但保留代码,产品意图希望翻译)
                SystemBubbleTranslateFooter(translatedText: translatedText, onTranslate: onTranslate)
            }
        }
    }

    private var fullText: String {
        let typeName = Self.itemTypeName(itemType)
        switch kind {
        case .get:
            let duration = addTime.map { Self.formatDuration($0) } ?? ""
            return L10n.chatSystemItemGet(itemName: itemName, itemType: typeName, duration: duration)
        case .expired:
            return L10n.chatSystemItemExpired(itemName: itemName, itemType: typeName)
        }
    }

    /// itemType 1-5 映射(对齐 H5 systemMsg.vue:178-188)
    static func itemTypeName(_ type: Int) -> String {
        switch type {
        case 1: return L10n.chatSystemItemTypeVehicle
        case 2: return L10n.chatSystemItemTypeFrame
        case 3: return L10n.chatSystemItemTypeEntrance
        case 4: return L10n.chatSystemItemTypeChatSkin
        case 5: return L10n.chatSystemItemTypeCardFrame
        default: return ""
        }
    }

    /// 时长格式化(对齐 H5 systemMsg.vue formatDuration:-1 = Perm / X hour(s) Y minute(s) / &lt;1h 只 minute)
    static func formatDuration(_ millis: Int64) -> String {
        if millis == -1 { return L10n.chatSystemDurationPerm }
        let totalMinutes = Int(millis / (60 * 1000))
        let hours = Int(millis / (60 * 60 * 1000))
        let minutes = totalMinutes - (hours * 60)
        if hours > 0 {
            if minutes > 0 {
                return L10n.chatSystemDurationHourMinute(hour: hours, minute: minutes)
            }
            return L10n.chatSystemDurationHour(hour: hours)
        }
        return L10n.chatSystemDurationMinute(minute: minutes)
    }
}

// MARK: - 钻石到账（对齐 H5 systemMsg.vue viewFlag=8 分支）

/// "Congratulations! You've received Diamond*X" 硬编码文案气泡。
struct RewardDiamondBubbleView: View {
    let demoContent: String
    var translatedText: String? = nil
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        SystemBubbleContainer {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.chatSystemRewardDiamond(count: demoContent))
                    .font(.system(size: 14))
                    .lineSpacing(4)
                SystemBubbleTranslateFooter(translatedText: translatedText, onTranslate: onTranslate)
            }
        }
    }
}

// MARK: - 惩罚申诉（对齐 H5 systemMsg.vue penaltyUserId + click here 可 tap）

/// 惩罚申诉气泡 —— body 内 "click here" 高亮为可点击链接;tap 触发 onAppeal 回调;已申诉态灰化。
///
/// **状态**:`isAppealed` 由父视图内存态维护(对齐 H5 `item.isAppeal`,不持久化)。
struct PunishmentAppealBubbleView: View {
    let text: String
    let penaltyUserId: String
    let isAppealed: Bool
    let onAppeal: () -> Void
    var translatedText: String? = nil
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        SystemBubbleContainer {
            VStack(alignment: .leading, spacing: 4) {
                Text(attributedBody)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .environment(\.openURL, OpenURLAction { url in
                        // 用 sentinel URL scheme 承载 tap 意图(SwiftUI AttributedString link 只能是 URL)
                        if url.scheme == "hily-appeal", !isAppealed {
                            onAppeal()
                            return .handled
                        }
                        return .discarded
                    })
                SystemBubbleTranslateFooter(translatedText: translatedText, onTranslate: onTranslate)
            }
        }
    }

    private var attributedBody: AttributedString {
        var attributed = AttributedString(text)
        let keyword = L10n.chatSystemAppealClickHere
        // 从后往前找最后一个 keyword —— 对齐 H5 正则 /(click here)(?!.*(click here))/g
        if let range = attributed.range(of: keyword, options: .backwards) {
            attributed[range].foregroundColor = isAppealed
                ? Color(hex: 0x999999)
                : Color(hex: 0x0443C7)
            attributed[range].underlineStyle = .single
            if !isAppealed {
                // 用 sentinel scheme 承载 tap
                attributed[range].link = URL(string: "hily-appeal://\(penaltyUserId)")
            }
        }
        return attributed
    }
}

// MARK: - 充值通知（对齐 H5 systemMsg.vue attachType=35 + ID 12345 可点跳详情）

/// 充值通知气泡 —— content 里 "ID 数字" 高亮紫色链接,tap 跳用户详情页。
struct RechargeNotifyBubbleView: View {
    let content: String
    let targetUserId: String?
    let onTapUserId: (String) -> Void
    var translatedText: String? = nil
    var onTranslate: (() -> Void)? = nil

    var body: some View {
        SystemBubbleContainer {
            VStack(alignment: .leading, spacing: 4) {
                Text(attributedContent)
                    .font(.system(size: 14))
                    .lineSpacing(4)
                    .environment(\.openURL, OpenURLAction { url in
                        // 用 sentinel scheme "hily-userprofile://<userId>" 承载 tap
                        if url.scheme == "hily-userprofile", let uid = url.host, !uid.isEmpty {
                            onTapUserId(uid)
                            return .handled
                        }
                        return .discarded
                    })
                SystemBubbleTranslateFooter(translatedText: translatedText, onTranslate: onTranslate)
            }
        }
    }

    /// 用正则匹配 `ID (\d+)` → 紫色下划线 + link(对齐 H5 formatRechargeContent regex /ID\s+(\d+)/g)
    private var attributedContent: AttributedString {
        var attributed = AttributedString(content)
        guard let regex = try? NSRegularExpression(pattern: #"ID\s+(\d+)"#) else { return attributed }
        let nsContent = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: nsContent.length))
        // 从后往前替换,避免 range 偏移
        for match in matches.reversed() {
            let digitsRange = match.range(at: 1)   // 只对数字部分加样式
            guard digitsRange.location != NSNotFound,
                  let swiftRange = Range(digitsRange, in: content),
                  let attributedRange = attributed.range(of: String(content[swiftRange])) else { continue }
            attributed[attributedRange].foregroundColor = Color(hex: 0x7C3AED)
            attributed[attributedRange].underlineStyle = .single
            attributed[attributedRange].link = URL(string: "hily-userprofile://\(content[swiftRange])")
        }
        return attributed
    }
}

// MARK: - Preview

#if DEBUG
struct SystemNotificationBubbles_Previews: PreviewProvider {
    static var previews: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                CpRankRewardBubbleView(
                    rankNo: 3,
                    items: [
                        CpRankRewardItem(itemIcon: nil, itemName: "Diamond", itemType: 7, quantity: 100, durationDays: 0),
                        CpRankRewardItem(itemIcon: nil, itemName: "Car", itemType: 1, quantity: 1, durationDays: 7),
                    ],
                    onCheckCpRanking: {}
                )
                ItemNoticeBubbleView(kind: .get, itemName: "Golden Wing", itemType: 1, addTime: 3600 * 1000 * 24, onViewNow: {})
                ItemNoticeBubbleView(kind: .expired, itemName: "Purple Frame", itemType: 2, addTime: nil, onViewNow: {})
                RewardDiamondBubbleView(demoContent: "50")
                PunishmentAppealBubbleView(
                    text: "Your account was warned for violation. If you disagree, click here to appeal.",
                    penaltyUserId: "u123",
                    isAppealed: false,
                    onAppeal: {}
                )
                PunishmentAppealBubbleView(
                    text: "Your account was warned. If you disagree, click here to appeal.",
                    penaltyUserId: "u123",
                    isAppealed: true,
                    onAppeal: {}
                )
                RechargeNotifyBubbleView(
                    content: "User ID 100234 just recharged 50 USD. Send them a gift now!",
                    targetUserId: "100234",
                    onTapUserId: { _ in }
                )
            }
            .padding()
        }
        .background(Color.black)
        .previewDisplayName("System Notification Bubbles")
    }
}
#endif
