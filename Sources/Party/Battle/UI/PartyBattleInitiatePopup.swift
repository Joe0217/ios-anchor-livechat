import SwiftUI

/// PK 发起浮层（对齐 H5 initiatePopup.vue 完整视觉 + 逻辑）
///
/// 视觉结构（对齐 docs/upload/party房发起pk开关*.png）：
/// - 底部 popup + 紫渐变背景 `#371F9F → #17063D`
/// - 头标 "Battle Team" title
/// - **Mode** 单胶囊 "Team Battle"（紫红渐变）—— **不展示模板选择**（H5 明说只选时长）
/// - **Time** 3 chip（templates.durationSec / 60 分钟数）
/// - **Choosing my side**（在麦时隐藏）：toggle + Join Red/Blue 2 大按钮
/// - **提示卡**：麦位人数 + selecting/cooldown 秒数
/// - **Confirm** 长按钮（44px 紫红渐变）
struct PartyBattleInitiatePopup: View {
    @ObservedObject var store: PartyBattleStore
    let onStarted: () -> Void

    @State private var selectedTemplateId: String?
    /// H5 :50 · true=参战（默认显示 Join Red/Blue），false=Neutral 不参战
    @State private var joinEnabled: Bool = true
    /// H5 :52 · 1=红 2=蓝（在 joinEnabled=true 时生效）
    @State private var hostSide: Int = 1
    @State private var submitting: Bool = false
    @State private var actionError: String?

    private let purple = Color(red: 0.52, green: 0.08, blue: 1.0)
    private let deepRed = Color(red: 0.89, green: 0.00, blue: 0.20)
    private let redBg = Color(red: 1.00, green: 0.00, blue: 0.56)
    private let blueBg = Color(red: 0.05, green: 0.43, blue: 1.0)

