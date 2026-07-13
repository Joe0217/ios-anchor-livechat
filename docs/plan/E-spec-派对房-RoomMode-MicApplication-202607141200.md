# E - Party Room Mode + Mic Application spec (v2)

> B 档精简 spec · 2026-07-14 · 对齐 H5 蓝本 `livechat-h5/src/views/party/*` + `stores/modules/party.js`
>
> **v2 修订**（2026-07-14 15:00，基于 3 份对抗式红队 17 findings 合并 P0/P1 反悔）：
> - §0/§1 补 IM 1017 版本号判丢 + 房主本地兜底 + 全量替换乱序保护
> - §2 补 agreeSeat 并发占位集合 + operatorType 待验证 + 观众端分流字段真机验证
> - §3 新增 queueSeatNum / micApplicationsState / rejectedAt 冷却字段 + Codable alias 兜底
> - §3 补 Sheet mount hoist 段（对齐 swiftui-fullscreencover-hoist rule）
> - §4 补 A6 IM 真机 log 验证 + R6-R9 并发/冷却/离线/空态反向

## §0 范围三圈 + H5 二次校验

### 范围三圈

- **内圈（本 spec 落地）**：
  - Room Mode：房主端模式选择弹窗 + 二次确认 + 服务端切模板 + 观众端 IM 1017 广播消费（全员下麦 + 刷麦位 + 公屏系统消息）
  - Mic Application：房主开关切换（含首次协议确认）+ 观众端申请/放弃 + 房主端申请列表 + 通过/拒绝审批 + IM 1018/1020/1021 消费
- **中圈（延后）**：
  - 排麦列表内房主"通过"后打开 `seat-roster-popup` 选具体麦位 —— 本 spec 落"agreeSeat 已带 seatIndex 入参"路径，UI 由 impl 决定是否弹选位（可先默认选第一个空位 + `pendingApproveSeatIndex` 占位集合防并发冲突）
  - VIP guide 冲突逻辑（末尾 3 条含 `switchMode` 时阻止插入 VIP 气泡，`party.js:355`）
  - 排麦通知 debounce 800ms 合批（H5 `undateQueueSeat`）
  - 房管路径 agreeSeat 的 operatorType 值（本 spec 硬编 1，真机验证后回填）
- **外圈（不做）**：
  - PK 场景 roomTempId===1 门槛（PartyRoomView.swift:690/792 TODO，属 G 里程碑）
  - 音乐循环模式 `switchMode`（`music-list.vue`，与 Room Mode 无关，明确不混淆）
  - 主动 kickSeat / lockSeat / prohibitMic API 及 my-mic-tool 面板（不属排麦流程，另开 spec）

### H5 二次校验实事（信源码不信推断）

- **模板项字段**：H5 `change-mode-popup.vue` 只字面消费 `roomTempId / imgUrl / createRoomLevel` 三字段；`voiceNum / videoNum / totalSeatNum` **是否存在**未在 popup 层证实（agent-recon-field-names-unverified rule）→ iOS `PartyRoomTemplate` decode 必须 log 一次真机响应确认字段名，先按 5 字段起草 + CodingKeys alias 兜底
- **IM 1017 payload**：H5 `party.js:436-461` 用 `GzipBase64Decoder.decode(extData)` 解压；消费字段 `seats / currentSeatIndex / currentUserId / seatOperate`（可用 attachType 1017 兜底）→ iOS 复用现有 gzip+base64 解码路径
- **IM 1017 房主自己回执**：H5 源码未证实房主发起切换后是否收到自己的云信广播；本 spec **不假设**，落"房主 API 成功即本地触发同款 handleModeChange，观众端也走 IM"双通道，重复触发靠 `roomTempId==目标值` 幂等（v2 修订）
- **IM 1017 全量替换乱序**：切模板 API 成功期间旧 1001/1012 单点麦位增量可能排队后到，若直接覆盖 seats 会踩旧数据；iOS 落"处理任何 IM 前先比对 `msgTimestamp` 与本地 `lastRoomTempSwitchAt`（切模板成功时间戳），早于该时间戳的 1001/1012 全部丢弃"（v2 修订）
- **IM 1018/1020/1021 payload**：H5 `_extData` 内部字段仅 `handleQueueSeat` 内推断（`num / operation / userId`），完整 payload keys **必须真机 log 抓 `dataKeys=` 校对**（im-payload-real-log-over-code-assumption rule）
- **观众 onSeat response 分流字段**：H5 `onSeat` 后 `.then` 分支不区分"直接上麦 vs 入队"，可能靠后续 IM 1001（上麦成功）/ 1018 op=1（入队成功）区分 → iOS 落"onSeat truthy 后本地暂标 `myApplyInfo.inIndex = 请求的 seatIndex`，等 IM 1001 到达清 inIndex（真上麦），或 1018 op=1 且 userId==self 时保持 inIndex"（v2 修订，字段名以真机 log 为准）
- **API path 前缀**：全部走 `/sapi/weidou/v1/client/party/...`，**不加** `/api/` 前缀（api-http-method-strict rule）
- **Throttle**：tab 300ms / Confirm 2000ms / Submit 2000ms —— iOS 用 Store 层 `isBusy` flag 幂等，不引入第三方 debounce

