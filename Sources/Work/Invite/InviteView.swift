import CoreImage
import SwiftUI
import UIKit

/// 原生 Invite 首页，按 H5 主播端的数据契约与交互范围实现。
struct InviteView: View {
    let entrySource: String
    let openDetails: (InviteAudience) -> Void
    @StateObject private var store = InviteStore()
    @State private var showRules = false
    @State private var sharePayload: InviteSharePayload?
    @State private var backgroundOpacity: Double = 1
    @State private var inviteButtonPulsing = false

    init(
        entrySource: String = InviteEntrySource.me.rawValue,
        openDetails: @escaping (InviteAudience) -> Void
    ) {
        self.entrySource = entrySource
        self.openDetails = openDetails
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: InviteScrollOffsetKey.self,
                        value: max(0, -proxy.frame(in: .named("inviteScroll")).minY)
                    )
                }
                .frame(height: 0)
                audienceTabs
                if let dashboard = store.dashboard, !dashboard.marquee.isEmpty {
                    InviteMarquee(items: dashboard.marquee)
                }
                rewardSection
                rankingSection
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .coordinateSpace(name: "inviteScroll")
        .onPreferenceChange(InviteScrollOffsetKey.self) { offset in
            backgroundOpacity = max(0, min(1, 1 - Double(offset) / 250))
        }
        .background(Color(hex: store.audience == .user ? 0x1A0730 : 0x2D083B).ignoresSafeArea())
        .background(background.opacity(backgroundOpacity).ignoresSafeArea())
        .navigationTitle(L10n.Invite.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { showRules = true } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(.white)
                }
                .accessibilityLabel(L10n.Invite.rules)
            }
        }
        .overlay {
            if store.state.isLoading && store.dashboard == nil {
                ProgressView().tint(.white)
            }
        }
        .refreshable { await store.reload() }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            inviteNowButton
        }
        .sheet(isPresented: $showRules) {
            InviteRulesSheet(
                rule: store.dashboard?.ruleText ?? "",
                faqURL: store.dashboard?.anchorInfo.faqURL ?? "",
                policyURL: store.dashboard?.anchorInfo.policyURL ?? ""
            )
            .giftPanelSheetBackground()
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $sharePayload) { payload in
            InviteShareSheet(payload: payload)
                .giftPanelSheetBackground()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task {
            AnalyticsTracker.track("h_invite_page_enter", properties: ["source": entrySource])
            AnalyticsTracker.track("h_invite_page_page_expose", properties: ["tab": store.audience == .user ? "user_page" : "host_page"])
            inviteButtonPulsing = true
            store.onAppear()
        }
    }

    private var background: some View {
        ZStack {
            CDNAssetImage(store.audience == .user ? "inviteUserBackground" : "inviteAnchorBackground")
                .resizable()
                .scaledToFill()
            LinearGradient(
                colors: [Color.black.opacity(0.04), Color(hex: 0x100D17).opacity(0.92)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var audienceTabs: some View {
        HStack(spacing: 4) {
            ForEach(InviteAudience.allCases) { audience in
                Button { store.selectAudience(audience) } label: {
                    Text(audience.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(store.audience == audience ? .white : .white.opacity(0.62))
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(store.audience == audience ? Color(hex: 0x9E2FE8) : .clear)
                        .clipShape(Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Color.black.opacity(0.22))
        .clipShape(Capsule())
        .padding(.top, 10)
        .onChange(of: store.audience) { _ in
            AnalyticsTracker.track("h_invite_page_page_expose", properties: ["tab": store.audience == .user ? "user_page" : "host_page"])
        }
    }

    private var rewardSection: some View {
        let share = store.currentShare
        return VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                Text(L10n.Invite.lifetimeReward)
                Image(systemName: "sparkles")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)

            Text(store.primaryCommission)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color(hex: 0xFFE600))
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(store.audience == .user
                 ? L10n.Invite.userRewardHint(store.primaryCommission)
                 : L10n.Invite.anchorRewardHint(store.primaryCommission))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(L10n.Invite.inviteCode)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.72))
                Text(share.code.isEmpty ? "--" : share.code)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button { copy(share.code) } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.Invite.copyCode)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(store.audience == .user ? Color(hex: 0xDE6C07) : Color(hex: 0xFD35B4))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            CDNAssetImage(store.audience == .user ? "inviteUserRewardBackground" : "inviteAnchorRewardBackground")
                .resizable()
                .scaledToFill()
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var rankingSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 4) {
                ForEach(InviteRankingTab.allCases) { tab in
                    Button {
                        AppLogger.net.notice("[Invite] UI ranking-tab tap current=\(store.rankingTab.rawValue, privacy: .public) target=\(tab.rawValue, privacy: .public)")
                        store.selectRankingTab(tab)
                    } label: {
                        Text(tab.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(store.rankingTab == tab ? .white : .white.opacity(0.62))
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(store.rankingTab == tab ? Color(hex: 0x7D24C7) : .clear)
                            .clipShape(Capsule())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
            .background(Color.black.opacity(0.22))
            .clipShape(Capsule())

            if store.rankingTab == .myRewards {
                statisticsPanel
                HStack {
                    Text(store.audience == .user ? L10n.Invite.last7DaysUser : L10n.Invite.last7DaysAnchor)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    CDNAssetImage("inviteLast7Days")
                        .resizable()
                        .scaledToFill()
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            if let message = store.visibleListError, store.visibleItems.isEmpty {
                InlineInviteError(message: message) { Task { await store.reload() } }
            } else if store.visibleItems.isEmpty, !store.state.isLoading {
                EmptyStateView(style: .compact, text: L10n.commonNoContent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 28)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.visibleItems) { item in
                        InviteRankRow(item: item)
                            .onAppear { store.loadMoreIfNeeded(current: item) }
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                    if store.isLoadingMore {
                        ProgressView().tint(.white).padding(.vertical, 14)
                    }
                }
                .padding(.horizontal, 14)
                .background(Color(hex: 0x2B1640).opacity(0.82))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

        }
    }

    private var inviteNowButton: some View {
        ZStack(alignment: .topTrailing) {
            Button {
                sharePayload = store.sharePayload()
            } label: {
                Label(L10n.Invite.inviteNow, systemImage: "square.and.arrow.up")
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(
                        LinearGradient(colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)], startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .scaleEffect(inviteButtonPulsing ? 1.025 : 1)
            .animation(.easeInOut(duration: 1).repeatForever(autoreverses: true), value: inviteButtonPulsing)

            Text(L10n.Invite.bigReward)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    LinearGradient(colors: [Color(hex: 0xFF591F), Color(hex: 0xFFC778)], startPoint: .top, endPoint: .bottom),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .offset(x: 4, y: -12)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Theme.Palette.screenBackground.opacity(0.96))
    }

    private var statisticsPanel: some View {
        HStack(spacing: 10) {
            InviteMetric(value: "\(store.currentStatistics.invitedCount)", title: store.audience == .user ? L10n.Invite.totalUsers : L10n.Invite.totalAnchors)
            InviteMetric(value: store.currentStatistics.awardTotal, title: L10n.Invite.cumulativeReward)
            Button {
                AppLogger.net.notice("[Invite] UI details tap audience=\(store.audience.rawValue, privacy: .public)")
                openDetails(store.audience)
            } label: {
                VStack(spacing: 8) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 19, weight: .medium))
                    Text(L10n.Invite.details)
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 66, height: 78)
                .background(Color(hex: 0x7D24C7))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.Invite.details)
        }
        .padding(12)
        .background(Color(hex: 0x42245D))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func copy(_ value: String) {
        guard !value.isEmpty else {
            AppToastCenter.shared.show(L10n.Invite.shareUnavailable)
            return
        }
        UIPasteboard.general.string = value
        AppToastCenter.shared.show(L10n.Invite.copySuccess)
    }
}

private struct InviteScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InviteMetric: View {
    let value: String
    let title: String

    var body: some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 21, weight: .bold))
                .foregroundStyle(Color(hex: 0xFFE970))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(height: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 78)
        .padding(.horizontal, 6)
    }
}

private struct InviteMarquee: View {
    let items: [InviteRankItem]
    @State private var currentIndex = 0

    private struct LoopKey: Hashable {
        let count: Int
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(hex: 0xBF25FF), Color(hex: 0x3E2FE4)],
                startPoint: .leading,
                endPoint: .trailing
            )
            marqueeItem(items[safeIndex])
        }
        .frame(height: 40)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: LoopKey(count: items.count)) {
            guard items.count > 1 else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    currentIndex += 1
                }
            }
        }
    }

    private var safeIndex: Int {
        guard !items.isEmpty else { return 0 }
        return currentIndex % items.count
    }

    private func marqueeItem(_ item: InviteRankItem) -> some View {
        HStack(spacing: 8) {
            AvatarView(urlString: item.iconURL, size: 20, kind: .user, userId: item.userID, disablesTap: true)
            Text(item.nickname)
                .foregroundStyle(Color(hex: 0x15FF3E))
                .lineLimit(1)
            Text(L10n.Invite.got)
                .foregroundStyle(.white)
            Spacer(minLength: 4)
            CDNAssetImage("diamondYellow")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(item.awardTotal)
                .foregroundStyle(Color(hex: 0xFFE600))
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 40)
        // 与首页 LiveNoticeBar 一致：以序号而非数据 id 触发每一条的完整转场。
        .id(currentIndex)
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .move(edge: .top).combined(with: .opacity)
        ))
    }
}

