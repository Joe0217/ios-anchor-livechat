import SwiftUI

/// 派对房「接待位（MC Seat）」sheet — 房主/管理员视角。
///
/// spec `E-spec-派对房-MCSeat-202607142200.md` §3.3 简化 row-list 版：
/// - 列出当前 seatList 中已占用麦位（H5 picker 是网格；本 sheet 用列表 pattern，与 blocklist / micApplication 一致）
/// - 每 row：avatar + nickname + MC badge（若 isMCSeat）+ Set / Cancel 按钮
/// - 顶部 MC 高亮条：已有 MC 时用 badge + 昵称显式标注当前 MC（visual highlight 替代显式 "Current MC:" 文案）
/// - Set / Cancel API 成功后**不本地乐观更新**，等 IM 1001 广播回来触发 seatList 变化 → UI 自动刷新
/// - `store.setMCSeat` / `store.closeMCSeat` 内部各自持 isBusy 幂等 flag（防连点双请求），UI 无需再挡
struct PartyMCSeatSheet: View {
    @ObservedObject var store: PartyStore

    /// 全局 toast（成功/失败共用，pattern 对齐 PartyBlocklistSheet）
    @State private var toast: ToastMessage?

    private struct ToastMessage: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                contentArea
            }
        }
        .presentationDetents([.medium, .large])
        .overlay(alignment: .top) {
            if let msg = toast {
                Text(msg.text)
                    .toastStyle(topInset: 60)
                    .transition(Toast.transition)
                    .task(id: msg.id) {
                        try? await Task.sleep(nanoseconds: Toast.dismissDurationNanos)
                        toast = nil
                    }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast?.id)
    }

    // MARK: - Derived

    /// spec §3.3 fix（verify P0 spec-drift）：列所有麦位，包括空位。
    /// 排序：MC 顶置 → 已占用 → 空位；同类按 seatIndex 升序
    private var allSeats: [PartyRoomSeat] {
        store.seatList.sorted { lhs, rhs in
            let lhsMC = (lhs.isHostSeat ?? 0) == 1
            let rhsMC = (rhs.isHostSeat ?? 0) == 1
            if lhsMC != rhsMC { return lhsMC && !rhsMC }
            if lhs.occupied != rhs.occupied { return lhs.occupied && !rhs.occupied }
            return (lhs.seatIndex ?? Int.max) < (rhs.seatIndex ?? Int.max)
        }
    }

    /// 当前 MC 位（用于顶部提示 & 排序辅助）
    private var currentMCSeat: PartyRoomSeat? {
        allSeats.first { ($0.isHostSeat ?? 0) == 1 }
    }

    /// 空态判定：seatList 完全为空（房间无任何麦位定义，罕见异常态）
    private var isEmptyCandidateSet: Bool {
        allSeats.isEmpty
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 6) {
            Text(L10n.Party.mcSeatSheetTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(height: 52)
            Text(L10n.Party.mcSeatTips)
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.partyGreeting)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
        }
    }

    // MARK: - Content area

    @ViewBuilder
    private var contentArea: some View {
        if isEmptyCandidateSet {
            emptyView
        } else {
            listView(items: allSeats)
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 42))
                .foregroundColor(.white.opacity(0.5))
            Text(L10n.Party.mcSeatTips)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listView(items: [PartyRoomSeat]) -> some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(items, id: \.stableId) { seat in
                    row(seat: seat)
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Row

    @ViewBuilder
    private func row(seat: PartyRoomSeat) -> some View {
        let isMC = (seat.isHostSeat ?? 0) == 1
        HStack(spacing: 12) {
            avatar(url: seat.avatar)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(displayNickname(seat: seat))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if isMC {
                        mcBadge
                    }
                }
                seatMetaLine(seat: seat)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            actionButton(seat: seat, isMC: isMC)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            // MC 行淡橙色底色区分（visual highlight 替代显式 "Current MC:" 文案）
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isMC ? Color(hex: 0xFF9A3D).opacity(0.12) : Color.clear)
        )
    }

    private func avatar(url: String?) -> some View {
        // 小头像走 avatarSmall（cdn-image-tier-consolidation preference）
        CachedAsyncImage(
            url: url.flatMap(URL.init(string:)),
            contentMode: .fill,
            cdn: (.avatarSmall, .fill)
        ) {
            Circle().fill(Color.white.opacity(0.1))
        }
        .frame(width: 40, height: 40)
        .clipShape(Circle())
    }

    private var mcBadge: some View {
        Text(L10n.Party.mcSeatBadge)
            .font(.system(size: 9, weight: .heavy))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(
                Capsule().fill(
                    LinearGradient(
                        colors: [Color(hex: 0xFF9A3D), Color(hex: 0xFF6A2C)],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
            )
    }

    private func displayNickname(seat: PartyRoomSeat) -> String {
        if let n = seat.nickname, !n.isEmpty { return n }
        return seat.userId ?? ""
    }

    /// 副行：seat # 序号（仅展示业务定位信息，不引入未落地 L10n 的角色文案）
    @ViewBuilder
    private func seatMetaLine(seat: PartyRoomSeat) -> some View {
        if let idx = seat.seatIndex {
            Text(verbatim: "#\(idx)")
                .font(.system(size: 11))
                .foregroundColor(Theme.Palette.partyGreeting)
        }
    }

    // MARK: - Action button

    @ViewBuilder
    private func actionButton(seat: PartyRoomSeat, isMC: Bool) -> some View {
        if isMC {
            Button {
                Task { await performClose() }
            } label: {
                Text(L10n.Party.cancel)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(hex: 0xFF6A8E))
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        Capsule().stroke(Color(hex: 0xFF6A8E).opacity(0.7), lineWidth: 1)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
        } else {
            Button {
                if let idx = seat.seatIndex {
                    Task { await performSet(seatIndex: idx) }
                }
            } label: {
                Text(L10n.Party.mcSeatSubmit)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(
                        Capsule().fill(Color(red: 0.21, green: 0.14, blue: 0.67))
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(seat.seatIndex == nil)
        }
    }

    // MARK: - Actions

    /// verify P0 fix：Store 层现返回 Bool 明示成功/失败，不再靠 lastError.localizedDescription
    /// diff（同错误消息连续两次会误判成功；且其他 Party 操作 pre-set 的 lastError 会污染判定）。
    private func performSet(seatIndex: Int) async {
        let ok = await store.setMCSeat(seatIndex: seatIndex)
        if ok {
            toast = ToastMessage(text: L10n.Party.mcSeatSetSuccess, isError: false)
        } else {
            // 失败 message：优先消费 store.lastError 具体码，兜底通用文案
            let concrete = store.lastError?.errorDescription ?? ""
            toast = ToastMessage(
                text: concrete.isEmpty ? L10n.Party.mcSeatOperationFailed : concrete,
                isError: true
            )
        }
    }

    private func performClose() async {
        let ok = await store.closeMCSeat()
        if ok {
            toast = ToastMessage(text: L10n.Party.mcSeatCloseSuccess, isError: false)
        } else {
            let concrete = store.lastError?.errorDescription ?? ""
            toast = ToastMessage(
                text: concrete.isEmpty ? L10n.Party.mcSeatOperationFailed : concrete,
                isError: true
            )
        }
    }
}
