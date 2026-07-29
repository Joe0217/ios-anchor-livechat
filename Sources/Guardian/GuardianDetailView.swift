import SwiftUI

/// 直播房内的主播守护详情。与 H5 一致为只读面板：展示配置和榜单，不提供付费 CTA。
struct GuardianDetailView: View {
    let anchorId: Int64

    @StateObject private var store: GuardianDetailStore
    @State private var selectedLevel: GuardianLevel = .gold
    @State private var showsRules = false
    @State private var showsList = false
    @State private var previewContext: GuardianPrivilegePreviewContext?
    @State private var userCardPresentation: UserCardPresentation?

    init(anchorId: Int64) {
        self.anchorId = anchorId
        _store = StateObject(wrappedValue: GuardianDetailStore(anchorId: anchorId))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(
                colors: [Color(hex: 0xEFE6FB), Color(hex: 0xE3D5F8), .white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            Image(GuardianArtwork.topGlow)
                .resizable()
                .scaledToFill()
                .opacity(0.55)
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        hero
                        levelTabs
                        privilegeGrid
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .refreshable { store.load() }

                // H5 面板用 flex-1 将三档价格区固定在 75% 面板底部；上方内容过长时仅滚动该区域。
                priceSection
            }

            Button {
                showsRules = true
            } label: {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.black.opacity(0.32))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.guardianRulesTitle)
            .padding(.top, 4)
            .padding(.trailing, 6)

            if let errorMessage = store.errorMessage {
                GuardianLoadErrorBanner(message: errorMessage, retry: store.load)
                    .padding(.top, 52)
                    .padding(.horizontal, 12)
            }
        }
        .task { store.load() }
        .sheet(isPresented: $showsRules) {
            GuardianRulesView()
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $previewContext) { context in
            GuardianPrivilegePreviewView(context: context)
                .presentationDetents([.height(390)])
                .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showsList) {
            GuardianListSheetView(anchorId: anchorId)
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
        }
        .userCardSheet(item: $userCardPresentation)
    }

    private var currentConfiguration: GuardianLevelConfiguration {
        store.panel.configuration(for: selectedLevel)
    }

    /// 与 H5 `hasTop1 = !!topGuardian.nickname` 一致：仅头像而没有昵称的脏数据不能被当作榜一。
    private var hasTopGuardian: Bool {
        guard let nickname = store.panel.topGuardian?.nickname else { return false }
        return !nickname.isEmpty
    }

    private var hero: some View {
        VStack(spacing: 0) {
            topGuardianAvatar
                .padding(.top, 6)

            Text(hasTopGuardian ? (store.panel.topGuardian?.nickname ?? L10n.guardianTitle) : L10n.guardianTitle)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Color(hex: 0x281B39))
                .lineLimit(1)
                .padding(.horizontal, 42)
                .padding(.top, 2)

            Button {
                showsList = true
            } label: {
                HStack(spacing: 7) {
                    Text(hasTopGuardian
                         ? String(format: L10n.guardianListFormat, store.panel.guardianCount)
                         : L10n.guardianBeFirst)
                        .foregroundStyle(.white)
                    topAvatarStack
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
                .padding(.leading, 12)
                .padding(.trailing, 8)
                .frame(minHeight: 30)
                .background(Color(hex: 0x9B7BE1), in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(format: L10n.guardianListFormat, store.panel.guardianCount))
            .padding(.top, 10)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    private var topGuardianAvatar: some View {
        let top = hasTopGuardian ? store.panel.topGuardian : nil
        let level = top?.level ?? .gold
        if let userId = top?.userId, !userId.isEmpty {
            Button { userCardPresentation = UserCardPresentation(userId: userId) } label: {
                GuardianAvatar(
                    urlString: top?.avatarURL,
                    size: 70,
                    level: level,
                    framed: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(top?.nickname ?? L10n.guardianTopGuardian)
        } else {
            GuardianAvatar(
                urlString: top?.avatarURL,
                size: 70,
                level: level,
                framed: true
            )
            .accessibilityHidden(true)
        }
    }

    private var topAvatarStack: some View {
        HStack(spacing: -8) {
            ForEach(0..<3, id: \.self) { index in
                GuardianAvatar(
                    urlString: store.panel.topAvatarURLs[safe: index],
                    size: 24,
                    level: nil,
                    framed: false
                )
                .overlay(Circle().stroke(.white, lineWidth: 1))
            }
        }
        .padding(.leading, 2)
    }

    private var levelTabs: some View {
        HStack(spacing: 6) {
            ForEach(GuardianLevel.displayOrder) { level in
                Button {
                    selectedLevel = level
                } label: {
                    HStack(spacing: 4) {
                        Image(GuardianArtwork.tabIcon(for: level))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                        Text(GuardianArtwork.levelName(level))
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(selectedLevel == level ? .white : Color(hex: 0x5E5A7F))
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        Image(selectedLevel == level ? GuardianArtwork.tabSelected : GuardianArtwork.tabUnselected)
                            .resizable()
                            .scaledToFill()
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(GuardianArtwork.levelName(level))
                .accessibilityAddTraits(selectedLevel == level ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
    }

    private var privilegeGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
        return LazyVGrid(columns: columns, spacing: 12) {
            ForEach(GuardianPrivilege.allCases) { privilege in
                let isAvailable = currentConfiguration.availablePrivileges.contains(privilege)
                GuardianPrivilegeTile(
                    privilege: privilege,
                    level: selectedLevel,
                    reward: currentConfiguration.reward(for: privilege),
                    isAvailable: isAvailable
                ) {
                    guard isAvailable else { return }
                    previewContext = GuardianPrivilegePreviewContext(
                        privilege: privilege,
                        level: selectedLevel,
                        staticImageURL: currentConfiguration.reward(for: privilege)?.staticImageURL,
                        dynamicImageURL: currentConfiguration.reward(for: privilege)?.dynamicImageURL
                    )
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 20)
    }

    private var priceSection: some View {
        HStack(spacing: 8) {
            ForEach([7, 30, 365], id: \.self) { days in
                GuardianPriceCard(days: days, price: currentConfiguration.price(for: days))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [Color(hex: 0xDBC4F2), .white],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(hex: 0xB86EFF), lineWidth: 1))
        .padding(.top, 22)
    }
}

private struct GuardianPrivilegeTile: View {
    let privilege: GuardianPrivilege
    let level: GuardianLevel
    let reward: GuardianReward?
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isAvailable
                                    ? [Color(hex: 0x9770EA), Color(hex: 0xD2C1F7)]
                                    : [Color(hex: 0xD1C7E6), Color(hex: 0xF8F6FB)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.white, lineWidth: 1)
                    GuardianPrivilegeImage(
                        assetName: GuardianArtwork.privilegeIcon(for: privilege, level: level, available: isAvailable),
                        remoteURL: reward?.staticImageURL
                    )
                    .frame(width: 58, height: 58)
                }
                .frame(width: 70, height: 70)

                Text(GuardianArtwork.privilegeName(privilege))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color(hex: 0x5E5A7F))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(height: 28, alignment: .top)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .accessibilityLabel(GuardianArtwork.privilegeName(privilege))
    }
}

private struct GuardianPrivilegeImage: View {
    let assetName: String
    let remoteURL: String?

    var body: some View {
        if let remoteURL, let url = URL(string: remoteURL) {
            CachedAsyncImage(url: url, contentMode: .fit, persistent: true) {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
            }
        } else {
            Image(assetName)
                .resizable()
                .scaledToFit()
        }
    }
}

private struct GuardianPriceCard: View {
    let days: Int
    let price: GuardianPrice?

    var body: some View {
        VStack(spacing: 8) {
            Text(GuardianArtwork.durationName(days))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0x5E5A7F))
            HStack(spacing: 3) {
                Image(GuardianArtwork.diamond)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                Text(price?.price.map(GuardianArtwork.formattedDiamond) ?? "--")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(hex: 0x5E5A7F))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let discount = price?.discountPercent, discount > 0 {
                Text(String(format: L10n.guardianSaveFormat, discount))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color(hex: 0xA964DE), in: Capsule())
            } else {
                Color.clear.frame(height: 18)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 106)
        .padding(.horizontal, 4)
        .background(
            LinearGradient(colors: [.white, Color(hex: 0xE9DEFA)], startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color(hex: 0xD5C4F5), lineWidth: 1))
    }
}

struct GuardianAvatar: View {
    let urlString: String?
    let size: CGFloat
    let level: GuardianLevel?
    let framed: Bool

    var body: some View {
        ZStack {
            CachedAsyncImage(url: urlString.flatMap(URL.init(string:)), contentMode: .fill, persistent: false) {
                Image("defaultUserAvatar")
                    .resizable()
                    .scaledToFill()
            }
            .frame(width: size, height: size)
            .clipShape(Circle())

            if framed, let level {
                Image(GuardianArtwork.topFrame(for: level))
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 1.7, height: size * 1.7)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: framed ? size * 1.25 : size, height: framed ? size * 1.25 : size)
    }
}

struct GuardianLoadErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xB33232))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0x5E2630))
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(L10n.commonRetry, action: retry)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6D36A5))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }
}