private struct InviteRankRow: View {
    let item: InviteRankItem

    var body: some View {
        HStack(spacing: 10) {
            AvatarView(urlString: item.iconURL, size: 37, kind: .user, userId: item.userID, disablesTap: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.nickname)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(L10n.Invite.uid(item.userID))
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            if item.createdAt != nil {
                Text(InviteDateFormatter.display(item.createdAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            } else {
                HStack(spacing: 4) {
                    CDNAssetImage("diamondYellow")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                    Text(item.awardTotal)
                        .lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: 0xFFE600))
            }
        }
        .padding(.vertical, 10)
    }
}

private struct InlineInviteError: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.78))
                .multilineTextAlignment(.center)
            Button(L10n.commonRetry, action: retry)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }
}

private struct InviteRulesSheet: View {
    let rule: String
    let faqURL: String
    let policyURL: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(rule.isEmpty ? L10n.Invite.ruleUnavailable : rule)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let faq = validURL(faqURL) {
                        Link(destination: faq) { Label(L10n.Invite.faq, systemImage: "questionmark.bubble") }
                            .foregroundStyle(Color(hex: 0xFFE970))
                    }
                    if let policy = validURL(policyURL) {
                        Link(destination: policy) { Label(L10n.Invite.policy, systemImage: "doc.text") }
                            .foregroundStyle(Color(hex: 0xFFE970))
                    }
                }
                .padding(20)
            }
            .navigationTitle(L10n.Invite.rules)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel(L10n.commonClose)
                }
            }
        }
    }

    private func validURL(_ string: String) -> URL? {
        guard let url = URL(string: string), url.scheme?.lowercased() == "https", url.host != nil else { return nil }
        return url
    }
}

