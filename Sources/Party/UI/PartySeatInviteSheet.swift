import Combine
import SwiftUI

/// H5 `seat-invite-recommend-popup` 对应的空麦位邀请面板。
/// 它只列当前房间可邀请的在线推荐用户，不复用“邀请进房”联系人分享面板。
struct PartySeatInviteSheet: View {
    @ObservedObject var store: PartyStore
    let seat: PartyRoomSeat

    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PartySeatInviteCandidate] = []
    @State private var isLoading = false
    @State private var hasMore = true
    @State private var isSendingInvite = false
    @State private var now = Date()

    private let pageSize = 20

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .background(Color(hex: 0x1A0033).ignoresSafeArea())
        .task { await reload() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var header: some View {
        HStack {
            Spacer().frame(width: 44)
            Text(L10n.Party.seatInviteTitle)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
            Button(action: dismiss.callAsFunction) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.8))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel(L10n.Party.cancel)
        }
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && candidates.isEmpty {
            ProgressView()
                .tint(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 34, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
                Text(L10n.Party.seatInviteEmpty)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(candidates) { candidate in
                        candidateRow(candidate)
                            .onAppear {
                                if candidate.id == candidates.last?.id {
                                    Task { await loadNextPage() }
                                }
                            }
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .padding(.vertical, 16)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func candidateRow(_ candidate: PartySeatInviteCandidate) -> some View {
        HStack(spacing: 12) {
            AvatarView(urlString: candidate.avatar, size: 46, kind: .user, userId: candidate.userId)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(candidate.nickname?.isEmpty == false ? candidate.nickname! : L10n.anonymous)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    PartyRoleBadge(roomRoleType: candidate.roomRoleType, size: 14)
                }
            }

            Spacer(minLength: 8)
            inviteControl(candidate)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func inviteControl(_ candidate: PartySeatInviteCandidate) -> some View {
        if isAlreadyOnSeat(candidate) {
            statusLabel(L10n.Party.seatInviteJoined)
        } else if needsVideoInvite(candidate), store.isVideoSeatInviteCoolingDown(candidate.userId, now: now) {
            statusLabel(L10n.Party.seatInviteInviting)
        } else {
            Button {
                sendInvite(candidate)
            } label: {
                Label(L10n.toolInvite, systemImage: "person.badge.plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 34)
                    .background(Capsule().fill(Theme.Palette.partyRoomFollowFill))
            }
            .buttonStyle(.plain)
            .disabled(isSendingInvite)
            .opacity(isSendingInvite ? 0.55 : 1)
        }
    }

    private func statusLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundColor(.white.opacity(0.55))
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Capsule().fill(Color.white.opacity(0.1)))
    }

    private func isAlreadyOnSeat(_ candidate: PartySeatInviteCandidate) -> Bool {
        store.seatList.contains { $0.userId == candidate.userId }
    }

    private func needsVideoInvite(_ candidate: PartySeatInviteCandidate) -> Bool {
        seat.seatType == PartyRoomSeatType.video.rawValue && candidate.userType == 1
    }

    private func reload() async {
        candidates = []
        hasMore = true
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !isLoading, hasMore, let roomId = store.roomInfo?.id, !roomId.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let next = try await PartyAPI.recommendedSeatInviteUsers(
                roomId: roomId,
                offset: candidates.last?.score,
                pageSize: pageSize
            )
            candidates.append(contentsOf: next.filter { incoming in
                !candidates.contains { $0.userId == incoming.userId }
            })
            hasMore = next.count == pageSize
        } catch {
            AppLogger.party.error("[PartySeatInvite] load candidates failed: \(String(describing: error), privacy: .private)")
            hasMore = false
        }
    }

    private func sendInvite(_ candidate: PartySeatInviteCandidate) {
        guard !isSendingInvite else { return }
        isSendingInvite = true
        Task {
            let sent = await store.requestInviteToSeat(seat: seat, candidate: candidate)
            isSendingInvite = false
            if sent { dismiss() }
        }
    }
}

struct PartySeatInvitePresentation: Identifiable {
    let seat: PartyRoomSeat
    var id: Int { seat.stableId }
}
