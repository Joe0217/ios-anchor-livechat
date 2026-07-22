import SwiftUI

/// 派对房「批准申请-选座」sheet — 房主/房管 tap Mic Application row "Approve" 时弹出。
///
/// **对齐安卓** `SeatRosterDialog(isAgreeOnSeatMode=true)`（`MicApplicationListDialog.kt:282`）+
/// `agreeApplyOnSeat()` (`SeatRosterDialog.kt:393`)：让房主手动挑目标麦位，而非自动挑首空位。
///
/// 布局顺序与 Party 房主界面保持一致：视频位在上、语音位在下。
/// - Header：申请人 avatar + nickname（"Approve XX to which seat?"）
/// - Grid：所有**空位**，视频位按主舞台网格、语音位按对应的小麦位网格排列；
///   - 排除 `pendingApproveSeatIndex`（房主已挑走进行中的位，防并发冲突）
///   - `canOnHostSeat==false` 时排除 `isHostSeat==1` 的接待位（对齐 MicApplicationInfo.canOnHostSeat）
/// - 视频位为禁用态，申请用户只能通过视频位邀请流程上位
/// - 语音位 tap 直接调 `agreeMicApplication(userId:, seatIndex: idx)`
/// - Sheet 内 API 成功后自动 dismiss（成功感知靠列表 1018 op=2 自动 splice）
struct PartyApproveSeatPickerSheet: View {
    @ObservedObject var store: PartyStore
    /// 要批准的申请人（承接申请项完整字段，含 canOnHostSeat / nickname / avatar）
    let application: PartyMicApplication
    /// 成功批准后 dismiss（由上层设 `activeRoomTool = nil`）
    let onDismiss: () -> Void

    @State private var isBusy: Bool = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                contentArea
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Derived

    /// 视频位按房间主舞台排在前面，但只能通过邀请流程上位，排麦批准时禁用。
    private var availableSeats: [PartyRoomSeat] {
        let allowHostSeat = application.canOnHostSeat ?? false
        return store.seatList
            .filter { seat in
                guard let idx = seat.seatIndex, idx > 0 else { return false }
                if seat.occupied { return false }
                if store.pendingApproveSeatIndexSet.contains(idx) { return false }
                if !allowHostSeat, (seat.isHostSeat ?? 0) == 1 { return false }
                return true
            }
            .sorted { lhs, rhs in
                if lhs.isVideoSeat != rhs.isVideoSeat { return lhs.isVideoSeat }
                return (lhs.seatIndex ?? Int.max) < (rhs.seatIndex ?? Int.max)
            }
    }

    private var videoSeats: [PartyRoomSeat] { availableSeats.filter(\.isVideoSeat) }
    private var voiceSeats: [PartyRoomSeat] { availableSeats.filter { !$0.isVideoSeat } }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 8) {
            Text(L10n.Party.approveSeatPickerTitle)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(height: 52)
            HStack(spacing: 8) {
                CachedAsyncImage(
                    url: application.avatar.flatMap(URL.init(string:)),
                    contentMode: .fill,
                    cdn: (.avatarSmall, .fill)
                ) {
                    Circle().fill(Color.white.opacity(0.1))
                }
                .frame(width: 28, height: 28)
                .clipShape(Circle())
                Text(String(format: L10n.Party.approveSeatPickerSubtitleFormat, application.nickname))
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .padding(.bottom, 6)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentArea: some View {
        if availableSeats.isEmpty {
            emptyView
        } else {
            listView
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "chair.lounge.fill")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.4))
            Text(L10n.Party.micApplicationNoSeatAvailable)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var listView: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !videoSeats.isEmpty {
                    LazyVGrid(columns: videoColumns, spacing: 10) {
                        ForEach(videoSeats, id: \.stableSeatId) { seat in
                            seatCell(seat: seat)
                        }
                    }
                }
                if !voiceSeats.isEmpty {
                    LazyVGrid(columns: voiceColumns, spacing: 14) {
                        ForEach(voiceSeats, id: \.stableSeatId) { seat in
                            seatCell(seat: seat)
                        }
                    }
                }
                Color.clear.frame(height: 24)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
        .scrollIndicators(.hidden)
    }

    private var videoColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: min(max(videoSeats.count, 1), 3))
    }

    private var voiceColumns: [GridItem] {
        let count = voiceSeats.count <= 8 && videoSeats.isEmpty ? 3 : 5
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }

    private func seatCell(seat: PartyRoomSeat) -> some View {
        let isVideoSeat = seat.isVideoSeat
        return Button {
            guard !isBusy, !isVideoSeat, let idx = seat.seatIndex else { return }
            isBusy = true
            Task {
                await store.agreeMicApplication(userId: application.userId, seatIndex: idx)
                await MainActor.run {
                    isBusy = false
                    onDismiss()
                }
            }
        } label: {
            VStack(spacing: 6) {
                seatTypeIcon(seat: seat)
                Text(String(format: L10n.Party.approveSeatPickerSeatNumberFormat, seat.seatIndex ?? 0))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(isVideoSeat
                     ? L10n.Party.approveSeatPickerVideoSeat
                     : L10n.Party.approveSeatPickerVoiceSeat)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
            .frame(height: isVideoSeat ? 102 : 88)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(isVideoSeat ? 0.035 : 0.08)))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(isVideoSeat ? 0.08 : 0), lineWidth: 1)
            }
            .opacity(isVideoSeat ? 0.45 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .disabled(isBusy || isVideoSeat)
    }

    private func seatTypeIcon(seat: PartyRoomSeat) -> some View {
        let isVideo = seat.seatType == PartyRoomSeatType.video.rawValue
        return ZStack {
            Circle().fill(Color.white.opacity(0.12))
                .frame(width: 36, height: 36)
            Image(systemName: isVideo ? "video.fill" : "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
        }
    }
}

// MARK: - PartyRoomSeat stable id fallback

private extension PartyRoomSeat {
    /// ForEach identity 稳定 id（对齐 iOS Identifiable 惯例；seatIndex 通常唯一但兜底 UUID）
    var stableSeatId: String { "seat_\(seatIndex ?? -1)" }
}