private struct InviteShareSheet: View {
    let payload: InviteSharePayload
    @Environment(\.dismiss) private var dismiss
    @State private var showSystemShare = false
    @State private var showQRCode = false
    @State private var isPreparingShare = false
    @State private var systemShareItems: [Any] = []

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text(L10n.Invite.saveAndShare)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                CDNAssetImage(payload.audience == .user ? "inviteStepUser" : "inviteStepHost")
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 323)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(payload.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.64))
                    .lineLimit(3)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                if showQRCode {
                    InviteQRCodeView(content: payload.url)
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                HStack(spacing: 12) {
                    Button {
                        prepareSystemShare()
                    } label: {
                        Group {
                            if isPreparingShare {
                                ProgressView().tint(.white)
                            } else {
                                Label(L10n.Invite.share, systemImage: "square.and.arrow.up")
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isPreparingShare)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showQRCode.toggle()
                        }
                    } label: {
                        Image(systemName: "qrcode")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(L10n.Invite.showQRCode)
                }
                Button {
                    UIPasteboard.general.string = payload.text
                    AnalyticsTracker.track("h_invite_shareType", properties: [
                        "path": payload.audience == .user ? "inviteUser" : "inviteHost",
                        "channel": "Copy",
                    ])
                    if payload.audience == .anchor {
                        AnalyticsTracker.track("h_invite_page_host_tab_copy_link")
                    }
                    AnalyticsTracker.track("invite_btn_click", properties: ["source": payload.audience == .user ? "inviteUser" : "inviteHost"])
                    AppToastCenter.shared.show(L10n.Invite.copySuccess)
                } label: {
                    Label(L10n.Invite.copyLink, systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                Button(L10n.commonClose) { dismiss() }
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(.top, 24)
            .padding(.horizontal, 16)
        }
        .sheet(isPresented: $showSystemShare) {
            InviteActivitySheet(items: systemShareItems) { activityType, completed, _, _ in
                guard completed else { return }
                AnalyticsTracker.track("h_invite_shareType", properties: [
                    "path": payload.audience == .user ? "inviteUser" : "inviteHost",
                    "channel": activityType?.rawValue ?? "System",
                ])
            }
        }
    }

    @MainActor
    private func prepareSystemShare() {
        guard !isPreparingShare else { return }
        isPreparingShare = true
        Task { @MainActor in
            let poster = await InviteSharePoster.loadOrCreate(for: payload)
            systemShareItems = [poster, payload.text]
            isPreparingShare = false
            showSystemShare = true
        }
    }
}

/// 原生分享必须携带可转发的图片。服务端有海报时优先使用；旧环境未下发图片地址时，
/// 生成带邀请码和二维码的本地海报，保证分享链路不退化成纯文本。
private enum InviteSharePoster {
    private static let maxDownloadBytes = 10 * 1_024 * 1_024
    private static let qrContext = CIContext()

    static func loadOrCreate(for payload: InviteSharePayload) async -> UIImage {
        if let remoteImage = await download(urlString: payload.posterImageURL) {
            return remoteImage
        }
        return createFallback(for: payload)
    }

    private static func download(urlString: String) async -> UIImage? {
        guard let url = URL(string: urlString),
              url.scheme?.lowercased() == "https" else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode),
                  data.count <= maxDownloadBytes,
                  let image = UIImage(data: data) else { return nil }
            return image
        } catch {
            return nil
        }
    }

    private static func createFallback(for payload: InviteSharePayload) -> UIImage {
        let size = CGSize(width: 1080, height: 1440)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let colors = payload.audience == .user
                ? [UIColor(red: 0.49, green: 0.08, blue: 0.82, alpha: 1), UIColor(red: 0.88, green: 0.02, blue: 0.38, alpha: 1)]
                : [UIColor(red: 0.55, green: 0.06, blue: 0.48, alpha: 1), UIColor(red: 0.17, green: 0.03, blue: 0.31, alpha: 1)]
            let context = UIGraphicsGetCurrentContext()
            context?.drawLinearGradient(
                CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors.map(\.cgColor) as CFArray, locations: nil)!,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )

            draw(
                L10n.Invite.title,
                in: CGRect(x: 72, y: 132, width: 936, height: 74),
                font: .systemFont(ofSize: 56, weight: .bold),
                color: .white,
                alignment: .center
            )
            draw(
                payload.audience.title,
                in: CGRect(x: 72, y: 230, width: 936, height: 56),
                font: .systemFont(ofSize: 34, weight: .semibold),
                color: UIColor(red: 1, green: 0.91, blue: 0.31, alpha: 1),
                alignment: .center
            )

            let content = payload.text.replacingOccurrences(of: "\n", with: " ")
            draw(
                content,
                in: CGRect(x: 104, y: 352, width: 872, height: 230),
                font: .systemFont(ofSize: 30, weight: .regular),
                color: UIColor.white.withAlphaComponent(0.9),
                alignment: .center
            )

            let codeFrame = CGRect(x: 120, y: 668, width: 840, height: 122)
            UIBezierPath(roundedRect: codeFrame, cornerRadius: 24).fill(with: .normal, alpha: 0.22)
            draw(
                payload.code.isEmpty ? payload.url : payload.code,
                in: codeFrame.insetBy(dx: 24, dy: 28),
                font: .monospacedSystemFont(ofSize: 36, weight: .bold),
                color: .white,
                alignment: .center
            )

            if let qrImage = qrImage(content: payload.url) {
                qrImage.draw(in: CGRect(x: 300, y: 870, width: 480, height: 480))
            }
        }
    }

    private static func qrImage(content: String) -> UIImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cgImage = qrContext.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func draw(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        alignment: NSTextAlignment
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: style,
            ]
        )
    }
}

