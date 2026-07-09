import SwiftUI

/// v8 公屏消息 row 分派子视图 —— 按 `PublicChatMessage.messageType` 各自处理背景/图标/昵称/正文
///
/// 每个子视图独立文件级 struct，避免 SwiftUI type-check timeout；由 `LiveRoomChatRow` 分派
/// 对齐 H5 messageScroller.vue L120-350 分类样式

/// 普通聊天 / 主播消息 row（对齐 H5 template L120-180）+ v9 翻译按钮 Stub
struct ChatRowRegular: View {
    let message: PublicChatMessage
    private var isAnchor: Bool { message.messageType == .anchor }

    /// v9 翻译状态（local @State per row instance；stub 场景够用，H 里程碑迁 store）
    @State private var translatePhase: TranslatePhase = .idle

    enum TranslatePhase: Equatable {
        case idle
        case translating
        case translated(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 4) {
                // 等级徽章
                if let lv = message.userLevel {
                    LevelBadge(level: lv)
                }
                // Host / VIP 徽章
                if message.isHost { HostBadge() }
                if message.isVip { VipBadge() }
                // 昵称 + 正文
                Group {
                    if let nick = message.senderNickname {
                        Text("\(nick): ")
                            .foregroundColor(isAnchor ? Color(hex: 0xFE00DE) : Color(hex: 0x1AFFCD))
                            + Text(message.text).foregroundColor(.white)
                    } else {
                        Text(message.text).foregroundColor(.white)
                    }
                }
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                // v9 翻译按钮（对齐 H5 CTranslate）
                translateButton
            }
            // 翻译结果显示（对齐 H5 CTranslate 结果换行显示）
            translateResultView
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            isAnchor
                ? Color(hex: 0x9817CA, opacity: 0.16)
                : Color.black.opacity(0.16),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var translateButton: some View {
        if case .idle = translatePhase {
            Button {
                startTranslate()
            } label: {
                Image(systemName: "character.bubble")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.5))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(L10n.publicScreenTranslate))
        }
    }

    @ViewBuilder
    private var translateResultView: some View {
        switch translatePhase {
        case .idle:
            EmptyView()
        case .translating:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.6).tint(.white.opacity(0.6))
                Text(L10n.publicScreenTranslating)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.5))
            }
        case .translated(let text):
            Text(text)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func startTranslate() {
        translatePhase = .translating
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)   // Stub 2s
            // TODO H 里程碑：接真 /api/xxx/translate API；当前用 "[Translated: 原文]" 占位
            translatePhase = .translated("[Translated: \(message.text)]")
        }
    }
}

/// 送礼消息 row（对齐 H5 messageScroller.vue L486-517）
///
/// **H5 三分支视觉**（VIP / NewUser / Regular）：
/// - 背景：`rgba(0,0,0,0.16)` 深灰透明 + rounded-12 + px8 py5
/// - 徽章顺序：LevelBadge → [VipBadge if isVip] → [NewUserBadge if isNewUser] → 昵称 → "Send"/"Sent" → 礼物图 16×16 → "x N"
/// - 昵称统一青绿 `#1AFFCD`（不分主播态；礼物 row 一律青绿），字号 12pt weight 500
/// - "Send"（VIP/Regular）/ "Sent"（NewUser）文案 —— iOS 简化为统一 "Send"（对齐主流场景）
/// - 礼物图 `h16 w16` + "×N" 白色字号 12pt weight 500
struct ChatRowGift: View {
    let message: PublicChatMessage
    private var giftInfo: (iconUrl: String?, name: String, count: Int)? {
        if case .gift(let icon, let name, let count) = message.messageType {
            return (icon, name, count)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let lv = message.userLevel { LevelBadge(level: lv) }
            if message.isVip { VipBadge() }
            if let nick = message.senderNickname, !nick.isEmpty {
                Text(nick)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color(hex: 0x1AFFCD))   // v12: H5 gift row 昵称一律青绿
                    .lineLimit(1)
            }
            Text(L10n.publicScreenSentAction)              // H5 "Send"（对齐 common.Send i18n）
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
            if let g = giftInfo {
                giftIcon(g.iconUrl)
                Text("×\(g.count)")                        // v12: H5 视觉为 "x N" 白色 12pt
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            Color.black.opacity(0.16),                     // v12: 深灰透明（H5 rgba(0,0,0,0.16)），非粉品红渐变
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    /// 礼物图 16×16（H5 img h16 w16）。真 iconUrl 优先，无图 fallback 到金色 gift.fill 占位
    @ViewBuilder
    private func giftIcon(_ url: String?) -> some View {
        if let s = url, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fit)
                default:
                    Image(systemName: "gift.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: 0xFFE600))
                }
            }
            .frame(width: 16, height: 16)
        } else {
            Image(systemName: "gift.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: 0xFFE600))
                .frame(width: 16, height: 16)
        }
    }
}

