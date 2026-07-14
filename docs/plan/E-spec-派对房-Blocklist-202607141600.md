# E - Party Blocklist spec (v1)

> 派对房房主/管理员维度黑名单（房间级、非账号级）：查看列表 + 解除封禁。踢人加黑主动方入口本 spec **不做**（H5 从 `party-user-card` 触发，属独立面板，后续 F 期用户名片接入）。

## §0 范围三圈 + H5 二次校验

### 三圈判定
- **内圈（本 spec 做）**：房主/管理员进入 Tools sheet → Blocklist → 列表页；下拉刷新；单项"移除"按钮 → 二次确认 → 解除封禁；空态 / 错态 / loading；倒计时（限时封禁自动解除）
- **中圈（外部已就绪）**：`PartyRoomToolsSheet.toolBlocklist` cell 已在位（PartyRoomToolsSheet.swift:29,68-70）；被踢方 attachType 1003 已通道（PartyAttachType.swift + PartyMessageRouter.handleKickedOut）；L10n `blocklistXxx` 全套翻译已存（个人 I-1 复用）
- **外圈（本 spec 不做）**：踢人主动入口（用户名片 → 选时长 → 加黑）；`kickOutRoom` API 接入；房主/管理员权限判定 UI；1010/1011 等未定义 attachType 探索

### H5 二次校验（关键差异，信 H5 源码不信文档）
1. **`banType` 字符串比较**：H5 `blocklist.vue` 用 `` `${item?.banType}` === '1' `` 判限时；iOS decoder 需 String/Int 双兼容（后端可能返 Int，见 [ios-decode-userid-compat.md](../../.claude/rules/ios-decode-userid-compat.md)）
2. **响应体是**直接 Array**，非 `{ list: [] }` 包装**（H5 `res.data` 直接 `.filter`）
3. **无分页**（H5 全量拉；`van-list` 只做壳，未配 `:finished`/`loading`）——iOS 沿用全量策略，量级由后端保证
4. **加/解黑无 IM 广播**（H5 blocklist.vue 无 IM 订阅；解除后仅本地 filter，其他管理员端不同步 → 下次开 popup 才见新态）
5. **倒计时归零仅停计时，不移除行**（H5 `clearCountdown` 后行仍在；下次 `getList()` 后端才不返）
6. **H5 存在 bug**：`.then/.finally` 均弹"Removed successfully" toast，失败无差别（iOS 修正：失败走 error toast）
7. **`roomId` 用业务 db id**（H5 `currentPartyInfo.id`，非云信 yxRoomId）——参 [im-payload-real-log-over-code-assumption.md](../../.claude/rules/im-payload-real-log-over-code-assumption.md) scopeId 派生一致性

## §1 业务契约 — API 端点

**Path 追 H5 `src/api/party/index.ts` 字面值，非从模块名反推**（[api-http-method-strict.md](../../.claude/rules/api-http-method-strict.md)）。

| 用途 | Method | Path | Body | Response |
|---|---|---|---|---|
| 查询黑名单 | POST | `/sapi/weidou/v1/client/party/room/getKickOutBlacklist` | `{ roomId: Int }` 业务 db id | `[PartyBlocklistItem]` **直接数组** |
| 解除封禁 | POST | `/sapi/weidou/v1/client/party/room/removeKickOutBlacklist` | `{ roomId: Int, targetUserId: String }` | Bool（真为成功） |
| 加黑（**本 spec 不做**，仅记录契约） | POST | `/sapi/weidou/v1/client/party/room/kickOutRoom` | `{ roomId, yxRoomId, seatIndex, targetUserId, banType: 1限时/2永久 }` | any |

**Blocklist item 字段（真机验证前草案）**：`userId` / `avatar` / `nickname` / `banType`(1限时/2永久，可能 String or Int) / `duration`(秒，限时才 >0) / `levelName?` / `vip?` / `medalList?` / `age?` / `gender?`（2 female / 1 male）。**上线前必真机 log dataKeys 一次**（[agent-recon-field-names-unverified.md](../../.claude/rules/agent-recon-field-names-unverified.md)）。

