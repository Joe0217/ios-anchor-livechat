import Foundation

/// 派对房搜索 store（E 增强 v2 · 对齐 H5 用户端 `livechat-h5/src/views/party/search.vue`）。
///
/// **触发方式**：显式 `search()` 调用（键盘回车 + 1500ms throttle），**不自动**跟 query 变化。
/// 对齐 H5 `keyup.enter="searchPartyRoomList()"` + `useThrottleFn(..., 1500)`。
///
/// 状态：`.idle` / `.searching` / `.result` / `.empty` / `.error`
/// - `.idle` / `.empty` / `.error` 视觉上都是空白（H5 无 hint/noResults 文案）。
/// - `.searching` 全屏 loading（H5 `<g-loading />`）
/// - `.result` 列表
@MainActor
final class PartySearchStore: ObservableObject {

    enum State: Equatable {
        case idle
        case searching(query: String)
        case result(rooms: [PartyRoomInfo], query: String)
        case empty(query: String)
        case error(message: String, query: String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.searching(let l), .searching(let r)): return l == r
            case (.result(let lr, let lq), .result(let rr, let rq)):
                return lq == rq && lr.count == rr.count && zip(lr, rr).allSatisfy { $0.stableListId == $1.stableListId }
            case (.empty(let l), .empty(let r)): return l == r
            case (.error(let lm, let lq), .error(let rm, let rq)): return lm == rm && lq == rq
            default: return false
            }
        }
    }

    /// 输入长度上限（对齐 H5 `maxlength="20"`）
    static let maxQueryLength = 20

    @Published private(set) var state: State = .idle
    @Published var query: String = "" {
        didSet {
            // 对齐 H5 `maxlength=20`：截断超长输入
            if query.count > Self.maxQueryLength {
                query = String(query.prefix(Self.maxQueryLength))
            }
        }
    }

    private var currentTask: Task<Void, Never>?
    private var lastFireAt: Date? = nil
    /// 对齐 H5 throttle 1500ms
    private let throttleInterval: TimeInterval = 1.5

    deinit { currentTask?.cancel() }

    /// 显式触发搜索（键盘回车 / 搜索按钮）。1500ms throttle 防抖。
    /// 对齐 H5 `useThrottleFn(searchPartyRoomList, 1500)`。
    func search() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            state = .idle
            return
        }
        // throttle：距上次触发不足 1500ms 时忽略
        if let last = lastFireAt, Date().timeIntervalSince(last) < throttleInterval {
            return
        }
        lastFireAt = Date()

        currentTask?.cancel()
        state = .searching(query: q)
        currentTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let rooms = try await PartyAPI.roomList(
                    languageCode: nil,
                    snapshotId: nil,
                    offset: nil,
                    pageSize: 10,     // 对齐 H5 `pageSize: 10`
                    queryParam: q,
                    version: "v2"
                )
                try Task.checkCancellation()
                await MainActor.run { [weak self] in
                    guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                    self.state = rooms.isEmpty ? .empty(query: q) : .result(rooms: rooms, query: q)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.query.trimmingCharacters(in: .whitespacesAndNewlines) == q else { return }
                    // 对齐 H5 catch：清空 list（error 态视觉同 empty）
                    self.state = .error(message: error.localizedDescription, query: q)
                }
            }
        }
    }

    /// 清空输入 + 状态回到 idle（点 ✕ 按钮 / 手动清空时用）
    func clear() {
        currentTask?.cancel()
        lastFireAt = nil
        query = ""
        state = .idle
    }
}