## §1 业务契约 — Room Mode

### 模式数 + roomTempId 映射

Tab 分类：`type=2` = Live+Voice / `type=1` = Voice；每 tab 多模板，`roomTempId: Int` 唯一。**已知具名映射**：`roomTempId === 1` = VIDEO_AND_TEMP（3 视频位 + 10 麦位，支持 PK，左上角 pk-tem-icon 贴片）；其余 roomTempId 与麦位配置映射由服务端返回决定，客户端不硬编码。

### 拉模板列表

- **API**：`POST /sapi/weidou/v1/client/party/room/getRoomTempList`
- **Body**：`{ type: 1 | 2 }`
- **Response**：`[PartyRoomTemplate]` —— 字段起草（真机验证前）：`roomTempId: Int / imgUrl: String / createRoomLevel: Int / voiceNum: Int? / videoNum: Int? / totalSeatNum: Int?`
- **调用时机**：房主点 Room Mode 入口时并发拉 type=1/2 两次，`Promise.allSettled` 语义（单 tab 失败不阻塞另一 tab），缓存到 `PartyStore.roomModeTemplates[type]`；已缓存则复用
- **UI 态**：`loading / loaded([templates]) / partialLoaded(voice: [templates]?, live: [templates]?) / error(msg)`（v2 补 partialLoaded 处理单 tab 失败的场景）

### 切模板

- **API**：`POST /sapi/weidou/v1/client/party/seat/switchRoomTemp`
- **Body**：`{ roomId: String, roomTempId: Int, yxRoomId: String }`
- **Response**：仅判 truthy（无字段消费）→ 埋点 `b_changeMode { modeNum }` + 关弹窗；成功 **不主动重刷麦位**，但**立即在本地打时间戳** `lastRoomTempSwitchAt = Date()` 用于后续 IM 乱序判丢
- **房主本地兜底**（v2 修订）：API 成功后房主本地立即调用同款 `handleRoomModeChanged(newTempId:)`（不等 IM 1017 回执，避免云信不发自己回执导致房主状态与观众端分裂）；观众端也走 IM 到达路径，重复触发靠 `PartyRoomInfo.roomTempId == newTempId` 幂等

### IM 广播 attachType=1017

- **Payload**：gzip+base64 压缩，解压后 `{ seats: [PartyRoomSeat], currentSeatIndex: Int?, currentUserId: String?, seatOperate: Int? }`（seatOperate 可用 1017 兜底）
- **处理顺序**（v2 修订，共 6 步）：
  1. **乱序判丢**：若 IM `msgTimestamp < lastRoomTempSwitchAt - 3s`（3s 容差）→ 直接丢弃（旧 1001/1012 排队错到）
  2. **幂等保护**：若 `PartyRoomInfo.roomTempId == 新 tempId`（房主本地兜底已跑）→ 只更新 seats，不重复触发下麦 hook + 系统消息
  3. **全量替换** `PartyStore.seats`（等价现 `postMikeList` 对账）
  4. **自身分支**：若本地用户先前在麦上（`selfSeatIndex >= 0`）→ 触发下麦 hook（清 RTC 视频位、上报埋点 `party_video_leave / party_voice_leave` reason=`modeChange`）
  5. **公屏落一条系统消息** `msgType: switchMode`，文案 `L10n.Party.roomModeSwitchedSystemMsg`（"Room layout updated. All users have been moved off seats. Please select a new seat to continue chatting!"）
  6. **清 Mic Application 相关状态**：`myApplyInfo.inIndex = 0` + `micApplications = []` + `queueSeatNum = 0`（服务端切模板时会清队列，观众 UI 不能卡"排麦中"）
  7. **更新** `PartyRoomInfo.roomTempId = 新 tempId`（PartyStore 需暴露 setter，当前只在进房时写入）
