import SwiftUI

/// PK 结束战报（对齐 H5 endedSettlement.vue 完整视觉 + 逻辑）
///
/// 视觉结构（对齐 docs/upload/party房pk结算弹窗.png）：
/// - 蓝紫渐变卡（300deg #1765C4 → #1D0E4C → #150B32 → #B00D5B）
/// - 双拳手套头标（设计稿素材，超出卡片顶部）
/// - Winner 大字（Red/Blue Team Win 或 Tie）
/// - Battle Time mm:ss（黄色）
/// - VS 双队卡：Red Team 卡 + VS icon + Blue Team 卡；winner 显示 "lead N"，loser 显示 "Lose"
/// - Gift-Giving MVP 卡（橙红渐变 · Total given out N）
/// - Gift-Receive MVP 卡（蓝紫或红据 team · personal gift Receiving N）
///
/// 数据消费逻辑（对齐 endedSettlement.vue :47-133）：
/// - redScore/blueScore：`redGems ?? redScore` 折算后金额，Math.floor 向下取整
/// - giftGivingMvp fallback：`giftSendMvp` → `redTop3[0]/blueTop3[0]` 较大者
/// - giftReceiveMvp fallback：`giftReceiveMvp` → `redCrownUid/blueCrownUid` + 麦位快照查名字
struct PartyBattleEndedSettlement: View {
    @ObservedObject var store: PartyBattleStore
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
            .ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                Spacer()
                settlementCard
                closeButton.padding(.top, 20)
                Spacer()
            }
            .padding(.horizontal, 24)
        }
        .ignoresSafeArea()
    }

    // MARK: - Card

    @ViewBuilder
    private var settlementCard: some View {
        VStack(spacing: 0) {
            winnerTitle
            battleTimeRow
            vsRow.padding(.top, 16)
            if let mvp = giftGivingMvp {
                mvpCard(title: "Gift-Giving MVP", mvp: mvp, isReceive: false)
                    .padding(.top, 20)
            }
            if let mvp = giftReceiveMvp {
                mvpCard(title: "Gift-Receive MVP", mvp: mvp, isReceive: true)
                    .padding(.top, 12)
            }
        }
        .padding(.horizontal, 15).padding(.bottom, 30).padding(.top, 60)
        .background(cardGradient)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .top) {
            Image("partyPkSettlementHero")
                .resizable()
                .scaledToFit()
                .frame(width: 281, height: 122)
                // 结算头图按设计稿悬挂在卡片上方，不能被卡片圆角裁切。
                .offset(y: -68)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var winnerTitle: some View {
        Text(winnerLabel)
            .font(.title3).bold()
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var battleTimeRow: some View {
        HStack(spacing: 4) {
            Text("Battle Time:")
                .font(.caption).foregroundColor(.white.opacity(0.65))
            Text(battleTimeText)
                .font(.caption).foregroundColor(.yellow)
        }
        .padding(.top, 4)
    }

    @ViewBuilder
    private var vsRow: some View {
        HStack(spacing: 6) {
            teamCard(color: .red, label: "Red Team", score: redScoreText, isWinner: winnerTeam == 1, isLoser: winnerTeam == 2)
            Image("partyPkBattleMarker")
                .resizable()
                .scaledToFit()
                .frame(width: 40, height: 40)
            teamCard(color: .blue, label: "Blue Team", score: blueScoreText, isWinner: winnerTeam == 2, isLoser: winnerTeam == 1)
        }
    }

    @ViewBuilder
    private func teamCard(color: Color, label: String, score: Int, isWinner: Bool, isLoser: Bool) -> some View {
        let redBg = LinearGradient(
            colors: [Color(red: 0.85, green: 0.05, blue: 0.35), Color(red: 0.55, green: 0.02, blue: 0.15)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        let blueBg = LinearGradient(
            colors: [Color(red: 0.10, green: 0.35, blue: 0.90), Color(red: 0.02, green: 0.12, blue: 0.45)],
            startPoint: .topLeading, endPoint: .bottomTrailing
        )
        let bg: AnyShapeStyle = color == .red ? AnyShapeStyle(redBg) : AnyShapeStyle(blueBg)
        VStack(spacing: 2) {
            Text(label)
                .font(.subheadline).foregroundColor(.white)
            Text("\(score)")
                .font(.headline).bold()
                .foregroundColor(.white)
            if isWinner {
                Text("lead \(scoreDeltaText)")
                    .font(.caption2).foregroundColor(Color(red: 1.0, green: 0.88, blue: 0.4))
            } else if isLoser {
                Text("Lose")
                    .font(.caption2).foregroundColor(.white.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 70)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - MVP card

    @ViewBuilder
    private func mvpCard(title: String, mvp: MvpDisplay, isReceive: Bool) -> some View {
        let orangeBg = LinearGradient(
            colors: [Color(red: 0.85, green: 0.43, blue: 0.0), Color(red: 0.15, green: 0.03, blue: 0.0), Color(red: 0.85, green: 0.43, blue: 0.0)],
            startPoint: .leading, endPoint: .trailing
        )
        let redBlueBg = LinearGradient(
            colors: [Color(red: 0.85, green: 0.0, blue: 0.0), Color(red: 0.15, green: 0.03, blue: 0.0), Color(red: 0.01, green: 0.0, blue: 0.57)],
            startPoint: .leading, endPoint: .trailing
        )
        let bg: AnyShapeStyle = isReceive ? AnyShapeStyle(redBlueBg) : AnyShapeStyle(orangeBg)

        ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                avatarView(mvp.avatar, teamColor: mvp.teamColor)
                    .padding(.leading, 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mvp.nickname ?? "User\(mvp.uid)")
                        .font(.subheadline).bold()
                        .foregroundColor(.white)
                        .lineLimit(1)
                    HStack(spacing: 2) {
                        Text(mvpMetaText(mvp: mvp, isReceive: isReceive))
                            .font(.caption2).foregroundColor(.white.opacity(0.75))
                        mvpValueIcon(isReceive: isReceive)
                    }
                }
                Spacer()
                mvpTipTag(title: title)
                    .padding(.trailing, 8)
            }
            // Team tag（顶部左）
            Text(mvp.teamName)
                .font(.caption2).bold()
                .foregroundColor(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(mvp.teamColor.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(y: -10)
                .padding(.leading, 6)
        }
        .frame(height: 64)
        .background(bg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(mvp.teamColor.opacity(0.6), lineWidth: 1)
        )
    }

    @ViewBuilder
    private func mvpValueIcon(isReceive: Bool) -> some View {
        Image(isReceive ? "partyGems" : "diamonds")
            .resizable()
            .scaledToFit()
            .frame(width: isReceive ? 12 : 14, height: 14)
    }

    @ViewBuilder
    private func avatarView(_ url: String?, teamColor: Color) -> some View {
        // MVP 头像走公共 CachedAsyncImage（对齐 H5 v-image cdn-measure="m" · 他人头像 persistent=false）
        Circle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 40, height: 40)
            .overlay(
                CachedAsyncImage(
                    url: URL(string: url ?? ""),
                    contentMode: .fill,
                    persistent: false,
                    cdn: (.avatarSmall, .fill)
                ) {
                    Image(systemName: "person.fill").foregroundColor(.white.opacity(0.5))
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            )
            .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
    }

    @ViewBuilder
    private func mvpTipTag(title: String) -> some View {
        Text(title)
            .font(.system(size: 10)).bold()
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .frame(minWidth: 96)
            .background(Color.white.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Close

    @ViewBuilder
    private var closeButton: some View {
        Button {
            onDismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(Color.white.opacity(0.2))
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Computed

    private var settlement: PartyBattleSettlementResponse? { store.lastSettlement }

    /// H5 :47-48 · gems 优先，回落 raw score
    private var redScore: Double { settlement?.redGems?.doubleValue ?? settlement?.redScore?.doubleValue ?? 0 }
    private var blueScore: Double { settlement?.blueGems?.doubleValue ?? settlement?.blueScore?.doubleValue ?? 0 }

    /// H5 :51-53 · Math.floor 向下取整（金额只舍不入）
    private var redScoreText: Int { Int(floor(redScore)) }
    private var blueScoreText: Int { Int(floor(blueScore)) }
    private var scoreDeltaText: Int { abs(redScoreText - blueScoreText) }

    /// winner 由后端权威 winnerTeam 决定（不用前端取整比较，避免整数相等仍显示 Tie 之类）
    private var winnerTeam: Int? { settlement?.winnerTeam }

    private var winnerLabel: String {
        switch winnerTeam {
        case 1: return "Red Team Win"
        case 2: return "Blue Team Win"
        default: return "Tie"
        }
    }

    private var battleTimeText: String {
        let d = max(0, settlement?.durationSec ?? 0)
        let m = d / 60
        let s = d % 60
        return String(format: "%02d:%02d", m, s)
    }

    // MARK: - MVP fallback（对齐 H5 :76-133）

    private struct MvpDisplay {
        let uid: Int64
        let nickname: String?
        let avatar: String?
        let value: Int
        let team: Int  // 1=红 2=蓝

        var teamName: String { team == 2 ? "Blue Team" : "Red Team" }
        var teamColor: Color { team == 2 ? Color(red: 0.05, green: 0.43, blue: 1.0) : Color(red: 1.0, green: 0.15, blue: 0.7) }
    }

    /// Gift-Giving MVP —— H5 :76-100 主字段 → Top3 较大者 fallback
    private var giftGivingMvp: MvpDisplay? {
        if let m = settlement?.giftSendMvp, m.uid > 0 {
            return MvpDisplay(
                uid: m.uid, nickname: m.nickname, avatar: m.avatar,
                value: Int(floor(m.displayValue)),
                team: m.team ?? (m.gems != nil || m.diamonds != nil ? 1 : 1)
            )
        }
        // fallback：Top3[0] 红蓝较大者
        let r = settlement?.redTop3?.first
        let b = settlement?.blueTop3?.first
        let rv = r?.contribution?.doubleValue ?? 0
        let bv = b?.contribution?.doubleValue ?? 0
        if let r = r, let b = b {
            if rv >= bv {
                return MvpDisplay(uid: r.uid, nickname: r.nickname, avatar: r.avatar, value: Int(floor(rv)), team: 1)
            } else {
                return MvpDisplay(uid: b.uid, nickname: b.nickname, avatar: b.avatar, value: Int(floor(bv)), team: 2)
            }
        }
        if let r = r { return MvpDisplay(uid: r.uid, nickname: r.nickname, avatar: r.avatar, value: Int(floor(rv)), team: 1) }
        if let b = b { return MvpDisplay(uid: b.uid, nickname: b.nickname, avatar: b.avatar, value: Int(floor(bv)), team: 2) }
        return nil
    }

    /// Gift-Receive MVP —— H5 :104-133 主字段 → crownUid + 麦位快照 fallback
    private var giftReceiveMvp: MvpDisplay? {
        if let m = settlement?.giftReceiveMvp, m.uid > 0 {
            return MvpDisplay(
                uid: m.uid, nickname: m.nickname, avatar: m.avatar,
                value: Int(floor(m.displayValue)),
                team: m.team ?? 1
            )
        }
        // fallback：crownUid + Top3/state.members 查名字头像 + personal
        if let rc = settlement?.redCrownUid, rc > 0 {
            let inTop = settlement?.redTop3?.first { $0.uid == rc }
            let inMembers = store.state?.redTeam.members.first { $0.uid == rc }
            let personal = inTop?.contribution?.doubleValue
                ?? inMembers?.personalGems?.doubleValue
                ?? inMembers?.personalScore?.doubleValue
                ?? 0
            return MvpDisplay(
                uid: rc,
                nickname: inTop?.nickname ?? inMembers?.nickname,
                avatar: inTop?.avatar ?? inMembers?.avatar,
                value: Int(floor(personal)),
                team: 1
            )
        }
        if let bc = settlement?.blueCrownUid, bc > 0 {
            let inTop = settlement?.blueTop3?.first { $0.uid == bc }
            let inMembers = store.state?.blueTeam.members.first { $0.uid == bc }
            let personal = inTop?.contribution?.doubleValue
                ?? inMembers?.personalGems?.doubleValue
                ?? inMembers?.personalScore?.doubleValue
                ?? 0
            return MvpDisplay(
                uid: bc,
                nickname: inTop?.nickname ?? inMembers?.nickname,
                avatar: inTop?.avatar ?? inMembers?.avatar,
                value: Int(floor(personal)),
                team: 2
            )
        }
        return nil
    }

    private func mvpMetaText(mvp: MvpDisplay, isReceive: Bool) -> String {
        isReceive
            ? "personal gift Receiving \(mvp.value)"
            : "Total given out \(mvp.value)"
    }

    // MARK: - Style

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.09, green: 0.40, blue: 0.77),  // #1765C4
                Color(red: 0.11, green: 0.06, blue: 0.30),  // #1D0E4C
                Color(red: 0.08, green: 0.04, blue: 0.20),  // #150B32
                Color(red: 0.69, green: 0.05, blue: 0.36)   // #B00D5B
            ],
            startPoint: .topTrailing,
            endPoint: .bottomLeading
        )
    }
}