## §2 IM 广播

**本 spec 范围内加/解黑无 IM 广播**（H5 blocklist.vue 无订阅，解除仅本地 filter）——iOS 同样不订阅，其他管理员端不同步依赖手动刷新。

**已通道路径（非本 spec 新增，仅确认）**：
- attachType `1003 .kickedOut` → PartyMessageRouter.handleKickedOut → PartyStore.forceLeaveRoom(.kicked)（被踢方唯一路径）
- 房主/管理员触发 `kickOutRoom` 后**后端主动**下发 1003 给被踢方（iOS 侧本 spec 不发起）

**待观察**：`PartyKnownButUnhandledAttachType.codes` 中 1010/1011/1013 等未定义位可能承载"新增/解除封禁"广播——真机加/解黑一次后抓 attachType + dataKeys log 判断（[im-payload-real-log-over-code-assumption.md](../../.claude/rules/im-payload-real-log-over-code-assumption.md)）；若发现是 blocklist 事件 → 本 spec 追加 v2 订阅同步刷新。

## §3 iOS 模型 + 状态机

### Model（`Sources/Party/Blocklist/PartyBlocklistItem.swift`）
```swift
struct PartyBlocklistItem: Identifiable, Equatable, Decodable {
    let userId: String          // String/Int 双兼容 decode（ios-decode-userid-compat）
    let avatar: String?
    let nickname: String?
    let banType: Int            // 1 限时 / 2 永久（H5 字符串比较，iOS 归一 Int）
    private(set) var duration: Int  // 秒，限时才 >0；本地倒计时递减
    let levelName: String?
    let vip: Int?
    let medalList: [String]?    // 具体元素类型真机验证
    let age: Int?
    let gender: Int?            // 1 male / 2 female
    var id: String { userId }
    var isTemporary: Bool { banType == 1 }
    mutating func tick() { if duration > 0 { duration -= 1 } }
}

// Codable init：banType/duration/gender/vip 全部 Int|String 兼容；medalList 空数组兜底
```

### 状态机（`PartyBlocklistState`）
遵循 [list-refresh-preserve-items.md](../../.claude/rules/list-refresh-preserve-items.md) 双铁律：
```swift
enum PartyBlocklistState: Equatable {
    case idle
    case loading                            // 首次或空态刷新
    case loaded(items: [PartyBlocklistItem])
    case refreshing(items: [PartyBlocklistItem])  // 下拉刷新保留视觉
    case empty
    case error(String)
}
```

**迁移**：
- `idle → loading → loaded/empty/error`
- `loaded/empty/error(有 items) → refreshing(items) → loaded/empty/error`（**下拉必保留视觉**）
- `loaded → loaded(items - removedId)` 解除封禁乐观本地 filter

### Store（`PartyBlocklistStore.swift`，独立 store，不塞 PartyStore）
理由：房间维度、生命周期跟 Blocklist view，退出即释放；不污染 PartyStore（1000+ 行已够重）。

```swift
@MainActor
final class PartyBlocklistStore: ObservableObject {
    @Published private(set) var state: PartyBlocklistState = .idle
    @Published private(set) var removingIds: Set<String> = []  // 幂等守护：per-row isBusy
    private let roomId: Int
    private let service: PartyBlocklistServicing
    private var currentTask: Task<Void, Never>?
    private var countdownTimer: Timer?

    func load() { /* state = .loading; fetch; state = .loaded/.empty/.error */ }
    func refresh() {
        beginRefresh()  // sync 触发 currentTask
    }
    func refreshAsync() async {
        beginRefresh()
        await currentTask?.value  // .refreshable closure 必须 await 到完成
    }
    private func beginRefresh() {
        currentTask?.cancel()
        switch state {
        case .loaded(let items), .refreshing(let items):
            state = .refreshing(items: items)      // 保留视觉
        case .empty, .error, .idle, .loading:
            state = .loading                        // 无 items 可保留
        }
        currentTask = Task { /* fetch → assign */ }
    }
    func remove(userId: String) async {
        guard !removingIds.contains(userId) else { return }  // 幂等
        removingIds.insert(userId)
        defer { removingIds.remove(userId) }
        do {
            let ok = try await service.remove(roomId: roomId, targetUserId: userId)
            guard ok else { throw PartyBlocklistError.removeFailed }
            // 乐观本地 filter
            if case .loaded(let items) = state {
                let next = items.filter { $0.userId != userId }
                state = next.isEmpty ? .empty : .loaded(items: next)
            }
        } catch {
            // 抛给 view 层做 toast，state 不变
            throw error
        }
    }
    // 倒计时：Timer 1s tick 遍历 items 递减 duration；deinit 停
}
```

