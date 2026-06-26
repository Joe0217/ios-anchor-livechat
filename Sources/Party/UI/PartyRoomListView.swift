import SwiftUI

/// 派对房大厅入口（spec §1.4.7）。MVP 仅 `room/list` 拉前 20 条 + 上拉加载；
/// 关注/最近/搜索推 F 期。
///
/// **导航风格**：用 destination-based `NavigationLink { ... }` 直接 push（与 POCDebugView 内
/// LivePrepareView 入口同风格）。曾试过 `NavigationLink(value:)` + `navigationDestination(for:)`
/// value-based 模式，但外层 MainTabView 的 `NavigationStack(path: $workPath)` 是
/// `WorkRoute.self` 路由表，自定义 PartyRoomDestination 即便 stack 把 destination 闭包实例化了
/// （enter 已跑），view 也不在 path 内 → 处不可见层级，用户看到的仍是列表页。
struct PartyRoomListView: View {
    @State private var rooms: [PartyRoomInfo] = []
    @State private var isLoading = false
    @State private var loadError: String = ""
    @State private var offset: Int = 0
    @State private var hasMore: Bool = true
    @State private var pushCreate: Bool = false

    private let pageSize = 20

    var body: some View {
        ZStack {
            if rooms.isEmpty, isLoading {
                ProgressView(L10n.Party.loading)
            } else if rooms.isEmpty, !loadError.isEmpty {
                emptyError
            } else {
                roomList
            }
        }
        .navigationTitle(L10n.Party.listNavTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    pushCreate = true
                } label: {
                    Image(systemName: "plus.circle")
                }
            }
        }
        .navigationDestination(isPresented: $pushCreate) {
            PartyCreateRoomView()
        }
        .task { await loadInitial() }
        .refreshable { await loadInitial() }
    }

    // MARK: - 子视图

    private var emptyError: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 36))
                .foregroundColor(.orange)
            Text(loadError).font(.subheadline).multilineTextAlignment(.center).padding(.horizontal, 24)
            Button(L10n.Party.retry) { Task { await loadInitial() } }
        }
    }

    private var roomList: some View {
        List {
            // P1-5：用 stableListId 多重 fallback（id → agoraChannelId → yxRoomId → ownerId → roomName），避免 PartyRoomInfo.id String? 多 nil 时 List Identity 坍缩
            ForEach(rooms, id: \.stableListId) { room in
                NavigationLink {
                    PartyRoomView(roomId: room.id ?? "")
                } label: {
                    rowView(room)
                }
            }
            if hasMore {
                HStack {
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text(L10n.Party.listLoadMore).font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .onAppear {
                    if !isLoading { Task { await loadMore() } }
                }
            }
        }
        .listStyle(.plain)
    }

    private func rowView(_ room: PartyRoomInfo) -> some View {
        HStack(spacing: 12) {
            // 房间头像占位
            if let icon = room.roomAvatar, !icon.isEmpty, let url = URL(string: icon) {
                CachedAsyncImage(url: url, persistent: false) {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 48, height: 48)
                    .overlay(Image(systemName: "music.mic").foregroundColor(.secondary))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(room.roomName ?? L10n.Party.listUnnamed)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(room.onlineCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if room.lockFlag == 1 || room.needPassword == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundColor(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    // MARK: - 数据加载

    @MainActor
    private func loadInitial() async {
        offset = 0
        hasMore = true
        loadError = ""
        rooms = []
        await fetchPage()
    }

    @MainActor
    private func loadMore() async {
        guard !isLoading, hasMore else { return }
        await fetchPage()
    }

    @MainActor
    private func fetchPage() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await PartyAPI.roomList(offset: offset, pageSize: pageSize)
            if page.isEmpty {
                hasMore = false
            } else {
                rooms.append(contentsOf: page)
                offset += pageSize
                if page.count < pageSize { hasMore = false }
            }
            loadError = ""
        } catch let api as PartyAPIError {
            loadError = api.errorDescription ?? String(format: L10n.Party.listErrorLoadFailedFormat, "")
            AppLogger.party.error("[PartyList] load failed: \(api.localizedDescription, privacy: .private)")
        } catch let dec as DecodingError {
            loadError = String(format: L10n.Party.listErrorDecodeFormat, PartyDecodeErrorDescriber.describe(dec))
            AppLogger.party.error("[PartyList] decoding error: \(String(describing: dec), privacy: .private)")
        } catch {
            loadError = String(format: L10n.Party.listErrorLoadFailedFormat, error.localizedDescription)
        }
    }
}

/// DecodingError 友好描述：把 codingPath 和具体 case 拼出来，方便 dev 调试看到"哪个字段类型不符"。
enum PartyDecodeErrorDescriber {
    static func describe(_ err: DecodingError) -> String {
        switch err {
        case .typeMismatch(let type, let ctx):
            return "类型不匹配 \(type) @ \(pathOf(ctx)) — \(ctx.debugDescription)"
        case .valueNotFound(let type, let ctx):
            return "缺值 \(type) @ \(pathOf(ctx))"
        case .keyNotFound(let key, let ctx):
            return "缺 key '\(key.stringValue)' @ \(pathOf(ctx))"
        case .dataCorrupted(let ctx):
            return "数据损坏 @ \(pathOf(ctx)) — \(ctx.debugDescription)"
        @unknown default:
            return "\(err)"
        }
    }

    private static func pathOf(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map { $0.stringValue.isEmpty ? "[\($0.intValue ?? -1)]" : $0.stringValue }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }
}