    var body: some View {
        VStack(spacing: 16) {
            header
            modeSection
            timeSection
            if !isSelfOnMic { sideSection }
            hintCard
            confirmButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(bgGradient)
        .fixedSize(horizontal: false, vertical: true)
        .overlay(alignment: .top) {
            if let actionError {
                Text(actionError)
                    .toastStyle(topInset: 8)
                    .transition(Toast.transition)
            }
        }
        .task { await store.loadTemplatesIfNeeded() }
        .task(id: store.templates.count) {
            // templates 拉到后自动 preselect 第一个
            if selectedTemplateId == nil, let first = store.templates.first {
                selectedTemplateId = first.id
            }
        }
        .onChange(of: store.isSelecting) { isSelecting in
            guard isSelecting else { return }
            actionError = nil
            submitting = false
            onStarted()
        }
        .onChange(of: store.isRunning) { isRunning in
            guard isRunning else { return }
            actionError = nil
            submitting = false
            onStarted()
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            CDNAssetImage("partyPkLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
            Text(L10n.Party.Battle.initiateTitle)
                .font(.title3).bold()
                .foregroundColor(.white)
            Spacer()
        }
    }

    @ViewBuilder
    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Party.Battle.modeLabel)
                .font(.subheadline)
                .foregroundColor(.white)
            // H5 `party.battle.modeTeamBattle`。
            Text(L10n.Party.Battle.modeTeamBattle)
                .font(.subheadline).bold()
                .foregroundColor(.white)
                .padding(.horizontal, 15).padding(.vertical, 6)
                .background(pillGradient)
                .clipShape(Capsule())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var timeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Party.Battle.timeLabel)
                .font(.subheadline)
                .foregroundColor(.white)
            HStack(spacing: 12) {
                ForEach(durationItems, id: \.templateId) { d in
                    Button {
                        selectedTemplateId = d.templateId
                    } label: {
                        Text(L10n.Party.Battle.minutes(d.min))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 15).padding(.vertical, 6)
                            .background(
                                selectedTemplateId == d.templateId
                                    ? AnyShapeStyle(pillGradient)
                                    : AnyShapeStyle(Color.white.opacity(0.1))
                            )
                            .clipShape(Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if durationItems.isEmpty {
                    Text("—")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var sideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.Party.Battle.chooseSideLabel)
                    .font(.subheadline)
                    .foregroundColor(.white)
                Spacer()
                sideToggle
            }
            if joinEnabled {
                HStack(spacing: 8) {
                    sideButton(title: L10n.Party.Battle.joinRed, team: 1, color: redBg)
                    sideButton(title: L10n.Party.Battle.joinBlue, team: 2, color: blueBg)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 15)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    /// H5 :194-197 · toggle 视觉：粉红边 30x80 圆胶囊，白色 knob，开关切文案+滑动
    @ViewBuilder
    private var sideToggle: some View {
        Button {
            joinEnabled.toggle()
        } label: {
            ZStack {
                Capsule()
                    .fill(joinEnabled
                        ? AnyShapeStyle(pillGradient)
                        : AnyShapeStyle(LinearGradient(
                            colors: [Color(red: 0.25, green: 0.10, blue: 0.36), Color(red: 0.35, green: 0.07, blue: 0.15)],
                            startPoint: .leading, endPoint: .trailing)))
                    .frame(width: 80, height: 30)
                    .overlay(Capsule().stroke(Color(red: 0.98, green: 0.02, blue: 0.96), lineWidth: 1))
                HStack {
                    if joinEnabled {
                        Circle().fill(Color.white).frame(width: 22, height: 22)
                        Text(L10n.Party.Battle.joinSideOn).font(.caption).foregroundColor(.white)
                            .padding(.trailing, 8)
                    } else {
                        Text(L10n.Party.Battle.joinSideOff).font(.caption).foregroundColor(.white)
                            .padding(.leading, 8)
                        Spacer()
                        Circle().fill(Color.white).frame(width: 22, height: 22)
                    }
                }
                .frame(width: 76, height: 30)
                .padding(.horizontal, 2)
            }
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func sideButton(title: String, team: Int, color: Color) -> some View {
        Button {
            hostSide = team
        } label: {
            Text(title)
                .font(.subheadline).bold()
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(hostSide == team ? color : color.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Party.Battle.initiateHint(players: store.roomEnv.lobbyMicCount, cooldown: store.cooldownDurationSec))
            Text(L10n.Party.Battle.initiateHint2(selecting: store.globalSelectingDurationSec))
        }
        .font(.caption)
        .foregroundColor(.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.black.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private var confirmButton: some View {
        Button(action: handleConfirm) {
            HStack {
                Spacer()
                if submitting {
                    ProgressView().tint(.white)
                }
                Text(L10n.Party.Battle.confirm)
                    .font(.headline).bold()
                    .foregroundColor(.white)
                Spacer()
            }
            .frame(height: 44)
            .background(pillGradient)
            .clipShape(Capsule())
            .opacity(submitting ? 0.6 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(submitting)
    }

    // MARK: - Computed

    private var isSelfOnMic: Bool { store.roomEnv.isSelfOnMic }

    private struct DurationItem: Hashable {
        let templateId: String
        let sec: Int
        let min: Int
    }

    private var durationItems: [DurationItem] {
        store.templates.compactMap { t in
            guard let sec = t.durationSec, sec > 0 else { return nil }
            return DurationItem(templateId: t.id, sec: sec, min: Int((Double(sec) / 60).rounded()))
        }
    }

    /// H5 :53-59 · 在麦时 hostInitialTeam=undefined；否则 joinEnabled=false→3 中立，true→hostSide
    private var computedHostInitialTeam: Int? {
        if isSelfOnMic { return nil }
        if !joinEnabled { return 3 }
        return hostSide
    }

    // MARK: - Styles

    private var bgGradient: some View {
        LinearGradient(
            colors: [
                Color(red: 0.22, green: 0.12, blue: 0.62),  // #371F9F
                Color(red: 0.09, green: 0.02, blue: 0.24)   // #17063D
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var pillGradient: LinearGradient {
        LinearGradient(
            colors: [purple, deepRed],
            startPoint: .leading, endPoint: .trailing
        )
    }

    // MARK: - Actions

    private func handleConfirm() {
        guard store.roomEnv.roomId > 0 else {
            actionError = L10n.Party.Battle.roomIdInvalid
            return
        }
        guard let tid = selectedTemplateId,
              let picked = durationItems.first(where: { $0.templateId == tid })
        else {
            actionError = L10n.Party.Battle.noTemplate
            return
        }
        actionError = nil
        submitting = true
        Task {
            let started = await store.start(
                templateId: picked.templateId,
                durationSec: picked.sec,
                hostInitialTeam: computedHostInitialTeam
            )
            await MainActor.run {
                submitting = false
                if started {
                    onStarted()
                } else {
                    actionError = store.actionError ?? L10n.Party.Battle.startNowFailed
                }
            }
        }
    }
}