struct GuardianPrivilegePreviewContext: Identifiable {
    let privilege: GuardianPrivilege
    let level: GuardianLevel
    let staticImageURL: String?
    let dynamicImageURL: String?

    var id: String { "\(privilege.rawValue)-\(level.rawValue)-\(staticImageURL ?? "")" }
}

enum GuardianArtwork {
    static let topGlow = "guardianTopGlow"
    static let tabSelected = "guardianTabSelected"
    static let tabUnselected = "guardianTabUnselected"
    static let diamond = "guardianDiamond"

    static func topFrame(for level: GuardianLevel) -> String {
        switch level {
        case .gold: return "guardianTopFrameGold"
        case .silver: return "guardianTopFrameSilver"
        case .bronze: return "guardianTopFrameBronze"
        }
    }

    static func tabIcon(for level: GuardianLevel) -> String {
        switch level {
        case .gold: return "guardianTabGold"
        case .silver: return "guardianTabSilver"
        case .bronze: return "guardianTabBronze"
        }
    }

    static func privilegeIcon(for privilege: GuardianPrivilege, level: GuardianLevel, available: Bool) -> String {
        guard available else { return "guardianPrivilege\(privilege.rawValue.capitalized)" }
        switch privilege {
        case .notice: return "guardianPrivilegeNotice\(level.assetSuffix)"
        case .highlight: return "guardianPrivilegeBroadcast\(level.assetSuffix)"
        case .gift: return "guardianPrivilegeGift\(level.assetSuffix)"
        default: return "guardianPrivilege\(privilege.rawValue.capitalized)"
        }
    }

