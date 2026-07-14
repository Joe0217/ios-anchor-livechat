# E - Party Lock Room spec (v1)

## §0 范围三圈 + H5 二次校验

**范围（B 档）**：房主 tools sheet "Lock Room" 项从 stub 接真流程 —— 加锁（4 位数字密码）/ 解锁（无二次确认）。观众端进锁房复用现有 `enterRoom(password:)`（已就绪，本 spec 不改）。

**三圈占位判定**：
- API endpoint 1 个（apiPartylockRoom）+ 状态机 ≤5 态 + 0 SDK 变更 + 单一 owner-only 入口 → **B 档**
- 依赖模块已就绪（PartyRoomInfo.lockFlag/needPassword 已 decode、PartyRoomToolsSheet 已占位、L10n.Party.toolLockRoom 已就位）→ 直接做，无占位

**H5 二次校验（关键约束）**：
- 蓝本 `livechat-h5/src/views/party/components/room-password.vue` + `room-mana-popup.vue` + `usePartyHooks.js:1225-1229`
- **密码固定 4 位纯数字**（`van-password-input length=4` + `van-number-keyboard`）
- **加锁/解锁不同 flow**：已锁时 tap → **直接调解锁 API 不弹弹窗**；未锁时 tap → 弹密码框输入
- **无"改密码"独立入口**：改密码 = 解锁 + 重设
- **无 IM 广播**：加锁瞬间已在房观众不 kick；跨端一致靠 `apiGetPartyRoomEnter` HTTP 拦截返 `10006` 触发密码弹窗
- **API 字段名 `lockRoomFlag`（不是 lockFlag）**：iOS model 别混
- **本地乐观更新**：接口 truthy 即成功，前端手动 `roomInfo.lockFlag = flag`

## §1 业务契约 — API

**唯一接口**（真机验证 path / method / 加解密 envelope）：
```
POST /sapi/weidou/v1/client/party/room/lockRoom
```

**加锁 payload**：
```json
{ "roomId": <Int64>, "password": "1234", "lockRoomFlag": 1 }
```

**解锁 payload**：
```json
{ "roomId": <Int64>, "lockRoomFlag": 0 }
```
`password` 字段省略（H5 `feachLockRoom({ lockFlag: 0 })` 未传）。

**Response**：truthy 即成功；后端不返 lockFlag，客户端本地乐观更新。**真机首次调用抓 log 确认 envelope 结构 + `code=='0000'` 判定**（对齐 `agent-recon-field-names-unverified` rule）。

**错误码**：跟随通用 error handler；`code != '0000'` → toast + 保持 sheet 打开（不 dismiss，让用户可重试）。

## §2 IM 广播

**无独立 IM attachType**。

跨端一致性完全靠：
1. 加锁后本地 `roomInfo.lockFlag = 1` + toast，**已在房观众不 kick**（对齐 H5）
2. 新进房观众走 `enterRoom(password:)` 已有路径，服务端返 `10006` 触发密码 sheet（该路径 iOS 已就绪，本 spec 不改）
3. 房间列表 badge：下次 refresh 拉最新 `lockFlag` 自然刷新（`PartyRoomListView.swift:187-189` 已渲染锁 icon）

若真机验证发现服务端**其实**下发了 attachType（H5 未订阅不代表不发）→ 补 IM handler 到 `PartyMsgAttachType` + `PartyStore` 消费（按 `im-payload-real-log-over-code-assumption` rule 追真机 log）。**当前假设无广播**。

## §3 iOS 模型 + 状态机

### 3.1 model 扩展
`PartyRoomInfo.withUpdated(...)`（Sources/Party/Models/PartyRoomInfo.swift:45）扩参：
- `lockFlag: Int?` 
- `needPassword: Bool?`

用于本地乐观更新回写。

### 3.2 PartyStore 新增
```swift
// Sources/Party/PartyStore.swift
@Published private(set) var isBusyLockRoom: Bool = false

@MainActor
func lockRoom(password: String) async {
    guard !isBusyLockRoom, let roomId = roomInfo?.id else { return }
    guard password.count == 4, password.allSatisfy(\.isNumber) else { return }  // 前端拦截
    isBusyLockRoom = true
    defer { isBusyLockRoom = false }
    do {
        try await PartyAPI.lockRoom(roomId: roomId, password: password)
        roomInfo = roomInfo?.withUpdated(lockFlag: 1)  // 乐观更新
        // toast: L10n.Party.roomLocked
    } catch {
        // toast: error.localizedDescription
    }
}

@MainActor
func unlockRoom() async {
    guard !isBusyLockRoom, let roomId = roomInfo?.id else { return }
    isBusyLockRoom = true
    defer { isBusyLockRoom = false }
    do {
        try await PartyAPI.unlockRoom(roomId: roomId)
        roomInfo = roomInfo?.withUpdated(lockFlag: 0)
        // toast: L10n.Party.roomUnlocked
    } catch { /* toast */ }
}
```