- **解压失败 fallback**：调 `reloadSeatListFromServer()`（现有 API `seatList(roomId)`）

### 观众反应

- 非房主/房管在 Tools sheet 中**无** Room Mode 入口（PartyRoomToolsSheet.swift 已 `isOwner` gated）
- 收到 1017 广播 → 若在麦上被踢下 → 视频停采（若 Voice-only 模板）+ RTC 视频位 disable + 公屏系统消息

## §2 业务契约 — Mic Application

### 观众端

- **申请上麦**：`POST /sapi/weidou/v1/client/party/seat/onSeat` — `{ roomId, seatIndex, yxRoomId, roomTempId }` — 复用现有 `PartyAPI.onSeat`
  - **分流**（v2 修订）：onSeat truthy 后本地暂标 `myApplyInfo.inIndex = 请求的 seatIndex`；后续通过 IM 分流：
    - IM 1001（上麦成功广播，`userId==self`）到达 → 清 `myApplyInfo.inIndex = 0`（真上麦，走正常 onSeat 路径）
    - IM 1018 op=1 且 `userId==self` → 保持 `myApplyInfo.inIndex`（真入队，等排到）
- **拒后冷却**（v2 修订）：观众收到 1018 op=3（被拒）→ 本地 `rejectedAt = Date()`，30s 内 tap 空麦位 → toast "Please try again later" 不发 onSeat（防 spam）
- **放弃排麦**：`POST /sapi/weidou/v1/client/party/seat/giveUpQueueSeat` — `{ roomId, yxRoomId }` — 成功清 `myApplyInfo.inIndex = 0` + toast
- **applying 超时兜底**（v2 修订）：`myApplyInfo.inIndex > 0` 持续 > 5min 无 IM 到达 → 本地自动 giveUp + toast "Application timed out"（防房主离线时观众永久卡状态）

### 房主/房管端

- **拉申请列表**：`POST /sapi/weidou/v1/client/party/seat/getQueueSeatList` — `{ roomId, pageSize: 99 }` — Response `{ totalNum: Int, records: [PartyMicApplication], myIndex: Int }`；`myIndex=-1` 表示当前用户不在列表
  - `PartyMicApplication` 字段（起草，真机验证前）：`userId / nickname / avatar / gender / age / userType / levelName / vip / seatType / seatIndex`
  - **列表状态机**（v2 修订，套 list-refresh-preserve-items rule）：`loading / loaded([apps]) / refreshing([oldApps]) / empty / error(msg)`
- **拒绝**：`POST /sapi/weidou/v1/client/party/seat/refuseQueueSeat` — `{ roomId, targetUserId, yxRoomId }`
- **通过**：`POST /sapi/weidou/v1/client/party/seat/agreeSeat` — `{ roomId, seatIndex, targetUserId, operatorType: 1, roomTempId, yxRoomId }`
  - **seatIndex 策略**（v2 修订，防并发冲突）：Store 内维护 `pendingApproveSeatIndex: Set<Int>`；agreeMicApplication 挑首空位时排除该集合内已占位；成功回收；失败也回收
  - **全麦位满 fallback**：无可用空位 → toast "No available seat, please wait for someone to leave" + 不调 agreeSeat（v2 修订）
  - **operatorType 值**：本 spec 内圈硬编 1（房主）；房管路径见 §5 待问，真机验证后回填
- **开关切换**：`POST /sapi/weidou/v1/client/party/room/updateOnSeatEnable` — `{ roomId, enable: 0 | 1 }`
  - 首次切换（本地 `partySaveInfo.autoEnterOnApplication / autoEnterOffApplication` = false 时）→ 弹协议确认（UI 层），用户确认后置本地 flag + 调 API；二次同方向切换直接调 API
  - iOS 复刻：`partySaveInfo` 用 `@AppStorage` 持久化两个 Bool flag（本地长驻）

### IM 广播