    static func giftPreview(for level: GuardianLevel) -> String {
        switch level {
        case .gold: return "guardianGiftPreviewGold"
        case .silver: return "guardianGiftPreviewSilver"
        case .bronze: return "guardianGiftPreviewBronze"
        }
    }

    static func levelName(_ level: GuardianLevel) -> String {
        switch level {
        case .gold: return L10n.guardianTabGold
        case .silver: return L10n.guardianTabSilver
        case .bronze: return L10n.guardianTabBronze
        }
    }

    static func durationName(_ days: Int) -> String {
        switch days {
        case 7: return L10n.guardianDay7
        case 30: return L10n.guardianDay30
        default: return L10n.guardianDay365
        }
    }

    static func privilegeName(_ privilege: GuardianPrivilege) -> String {
        switch privilege {
        case .badge: return L10n.guardianPrivilegeBadge
        case .frame: return L10n.guardianPrivilegeFrame
        case .chat: return L10n.guardianPrivilegeChat
        case .highlight: return L10n.guardianPrivilegeHighlight
        case .notice: return L10n.guardianPrivilegeNotice
        case .mount: return L10n.guardianPrivilegeMount
        case .gift: return L10n.guardianPrivilegeGift
        }
    }

    static func formattedDiamond(_ value: Int64) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: value), number: .decimal)
    }
}

private extension GuardianLevel {
    var assetSuffix: String {
        switch self {
        case .gold: return "Gold"
        case .silver: return "Silver"
        case .bronze: return "Bronze"
        }
    }
}

/// 直播房挂载守护详情时使用独立 modifier，避免把额外 sheet 泛型继续压入 LiveRoomView.body。
struct GuardianLiveSheetModifier: ViewModifier {
    @Binding var isPresented: Bool
    let anchorId: Int64

    func body(content: Content) -> some View {
        content.sheet(isPresented: $isPresented) {
            GuardianDetailView(anchorId: anchorId)
                .presentationDetents([.fraction(0.75)])
                .presentationDragIndicator(.visible)
        }
    }
}

/// 直播顶部守护入口。仅由这个小视图订阅人数和 146 队列，避免高频直播页面整体重算。
struct LiveRoomGuardianEntry: View {
    let anchorId: Int64
    @ObservedObject var broadcastQueue: GuardianBroadcastQueue
    let onTap: () -> Void

    @StateObject private var countStore: GuardianCountStore

    init(anchorId: Int64,
         broadcastQueue: GuardianBroadcastQueue,
         onTap: @escaping () -> Void) {
        self.anchorId = anchorId
        self.broadcastQueue = broadcastQueue
        self.onTap = onTap
        _countStore = StateObject(wrappedValue: GuardianCountStore())
    }

    var body: some View {
        Button {
            AnalyticsTracker.track("h_guardian_top_entry_click")
            onTap()
        } label: {
            ZStack(alignment: .bottom) {
                Image("guardianShield")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 29, height: 29)
                    .opacity(countStore.guardianCount > 0 ? 1 : 0.5)
                if countStore.guardianCount > 0 {
                    Text(countStore.guardianCount > 99 ? "99+" : "\(countStore.guardianCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(minHeight: 13)
                        .background(Color(hex: 0xAF4A01).opacity(0.82), in: Capsule())
                        .overlay(Capsule().stroke(Color(hex: 0xEFAA34), lineWidth: 1))
                        .offset(y: 4)
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.toolMyGuardian)
        .task(id: anchorId) { countStore.load(anchorId: anchorId) }
        .onChange(of: broadcastQueue.enqueueRevision) { _ in
            countStore.load(anchorId: anchorId)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
