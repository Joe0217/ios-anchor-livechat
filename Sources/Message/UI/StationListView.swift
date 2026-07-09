import SwiftUI

/// 站内信独立列表页（Batch 3.8，对齐 H5 `views/news/message/stationMsg.vue`）。
///
/// **不是 P2P 会话**：走 HTTP `/api/sysmail/loadList` 分页拉列表；每条含 title / HTML content / expiryDate。
/// 用户点 Flame 顶部 Station 入口后 push 到本页。
///
/// **UI 简版**（v1）：
/// - 顶部 nav：`Station Information` i18n + 返回
/// - List：每条卡片 title + expiryDate + HTML→纯文本 mailContent（简易 strip；v2 换 AttributedString/WKWebView）
/// - 分页：滚到底部触发 loadMore
struct StationListView: View {

    @StateObject private var store = StationListStore()

    var body: some View {
        ZStack {
            ChatPalette.pageBackground.ignoresSafeArea()
            content
        }
        .navigationTitle(L10n.messageSystemInboxStation)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(ChatPalette.navGradient, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await store.loadFirstPageIfNeeded() }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading where store.mails.isEmpty:
            ProgressView().tint(.white)
        case .error(let msg) where store.mails.isEmpty:
            errorState(msg)
        default:
            list
        }
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.white.opacity(0.6))
            Text(msg)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Retry") { Task { await store.loadFirstPage() } }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(store.mails, id: \.id) { mail in
                    row(mail)
                        .onAppear {
                            if mail.id == store.mails.last?.id { Task { await store.loadMore() } }
                        }
                }
                if store.isLoadingMore {
                    ProgressView().tint(.white.opacity(0.5)).padding(.vertical, 12)
                }
            }
            .padding(16)
        }
    }

    private func row(_ mail: StationMail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "envelope.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(ChatPalette.primaryGradient, in: Circle())
                Text(mail.mailTitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            Divider().background(Color.black.opacity(0.3))
            Text(Self.stripHTML(mail.mailContent))
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if !mail.expiryDate.isEmpty {
                Text(mail.expiryDate)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(12)
        .background(ChatPalette.cardBackground, in: RoundedRectangle(cornerRadius: 8))
    }

    /// 简易 HTML → 纯文本（v1 版本；v2 换 AttributedString(html:) 支持 img/富文本）
    private static func stripHTML(_ html: String) -> String {
        // 简单 regex 去 <tag> —— H5 mailContent 常见 <p><br><img>；本版本忽略 img 渲染
        let noTags = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return noTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&amp;",  with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Batch 3.8：Station 详情列表页 store（分页 + loading/error）
@MainActor
final class StationListStore: ObservableObject {

    enum State: Equatable {
        case idle
        case loading
        case loaded
        case error(String)
    }

    @Published private(set) var mails: [StationMail] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore: Bool = false

    private var currentPage: Int = 1
    private var isEndReached: Bool = false
    private let service: StationListService

    init(service: StationListService = .shared) {
        self.service = service
    }

    func loadFirstPageIfNeeded() async {
        guard mails.isEmpty, state == .idle else { return }
        await loadFirstPage()
    }

    func loadFirstPage() async {
        state = .loading
        currentPage = 1
        isEndReached = false
        do {
            let list = try await service.fetchList(page: 1)
            mails = list
            state = .loaded
            if list.count < 20 { isEndReached = true }
            if let first = list.first { service.markRead(first) }
        } catch {
            state = .error("Failed to load, tap Retry")
        }
    }

    func loadMore() async {
        guard !isEndReached, !isLoadingMore, state == .loaded else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let next = currentPage + 1
        do {
            let list = try await service.fetchList(page: next)
            if list.isEmpty || list.count < 20 { isEndReached = true }
            mails.append(contentsOf: list)
            currentPage = next
        } catch {
            // 分页失败静默——避免打断浏览
        }
    }
}