| attachType | 语义 | Payload（真机验证前起草） | iOS 处理 |
|---|---|---|---|
| 1018 | 排麦通知 | `{ num: Int, operation: Int, userId: String }`；operation 1=申请 / 2=同意 / 3=拒绝 / 4=放弃 | `operation=1 && 非本人`：面板已开则重拉列表（走 refreshing(items) 中间态，保留视觉）；`operation∈{2,3,4}`：面板已开时从列表 splice；`isMine && [2,3]`：关面板 + `myApplyInfo.inIndex=0`；`operation=3` toast + 设 `rejectedAt = now`（冷却）；`queueSeatNum = num` |
| 1020 | 拒接上麦通知 | H5 空 body | iOS log 一条 debug + 保留 known-but-unhandled，不消费 |
| 1021 | 开启/关闭申请上麦开关 | `{ enable: Int }` (0/1) | `onSeatApplySwitch = enable==1`；关时若面板打开顺手关；公屏落系统消息（"The mic application is turned on / removed"） |

**批准通道无独立 IM**：房主通过后走 1001/1012 麦位刷新 + 1018 operation=2 组合，申请者从队列出队 → 座位上有人（**无**"你被批准了"专用广播）。

## §3 iOS 模型 + 状态机

### 新增 model

```swift
// PartyRoomTemplate.swift（新建）
struct PartyRoomTemplate: Decodable, Identifiable {
    let roomTempId: Int
    let imgUrl: String
    let createRoomLevel: Int
    let voiceNum: Int?      // 真机验证前 optional
    let videoNum: Int?
    let totalSeatNum: Int?
    var id: Int { roomTempId }

    // CodingKeys alias 兜底（真机字段可能不同）
    enum CodingKeys: String, CodingKey {
        case roomTempId, imgUrl, createRoomLevel
        case voiceNum, videoNum, totalSeatNum
        // 已知 alias 候选（真机 log 后按需保留）：
        // case cover = "cover"
        // case level = "level"
    }
}

enum PartyRoomModeType: Int, CaseIterable {
    case liveAndVoice = 2   // Live+Voice tab
    case voiceOnly = 1      // Voice tab
}

// PartyMicApplication.swift（新建）
struct PartyMicApplication: Decodable, Identifiable {
    let userId: String       // String/Int 双兼容 decode（ios-decode-userid-compat rule）
    let nickname: String
    let avatar: String?
    let gender: Int?
    let age: Int?
    let userType: Int?
    let levelName: String?
    let vip: Int?
    let seatType: Int?
    let seatIndex: Int?
    var id: String { userId }

    // CodingKeys alias 兜底（v2 补 —— agent-recon-field-names-unverified rule）
    // 真机 log 后按需保留，起草期先都写候选，decode 时用 (try? c.decode(...)) 兜底：
    // nickname ← nick / userName
    // avatar ← head / userIcon / headImg
    // levelName ← lv / levelStr
    // 房主视角 UI 消费字段（见 §4 A3）：nickname / avatar / gender / age / vip / levelName
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: FlexibleKey.self)
        // userId String/Int 双兼容
        if let s = try? c.decode(String.self, forKey: FlexibleKey(stringValue: "userId")!) {
            self.userId = s
        } else if let n = try? c.decode(Int64.self, forKey: FlexibleKey(stringValue: "userId")!) {
            self.userId = String(n)
        } else {
            throw DecodingError.dataCorruptedError(forKey: FlexibleKey(stringValue: "userId")!, in: c, debugDescription: "userId neither String nor Int64")
        }
        self.nickname = (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "nickname")!))
                     ?? (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "nick")!))
                     ?? (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "userName")!))
                     ?? ""
        self.avatar = (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "avatar")!))
                   ?? (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "head")!))
                   ?? (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "userIcon")!))
        // 其余 optional 字段照常
        self.gender = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "gender")!)
        self.age = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "age")!)
        self.userType = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "userType")!)
        self.levelName = (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "levelName")!))
                      ?? (try? c.decode(String.self, forKey: FlexibleKey(stringValue: "lv")!))
        self.vip = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "vip")!)
        self.seatType = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "seatType")!)
        self.seatIndex = try? c.decode(Int.self, forKey: FlexibleKey(stringValue: "seatIndex")!)
    }
}

struct PartyMyApplyInfo {
    var inIndex: Int = 0     // 当前申请中的 seatIndex；0 = 未申请
    var rejectedAt: Date? = nil  // v2 新增：上次被拒时间；30s 冷却用
}

// Mic Applications 列表状态机（v2 修订 · list-refresh-preserve-items rule）
enum PartyMicApplicationsState {
    case idle
    case loading
    case loaded([PartyMicApplication])
    case refreshing([PartyMicApplication])  // 保留旧 items 视觉
    case empty
    case error(String)
}
```

