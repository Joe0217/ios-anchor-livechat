import SwiftUI

/// 派对房大厅入口（spec §1.4.7）。MVP 仅 `room/list` 拉前 20 条 + 上拉加载；
/// 关注/最近/搜索推 F 期。
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
                ProgressView("加载中…")
            } else if rooms.isEmpty, !loadError.isEmpty {
                emptyError
            } else {
                roomList
            }
        }
        .navigationTitle("派对房")
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
        .navigationDestination(for: String.self) { roomId in
            PartyRoomView(roomId: roomId)
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
            Button("重试") { Task { await loadInitial() } }
        }
    }

    private var roomList: some View {
        List {
            ForEach(rooms, id: \.id) { room in
                NavigationLink(value: room.id ?? "") {
                    rowView(room)
                }
            }
            if hasMore {
                HStack {
                    Spacer()
                    if isLoading {
                        ProgressView()
                    } else {
                        Text("上拉加载更多").font(.caption).foregroundColor(.secondary)
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
                Text(room.roomName ?? "未命名房间")
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(room.onlineCount ?? 0)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if room.lockRoomFlag == 1 {
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
            loadError = api.errorDescription ?? "加载失败"
            AppLogger.party.error("[PartyList] load failed: \(api.localizedDescription, privacy: .private)")
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }
}