### 3.3 PartyAPI 新增（Sources/Party/Network/PartyAPI.swift）
```swift
static func lockRoom(roomId: Int64, password: String) async throws
static func unlockRoom(roomId: Int64) async throws
```
两者拼同一 endpoint，仅 payload 差异（对齐 H5 `apiPartylockRoom` 单接口双语义）。

### 3.4 状态机（tap Lock Room 分流）
```
tap Lock Room
  ├─ roomInfo.lockFlag == 1 → PartyStore.unlockRoom() 直接调（无弹窗）
  └─ roomInfo.lockFlag == 0/nil → 弹 PartyLockRoomPasswordSheet
                                      ├─ 输 4 位 → PartyStore.lockRoom(password:)
                                      └─ 取消 → dismiss
```

### 3.5 UI 接线（PartyRoomToolsSheet.swift:49-53）
- 新增 callback `onTapLockRoom: () -> Void`（替换 `onTapStub`）
- 调用方 `PartyRoomView` 承接：owner 分流 lock/unlock，未锁弹 sheet
- 新组件 `PartyLockRoomPasswordSheet`（4 位数字键盘 + PIN 圆点，参考 iOS 系统数字锁样式；无 SF Symbol 依赖，`presentationDetents([.medium])`）

### 3.6 Tools sheet enum
`PartyRoomToolSheetKind` **不加** case —— lock 走"直接 API"或"独立密码 sheet"路径，与 Room Mode 双 case 模式不同。密码 sheet 由 PartyRoomView 用独立 `@State var showLockPasswordSheet: Bool` 管理，避免复用 tools hoist 状态污染。

## §4 验收清单

### 正向（F）
- **F1** 房主未锁态 tap Lock Room → 弹密码 sheet → 输 4 位数字 → API 成功 → sheet dismiss + toast "Room locked" + tools sheet 里 Lock Room icon 切 ON
- **F2** 房主已锁态 tap Lock Room → **不弹弹窗** → 直接调 unlockRoom → toast "Room unlocked" + icon 切 OFF
- **F3** 加锁瞬间已在房观众**不被 kick**（无本地/远端 leave 行为）
- **F4** 新进房观众走 `enterRoom(password:)` 现有路径不受本 spec 改动影响（回归验证）
- **F5** 房间列表下次 refresh 后 lockFlag=1 房间显示锁 icon（已有渲染，验证乐观更新后 refresh 一致）

### 反向（R）
- **R1** 密码 <4 位或含非数字 → 前端拦截**不发 API**（`password.count == 4 && allSatisfy(\.isNumber)` guard），Save 按钮 disable
- **R2** API 失败（网络 / code != '0000'）→ sheet 保持打开 + toast 显示错误 + lockFlag 不改
- **R3** isBusyLockRoom 幂等：连点 Save / Lock Room icon 只走一次 API（button `.disabled(store.isBusyLockRoom)`）
- **R4** 解锁 API 失败 → lockFlag 保持 1，toast 提示，用户可重试
- **R5** 密码 sheet dismiss（取消）→ 不调 API + 不改 lockFlag

## §5 待问用户

1. **改密码 UX**：H5 无独立改密码入口（解锁+重设 two-step）。iOS 是否对齐 H5？还是 F2 已锁态 tap → 弹"当前密码 / 解锁 / 修改"三选一 action sheet？**建议按 H5，无改密码**（B 档极简；未来 F 里程碑派对房完整玩法可再评估）
2. **密码持久化**：H5 房主设完**无查看当前密码入口**；iOS 是否保留（简单粗暴对齐 H5）？还是本地 Keychain 存房主自己房的密码供再次查看？**建议对齐 H5 不存**
3. **API path 未真机验证**：`/sapi/weidou/v1/client/party/room/lockRoom` 是 H5 字面（`src/api/party/index.ts:177`），iOS 首次接入必须真机 log 确认（对齐 `api-http-method-strict` rule）—— impl 期第一次调用前预留 15 分钟真机抓包环节