### PartyStore 新增字段

- `@Published var roomModeTemplates: [PartyRoomModeType: [PartyRoomTemplate]] = [:]`
- `@Published var roomModeTemplatesState: PartyRoomModeTemplatesState = .idle`（含 loading / partialLoaded / error）
- `@Published var micApplicationsState: PartyMicApplicationsState = .idle`（v2 修订）
- `@Published var queueSeatNum: Int = 0`（v2 补 —— 1018 payload num 消费）
- `@Published var micApplicationSwitchOn: Bool = false`（来源：`PartyRoomInfo.onSeatApplySwitch`）
- `@Published var myApplyInfo: PartyMyApplyInfo = .init()`
- `private var pendingApproveSeatIndex: Set<Int> = []`（v2 补 —— 并发 approve 占位集合，非 Published）
- `private var lastRoomTempSwitchAt: Date? = nil`（v2 补 —— IM 1017 乱序判丢时间戳）
- `private var applyingTimeoutTask: Task<Void, Never>? = nil`（v2 补 —— 5min 超时兜底）
- `@AppStorage("party.autoEnterOnApplication") var autoEnterOnApplication: Bool = false`
- `@AppStorage("party.autoEnterOffApplication") var autoEnterOffApplication: Bool = false`

### PartyStore 新增方法

所有 async 方法开头用 `isBusyXxx` flag 幂等（2000ms window）；`isBusyXxx` 是 `private var` 非 Published，`defer` 清零。

- `func loadRoomModeTemplates() async` — 并发拉 type=1/2；已缓存跳过；单 tab 失败走 partialLoaded 态
- `func switchRoomMode(to tempId: Int) async` — `isBusySwitchRoomMode` 幂等；成功仅关弹窗（不刷麦位）+ 打时间戳 + **房主本地立即调 handleRoomModeChanged(tempId)**
- `func handleRoomModeChanged(newTempId: Int, seats: [PartyRoomSeat]?, cause: RoomModeChangeCause)` — 统一处理入口，`cause` = `.local`（房主 API 成功）/ `.remote`（IM 1017）；幂等靠 `PartyRoomInfo.roomTempId == newTempId` 判断
- `func loadMicApplications(reason: LoadReason) async` — `.initial` → `.loading`；`.refresh` → `.refreshing([old])`（保留视觉）；empty 时 `.empty`
- `func applyMic(seatIndex: Int) async` — 检查 `myApplyInfo.rejectedAt` 30s 冷却；未过期 return + toast；成功后启动 5min 超时兜底 Task
- `func cancelMyMicApplication() async`
- `func agreeMicApplication(userId: String, seatIndex: Int?) async` — seatIndex nil 时 store 内挑首空位（排除 `pendingApproveSeatIndex`）；无可用位 → error toast；成功清占位集合
- `func refuseMicApplication(userId: String) async`
- `func toggleMicApplicationSwitch(enable: Bool) async`
- IM handler：`didReceiveModeChange(payload:msgTimestamp:)` / `didReceiveQueueSeatUpdate(payload:)` / `didReceiveMicApplicationSwitch(payload:)`

### PartyAttachType 变更

- 新增 case `.changeMode = 1017` / `.queueSeatUpdate = 1018` / `.micApplicationSwitch = 1021`
- 从 `PartyKnownButUnhandledAttachType.codes` 移除 1017 / 1018 / 1021
- 保留 1020 在 known-but-unhandled（H5 空实现，iOS 同步不消费）

### Sheet Mount Hoist（v2 补 · swiftui-fullscreencover-hoist rule）

所有 Room Mode + Mic Application 相关 modal **hoist 到 PartyRoomView 单一 activeRoomTool enum**，禁止各子 view 各自挂 `.sheet`：

```swift
enum PartyRoomToolSheetKind: String, Identifiable {
    case tools, settings, blocklist
    // v2 新增：
    case roomMode           // 模板 grid + tab
    case roomModeConfirm    // 二次确认（Tools sheet 内嵌，不外层挂 sheet）
    case micApplicationList // 申请列表
    case micApplicationSwitchConfirm  // 首次开关协议确认
}
```