### Service（`PartyBlocklistService.swift`）
```swift
protocol PartyBlocklistServicing {
    func fetch(roomId: Int) async throws -> [PartyBlocklistItem]
    func remove(roomId: Int, targetUserId: String) async throws -> Bool
}
```

### View（`PartyRoomBlocklistView.swift`）
- NavigationStack + 列表 + `.refreshable { await store.refreshAsync() }`
- Row 视觉参考 `Sources/Profile/Settings/Blocklist/BlocklistView.swift`（复用视觉语言）
- Row 右侧移除按钮 + 二次确认 alert（L10n `blocklistRemoveConfirm*`）
- 限时行下方倒计时条 + `L10n.Party.autoUnban`
- 空态：`L10n.Party.blocklistEmpty`（新加 key）
- 错态：banner + retry
- 移除失败：toast `L10n.Party.blocklistRemoveNetworkError`（复用个人 blocklist key）

### 接线（PartyRoomView.swift）
- **:586-592** `onTapBlocklist`：删 `stubToolToast = ...`，改 `activeRoomTool = .blocklist`（保留 350ms sleep 规避 iOS 16 sheet race，对齐 `onTapSettings` 模式）
- **:643-645** `case .blocklist`：删 `Text("Blocklist coming soon")` + TODO 注释，改 `PartyRoomBlocklistView(store: PartyBlocklistStore(roomId: store.currentRoom.id))`

## §4 验收清单

### 正向（F）
- F1 房主/管理员点 Tools sheet → Blocklist → 列表页正常 push；后端返数据全部渲染（头像/昵称/性别年龄/限时倒计时条）
- F2 下拉刷新期间**列表视觉保留**（不闪空），顶部 spinner 正常显示至 refreshAsync 完成
- F3 点某行移除 → 二次确认弹窗 → Remove → row 即时消失（乐观 filter）+ toast "Removed successfully"
- F4 限时封禁 row 每秒倒计时递减；归 0 后倒计时消失但行仍在（下次刷新才移除）
- F5 空态显示图片 + 文案

### 反向（R critical）
- R1 首次拉取失败 → error banner + retry；retry 成功后正常渲染（不残留 error）
- R2 remove 接口失败 → 保留 row + 错误 toast；不做静默失败（不同于 H5 bug）
- R3 同一 userId 快速连点移除 → 只发一次请求（`removingIds` 幂等守护）
- R4 后端返 `userId` 为 Int 类型时 decode 不 crash（String/Int 双兼容）
- R5 后端返 `banType` 为 String `"1"` 时 decode 正确归一为 Int 1

## §5 待问用户（critical）

1. **本次范围确认**：只做查看 + 解除，踢人加黑主动入口留到 F 期用户名片 spec —— 是否 OK？
2. **权限判定**：H5 从 Tools sheet 进 Blocklist popup 是否隐式要求"房主/管理员"？iOS 侧 `PartyRoomToolsSheet` 当前 `toolBlocklist` cell 无条件显示——是否需要按 `PartyStore.currentRole` 过滤 cell 可见性？若是，卡到本 spec 还是 F 期？
3. **`banType`/`duration` 真机字段类型**：本 spec Codable 用 String/Int 双兼容兜底，但上线前需真机拉一次抓 dataKeys log 确认（不阻塞本 spec 编码）——是否安排真机验证节点在 step 2 impl 后？
