import Foundation
import SwiftUI

/// 受限首屏"消息"tab:完整对齐 H5 [newsRestricted/index.vue](../../../anchor-livechat-h5/src/views/newsRestricted/index.vue)。
///
/// 布局(自上而下,深色主题对齐 mineRestricted):
/// 1. 顶部标题栏 "News"
/// 2. Administrator 消息行:**复用 `SystemInboxRow`**(与主界面 Flame tab 顶部 3 入口同款切图 + 时间/未读徽章)
///    - preview / updateTime / unread 数据源:MessageSessionStore.systemInboxEntries[kind==.admin]
///    - tap → 进 ChatDetailContainer(与主界面同款,NIM adapter/store 完整)
/// 3. Card-box:审核提示长文案(banner variant=.news) + Admin WhatsApp 联系卡片(后端 config 拉取 WhatsApp 号)
struct NewsRestrictedView: View {
    @EnvironmentObject private var session: SessionStore
    @Binding var isOnSubpage: Bool
    @ObservedObject private var customerStore = CustomerServiceIdStore.shared
    @ObservedObject private var msgStore = MessageSessionStore.shared

    @State private var messagesPath: [String] = []
    @State private var transientError: String?
    @State private var isRefreshingCustomer = false
    /// H5 newsRestricted 通过 config 拉取的 WhatsApp 号，首次显示前使用固定兜底。
    @State private var whatsappPhone: String = "+86 185 0202 7264"
    /// 2026-07-17 G5:审核提示 banner 的翻译文案(对齐 H5 newsRestricted CTranslate)
    @State private var translatedText: String?
    @State private var isTranslating: Bool = false
    @State private var showHomeRanking = false

    /// 2026-07-17 R7:audit 相关 4 字段合成 signature,用于 onChange 监听变化触发 translatedText 清除。
    /// SwiftUI onChange 对 String 是 Equatable + 高效,比 4 个独立 onChange 更简洁。
    private var auditStateSignature: String {
        guard let u = session.user else { return "nil" }
        return "\(u.valid ?? -1)-\(u.type ?? -1)-\(u.onReview == true ? "1" : "0")-\(u.banAlways == true ? "1" : "0")"
    }