Sheet 切换用 `activeRoomTool = nil` + 350ms `Task.sleep` 规避 iOS 16 双 sheet race（现有 pattern，见 PartyRoomView.swift:551-555）。

### 状态机（Mic Application 观众端）

```
idle → apply → (server: direct on-seat) → onSeat
             → (server: queued) → applying(inIndex=N)
                                → giveUp → idle
                                → IM 1018 op=2 → onSeat
                                → IM 1018 op=3 → idle + toast + rejectedAt = now
                                → 5min timeout → idle + toast (auto giveUp)
idle → apply (rejectedAt < 30s ago) → toast "wait" + 不发接口
```

## §4 验收清单

### 正向（5 条）

- [ ] A1：房主打开 Tools sheet 点 Room Mode → 底部弹模板 grid（两 tab Live+Voice / Voice）→ 选中新模板 → 弹二次确认 → 点 Switch → 服务端返回 truthy → 弹窗关 + 房主本地立即 handleRoomModeChanged；1017 IM 到达 → 观众端全员看到麦位刷新 + 公屏系统消息（房主端幂等不重复触发）
- [ ] A2：观众点空麦位 + `onSeatApplySwitch=true` + 自己普通用户 → 不发 onSeat 请求，Store 内标 `myApplyInfo.inIndex = 请求的 seatIndex` + 弹排麦确认底部条 → 点"Apply"发 onSeat → 服务端返"已入队"→ myApplyInfo.inIndex 保持（等 IM 1001 or 1018 分流）
- [ ] A3：房主打开 Mic Application 面板 → 拉队列显示申请人列表（头像/nickname/gender/age/vip/levelName 均可见）→ 点"通过"→ 调 agreeSeat（seatIndex 取首空位排除 pendingApproveSeatIndex）→ 1018 op=2 + 1001/1012 到达 → 申请人出队 + 麦位刷新
- [ ] A4：房主首次切换 Mic Application 开关 → 弹协议确认（popupType 1/2）→ 确认后本地 flag 置 true + 调 updateOnSeatEnable → 1021 广播到达 → 所有客户端 `onSeatApplySwitch` 同步 + 公屏落系统消息
- [ ] A5：切模板后本地用户先前在视频位 → 收到 1017 → 触发下麦 hook + 视频停采 + RTC 视频位 disable + 埋点 `party_video_leave reason=modeChange` + `myApplyInfo.inIndex = 0` + `micApplications = []`
- [ ] **A6（v2 新增 · im-payload-real-log-over-code-assumption rule）**：真机跑一次 Room Mode 切换 + 一次观众申请 + 一次房主批准 + 一次房主拒绝，抓 Console log 里 `dataKeys=` 与 spec §1/§2 起草的 `seats / currentSeatIndex / num / operation / userId` 字段名对齐，不对齐则**回来补 CodingKeys alias 或改 handler 字段名**

### 反向（8 条）

- [ ] R1：非房主打开 Tools sheet **无** Room Mode 入口（PartyRoomToolsSheet 已 gated，本 spec 只需保持）
- [ ] R2：模板 `createRoomLevel > 当前用户 level` 且非白名单 → 点击不选中，弹升级引导（`L10n.Party.roomModeUpgradeGuide`）；`state.selectedTempId` 不变
- [ ] R3：Confirm 2000ms 内二次点击不重复请求（isBusy 幂等）
- [ ] R4：切模板 API 失败（网络 / 非 truthy 响应）→ 弹窗保持 + 依赖 APIClient 全局 toast（不本地 toast，避免双弹）
- [ ] R5：IM 1017 payload gzip 解压失败 → fallback `reloadSeatListFromServer()`；不 crash 不吞错
- [ ] **R6（v2 新增）**：房主快速点两不同申请者「通过」→ 第一次占位 seatIndex=1 后 pendingApproveSeatIndex={1}，第二次挑首空位排除 {1} → seatIndex=2；若两次并发都取 1 走服务端返错分支 → toast "Seat already taken"
- [ ] **R7（v2 新增）**：全麦位满时 agreeMicApplication → 无可用空位 → toast "No available seat, please wait for someone to leave"，不调 agreeSeat
- [ ] **R8（v2 新增）**：观众被拒（IM 1018 op=3）→ `rejectedAt = now`；30s 内 tap 空麦位 → toast "Please try again later"，不发 onSeat
- [ ] **R9（v2 新增）**：观众 `myApplyInfo.inIndex > 0` 持续 5min 无 IM 到达 → 本地自动 giveUp + toast "Application timed out"（防房主离线永久卡态）
- [ ] **R10（v2 新增）**：IM 1017 `msgTimestamp < lastRoomTempSwitchAt - 3s` → 直接丢弃（旧 1001/1012 排队错到）；本地不重复触发下麦
- [ ] R11（v2 新增）：Mic Application 面板 refresh → `state = .refreshing([old])` 保留旧 items 视觉 + `.refreshable` closure `await` 到任务完成（不闪烁）