/// 用户进入房间 row（对齐 H5 template L280-310）
struct ChatRowEnterRoom: View {
    let message: PublicChatMessage
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            if let lv = message.userLevel { LevelBadge(level: lv) }
            if message.isVip { VipBadge() }
            if let nick = message.senderNickname {
                Text(nick)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1AFFCD))
            }
            Text(L10n.publicScreenEnteredRoom)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            LinearGradient(colors: [Color(hex: 0x5300A1, opacity: 0.5), Color(hex: 0x3800A0, opacity: 0.2)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// PK 通知 row（对齐 H5 template L315-330，橙色半透）
struct ChatRowPKNotify: View {
    let message: PublicChatMessage
    var body: some View {
        Text(message.text)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color(hex: 0xD43801, opacity: 0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 直播公告 row（对齐 H5 template L340-360，蓝紫色 + 喇叭图标）
struct ChatRowAnnouncement: View {
    let message: PublicChatMessage
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "megaphone.fill")
                .font(.system(size: 12))
                .foregroundColor(Color(hex: 0xFFE600))
            Text(message.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Color(hex: 0x0000FF, opacity: 0.36), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// 猜拳/转盘/其他系统消息通用 row（黄色 fallback）
struct ChatRowSystem: View {
    let message: PublicChatMessage
    var body: some View {
        Text(message.text)
            .font(.system(size: 12))
            .foregroundColor(Color.yellow.opacity(0.9))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - v18 新增 row 类型（对齐 H5 messageScroller.vue 完整分支）

/// v18 幸运礼物中奖 row（对齐 H5 L474-484 `.lucky-gift-box`）
///
/// 视觉：粉→黄渐变背景 `rgba(255,50,227,0.8) → rgba(248,201,48,0.8)` + rounded-24 + h50
/// 结构：luck-gift icon + 昵称 `#1AFFCD` + "wins" + reward `#F2FF00` 荧光黄 + "by sending lucky" + giftImg + "×N"
struct ChatRowLuckyGift: View {
    let message: PublicChatMessage
    private var info: (iconUrl: String?, count: Int, totalReward: Int64)? {
        if case .luckyGift(let icon, let count, let total) = message.messageType {
            return (icon, count, total)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            // 幸运礼物图标（H5 luck-gift.png h28 w28）
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundColor(Color(hex: 0xF2FF00))
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            if let g = info {
                (
                    Text((message.senderNickname ?? ""))
                        .foregroundColor(Color(hex: 0x1AFFCD))
                        .font(.system(size: 13, weight: .semibold))
                    + Text(" \(L10n.publicScreenLuckyWin) ")
                        .foregroundColor(.white)
                        .font(.system(size: 13))
                    + Text("\"\(g.totalReward) 💎\" ")
                        .foregroundColor(Color(hex: 0xF2FF00))
                        .font(.system(size: 13, weight: .semibold))
                    + Text(L10n.publicScreenLuckyBySending)
                        .foregroundColor(.white)
                        .font(.system(size: 13))
                    + Text(" ×\(g.count)")
                        .foregroundColor(.white)
                        .font(.system(size: 13, weight: .medium))
                )
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 10)
        .background(
            LinearGradient(colors: [Color(hex: 0xFF32E3, opacity: 0.8),
                                    Color(hex: 0xF8C930, opacity: 0.8)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 24)
        )
    }
}

/// v18 猜拳获胜 row（对齐 H5 L549-562 `.rps-win-msg`）
///
/// 视觉：紫渐变 `rgba(160,101,216,0.6) → 透明` + border `rgba(174,221,255,0.6)` + rounded-14
/// 结构：ye icon + 昵称 `#FFE000 黄粗体` + "wins RPS" + "get" + medalUrl + medalHours
struct ChatRowRpsWin: View {
    let message: PublicChatMessage
    private var rpsInfo: (medalUrl: String?, medalHours: Int?)? {
        if case .rpsWin(let url, let hours) = message.messageType {
            return (url, hours)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            // 猜拳手势图标（H5 ye.webp h28 w28）
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(message.senderNickname ?? "")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundColor(Color(hex: 0xFFE000))
                        .lineLimit(1)
                    Text(L10n.publicScreenRpsWin)
                        .font(.system(size: 13))
                        .foregroundColor(.white)
                }
                if let info = rpsInfo {
                    HStack(spacing: 4) {
                        Text(L10n.publicScreenRpsGet)
                            .font(.system(size: 12))
                            .foregroundColor(.white)
                        if let url = info.medalUrl, let u = URL(string: url) {
                            AsyncImage(url: u) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().aspectRatio(contentMode: .fit)
                                } else {
                                    Image(systemName: "rosette").foregroundColor(Color(hex: 0xFFE000))
                                }
                            }
                            .frame(width: 50, height: 14)
                        }
                        if let hours = info.medalHours {
                            Text("*\(hours)h")
                                .font(.system(size: 12))
                                .foregroundColor(.white)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            LinearGradient(colors: [Color(hex: 0xA065D8, opacity: 0.6), Color(hex: 0xA065D8, opacity: 0)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color(hex: 0xAEDDFF, opacity: 0.6), lineWidth: 1)
        )
    }
}

/// v18 转盘结果 row（对齐 H5 L529-547）
///
/// 视觉：橙色半透背景 `rgba(238,102,67,0.6)` + border `rgb(255,190,174)/60` + rounded-24
/// 结构：roulette icon + 昵称 `#1AFFCD` + "hit" + result `#FFED68 亮黄` + "on the wheel"
struct ChatRowWheelRes: View {
    let message: PublicChatMessage
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "circle.grid.hex.fill")
                .font(.system(size: 18))
                .foregroundColor(.white)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            (
                Text(message.senderNickname ?? "")
                    .foregroundColor(Color(hex: 0x1AFFCD))
                    .font(.system(size: 13, weight: .bold))
                + Text(" \(L10n.publicScreenWheelHit) ")
                    .foregroundColor(.white)
                    .font(.system(size: 13))
                + Text("\"\(message.text)\"")
                    .foregroundColor(Color(hex: 0xFFED68))
                    .font(.system(size: 13, weight: .bold))
                + Text(" \(L10n.publicScreenWheelOnTheWheel)")
                    .foregroundColor(.white)
                    .font(.system(size: 13))
            )
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(hex: 0xEE6643, opacity: 0.6), in: RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .stroke(Color(red: 1, green: 190/255, blue: 174/255, opacity: 0.6), lineWidth: 1)
        )
    }
}

/// v18 活动中奖广播 row（对齐 H5 L606-650 winner_broadcast marquee）
///
/// 视觉：淡金→淡粉渐变，跑马灯效果（本会话静态展示，marquee 动画留 v19+）
/// 结构：奖杯 icon + 昵称 `#FFD84E 活动黄` + "wins" + activityName + "×quantity"
struct ChatRowWinnerBroadcast: View {
    let message: PublicChatMessage
    private var info: (activityName: String, quantity: Int?)? {
        if case .winnerBroadcast(let name, let qty) = message.messageType {
            return (name, qty)
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "trophy.fill")
                .font(.system(size: 16))
                .foregroundColor(Color(hex: 0xFFD84E))
                .frame(width: 22, height: 22)
                .accessibilityHidden(true)

            if let info {
                (
                    Text(message.senderNickname ?? "")
                        .foregroundColor(Color(hex: 0xFFD84E))
                        .font(.system(size: 13, weight: .bold))
                    + Text(" \(L10n.publicScreenLuckyWin) ")
                        .foregroundColor(.white)
                        .font(.system(size: 13))
                    + Text(info.activityName)
                        .foregroundColor(Color(hex: 0xFFED68))
                        .font(.system(size: 13, weight: .semibold))
                    + Text(info.quantity.map { " ×\($0)" } ?? "")
                        .foregroundColor(.white)
                        .font(.system(size: 13))
                )
                .lineLimit(1)
                .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(
            LinearGradient(colors: [Color(hex: 0xFFB400, opacity: 0.25),
                                    Color(hex: 0xFF50B4, opacity: 0.25)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// v18 官方推荐进房 row（对齐 H5 L595 inLiveChannel===1）
///
/// 视觉：蓝色渐变 `#5F8FBC 50% → transparent` + Official Boost✨ 前缀 `#FFE600`
struct ChatRowOfficialBoostEnter: View {
    let message: PublicChatMessage
    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            Text("Official Boost✨")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(Color(hex: 0xFFE600))
            if let nick = message.senderNickname {
                Text(nick)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1AFFCD))
            }
            Text(L10n.publicScreenEnteredRoom)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(
            LinearGradient(colors: [Color(hex: 0x5F8FBC).opacity(0.6), Color.clear],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// v18 心愿单登顶 row（对齐 H5 L600-604 wishlist_effect）
///
/// 简化版：显示 "🎁 {昵称} became TOP1 gifter!"（H5 是异步组件 wishlist-chat-effect，视觉复杂）
struct ChatRowWishlistEffect: View {
    let message: PublicChatMessage
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "crown.fill")
                .font(.system(size: 14))
                .foregroundColor(Color(hex: 0xFFBB02))
            if let nick = message.senderNickname {
                Text(nick)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: 0x1AFFCD))
            }
            Text(L10n.publicScreenWishlistTop1)
                .font(.system(size: 12))
                .foregroundColor(.white)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            LinearGradient(colors: [Color(hex: 0xFF9438, opacity: 0.3),
                                    Color(hex: 0xFF0090, opacity: 0.3),
                                    Color(hex: 0xFE00DE, opacity: 0.3)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }
}

/// v18 钻石盲盒 4 子类型 row（对齐 H5 L523-527 DiamondGiftChatMessage）
///
/// **占位实现**（H 期完整实现钻石盲盒详细弹窗 + 飘屏）：4 subType 用不同 icon + 简要文案表达
struct ChatRowDiamondGift: View {
    let message: PublicChatMessage
    private var subType: DiamondGiftSubType? {
        if case .diamondGift(let sub) = message.messageType { return sub }
        return nil
    }

    var body: some View {
        HStack(spacing: 6) {
            iconImage
            content
                .font(.system(size: 12))
                .foregroundColor(.white)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            LinearGradient(colors: [Color(hex: 0x9C27B0, opacity: 0.35),
                                    Color(hex: 0x4A148C, opacity: 0.35)],
                           startPoint: .leading, endPoint: .trailing),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    @ViewBuilder
    private var iconImage: some View {
        Image(systemName: "shippingbox.fill")
            .font(.system(size: 14))
            .foregroundColor(Color(hex: 0xF2FF00))
            .frame(width: 18, height: 18)
    }

    @ViewBuilder
    private var content: some View {
        switch subType {
        case .send(let sender, let tier, let total):
            (
                Text(sender).foregroundColor(Color(hex: 0x1AFFCD)).font(.system(size: 12, weight: .semibold))
                + Text(" \(L10n.publicScreenDiamondBoxSend) ").foregroundColor(.white)
                + Text(tier ?? "").foregroundColor(Color(hex: 0xFFE000))
                + Text(" \(total)💎").foregroundColor(Color(hex: 0xF2FF00)).font(.system(size: 12, weight: .semibold))
            )
        case .claim(let user, let diamonds):
            (
                Text(user).foregroundColor(Color(hex: 0x1AFFCD)).font(.system(size: 12, weight: .semibold))
                + Text(" \(L10n.publicScreenDiamondBoxClaim) ").foregroundColor(.white)
                + Text("\(diamonds)💎").foregroundColor(Color(hex: 0xF2FF00)).font(.system(size: 12, weight: .semibold))
            )
        case .settled(let user, let diamonds):
            (
                Text(user).foregroundColor(Color(hex: 0x1AFFCD)).font(.system(size: 12, weight: .semibold))
                + Text(" \(L10n.publicScreenDiamondBoxSettled) ").foregroundColor(.white)
                + Text("\(diamonds)💎").foregroundColor(Color(hex: 0xF2FF00)).font(.system(size: 12, weight: .semibold))
            )
        case .expired(let sender, let refund):
            (
                Text(sender).foregroundColor(Color(hex: 0x1AFFCD)).font(.system(size: 12, weight: .semibold))
                + Text(" \(L10n.publicScreenDiamondBoxExpired) ").foregroundColor(.white)
                + Text("\(refund)💎").foregroundColor(Color(hex: 0xF2FF00)).font(.system(size: 12, weight: .semibold))
            )
        case .none:
            EmptyView()
        }
    }
}

// MARK: - 徽章子视图（等级 / Host / VIP）

/// 等级徽章 —— 按 Lv 分档取色（对齐 H5 bg-level1~6）
struct LevelBadge: View {
    let level: Int
    private var color: Color {
        switch level {
        case 0..<10: return Color(hex: 0x808080)
        case 10..<30: return Color(hex: 0x00A5FF)
        case 30..<50: return Color(hex: 0x9817CA)
        case 50..<70: return Color(hex: 0xFFBB02)
        default: return Color(hex: 0xFF0090)
        }
    }
    var body: some View {
        Text("Lv.\(level)")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(color, in: RoundedRectangle(cornerRadius: 3))
    }
}

/// Host 徽章 —— 绿色小标
struct HostBadge: View {
    var body: some View {
        Text("HOST")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color(hex: 0x1AFFCD, opacity: 0.8), in: RoundedRectangle(cornerRadius: 3))
    }
}

/// VIP 徽章 —— 金色小标
struct VipBadge: View {
    var body: some View {
        Text("VIP")
            .font(.system(size: 8, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 3).padding(.vertical, 1)
            .background(Color(hex: 0xFFBB02), in: RoundedRectangle(cornerRadius: 3))
    }
}