    var body: some View {
        NavigationStack(path: $messagesPath) {
            VStack(spacing: 0) {
                pageHeader
                content
            }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: String.self) { peerYxAccId in
                    if let selfId = session.user?.yxAccid, !selfId.isEmpty {
                        ChatDetailContainer(
                            peerYxAccId: peerYxAccId,
                            selfYxAccId: selfId,
                            onClose: nil,
                            originProfileUserId: nil,
                            sheetDetent: nil
                        )
                    } else {
                        Text("Chat unavailable: missing account info.")
                            .padding()
                            .foregroundStyle(.secondary)
                    }
                }
        }
        // 深色主题:与 MineRestrictedView 一致(profileBackground=#0B0010);SystemInboxRow 用 .primary/.secondary
        // 系统颜色必须在 dark colorScheme 下才能显示为白色系,否则 light mode 用户看到黑字黑底。
        .preferredColorScheme(.dark)
        .onAppear(perform: syncTabBarVisibility)
        .onChange(of: messagesPath.isEmpty) { _ in syncTabBarVisibility() }
        .onChange(of: showHomeRanking) { _ in syncTabBarVisibility() }
    }

    /// H5 `newsRestricted` 顶栏：透明背景、居中标题、首页同款金冠榜单入口。
    private var pageHeader: some View {
        ZStack {
            Text(L10n.tabMessages)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)

            HStack {
                Spacer()
                NavigationLink(isActive: $showHomeRanking) {
                    HomeRankingView()
                } label: {
                    Image("liveRankBadge")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 56, height: 28)
                        .frame(width: 56, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.liveRankBadge)
                .padding(.trailing, 8)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(alignment: .top) {
            Image("restrictedNewsHeader")
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 88)
                .clipped()
                .ignoresSafeArea(edges: .top)
        }
    }

    private func syncTabBarVisibility() {
        isOnSubpage = !messagesPath.isEmpty || showHomeRanking
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Administrator 会话行:直接复用主界面 SystemInboxRow 组件
                // - 有 adminEntry(NIM P2P session 已建)→ 显示实际 preview + updateTime + unread
                // - 无 adminEntry(未审核账号 imId 未拉/无 admin 消息)→ 显示占位 entry 保持视觉一致
                SystemInboxRow(entry: adminInboxEntry) {
                    handleAdminTap()
                }
                .redacted(reason: isRefreshingCustomer ? .placeholder : [])

                // Card-box:审核态提示 + WhatsApp 联系卡片
                cardBox

                if let err = transientError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                        .padding(.top, 8)
                }

                Spacer(minLength: 32)
            }
            .padding(.top, 8)
        }
        .background(Theme.Palette.profileBackground.ignoresSafeArea())
        .task {
            // 2026-07-17 H4:未审核账号进入 news tab 也必须触发 MessageSessionStore.load,让 recomputeSystemInbox
            // 能 populate admin session(preview/updateTime/unread)—— 否则 SystemInboxRow 永远走 fallback 分支
            // 显 "Contact support for questions." 静态文案,与 H5 newsRestricted MessageBar 真数据展示不对齐。
            //
            // load() 内部会并发拉:P2P sessions list + customerYxAccId(refreshIfNeeded) + station mail
            // + recomputeSystemInbox。conditional idle 短路对齐 MessageListView.task 同款语义,避免重复拉取。
            if case .idle = msgStore.state {
                async let sessionLoad: Void = msgStore.load()
                async let whatsapp: Void = fetchWhatsappPhone()
                _ = await (sessionLoad, whatsapp)
            } else {
                // 已 loaded/loading:load 内部会短路,只需并发拉 whatsapp + customer refresh(load 内部已顺带)
                async let customer: Void = customerStore.refreshIfNeeded()
                async let whatsapp: Void = fetchWhatsappPhone()
                _ = await (customer, whatsapp)
            }
        }
        // 2026-07-17 R7:audit 字段(valid/type/onReview/banAlways)任一变化 → 清 translatedText,回到 Translate 按钮态。
        // 场景:用户 tap Translate 拿到基于旧审核态的译文 → 收到 sysMsg 58 触发 refreshAuditStatus → banner 显示新审核态
        // 原文 → 但 translatedText 是基于旧原文的 → 用户看到译文与原文不匹配。
        // 用 signature 字符串合并 4 字段变化,SwiftUI onChange 对 String 是 Equatable 高效。
        .onChange(of: auditStateSignature) { _ in
            translatedText = nil
        }
        // 2026-07-17 G1:下拉刷新 admin 会话消息(NIM SDK 未主动 push 时手动同步)+ WhatsApp
        .refreshable {
            await refreshNews()
        }
    }

    /// admin 系统入口 entry:优先取 MessageSessionStore 已派生的 .admin entry;
    /// 未派生时给一条占位 entry(preview=空态提示;unread=0;updateTime=0 隐藏时间)
    private var adminInboxEntry: SystemInboxEntry {
        if let entry = msgStore.systemInboxEntries.first(where: { $0.kind == .admin }) {
            return entry
        }
        return SystemInboxEntry(
            id: "admin",
            kind: .admin,
            preview: customerStore.customerYxAccId != nil ? "Contact support for questions." : "Tap to load customer service.",
            updateTime: 0,
            unread: 0
        )
    }

    // MARK: - Card-box(H5 line 115-138):审核态长文案 + WhatsApp 联系卡片

    @ViewBuilder
    private var cardBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            RestrictedStatusBanner(user: session.user, variant: .news)
            translateRow
            adminWhatsappCard
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.Palette.cardFill)
        )
        .padding(.horizontal, 16)
        .padding(.top, 20)
    }

    /// 2026-07-17 G5:Translate 按钮 + 译文展示(对齐 H5 newsRestricted CTranslate 组件)。
    /// - 无原文(session.user==nil / message 空)→ 隐藏
    /// - 未翻译 → 显示 "Translate" 按钮
    /// - 翻译中 → spinner
    /// - 已翻译 → 展示译文(与原文相同视觉规格白色系)
    @ViewBuilder
    private var translateRow: some View {
        let originalMessage = RestrictedStatusBanner.derive(user: session.user, variant: .news)
        if !originalMessage.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if let translated = translatedText {
                    Text(translated)
                        .font(.system(size: 14))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Button {
                        Task { await handleTranslate(text: originalMessage) }
                    } label: {
                        HStack(spacing: 4) {
                            if isTranslating {
                                ProgressView().scaleEffect(0.75).tint(Color(red: 0.08, green: 1.0, blue: 0.24))
                            }
                            Text("Translate")
                                .font(.system(size: 14))
                                .foregroundStyle(Color(red: 0.08, green: 1.0, blue: 0.24))   // H5 #15FF3E
                            Image(systemName: "arrow.left.arrow.right")
                                .font(.system(size: 12))
                                .foregroundStyle(Color(red: 0.08, green: 1.0, blue: 0.24))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())   // 按 rule swiftui-button-plain-hitarea.md,组合 label 必须显式定义热区
                    }
                    .buttonStyle(.plain)
                    .disabled(isTranslating)
                }
            }
        }
    }

    @ViewBuilder
    private var adminWhatsappCard: some View {
        Button {
            UIPasteboard.general.string = whatsappPhone
            // 2026-07-17 R1:复制后 toast 反馈(对齐 WorkSysInfoFooter 已有模式)
            AppToastCenter.shared.show(L10n.commonCopySuccess)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "phone.badge.plus")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.green)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.green.opacity(0.15)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Administrator: Hily")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                    HStack(spacing: 4) {
                        Text("WhatsApp \(whatsappPhone)")
                            .font(.system(size: 14))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }

                Spacer()
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 交互

    /// 2026-07-17 G1:下拉刷新
    /// - **audit 刷新**:banner 文案依赖 SessionStore.user 的 valid/onReview/... 字段(F3 修:news tab
    ///   也用同款 banner,用户若一直在 news tab 不去 mine tab,不刷新审核态则永远看不到新状态)
    /// - **客服 imId**:H5 语义登录期恒不变,refreshIfNeeded 短路
    /// - **WhatsApp 号**:后端 config 可能变更
    /// - 系统消息(SystemInboxRow preview/unread):NIM SDK 已 push session,靠 recomputeSystemInbox 自动同步,无需显式拉
    private func refreshNews() async {
        async let audit: Void = session.refreshAuditStatus()
        async let customer: Void = refreshCustomer()
        async let whatsapp: Void = fetchWhatsappPhone()
        _ = await (audit, customer, whatsapp)
    }

    private func refreshCustomer() async {
        // customerYxAccId 已有值时 refreshIfNeeded 幂等短路,需要主动重拉:构造一次性 fetch
        // 但 CustomerServiceIdStore 只暴露 refreshIfNeeded,已有值就短路——受限首屏下拉刷新场景保留短路语义
        // (customerYxAccId 登录期恒不变,H5 也同款只在 login 后一次;下拉刷新主要是 audit + whatsapp)
        await customerStore.refreshIfNeeded()
    }

    /// 拉后端 WhatsApp 号(nil 保持既有值)
    private func fetchWhatsappPhone() async {
        if let phone = await AppConfigService.fetchWhatsAppPhone(), !phone.isEmpty {
            whatsappPhone = phone
        }
    }

    /// 2026-07-17 G5:Translate 按钮 tap → 调 MicrosoftTranslateService(与 ChatDetailView/PublicChat 同款)。
    /// - H5 使用应用启动时的微软翻译配置；iOS 若首次点击早于配置完成，会补一次应用级加载
    /// - 失败静默 log(对齐 H5 messageScroller 静默失败,不弹 toast)
    private func handleTranslate(text: String) async {
        guard !isTranslating, translatedText == nil, !text.isEmpty else { return }
        isTranslating = true
        defer { isTranslating = false }

        guard let credentials = await translatorCredentials() else {
            AppLogger.auth.warning("[NewsRestricted] translate unavailable: config missing")
            return
        }
        let targetLang: String = {
            switch AppLocaleStore.shared.current {
            case .en: return "en"
            case .ar: return "ar"
            case .tr: return "tr"
            case .system: return Locale.current.language.languageCode?.identifier ?? "en"
            }
        }()

        do {
            let translated = try await MicrosoftTranslateService.shared.translate(
                text: text, targetLang: targetLang, key: credentials.key, area: credentials.area
            )
            translatedText = translated
        } catch {
            AppLogger.auth.warning("[NewsRestricted] translate failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// `applyLogin` 会异步 activate，受限首页可能比该任务先可点击。
    /// 仅在凭证尚未就绪时补一次，后续点击直接复用会话级缓存，与 H5 App 初始化语义一致。
    private func translatorCredentials() async -> (key: String, area: String)? {
        if let key = AppConfigStore.shared.microsoftTranslatorKey,
           let area = AppConfigStore.shared.microsoftTranslatorArea,
           !key.isEmpty, !area.isEmpty {
            return (key, area)
        }

        await AppConfigStore.shared.activate()
        guard let key = AppConfigStore.shared.microsoftTranslatorKey,
              let area = AppConfigStore.shared.microsoftTranslatorArea,
              !key.isEmpty, !area.isEmpty else {
            return nil
        }
        return (key, area)
    }

    /// Administrator tap:客服 imId 已拉到 → 直接 push;未拉到 → 主动触发一次 refresh 后再判断。
    /// **改进**(2026-07-16):原设计 `.disabled(customerYxAccId==nil)` 导致 tap 完全无反应;
    /// 现改为始终可 tap,nil 时展示 loading + 触发 refresh,失败时展示 error message。
    private func handleAdminTap() {
        // 已拉到 → 直接 push
        if let cid = customerStore.customerYxAccId, !cid.isEmpty {
            transientError = nil
            messagesPath.append(cid)
            return
        }
        // 未拉到 → 主动 refresh(refreshIfNeeded 幂等,失败静默 log)
        guard !isRefreshingCustomer else { return }
        Task {
            isRefreshingCustomer = true
            defer { isRefreshingCustomer = false }
            transientError = nil
            await customerStore.refreshIfNeeded()
            if let cid = customerStore.customerYxAccId, !cid.isEmpty {
                messagesPath.append(cid)
            } else {
                transientError = "Customer service unavailable right now. Please try again in a moment or contact us via WhatsApp below."
                AppLogger.auth.warning("[NewsRestricted] admin tap: customerYxAccId still nil after refresh(未审核账号可能无 /api/im/getCustomerServiceList 权限)")
            }
        }
    }
}

// MARK: - Review ranking

/// H5 `/rank?path=review` 的原生入口。受限页从默认魅力日榜打开，并保留魅力/财富、日/周/月切换。
private struct ReviewRankingView: View {
    @StateObject private var store = ReviewRankingStore()
    @State private var category: ReviewRankCategory = .charm
    @State private var period: ReviewRankPeriod = .day

    var body: some View {
        List {
            Section {
                Picker("Category", selection: $category) {
                    ForEach(ReviewRankCategory.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Period", selection: $period) {
                    ForEach(ReviewRankPeriod.allCases) { item in
                        Text(item.title).tag(item)
                    }
                }
                .pickerStyle(.segmented)
            }
            .listRowBackground(Color.clear)

            if let error = store.error, store.members.isEmpty {
                Text(error)
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            } else if store.isLoading, store.members.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(Array(store.members.enumerated()), id: \.element.id) { index, member in
                        ReviewRankRow(rank: index + 1, member: member)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.Palette.profileBackground.ignoresSafeArea())
        .navigationTitle("Ranking")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.Palette.profileBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .safeAreaInset(edge: .bottom) {
            if let mine = store.mine {
                ReviewRankRow(rank: mine.rank ?? 0, member: mine, isMine: true)
                    .background(Theme.Palette.profileBackground)
            }
        }
        .task(id: "\(category.rawValue)-\(period.rawValue)") {
            await store.load(category: category, period: period)
        }
        .refreshable {
            await store.load(category: category, period: period)
        }
    }
}

private enum ReviewRankCategory: String, CaseIterable, Identifiable {
    case charm
    case wealth

    var id: String { rawValue }
    var title: String { self == .charm ? "Charm" : "Wealth" }
    func rankType(for period: ReviewRankPeriod) -> String {
        let prefix = self == .charm ? "ANCHOR" : "USER"
        return "\(prefix)_\(period.apiValue)"
    }
}

private enum ReviewRankPeriod: String, CaseIterable, Identifiable {
    case day, week, month

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var apiValue: String {
        switch self {
        case .day: return "DAY"
        case .week: return "WEEK"
        case .month: return "MON"
        }
    }
}

@MainActor
private final class ReviewRankingStore: ObservableObject {
    @Published private(set) var members: [ReviewRankMember] = []
    @Published private(set) var mine: ReviewRankMember?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    func load(category: ReviewRankCategory, period: ReviewRankPeriod) async {
        isLoading = true
        error = nil
        defer { isLoading = false }

        do {
            let data = try await APIClient.shared.post(
                "/api/ranking/getRankingList",
                body: ["rankType": category.rankType(for: period), "pageSize": 30, "currentPage": 1, "key": ""]
            )
            let response = try JSONDecoder().decode(ReviewRankingResponse.self, from: data)
            members = response.members
            mine = response.mine
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ReviewRankingResponse: Decodable {
    let members: [ReviewRankMember]
    let mine: ReviewRankMember?

    private enum CodingKeys: String, CodingKey {
        case rankingMembers, rankingMineVo
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        members = (try? container.decode([ReviewRankMember].self, forKey: .rankingMembers)) ?? []
        mine = try? container.decodeIfPresent(ReviewRankMember.self, forKey: .rankingMineVo)
    }
}

private struct ReviewRankMember: Decodable, Identifiable {
    let id: String
    let nickname: String
    let icon: String?
    let rank: Int?
    let value: String

    private enum CodingKeys: String, CodingKey {
        case userId, anchorUid, nickname, icon, rank
        case num, diamonds, diamondNum, totalDiamond, value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = container.decodeFlexibleString(forKey: .userId)
            ?? container.decodeFlexibleString(forKey: .anchorUid)
            ?? UUID().uuidString
        nickname = container.decodeFlexibleString(forKey: .nickname) ?? "--"
        icon = container.decodeFlexibleString(forKey: .icon)
        rank = container.decodeFlexibleInt(forKey: .rank)
        value = container.decodeFlexibleString(forKey: .num)
            ?? container.decodeFlexibleString(forKey: .diamonds)
            ?? container.decodeFlexibleString(forKey: .diamondNum)
            ?? container.decodeFlexibleString(forKey: .totalDiamond)
            ?? container.decodeFlexibleString(forKey: .value)
            ?? "0"
    }
}

private struct ReviewRankRow: View {
    let rank: Int
    let member: ReviewRankMember
    var isMine = false

    var body: some View {
        HStack(spacing: 12) {
            Text(rank > 0 ? "\(rank)" : "--")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(rank <= 3 && rank > 0 ? .yellow : .white.opacity(0.75))
                .frame(width: 28)
            AvatarView(urlString: member.icon, size: 40, kind: .anchor, disablesTap: true)
            Text(member.nickname)
                .font(.system(size: 15, weight: isMine ? .semibold : .regular))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 4) {
                Image("coins")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                Text(member.value)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 4)
    }
}