## §5 待问用户

1. **切模板后 seatIndex 选择策略**：内圈默认"取第一个空位（排除 pendingApproveSeatIndex）"够用吗？还是本 spec 必须落"seat-roster-popup 选位 UI"？
2. **首次协议确认弹窗**：iOS 是否复用现有 `PartyRoomSettingsView` 系列样式，还是独立 alert-style？H5 是全屏底部弹层（title + body + 2 按钮）
3. **`agreeSeat` operatorType** 除了 1 还有别的值吗？H5 源码只见 operatorType=1（房主同意）；房管同意是否用别值需真机验证 → 本 spec 内圈硬编 1 + 中圈房管路径 TODO
4. **1017/1018/1021 payload 字段命名**：`seats / num / operation / userId / enable` 是 H5 store 层解构变量名，后端真实字段名需真机 log 抓一次 —— 已列入 A6 验收 checklist
5. **模板列表 grid 换行策略**：H5 是 `flex-wrap` 每卡 w-172 h-156；iOS 用 LazyVGrid 2 列还是 flex-wrap 自适应？（B 档不强制视觉像素还原，走 iOS 原生 2 列足够）
6. **applying 5min 超时时长**：H5 未见该兜底逻辑（H5 靠 UI 常驻手动 giveUp），iOS 5min 是我拍脑袋的兜底；用户接受还是要缩短/延长？

## §6 v2 修订 changelog

| # | red team finding | 严重度 | v2 落地位置 |
|---|---|---|---|
| 1 | 并发 approve 冲突（seatIndex 双取首空位）| P0 | §2 房主端 pendingApproveSeatIndex + §3 store 字段 + R6 |
| 2 | IM 1017 乱序旧 1001/1012 覆盖 | P0 | §0 二次校验 + §1 IM 1017 步骤 1 判丢 + §3 lastRoomTempSwitchAt + R10 |
| 3 | 房主自己 1017 云信回执未验证 | P0 | §1 切模板房主本地兜底 + §3 handleRoomModeChanged(cause:) + A1 |
| 4 | queueSeatNum 消费无定义 | P0 | §3 @Published queueSeatNum |
| 5 | agreeSeat 全麦位满无 fallback | P0 | §2 房主端 fallback + R7 |
| 6 | 观众 onSeat 分流字段未定 | P0 | §0 二次校验 + §2 观众端分流 IM 1001 vs 1018 op=1 |
| 7 | Mic 面板 refresh 未套 rule | P1 | §2 房主端 loading/refreshing/empty/error 状态机 + §3 PartyMicApplicationsState + R11 |
| 8 | PartyMicApplication CodingKeys 缺 alias | P1 | §3 model 补 alias init 兜底 |
| 9 | IM 真机 log 验证未列 checklist | P1 | A6 验收新增 |
| 10 | 多 modal 未 hoist | P1 | §3 Sheet Mount Hoist 段 |
| 11 | Room Mode 模板 loading/error UI 未列 | P1 | §1 UI 态 partialLoaded + §3 roomModeTemplatesState |
| 12 | Mic Application empty/loading/error 未列 | P1 | §2 房主端列表状态机 + §3 PartyMicApplicationsState |
| 13 | throttle 落地缺失 | P1 | §3 store 新增方法段说明"所有方法 isBusy 幂等" |
| 14 | gender/age/vip/levelName 未消费展示 | P1 | A3 明示 UI 消费字段 |
| 15 | 房管 operatorType 未消费 | P1 | §2 明示硬编 1 + 中圈 TODO |
| 16 | 观众拒后无冷却 | P1 | §2 观众端 rejectedAt + R8 |
| 17 | 1017 seatOperate 自他人分支 | P1 | §1 IM 1017 步骤 4 自身分支处理 |
| 18 | 房主离线 applying 无兜底 | P1 | §2 观众端 5min timeout + §3 applyingTimeoutTask + R9 |