/// 原生分享面板让已安装的 Facebook、WhatsApp、LINE、Instagram 等渠道自行接管，
/// 也保留系统 Copy 动作；无需为每个 App 维护 URL scheme 白名单。
private struct InviteActivitySheet: UIViewControllerRepresentable {
    let items: [Any]
    let completion: (UIActivity.ActivityType?, Bool, [Any]?, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct InviteQRCodeView: View {
    let content: String
    private static let context = CIContext()

    var body: some View {
        Group {
            if let image = qrImage {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
            }
        }
        .accessibilityLabel(L10n.Invite.showQRCode)
    }

    private var qrImage: UIImage? {
        guard let data = content.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cgImage = Self.context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct InviteDetailsView: View {
    @StateObject private var store = InviteDetailsStore()
    @State private var selectedTab: InviteDetailTab = .invitedUsers
    @State private var showStartDatePicker = false
    @State private var pendingStartDate = Date()

    var body: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("inviteNavBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 18) {
                    detailTabs
                    dateFilters
                    detailsList
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.screenBackground.ignoresSafeArea())
        .navigationTitle(L10n.Invite.details)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { store.onAppear() }
        .sheet(isPresented: $showStartDatePicker) {
            VStack(spacing: 20) {
                DatePicker(
                    L10n.Invite.startDate,
                    selection: $pendingStartDate,
                    in: detailDateRange,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .tint(Color(hex: 0xFA06F4))

                HStack(spacing: 12) {
                    Button(L10n.commonCancel) {
                        showStartDatePicker = false
                    }
                    .buttonStyle(.bordered)

                    Button(L10n.commonConfirm) {
                        store.startDate = pendingStartDate
                        store.endDate = Date()
                        showStartDatePicker = false
                        Task { await store.reload() }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
    }

    private var detailTabs: some View {
        HStack(spacing: 0) {
            ForEach(InviteDetailTab.allCases) { tab in
                let isSelected = selectedTab == tab
                Button {
                    selectedTab = tab
                    store.selectTab(tab)
                } label: {
                    VStack(spacing: 9) {
                        Text(tab.title)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(isSelected ? Color(hex: 0xFFE600) : .white.opacity(0.5))
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Capsule()
                            .fill(isSelected ? Color(hex: 0xFFE600) : .clear)
                            .frame(width: 12, height: 4)
                    }
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var dateFilters: some View {
        Button {
            pendingStartDate = store.startDate
            showStartDatePicker = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "calendar")
                    .font(.system(size: 17, weight: .semibold))
                Text(InviteDateFormatter.dateText(store.startDate))
                Text("/").foregroundStyle(.white.opacity(0.7))
                Text(InviteDateFormatter.dateText(store.endDate))
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(height: 42)
            .background(
                LinearGradient(
                    colors: [Color(hex: 0x8515FF), Color(hex: 0xE40132)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .clipShape(Capsule())
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    private var detailDateRange: ClosedRange<Date> {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let earliest = calendar.date(from: DateComponents(year: 2015, month: 1, day: 1)) ?? .distantPast
        return earliest...Date()
    }

    @ViewBuilder
    private var detailsList: some View {
        if store.isLoading && store.items.isEmpty {
            ProgressView().tint(.white).padding(.top, 40)
        } else if let error = store.errorMessage, store.items.isEmpty {
            InlineInviteError(message: error) { Task { await store.reload() } }
        } else if store.items.isEmpty {
            EmptyStateView(style: .compact).frame(maxWidth: .infinity).padding(.top, 32)
        } else {
            VStack(spacing: 0) {
                InviteDetailListHeader(tab: store.tab)
                LazyVStack(spacing: 0) {
                    ForEach(store.items) { item in
                        if store.tab == .invitedUsers, !item.userID.isEmpty {
                            NavigationLink { InviteUserAwardsView(userID: item.userID) } label: {
                                InviteDetailRow(item: item, chevron: true)
                            }
                            .buttonStyle(.plain)
                        } else {
                            InviteDetailRow(item: item, chevron: false)
                        }
                        Divider().overlay(Color.white.opacity(0.08))
                            .onAppear { store.loadMoreIfNeeded(current: item) }
                    }
                    if store.isLoadingMore { ProgressView().tint(.white).padding(.vertical, 14) }
                }
            }
            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct InviteDetailListHeader: View {
    let tab: InviteDetailTab

    var body: some View {
        HStack(spacing: 8) {
            Text(L10n.Invite.user)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(tab == .invitedUsers ? L10n.Invite.accumulatedRewards : L10n.Invite.rewardQuantity)
                .frame(width: 76, alignment: .trailing)
            Text(L10n.Invite.invitationTime)
                .frame(width: 82, alignment: .trailing)
            if tab == .invitedUsers { Color.clear.frame(width: 12) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.6))
        .lineLimit(2)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 14)
        .frame(height: 74)
        .background {
            CDNAssetImage("inviteDashboardTableBackground")
                .resizable()
                .scaledToFill()
        }
    }
}

private struct InviteDetailRow: View {
    let item: InviteRewardRecord
    let chevron: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 10) {
                AvatarView(urlString: item.iconURL, size: 38, kind: .user, userId: item.userID, disablesTap: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.nickname).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    Text(L10n.Invite.userID(item.userID)).font(.system(size: 11)).foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 3) {
                CDNAssetImage("diamondYellow").resizable().scaledToFit().frame(width: 12, height: 12)
                Text(item.amount)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color(hex: 0xFFE600))
            .frame(width: 76, alignment: .trailing)
            Text(InviteDateFormatter.detailDisplay(item.createdAt))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
                .frame(width: 82, alignment: .trailing)
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 12)
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

private struct InviteUserAwardsView: View {
    @StateObject private var store: InviteUserAwardsStore

    init(userID: String) {
        _store = StateObject(wrappedValue: InviteUserAwardsStore(userID: userID))
    }

    var body: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("inviteNavBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 14) {
                    if let firstRecord = store.records.first {
                        VStack(spacing: 10) {
                            AvatarView(urlString: firstRecord.iconURL, size: 68, kind: .user, userId: store.userID, disablesTap: true)
                            Text(L10n.Invite.userID(store.userID))
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        Text(L10n.Invite.userID(store.userID))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if store.isLoading {
                        ProgressView().tint(.white).padding(.top, 40)
                    } else if let error = store.errorMessage {
                        InlineInviteError(message: error) { Task { await store.load() } }
                    } else if store.records.isEmpty {
                        EmptyStateView(style: .compact).frame(maxWidth: .infinity).padding(.top, 32)
                    } else {
                        VStack(spacing: 0) {
                            HStack {
                                Text(L10n.Invite.accumulatedRewardsDetail).frame(maxWidth: .infinity, alignment: .center)
                                Text(L10n.Invite.invitationTimeDetail).frame(maxWidth: .infinity, alignment: .center)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(height: 74)
                            .background {
                                CDNAssetImage("inviteDashboardTableBackground")
                                    .resizable()
                                    .scaledToFill()
                            }
                            LazyVStack(spacing: 0) {
                                ForEach(store.records) { item in
                                    HStack {
                                        HStack(spacing: 4) {
                                            CDNAssetImage("diamondYellow").resizable().scaledToFit().frame(width: 14, height: 14)
                                            Text(item.amount)
                                        }
                                        .foregroundStyle(Color(hex: 0xFFE600))
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        Text(InviteDateFormatter.detailDisplay(item.createdAt))
                                            .foregroundStyle(.white.opacity(0.62))
                                            .frame(maxWidth: .infinity, alignment: .center)
                                    }
                                    .font(.system(size: 14, weight: .medium))
                                    .padding(.vertical, 14)
                                    Divider().overlay(Color.white.opacity(0.08))
                                        .onAppear { store.loadMoreIfNeeded(current: item) }
                                }
                                if store.isLoadingMore { ProgressView().tint(.white).padding(.vertical, 14) }
                            }
                        }
                        .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(16)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.screenBackground.ignoresSafeArea())
        .navigationTitle(L10n.Invite.dataDetails)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await store.load() }
    }
}

struct InviteAnchorDashboardView: View {
    @StateObject private var store = InviteAnchorDashboardStore()

    private let primaryPeriods: [InviteDashboardPeriod] = [.today, .thisWeek, .lastMonth]

    var body: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("inviteDashboardBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 240)
                .ignoresSafeArea(edges: .top)

            ScrollView {
                VStack(spacing: 20) {
                    dashboardTabs
                    InviteDashboardIncomeCard(totalReward: store.dashboard?.totalReward ?? "0")
                    anchorList
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 24)
            }
        }
        .scrollIndicators(.hidden)
        .background(Theme.Palette.screenBackground.ignoresSafeArea())
        .navigationTitle(L10n.Invite.myDashboard)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { store.onAppear() }
    }

    private var dashboardTabs: some View {
        VStack(spacing: 8) {
            HStack(spacing: 0) {
                ForEach(primaryPeriods) { period in
                    let isSelected = isPrimaryPeriodSelected(period)
                    Button {
                        selectPrimaryPeriod(period)
                    } label: {
                        VStack(spacing: 9) {
                            Text(period.title)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(isSelected ? Color(hex: 0xFFE600) : .white.opacity(0.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                            Capsule()
                                .fill(isSelected ? Color(hex: 0xFFE600) : .clear)
                                .frame(width: 12, height: 4)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if store.period == .thisWeek || store.period == .lastWeek {
                HStack(spacing: 4) {
                    weekPeriodButton(.thisWeek)
                    weekPeriodButton(.lastWeek)
                }
                .padding(4)
                .background(Color.black.opacity(0.22))
                .clipShape(Capsule())
            }
        }
    }

    private func isPrimaryPeriodSelected(_ period: InviteDashboardPeriod) -> Bool {
        switch period {
        case .thisWeek:
            return store.period == .thisWeek || store.period == .lastWeek
        default:
            return store.period == period
        }
    }

    private func selectPrimaryPeriod(_ period: InviteDashboardPeriod) {
        if period == .thisWeek, store.period == .lastWeek {
            return
        }
        store.selectPeriod(period)
    }

    private func weekPeriodButton(_ period: InviteDashboardPeriod) -> some View {
        Button {
            store.selectPeriod(period)
        } label: {
            Text(period.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(store.period == period ? .white : .white.opacity(0.6))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(store.period == period ? Color(hex: 0x7D24C7) : .clear)
                .clipShape(Capsule())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var anchorList: some View {
        if store.isLoading && store.dashboard == nil {
            ProgressView().tint(.white).padding(.top, 40)
        } else if let error = store.errorMessage, store.dashboard == nil {
            InlineInviteError(message: error) { Task { await store.load() } }
        } else if store.dashboard?.anchors.isEmpty != false {
            EmptyStateView(style: .compact).frame(maxWidth: .infinity).padding(.top, 30)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(L10n.Invite.identifier).frame(width: 42, alignment: .center)
                    Text(L10n.Invite.nickname).frame(maxWidth: .infinity, alignment: .center)
                    Text(L10n.Invite.totalIncome).frame(width: 50, alignment: .center)
                    Text(L10n.Invite.giftIncome).frame(width: 50, alignment: .center)
                    Text(L10n.Invite.diamondIncome).frame(width: 50, alignment: .center)
                    Color.clear.frame(width: 12)
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 10)
                .frame(height: 74)
                .background {
                    CDNAssetImage("inviteDashboardTableBackground")
                        .resizable()
                        .scaledToFill()
                }

                LazyVStack(spacing: 0) {
                    ForEach(store.dashboard?.anchors ?? []) { item in
                        NavigationLink { InviteAnchorDetailView(uid: item.uid) } label: {
                            HStack(spacing: 8) {
                                Text(item.uid).frame(width: 42, alignment: .center)
                                Text(item.nickname).frame(maxWidth: .infinity, alignment: .center).lineLimit(1)
                                HStack(spacing: 2) {
                                    CDNAssetImage("diamondYellow").resizable().scaledToFit().frame(width: 10, height: 10)
                                    Text(item.totalIncome)
                                }
                                .frame(width: 50, alignment: .center)
                                .foregroundStyle(Color(hex: 0xFFE970))
                                HStack(spacing: 2) {
                                    CDNAssetImage("diamondYellow").resizable().scaledToFit().frame(width: 10, height: 10)
                                    Text(item.giftIncome)
                                }
                                .frame(width: 50, alignment: .center)
                                .foregroundStyle(Color(hex: 0xFFE970))
                                HStack(spacing: 2) {
                                    CDNAssetImage("diamondYellow").resizable().scaledToFit().frame(width: 10, height: 10)
                                    Text(item.diamondIncome)
                                }
                                .frame(width: 50, alignment: .center)
                                .foregroundStyle(Color(hex: 0xFFE970))
                                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).frame(width: 12)
                            }
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.vertical, 14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().overlay(Color.white.opacity(0.08))
                    }
                }
            }
            .background(Color.black.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct InviteDashboardIncomeCard: View {
    let totalReward: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.Invite.referralIncomeReward)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Text(totalReward)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Color(hex: 0xFFE970))
        }
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .padding(.horizontal, 24)
        .background {
            CDNAssetImage("inviteIncomeBackground")
                .resizable()
                .scaledToFill()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct InviteAnchorDetailView: View {
    @StateObject private var store: InviteAnchorDetailStore

    init(uid: String) { _store = StateObject(wrappedValue: InviteAnchorDetailStore(uid: uid)) }

    var body: some View {
        ZStack(alignment: .top) {
            CDNAssetImage("inviteNavBackground")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .ignoresSafeArea(edges: .top)

            ScrollView {
                if store.isLoading && store.detail == nil {
                    ProgressView().tint(.white).padding(.top, 50)
                } else if let error = store.errorMessage, store.detail == nil {
                    InlineInviteError(message: error) { Task { await store.load() } }.padding(16)
                } else if let detail = store.detail {
                    VStack(spacing: 18) {
                        AvatarView(urlString: detail.iconURL, size: 68, kind: .anchor, userId: detail.uid)
                            .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 3))
                        Text(L10n.Invite.userID(detail.uid))
                            .font(.system(size: 14, weight: .semibold))
                            .italic()
                            .foregroundStyle(.white)
                        metricGrid(detail)
                    }
                    .padding(16)
                }
            }
        }
        .scrollIndicators(.hidden)
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(L10n.Invite.dataDetails)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await store.load() }
    }

    private func metricGrid(_ detail: InviteAnchorDetail) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                metric(L10n.Invite.cumulativeOutputReward, detail.cumulativeOutputReward, "inviteMetricReward", [Color(hex: 0x5E1E2C), Color(hex: 0xC43E60)], border: Color(hex: 0xD47B97).opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 150)
                VStack(spacing: 10) {
                    metric(L10n.Invite.callIncome, detail.callIncome, "inviteMetricCall", [Color(hex: 0x5E1E4E), Color(hex: 0xA60775)], border: Color(hex: 0xF37BD0).opacity(0.4))
                    metric(L10n.Invite.giftIncome, detail.giftIncome, "inviteMetricGift", [Color(hex: 0x84184C), Color(hex: 0xAE336F)], border: Color(hex: 0xED84B7).opacity(0.4))
                }
                .frame(maxWidth: .infinity)
            }
            metric(L10n.Invite.connectionRate, detail.averageConnectionRate, "inviteMetricRate", [Color(hex: 0x183684), Color(hex: 0x335AAE)], border: Color(hex: 0x84AEEF).opacity(0.4))
                .frame(maxWidth: .infinity, minHeight: 70)
            HStack(spacing: 10) {
                metric(L10n.Invite.currentRanking, detail.rankingNumber, "inviteMetricRank", [Color(hex: 0x183A84), Color(hex: 0x3377AE)], border: Color(hex: 0x84BAED).opacity(0.4))
                metric(L10n.Invite.currentLevel, detail.level, "inviteMetricLevel", [Color(hex: 0x333177), Color(hex: 0x3356AE)], border: Color(hex: 0x8495ED).opacity(0.4))
            }
            HStack(spacing: 10) {
                VStack(spacing: 10) {
                    metric(L10n.Invite.onlineDuration, InviteDateFormatter.duration(detail.cumulativeOnlineSeconds), "inviteMetricOnline", [Color(hex: 0x621884), Color(hex: 0x7533AE)], border: Color(hex: 0xCF84ED).opacity(0.4), compactValue: true)
                    metric(L10n.Invite.averageCallDuration, InviteDateFormatter.duration(detail.averageCallSeconds), "inviteMetricAverage", [Color(hex: 0x4C226C), Color(hex: 0x6033AE)], border: Color(hex: 0xCB84ED).opacity(0.4), compactValue: true)
                }
                .frame(maxWidth: .infinity)
                metric(L10n.Invite.totalCallDuration, InviteDateFormatter.duration(detail.totalChatSeconds), "inviteMetricTotal", [Color(hex: 0x3A1E5E), Color(hex: 0x783EC4)], border: Color(hex: 0xA27BD4).opacity(0.4))
                    .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        _ iconName: String,
        _ colors: [Color],
        border: Color,
        compactValue: Bool = false
    ) -> some View {
        VStack(spacing: 5) {
            Text(value)
                .font(.system(size: compactValue ? 20 : 28, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(16)
        .background(
            LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(border, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            CDNAssetImage(iconName)
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .padding(8)
        }
    }
}
