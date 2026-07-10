import SwiftUI

/// UserCard 名片卡 popup（对齐 H5 userCard.vue）
struct UserCardPopup: View {
    @Binding var isPresented: Bool
    @StateObject private var store: UserCardStore

    init(userId: String, isPresented: Binding<Bool>) {
        self._store = StateObject(wrappedValue: UserCardStore(userId: userId))
        self._isPresented = isPresented
    }

    var body: some View {
        PKPopupCard(isPresented: $isPresented, title: L10n.userCardTitle) {
            Group {
                switch store.state {
                case .idle, .loading:
                    ProgressView().tint(.white)
                        .frame(minHeight: 200)
                case .loaded(let info):
                    profileContent(info)
                case .error:
                    errorView
                }
            }
            .onAppear { store.loadIfNeeded() }
        }
    }

    private func profileContent(_ info: UserCardInfo) -> some View {
        VStack(spacing: 12) {
            // 头像 + 昵称 + level
            AvatarView(urlString: info.avatarUrl, size: 64, kind: .user)
            HStack(spacing: 6) {
                Text(info.nickname)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if info.isVip { PublicChatVipBadge() }
            }

            // 性别 / 年龄 / 国家 / level 徽章
            HStack(spacing: 6) {
                if let age = info.age {
                    HStack(spacing: 2) {
                        Image(systemName: info.gender == .female ? "person.fill" : "person")
                            .font(.system(size: 9))
                        Text("\(age)").font(.system(size: 11))
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.white.opacity(0.15), in: Capsule())
                    .foregroundColor(.white)
                }
                if let flag = info.countryEmoji {
                    Text(flag).font(.system(size: 13))
                }
                UserLevelBadge(level: info.level, size: .small)
            }

            // 关注 / 粉丝数
            HStack(spacing: 24) {
                VStack(spacing: 2) {
                    Text("\(info.followerCount)").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text(L10n.userCardFollowers).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                }
                VStack(spacing: 2) {
                    Text("\(info.followingCount)").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                    Text(L10n.userCardFollowing).font(.system(size: 11)).foregroundColor(.white.opacity(0.6))
                }
            }

            // 礼物墙
            if !info.giftWalls.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.userCardGiftWall)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.7))
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(info.giftWalls) { g in
                                VStack(spacing: 2) {
                                    Image(systemName: "gift.fill")
                                        .font(.system(size: 20))
                                        .foregroundColor(Color(hex: 0xFFE600))
                                    Text("×\(g.count)")
                                        .font(.system(size: 10))
                                        .foregroundColor(.white)
                                }
                                .frame(width: 44, height: 44)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 关注 / 拉黑按钮
            HStack(spacing: 12) {
                PKPopupButton(
                    title: info.isFollowed ? L10n.userCardUnfollow : L10n.userCardFollow,
                    style: .gradientPurpleToRed
                ) {
                    store.toggleFollow()
                }
                PKPopupButton(
                    title: info.isBlocked ? L10n.userCardUnblock : L10n.userCardBlock,
                    style: .solidPurple
                ) {
                    store.toggleBlock()
                }
            }
        }
        .padding(.horizontal, 4)
    }

    private var errorView: some View {
        VStack(spacing: 12) {
            Text(L10n.userCardErrorRetry)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.6))
            Button {
                store.retry()
            } label: {
                Text(L10n.liveRoomRetry)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 20).padding(.vertical, 6)
                    .background(Color.white.opacity(0.15), in: Capsule())
            }
        }
        .frame(minHeight: 200)
    }
}
