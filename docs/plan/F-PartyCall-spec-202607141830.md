# F-PartyCall 派对房私 call · 规范文档 v2

> 里程碑 F · 派对房完整玩法 · 私 call 抢占子项  
> v1 · 2026-07-14 18:30 起草  
> **v2 · 2026-07-14 19:30 · 整合红队 30 条意见（4 P0 + 12 P1 + 10 P2 + 4 P3）+ 用户 D-1/D-2/P0-2/P1-7 决策**  
> 蓝本：安卓源码梳理（[F-PartyCall-安卓源码梳理-*.md](F-PartyCall-安卓源码梳理-*.md)）+ 后端接口契约

---

## §0 H5 / 安卓代码二次校验

**结论**：本子项**唯一蓝本 = 安卓源码 + 后端接口契约**。H5 侧无交叉验证源。

### §0.1 H5 侧扫描结果

| 目标 | 命令 | 结果 |
|---|---|---|
| H5 `src/views/party/*` | `ls anchor-livechat-h5/src/views/ \| grep party` | ❌ 不存在 |
| H5 `src/api/` party 相关 | `grep -rln "partyPrivateCall\|updatePartyPrivateCall\|getPartyCallGiftList\|callerType" src/` | ❌ 零命中 |
| H5 `src/api/call/index.ts` queryCall | `grep queryCall` | ❌ 无（仅 createCall/joinCall/beginCallV2/callOver/missCall/callDeductionFee） |
| H5 `src/sapi/` party 相关 | `grep -rln party src/sapi/` | ❌ 零命中 |

派对房与 PartyCall 都是 H5 完全没有的模块（对齐 CLAUDE.md 铁律"派对房 H5 无代码"）。spec 全部行为、接口、字段以**安卓源码 + 后端接口**为唯一权威源。

### §0.2 蓝本文档信源

[F-PartyCall-安卓源码梳理-*.md](F-PartyCall-安卓源码梳理-*.md) 用户交付 · 398 行 · 含 8 大部分 + 附录 API 清单 + 时序图。本 spec §3-§7 全部字段/接口/时序**直接引用**梳理文档 file:line，不重述。

### §0.3 iOS 侧现状 preflight

**preflight 权威源**：本 spec v2 版内嵌关键决策及 iOS 侧现状；外部实施蓝图曾在 `~/.claude/plans/` 但为会话级临时文件，v2 起不再引用避免文件消失风险。

- ✅ 基础设施完备：`CallStore` / `CallSignaling` / `PartyRTCEngine` (§9 frameSnapshot) / `PartyAPI` (sapi 前缀) / `downSeat` + `updateMedia` / `NIMService` + `PartyMessageRouter`
- ⚠️ S 级扩展：`CallFrontGameType` +party / `AttachType` +1029 / `CallStore` 分派点 / `PartyStore` observer / `PartyAPI` +2 endpoint / `CallService.queryCall`
- ❌ M 级新写：`PartyStore.pauseForCall / resumeParty` / `PartyPrivateCallSettingSheet` / 1029 payload model / **CallStore observer 从单槽 refactor 为多观察者数组（P0-2 决策）**

### §0.4 E→F 项目铁律变更清单（关键 · 阻止 impl 期意外阻断）

E 期在 [`Sources/Party/PartyStore.swift:14`](../../Sources/Party/PartyStore.swift) 明示铁律：
> **禁止字段**：`weak var liveStore` / `weak var callStore`（spec §1.0.3 验证；E 期完全不与 B/C/D 耦合）

**F 期需推翻的部分**：
- ✅ **允许** `PartyStore` 引用 `CallStore`（通过多观察者数组 attach/detach，非直接 weak var 字段）
- ✅ **允许** `PartyStore` conform `CallStoreObserver` 协议
- ❌ **保留** 禁止直接 `weak var liveStore` 字段（不与直播互相引用）

Impl 时同步修订：
- [ ] `Sources/Party/PartyStore.swift:14` 类注释加 "F 期允许通过 CallStore.attach 观察通话事件"
- [ ] `E-里程碑实施计划-202606231600.md` §1.0.3 若明示禁令 → 加 "F 期修订" 注

---

## §1 业务概念词表

以下概念只锁业务语义，不锁具体 Swift protocol / class 名。

| 概念 | 业务定义 | 梳理引用 |
|---|---|---|
| **派对房私 call** | 用户端向房内主播发起 1v1 视频通话；后端标记 `callerType==5` | §1 |
| **私 call 开关** | 房间维度开关，房主可开关本房间接受 PartyCall；关闭时后端拦截 | §3 |
| **私 call 礼物** | 房主选定的通话专属礼物，用户端拨打时预扣 | §3.2 |
| **来电抢占** | 主播端收 `callerType==5` → 挂起派对房 → 跳 1v1 → 结束回派对房 | §1/§4/§5 |
| **通话状态通知（1029）** | NIM 聊天室 attachType=1029，房内广播私 call 生命周期 | §2 |
| **派对房挂起** | 派对房状态机中间态：RTC 已离房但 roomInfo/seatList/chat login 保留 | §5.2 |
| **派对房恢复** | 通话结束后重新 join RTC + 刷新麦位面板（**麦位不自动恢复**） | §5 |
| **前置守卫** | 三层：`CallStore.state == .idle` · `appForeground` · `partyPrivateCallOpen==1` | §4.2/§8.1 |

---

## §2 业务契约

### §2.1 三大 flow

#### Flow A: 房主设置私 call（开关 + 选礼物）

```
房主 → PartyRoomToolsSheet → 点"私 call"入口（enum-driven，见 §5.3）
     → PartyPrivateCallSettingSheet 打开
     → 展示当前 partyPrivateCallOpen + partyCallGiftId
     → 房主切开关：立即调 updatePartyPrivateCall(roomId, enable, giftId) · optimistic UI
        · 成功 → toast · 关闭 sheet
        · 失败 → 恢复原状态 + banner 错误
     → 房主换礼物：加载 getPartyCallGiftList(scene=2) → grid → 选中同接口保存
```

权限：仅**房主**（`selfRole == .owner`）可打开设置 sheet。

#### Flow B: 主播端接来电（PartyCall 抢占）—— 核心流程

**CallStore.handleIncomingVideoCall 精确分派顺序**（P1-5 补齐）：

```pseudo
handleIncomingVideoCall(msg):
    if liveStore.state == .living:
        // 直播分支（已有）
        走 live 分支
    else if pkStore.state != .idle:
        // PK 中直接 reject（已有）
        走 PK guard
    else if partyStore.roomState == .joined:
        // 派对房分支（F 新增）
        if !appForeground: reject
        if !partyStore.partyPrivateCallOpen: reject  // §2.3 局部拦截（P1-9 决策：对齐 LiveStore 显式 guard）
        queryCall(fromUserId, channelId) 
            超时/失败 → reject（P2-19 保守策略）
            callerType == 5 → 进 partyStore.pauseForCall(msg)
            callerType != 5 → reject reason="party room reject non-party call"（P1-7 决策：对齐安卓+直播）
    else if state == .idle:
        // 未在任何场景（默认 direct 1v1）
        走 idle guard + direct 分支
    else:
        // 已在 direct 通话中或 match 中
        busy reject
```

**pauseForCall 时序**（无 5s delay · D-1 决策）：

```
时刻 T0: pauseForCall(msg) 触发
时刻 T0+Δ1: 前置守卫
        · guard roomState == .joined
        · guard PartyBattleController.state == .idle（F 期 PartyBattle 接入时激活；本 spec 预留 nil-check）
时刻 T0+Δ2: 若在麦位上：updateMedia(type=3, enable=false) + downSeat（都可 fire-and-forget，不阻塞）
时刻 T0+Δ3: disableLocalVideoCapture()（内部串行：BeautyPipelineSharer detach → cm.unsubscribe → cm.tearDown → camera=nil · P1-16 对齐真实内部顺序）
时刻 T0+Δ4: try? await Task.sleep(nanoseconds: 200_000_000) 
        // 200ms 让 AVCaptureSession 硬件层完全释放前置摄像头（P1-8：Task.yield 不够）
时刻 T0+Δ5: await rtc.leave() await didLeaveChannelWith
时刻 T0+Δ6: await CallStore.shared.acceptIncomingFromParty(msg) 
        · 内部 CallView.fallback.camera start · CallView zIndex=100 overlay 显示
时刻 T0+Δ7: 派对房进入"suspended for call"派生状态（isSuspendedForCall==true）
        · roomInfo / seatList / chat login 保留
```

#### Flow C: 通话结束回派对房

```
时刻 T1: 通话结束（正常/被拒/超时/弱网 forceEnd）→ CallStore.state 转 .ended → .idle
时刻 T1+Δ1: CallStore 遍历 observers 数组 → 调 PartyStore.onCallEnded
时刻 T1+Δ2: PartyStore.resumeParty()
        A. guard roomState == .joined（防中途被踢/解散）
        B. rtc.join(channelId, token, uid) 重入 · 内部 setChannelProfile(.liveBroadcasting)
           失败 → refreshRtcToken → 重试 1 次（P2-18）
           仍失败 → forceLeaveRoom(.networkLost) + banner
        C. 若视频位可用：重 setup camera + 美颜（FURenderKit 单例复用 · D-2 不 release）
        D. postMikeList(seatList) 刷新麦位面板
        E. 麦位不自动恢复，主播需手动上麦
时刻 T1+Δ+error: 通话中派对房被踢/解散
        · roomState → .ended · onCallEnded 触发时 §B 短路 · 不 rejoin
```

### §2.2 iOS vs 安卓关键行为差异（已知产品差异）

| 项 | 安卓 | iOS | 决策 |
|---|---|---|---|
| 5s delay | delay 5000ms 再 downSeat + leave + joinCall | **无 delay 立即接听**（对齐 LiveStore.pauseForCall） | D-1 |
| FURenderKit release | 每场景切换 release | **不 release**，沿用 FUManager 懒模式 | D-2 |
| 无 UI 打扰 | 5s 内无浮层 | 立即 CallView calling 浮层 | D-1 |
| 非派对来电 | callerType!=5 → reject | 对齐安卓 → reject | P1-7 |

### §2.3 私 call 开关拦截（P1-9 契约调整）

**决策**：对齐 LiveStore 模式 —— iOS **加显式 guard** `guard partyStore.partyPrivateCallOpen`（Sources/Call/CallStore.swift 派对分支内）。

**理由**：
- 后端 partyPrivateCallOpen=0 时拦截是主拦截；iOS 加本地二次校验防"前端 UI stale / 后端广播漂移"边界
- 项目内一致性：LiveStore.privateCallOpen 有本地 guard（[CallStore.swift:1143](../../Sources/Call/CallStore.swift#L1143)）

**默认值**（P1-12 修订）：新建房间 `partyPrivateCallOpen` 默认值 **待 Step 1c 真机首拉 room enter 响应校验**（可能是 0 关闭 or 1 开启，未在安卓源码梳理明示）。iOS 侧 model `partyPrivateCallOpen: Int?` nil → 视为 0（保守）。

---

## §3 状态机

### §3.1 PartyStore 派生状态（不新增 enum case）

现有 `PartyRoomState`：`idle → preparing → entering → joined → leaving → ended`。

派生属性：
```swift
var isSuspendedForCall: Bool {
    roomState == .joined && CallStore.shared.state != .idle
}
```

### §3.2 PartyStore × CallStore 双状态机联动

```mermaid
stateDiagram-v2
    [*] --> Party_Idle
    Party_Idle --> Party_Joined: enter room OK
    Party_Idle -->|❌ non-.joined pauseForCall guard reject| Party_Idle
    Party_Joined --> Party_Joined_CallCalling: pauseForCall (callerType==5 + partyPrivateCallOpen==1)
    Party_Joined_CallCalling --> Party_Joined_CallConnected: CallStore.state=.connected
    Party_Joined_CallConnected --> Party_Joined_CallEnded: hangup / peer hangup / network fail
    Party_Joined_CallEnded --> Party_Joined: resumeParty (rtc.join 成功)
    Party_Joined_CallEnded --> Party_Idle: room 已被踢/解散 (roomState != .joined 短路)
    Party_Joined -->|❌ pauseForCall 重入 CallStore.state != .idle guard reject| Party_Joined
    Party_Joined --> Party_Leaving: user leave
    Party_Leaving --> Party_Idle
```

### §3.3 非法迁移防御表（P1-15 完整化）

| 非法迁移 | 触发场景 | 防御位置 |
|---|---|---|
| `Party_Idle → pauseForCall` | 用户在派对房外收到 PartyCall（走 direct 分支）| CallStore.handleIncomingVideoCall §2.1 pseudo · 派对分支只在 `roomState==.joined` 触发 |
| `Party_Joined_CallCalling → pauseForCall`（重入） | 通话中又来第二个 VideoCall | handleIncomingVideoCall `state == .idle` guard 短路 |
| `resumeParty` 失败无退路 | rtc.join 网络异常 | refreshRtcToken + 重试 1 次 · 仍失败 `forceLeaveRoom(.networkLost)` |

### §3.4 CallStoreObserver 多观察者数组（P0-2 决策 · 关键架构变更）

**问题**：现有 `CallStore.observer: CallStoreObserver?` 是**单 weak 槽**，已被 LiveRoomView.onAppear 独占（Sources/Live/LiveRoomView.swift:616）。F 期 PartyStore 也要 observe → 会踩踏。

**决策方案**：refactor CallStore 为多观察者数组。

```swift
// Sources/Call/CallStore.swift 修订
final class CallStore: ObservableObject {
    // ❌ 删除 
    // weak var observer: CallStoreObserver?
    
    // ✅ 新增
    private let observers = NSHashTable<AnyObject>.weakObjects()
    
    func attach(_ observer: CallStoreObserver) {
        observers.add(observer as AnyObject)
    }
    
    func detach(_ observer: CallStoreObserver) {
        observers.remove(observer as AnyObject)
    }
    
    private func notifyObservers(_ block: (CallStoreObserver) -> Void) {
        observers.allObjects.compactMap { $0 as? CallStoreObserver }.forEach(block)
    }
    
    // 内部所有 self.observer?.xxx 调用改为 notifyObservers { $0.xxx }
}
```

**调用侧同步修订**：
- `Sources/Live/LiveRoomView.swift:616` `CallStore.shared.observer = store` → `CallStore.shared.attach(store)` + `onDisappear { CallStore.shared.detach(store) }`
- `Sources/Party/UI/PartyRoomView.swift` `.onAppear { CallStore.shared.attach(store) }` + `.onDisappear { CallStore.shared.detach(store) }`

**契约**：
- attach 幂等（NSHashTable 内含即忽略）
- detach 幂等（不存在时 no-op）
- weak：view dismiss 后自动 nil，无需手动清理（但显式 detach 是好习惯）
- 通知顺序不保证（观察者不能相互依赖顺序）

**回归验证**（关联 P2-25）：
- 直播 → 派对房 → 退派对房 → 直播私 call → 15s 倒计时正常触发（多次 attach/detach 不干扰）
- 直播私 call 15s 倒计时链路 unchanged

---

## §4 Model + API 契约

### §4.1 Enum 扩展

| Enum | 位置 | 新增 |
|---|---|---|
| `CallFrontGameType` | Sources/Call/CallConstants.swift:91 | `case party = 5` |
| `AttachType` | Sources/Live/NIM/AttachType.swift:27 | `case partyPrivateCallNotify`（`decodeInt` line:254 `case 1029: return .partyPrivateCallNotify`）|
| `PartyAttachType` | Sources/Party/Models/PartyAttachType.swift:13 | `case partyPrivateCallNotify = 1029`（同时从 `PartyKnownButUnhandledAttachType.codes` **line:82 内**移出 `1029`，保留 `45` · P2-24 精确化）|

### §4.2 Model 新增

#### `PartyPrivateCallNotify`（1029 payload · 含 status 双重定义防御 · P0-4）

位置：`Sources/Party/Models/PartyPrivateCallNotify.swift`

```swift
struct PartyPrivateCallNotify: Decodable {
    enum Status: String, Decodable {
        case calling = "calling"
        case ended = "ended"
    }
    
    let userId: String            // 主播 userId · String/Int 双兼容
    let nickname: String?
    let seatIndex: Int?
    let status: Status            // ⚠️ 双重定义防御：status 必须能 decode 成 enum 才 accept
    let callerUserId: String?
    let callerNickname: String?
    let callerSeatIndex: Int?
    let partyCallOpen: Int?       // 0/1
    
    init(from decoder: Decoder) throws {
        // 硬要求：status 字段必须存在且值 ∈ {calling, ended}，否则 throw
        // 这样 1029 若为 GIFT_DOUBLED 语义（无 status 字段）decode 自然失败 → PartyMessageRouter drop
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // ...userId/callerUserId 走 String/Int 双兼容（.claude/rules/ios-decode-userid-compat.md）
        status = try c.decode(Status.self, forKey: .status)  // 缺失/非法 → throw
        // ...其余字段 optional decode
    }
}
```

**Router 分派守卫**（Sources/Party/NIM/PartyMessageRouter.swift）：
```swift
case .partyPrivateCallNotify:
    guard let notify = try? PartyPrivateCallNotify(from: decoder) else {
        AppLogger.debug("1029 payload decode failed; likely GIFT_DOUBLED semantic or unknown, dropping")
        return true  // consumed（drop）
    }
    delegate?.partyRoomChat(chat, didReceivePartyCallNotify: notify, raw: message)
    return true
```

**真机验证承诺**（[im-payload-real-log-over-code-assumption](.claude/rules/im-payload-real-log-over-code-assumption.md)）：Step 3 首次真机收 1029 → 抓 `dataKeys=` log → 校验字段。

#### `PartyRoomInfo` 字段扩展

位置：Sources/Party/Models/PartyRoomInfo.swift

```swift
let partyPrivateCallOpen: Int?    // 0/1 · 后端 enter/getRoomInfo 响应 · 默认 nil→0（保守）
let partyCallGiftId: String?      // 当前设置的私 call 礼物 id
```

派生：
```swift
extension PartyRoomInfo {
    var isPartyPrivateCallEnabled: Bool { partyPrivateCallOpen == 1 }
}
```

#### `PartyCallGiftItem`（礼物列表项 · 字段真机校准 · P1-13）

位置：Sources/Party/Models/PartyCallGiftItem.swift

**⚠️ Step 1a 起草前置门**（P1-13）：先真机 curl 一次 `getPartyCallGiftList(scene=2)` 抓 log → 按响应字段起草 model。以下为**预估字段**，v3 校准：

```swift
struct PartyCallGiftItem: Decodable {
    let giftId: String
    let giftName: String?
    let giftIcon: String?         // 大图
    let smallImg: String?         // 缩略图
    let giftPrice: Int?
}
```

#### `QueryCallResponse`（queryCall 响应 · 字段真机校准 · P1-13）

位置：Sources/Call/CallModels.swift 追加

**⚠️ Step 1a 起草前置门**（P1-13）：真机 curl 一次 `/api/call/record/v2/queryCall` 抓 log → 按响应字段起草 model。以下为**预估字段**，v3 校准：

```swift
struct QueryCallResponse: Decodable {
    let callerType: Int?
    let fromUserId: String?       // String/Int 双兼容
    let channelId: String?
    // 其他字段等真机 log
}
```

### §4.3 API 新增

#### `PartyAPI.updatePartyPrivateCall(roomId:enable:giftId:)`

```
POST /sapi/weidou/v1/client/party/room/updatePartyPrivateCall
Body: { roomId: String, enable: Int(0/1), giftId: String? }
Resp: HttpResult<Any?>
认证：PartyAPIClient 自动处理 sapi 加密 + auth_token
```

#### `PartyAPI.getPartyCallGiftList(scene:)`

```
POST /sapi/weidou/v1/client/party/room/getPartyCallGiftList
Body: { scene: Int } · 本 spec 仅用 scene=2（设置弹窗）
Resp: HttpResult<[PartyCallGiftItem]>
```

#### `CallService.queryCall(fromUserId:channelId:)`

```
POST /api/call/record/v2/queryCall
Body: { fromUserId: String, channelId: String }
Resp: HttpResult<QueryCallResponse>
超时：6s（P2-19 决策：超时视为 non-PartyCall，一律 reject 保守）
```

### §4.4 Path 追踪结论

| API | 唯一信源 | H5 侧 | 契约风险 |
|---|---|---|---|
| updatePartyPrivateCall | 安卓 `HttpHelper.kt:1039` + 后端 | ❌ 无 | 中 · Step 1c 真机校验 |
| getPartyCallGiftList | 安卓 `ApiService.kt` | ❌ 无 | 中 · scene 语义需真机 |
| queryCall | 安卓 `PartyRoomDataManager.kt:654-688` | ❌ 无 | 中 · response 结构真机校准 |

---

## §5 UI 层

### §5.1 PartyPrivateCallSettingSheet（复用 CommonGiftPanelConfig · P1-10 修订）

位置：`Sources/Party/Settings/PartyPrivateCallSettingSheet.swift`（新建）

**礼物区不再私造 grid**，复用 [`CommonGiftPanelConfig`](../../Sources/Gift/Panel/Config.swift)（工程内已有 gift panel 通用组件，直播私 call 门槛用的 `.callGate` factory 是同款场景）：

```swift
struct PartyPrivateCallSettingSheet: View {
    @StateObject var store = PartyPrivateCallSettingStore()
    
    var body: some View {
        VStack {
            // 顶部 title bar
            // Toggle "允许接受来电" bound to store.isEnabledBinding (Bool 派生 · P2-17)
            if store.isEnabled {
                CommonGiftPanel(
                    config: CommonGiftPanelConfig.partyCallSetting(
                        dataSource: store.giftDataSource,  // 内部拉 getPartyCallGiftList(scene=2)
                        initialSelection: store.currentGiftId,
                        onConfirm: { giftId in
                            store.saveGift(giftId)
                        }
                    )
                )
            }
            // Loading / error 用 async-state-fallback rule
        }
    }
}
```

`PartyPrivateCallSettingStore`（新建）：
- `@Published var isEnabled: Bool` (派生自 partyPrivateCallOpen==1)
- `func toggleEnabled()`: 立即调 updatePartyPrivateCall(enable) · optimistic UI + 失败回滚
- `func saveGift(_ giftId: String)`: updatePartyPrivateCall(enable=1, giftId)
- `giftDataSource: PartyCallGiftDataSource`(scene=2 · 注入 CommonGiftPanel)

**遵守 rules**：
- [swiftui-button-plain-hitarea](.claude/rules/swiftui-button-plain-hitarea.md)
- [sf-symbol-usage-preflight](.claude/rules/sf-symbol-usage-preflight.md)
- [toast-vs-banner-consistency](.claude/rules/toast-vs-banner-consistency.md)
- [cross-scene-component-reuse-preflight](.claude/rules/cross-scene-component-reuse-preflight.md) — Step 1c preflight CommonGiftPanelConfig 是否自持相机/store（预估无）

### §5.2 派对房挂起期 UI + CallView 层级验证（P2-20）

**决策**：不加任何独立 UI。CallView 由 RootView 挂载 zIndex=100 overlay。

**✅ P2-20 verified**（Step 1a preflight 完成）：`PartyRoomView` 在 `PartyTabRootView.swift:71` 通过 `NavigationStack + .navigationDestination(for: PartyRoute.self)` **push** 挂载。RootView 的 CallView zIndex=100 天然在其上层，无需额外 hoist。

### §5.3 PartyRoomToolsSheet 入口（enum-driven · P1-11 修订）

位置：`Sources/Party/UI/Components/PartyRoomToolsSheet.swift`

**新增 case**：
```swift
enum PartyRoomToolSheetKind {
    case settings
    case lockRoom
    case mcSeat
    case privateCall  // F 新增
}
```

Sheet 内加入口 icon（仅房主可见）：
```swift
if selfRole == .owner {
    ToolIcon(symbol: "...", title: L10n.Party.Tools.privateCall) {
        // 沿用现有 pattern: 关本 sheet → 350ms → 打开 activeRoomTool = .privateCall
        onTapPrivateCall?()
    }
}
```

调用侧（PartyRoomView）传 closure：
```swift
onTapPrivateCall: {
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 350_000_000)
        activeRoomTool = .privateCall
    }
}
```

**SF Symbol**（[sf-symbol-usage-preflight](.claude/rules/sf-symbol-usage-preflight.md)）：候选 `phone.badge.checkmark` / `phone.fill.badge.plus` / `bell.badge` · Step 1b preflight 用 SF Symbols.app 验证。

### §5.4 相机 & 美颜串行切换（关键风险 · P1-8 修订）

**问题**：`PartyStore.camera`（PartyRTCEngine 用）+ `CallView.fallback.camera`（CallStore 用）是两个 CameraManager 实例，同时启动触发 `reason=3`。

**串行契约**：pauseForCall §2.1 Flow B 已含时序。关键：

```swift
func pauseForCall(msg: CallMessage) async {
    // guard + updateMedia + downSeat...
    
    // 步骤 D: 释放相机（内部串行 detach Sharer → unsubscribe → tearDown → camera=nil）
    disableLocalVideoCapture()
    
    // 步骤 E: 等 AVCaptureSession 硬件层真正释放前摄
    // ⚠️ P1-8 修订：Task.yield() 不够（只让 executor slot）
    //    真实相机硬件释放 20~200ms · 保守取 200ms · Step 3 真机 5 循环压测调优
    try? await Task.sleep(nanoseconds: 200_000_000)
    
    // 步骤 F: rtc.leave
    await rtc.leave()
    
    // 步骤 G: CallStore 接听 → 内部 CallView.fallback.camera start（此时前摄已释放）
    await CallStore.shared.acceptIncomingFromParty(msg: msg)
}
```

resumeParty 时反向串行：CallView.onDisappear tearDown fallback camera → RunLoop tick → PartyStore setup camera + 美颜。

**R6 验收改为真机集成测试**（P1-8）：单测不能触发真机 AVCaptureSession，只能压 5 次循环。

---

## §6 复用判断表

### §6A: 已就位可直接复用

| 需求 | 复用点 | 位置 | 判断 |
|---|---|---|---|
| 全局来电分派 | `CallStore.handleIncomingVideoCall` | Sources/Call/CallStore.swift:1131 | ✅ 加 party 分支（§2.1 pseudo）|
| 直播 → 通话挂起模式 | `LiveStore.pauseForCall` | Sources/Live/LiveStore.swift:383-419 | ✅ 拷贝改造 |
| 通话结束观察 | 多观察者数组（P0-2 refactor 后）| Sources/Call/CallStore.swift | ⚠️ 需 refactor 单槽 → NSHashTable |
| PartyRTCEngine.leave async | Sources/Party/RTC/PartyRTCEngine.swift:333-388 | ✅ 直接调 |
| Router 分派 pattern | 1040 videoSeatInvite | Sources/Party/NIM/PartyMessageRouter.swift:145-161 | ✅ 加 1029 同款 |
| 房间设置 sheet enum-driven | `PartyRoomToolSheetKind` + `activeRoomTool` | Sources/Party/UI/Components/PartyRoomToolsSheet.swift:8-16 | ✅ 加 `.privateCall` case |
| 房间设置 API pattern | `lockRoom` / `setRoomAdmin` / `updateOnSeatEnable` | Sources/Party/Network/PartyAPI.swift | ✅ 加 endpoint 同款 |
| 礼物面板 UI | `CommonGiftPanelConfig` | Sources/Gift/Panel/Config.swift:171 | ✅ 加 `.partyCallSetting` factory · P1-10 |
| RTM 信令 | `CallSignaling + RtmReconnect` | Sources/Call/CallSignaling.swift | ✅ 无场景差异 |
| Empty room 心跳 | `CallEmptyRoomDetector` | Sources/Call/CallEmptyRoomDetector.swift | ✅ 无 frontGameType guard |

### §6B: cross-scene preflight（[cross-scene-component-reuse-preflight](.claude/rules/cross-scene-component-reuse-preflight.md)）

| 目标 | 自持相机 | 自持 store | ignoresSafeArea | 结论 |
|---|---|---|---|---|
| `CommonGiftPanel` (Sources/Gift/Panel/) | ❌ **无 CameraManager** | ✅ CommonGiftPanelStore（大量 @Published，sheet lifecycle 内 init/销毁）| 待 verify | ✅ 可复用；sheet 使用天然安全 |
| `PartyRoomSettingsView` | 待 preflight | ✅ PartyRoomSettingsStore | 待 preflight | ⚠️ 本 spec 只**参考模式**不复用 sheet 本体 |
| `CallView` | ❌（外部 liveCamera or fallback）| ✅ CallStore | ✅（zIndex 100 overlay）| ✅ 由 RootView 挂载 |
| `PartyRoomView` 挂载方式 | — | — | — | ✅ **verified**：NavigationStack push（`PartyTabRootView.swift:71`），CallView 天然在上层无需 hoist |
| `GiftEffectSceneModifier` (`.giftEffectScene`) | ❌ | ❌（自身仅是 modifier，逻辑在 GiftEffectCenter）| — | ✅ **Q10 决策承载**：PartyRoomView:79 + CallView:68 已挂 · setActiveScene push 栈 / leaveScene pop restore |

### §6C: 完全新写

| 项 | 位置 | 估行数 |
|---|---|---|
| PartyStore.pauseForCall / resumeParty | Sources/Party/PartyStore.swift 追加 | ~130 |
| PartyPrivateCallSettingSheet + Store | Sources/Party/Settings/PartyPrivateCallSetting*.swift 新建 | ~250 |
| PartyPrivateCallNotify model | Sources/Party/Models/PartyPrivateCallNotify.swift 新建 | ~60 |
| PartyCallGiftItem model | Sources/Party/Models/PartyCallGiftItem.swift 新建 | ~30 |
| QueryCallResponse model | Sources/Call/CallModels.swift 追加 | ~25 |
| CallStore observer refactor（P0-2）| Sources/Call/CallStore.swift 修订 | ~50（含 attach/detach/notifyObservers）|
| CallStore.acceptIncomingFromParty | 同上追加 | ~70 |
| CallService.queryCall | Sources/Call/CallService.swift 追加 | ~25 |
| PartyAPI +2 endpoint | Sources/Party/Network/PartyAPI.swift 追加 | ~40 |
| CommonGiftPanelConfig.partyCallSetting factory | Sources/Gift/Panel/Config.swift 追加 | ~30 |
| LiveRoomView observer 调用改 attach/detach | Sources/Live/LiveRoomView.swift 修订 | ~10 |

**总估**：~720 行 impl + ~150 行 enum/model 扩展 + ~230 行单测/Fakes = **~1100 行**（P3-28 补齐）

---

## §7 边界矩阵（覆盖梳理 §8.1 全部 9 case + iOS 特有）

| # | 场景 | 预期行为 | 验证方式 | 引用 |
|---|---|---|---|---|
| B1 | 房主关私 call → 用户端拨 | 后端拦截，iOS 端不收 RTM VideoCall；无 1029 | 真机 | §8.1-7 |
| B2 | 房主开私 call → 用户端拨 | RTM + queryCall(callerType=5) → 立即 pauseForCall → CallView | 真机 | §8.1 核心 |
| B3 | 派对房内收非派对 callerType!=5 | reject reason="party room reject non-party call" · 无 toast 无 UI（对齐安卓+直播 · P1-7）| 真机 + 单测（queryCall Fakes 返 callerType=1）| §8.1-2 |
| B4 | 通话中（CallStore.state != .idle）再收 VideoCall | handleIncomingVideoCall idle guard 短路 reject | 单测 | §8.1-9 |
| B5 | App 后台时收派对来电 | reject（appForeground==false）| 真机 | §8.1-8 |
| B6 | 通话中被踢（1003）出派对房 | PartyMessageRouter 收 1003 → roomState=.ended；通话继续；onCallEnded 触发时短路 | 真机 + 单测 | §8.1-3 |
| B7 | 通话中派对房被解散（1009）| 同 B6 | 真机 + 单测 | §8.1-4 |
| B8 | 通话弱网 → CallStore forceEnd | onCallEnded 触发；resumeParty；若 roomState=.ended 短路 | 真机（飞行模式） | §8.1-5 |
| B9 | PartyBattle 同时（未来接入）| pauseForCall guard `PartyBattleController.state == .idle`（本 spec 预留 nil-check）| 单测 | §8.1-6 |
| B10 | 用户在派对房**外**收私 call | roomState != .joined → 走 direct 分支 idle guard（P1-6 修订）| 单测 | §8.1-1 |
| B11 | 私 call 中主播 kill App 冷启动 | CallStore.stop → state=.idle · 派对房也已 exit（Session 恢复走登录态）· 不做恢复提示（Q5=A）| 真机 | iOS 特有 |
| B12 | resumeParty rtc.join 失败 | refreshRtcToken 重试 1 次；仍失败 forceLeaveRoom(.**networkLost**) + banner + 退大厅 · P0-1 修订 | 单测（Fakes rtc.join throws x2）| iOS 特有 |
| B13 | 通话中收本房间他人 1029 status=ended | userId != myUserId → drop（不影响自己）| 单测 | §2.3 扩展 |
| B14 | 1029 payload status 字段缺失/非法（含 GIFT_DOUBLED 误路由）| PartyPrivateCallNotify decode throw → Router drop · P0-4 防御 | 单测（Fakes payload 无 status / status=`gift_doubled`）| iOS 特有 · P0-4 |
| B15 | ~~5s 内主播主动下麦/退房~~ | N/A · iOS 无 5s 窗口 | — | D-1 |
| B16 | 通话结束回派对房时用户已切 tab | scenePhase / isActive 守卫；rtc.join 保留，UI 不 refresh；用户回来自动同步 | 真机 | swiftui-keepalive-publisher-isolation |
| B17 | CameraManager 双实例竞争前摄 | §5.4 串行契约：disableLocalVideoCapture → sleep(200ms) → rtc.leave → acceptIncomingFromParty | 真机（连续 5 次循环 · P1-8） | swiftui-camera-preview §3/§7 |
| B18 | FURenderKit 二次 setup（D-2 决策留验）| 观察是否降级；本 spec 不 release · P2-22 加量化 rollback 条件 | 真机 3-5 循环 · Instruments Memory + GPU | D-2 |
| B19 | queryCall 请求超时 | 一律 reject 保守（不 fallback direct 避免 sharedEngine 打架）· P2-19 | 单测 + 真机弱网 | iOS 特有 |
| B20 | 1029 与 1040 等派对房消息并发 | Router 按 attachType 分派互不干扰 · 复用 §6A row 5 pattern | 单测 | iOS 特有 |
| B21 | 1029 status 字段值非 calling/ended（未来后端扩展）| Status enum decode throw → Router drop（保守）· P0-4 | 单测 | 前向兼容 |
| B22 | 私 call 期间派对房内他人送礼 SVGA/礼物特效 | ✅ **Q10 决策已由 GiftEffectSceneModifier 天然承担**：CallView.onAppear 触发 `setActiveScene(.call, callId)` push 旧 `.party` scene 到栈；通话结束 CallView.onDisappear 触发 `leaveScene(.call)` pop restore `.party`。跨场景清理 + 恢复对齐直播私 call | 单测 + 真机验 stack push/pop | P2-23 · Q10 · 现有 GiftEffectCenter §98-154 |

---

## §8 rules 关联

| Rule | 应用点 |
|---|---|
| [swiftui-camera-preview.md §3 §5 §7 §9](.claude/rules/swiftui-camera-preview.md) | §5.4 双相机串行 + sleep 200ms · PartyRTCEngine §9 已就位 · AVCaptureSession reason=1/4/3 |
| [im-payload-real-log-over-code-assumption.md](.claude/rules/im-payload-real-log-over-code-assumption.md) | 1029 真机 log 校验（P0-4 status enum）· queryCall response 真机校准（P1-13）|
| [agent-recon-field-names-unverified.md](.claude/rules/agent-recon-field-names-unverified.md) | 所有 Codable model 加 CodingKeys · Step 1a 起草前置真机 curl |
| [api-http-method-strict.md](.claude/rules/api-http-method-strict.md) | 3 endpoint 追安卓源码 + 真机；本 spec 已明示 H5 无源 |
| [ios-decode-userid-compat.md](.claude/rules/ios-decode-userid-compat.md) | userId / callerUserId / fromUserId String/Int 双兼容 |
| [feature-pipeline-complexity-tier.md](.claude/rules/feature-pipeline-complexity-tier.md) | A 档 · step 1a-1c-2-3-4-5-6 全走 |
| [cross-scene-component-reuse-preflight.md](.claude/rules/cross-scene-component-reuse-preflight.md) | §6B CommonGiftPanel + PartyRoomView 挂载方式 preflight |
| [swiftui-button-plain-hitarea.md](.claude/rules/swiftui-button-plain-hitarea.md) | 礼物 cell contentShape |
| [toast-vs-banner-consistency.md](.claude/rules/toast-vs-banner-consistency.md) | 设置 sheet 错误分层 |
| [swiftui-keepalive-publisher-isolation.md](.claude/rules/swiftui-keepalive-publisher-isolation.md) | B16 · onCallEnded observer 派生 publisher 隔离 |
| [swiftui-fullscreencover-hoist.md](.claude/rules/swiftui-fullscreencover-hoist.md) | 私 call 设置 sheet enum-driven hoist（§5.3 P1-11） |
| [prefer-shared-component-over-adhoc.md](.claude/rules/prefer-shared-component-over-adhoc.md) | 礼物面板复用 CommonGiftPanel（P1-10） |
| [sf-symbol-usage-preflight.md](.claude/rules/sf-symbol-usage-preflight.md) | 设置 sheet SF Symbol preflight |
| [async-state-fallback.md](.claude/rules/async-state-fallback.md) | 礼物列表加载态 |
| [xcodegen-podinstall-binding.md](.claude/rules/xcodegen-podinstall-binding.md) | 每次改 project.yml 后 `./bin/regen.sh` |
| [error-handling.md](.claude/rules/error-handling.md) | queryCall / updatePartyPrivateCall 失败分级 |

---

## §9 验收清单

### §9.1 正向路径（F 全列 · P3-29 正向表述）

- [ ] F1: 房主进入派对房，PartyRoomToolsSheet 可见"私 call"入口
- [ ] F2: 房主打开开关 → toast 保存成功 + updatePartyPrivateCall HTTP 200
- [ ] F3: 房主选择礼物 → 保存成功
- [ ] F4: 房主关闭开关 → 用户端拨打后 iOS 端不收 RTM VideoCall
- [ ] F5: 房主开启 → 用户端拨打 → **pauseForCall 触发 → 500ms 内 CallView calling 首帧渲染** → 通话建立
- [ ] F6: 通话正常挂断 → **1000ms 内**回派对房 → 麦位面板已刷新
- [ ] F7: 主播需手动重新上麦（麦位不自动恢复）
- [ ] F8: 观众/房管无"私 call"入口
- [ ] F9: 通话中派对房 chat 保持 login（观察聊天室历史消息不 exit）

### §9.2 反向 / 边界（R critical · P0/P1 严重度）

- [ ] R1（P0）：**§5.4 相机串行**：连续 5 次"派对房 ↔ 私 call"循环无 `reason=3`。真机
- [ ] R2（P0）：**通话中被踢/解散**：onCallEnded 触发时 `roomState != .joined` 短路 · 单测 + 真机
- [ ] R3（P0）：**多观察者数组不干扰**（P0-2 关键回归）：直播 → 派对房 → 退 → 直播私 call → 15s 倒计时正常。真机
- [ ] R4（P0）：**1029 双重定义防御**（P0-4）：Fakes 注入 status 缺失 / status=`gift_doubled` payload → Router drop 无副作用。单测
- [ ] R5（P0）：**弱网**：飞行模式期通话 forceEnd → 恢复网络 → CallView dismiss + 派对房 UI 正常恢复（若房间未被踢）。真机
- [ ] R6（P1）：**queryCall 超时**：接口超时 6s → 一律 reject 保守（不 fallback direct 避免 sharedEngine 打架）· 单测
- [ ] R7（P1）：**双相机 sleep 时序**（P1-8）：改序 or 缩短 sleep 到 20ms 应触发 reason=3 · 真机（negative test 验 sleep 200ms 是必要的）
- [ ] R8（P1）：**resumeParty rtc.join 失败重试**（P2-18）：Fakes 第 1 次 throw + 第 2 次 refreshRtcToken 后成功 · 单测

### §9.3 反向单测 ↔ Fakes 对应表（P1-14 加 F 全列）

| 单测 tc | Fakes 注入 |
|---|---|
| **正向 tc** | |
| test_pauseForCall_happyPath_transitionsSuspended | 正常 path |
| test_resumeParty_happyPath_rejoinsRtcAndPostsMikeList | rtc.join 成功 |
| test_updatePartyPrivateCall_persistsToServerAndUpdatesUI | API Fakes 200 |
| test_getPartyCallGiftList_populatesGiftGrid | API Fakes 返 3 gifts |
| test_ownerToolsSheet_showsPrivateCallEntry_forOwnerOnly | selfRole=.owner vs .admin/.audience |
| **反向 tc** | |
| test_pauseForCall_notInJoinedState_guardRejects | PartyStore.roomState=.idle |
| test_pauseForCall_downSeatFails_stillProceedsToLeave | PartyAPI.downSeat throw |
| test_resumeParty_rtcJoinFails_refreshTokenAndRetries | PartyRTCEngine.join throw 1st + refresh success |
| test_queryCall_nonType5_rejectsCall | CallService.queryCall Fakes callerType=1 |
| test_queryCall_timeout_rejects | CallService.queryCall Fakes throw timeout |
| test_notify1029_missingStatus_dropsPayload | 1029 Fakes payload without status |
| test_notify1029_giftDoubledSemantic_dropsPayload | 1029 Fakes payload status=`gift_doubled` |
| test_notify1029_missingPartyCallOpen_defaultsZero | 1029 Fakes payload without partyCallOpen |
| test_incomingCallDuringCall_shortCircuitsWithIdleGuard | CallStore.state 预设 .calling |
| test_callEnded_whileRoomEnded_doesNotResume | roomState=.ended + CallStore.state → .idle |
| test_multiObservers_liveAndPartyBothReceiveEvents | Attach live + party；模拟 onCallEnded；两方都收 |
| test_partyPrivateCallOpen_falseGuardRejects | partyPrivateCallOpen=0 |

### §9.4 Step 3 真机验收（用户签字）

- [ ] 场景 1 (F4)：关开关 + 拨打 → 无来电
- [ ] 场景 2 (F5)：开开关 + 拨打 → 立即接听 + 通话建立
- [ ] 场景 3 (F6/F7)：正常挂断 → 回派对房 → 手动重新上麦
- [ ] 场景 3b (B18/D-2 rollback 观察 · P2-22)：连续 5 次循环 · Instruments Memory 增长 <30MB · 平均帧率 ≥24fps · GPU 时间 <8ms。任一命中 → D-2 回滚
- [ ] 场景 4 (R2)：通话中被踢 → 通话继续 → 挂断后不回派对房
- [ ] 场景 5 (R5)：弱网 forceEnd → 恢复
- [ ] 场景 6 (R1)：连续 5 次抢占循环 无 reason=3
- [ ] 场景 7 (B10)：用户在派对房外收私 call → 走 direct 分支（非派对分支）

### §9.5 回归（P0-2 关联 P2-25）

- [ ] E 期原有派对房 12 大场景（进房/退房/上下麦/送礼/黑名单/锁房/接待位/排麦/RoomMode）不受影响
- [ ] C 期直播私 call、直连 1v1 通话不受影响
- [ ] D 期直播转私 call 不受影响
- [ ] B 期直播心跳 / 弱网监控不受影响
- [ ] **F1（新增 · P2-25）**：直播态 → 进派对房 → 退派对房 → 收直播私 call → 15s 倒计时正常触发（多次 attach/detach 不干扰 · P0-2 关键回归）

---

## §10 待问用户（分层 · P2-21）

### §10.1 已答（本文档已应用）

| # | 问题 | 决策 |
|---|---|---|
| D-1 | 5s delay | 无 5s delay 直接接听 |
| D-2 | FURenderKit release | 本期不做 |
| P0-2 | CallStore observer 冲突 | 多观察者数组（NSHashTable） |
| P1-7 | 派对房内非派对来电 | 自动 reject 对齐安卓+直播 |

### §10.2 待答（用户必须决 · 产品）

| # | 问题 | 建议 |
|---|---|---|
| Q3 | D-5: 私 call 开关的作用域（房间 vs 主播）| 房间维度（对齐安卓 `partyPrivateCallOpen` room enter 响应） |
| Q7 | 私 call 礼物 grid 布局是几列 | 4 列（对齐 CommonGiftPanel 现有 pattern；Step 1c preflight 后定） |
| Q8 | 房主自己收自己的 1029 是否 UI 提示 | 不需要（CallView 已展示） |
| Q9 | 通话中他人 1029 status=calling 是否显示"主播通话中" | 不显示（避免与麦位面板冗余） |
| Q10 | **P2-23** 私 call 期间派对房内他人送礼特效 pause/queue/flush? | 建议：GiftEffectCenter 队列继续（跨场景 scopeId 匹配已治理）；回房后 backlog 若过时不 flush（观察队列时间戳） |

### §10.3 待答（Claude 建议决 · 技术）

| # | 问题 | 建议 |
|---|---|---|
| Q1 | D-3: AgoraManager frameSnapshot 是否本期做 | A · 独立小 spec 并行做（保持本 spec 聚焦） |
| Q2 | D-4: RTCSharedEngineGuard 抽公共 | A · F 期不抽（3 处可接受） |
| Q4 | D-6: PartyBattle guard 是否本期写 | A · 写 nil-check 预留（0 impl 成本） |
| Q6 | queryCall 超时时间 | 6s（对齐默认） |

---

## §11 自检（v1 起草状态 · Step 6 后统一勾 · P3-30）

- [ ] §0 二次校验完成
- [ ] §0.4 E→F invariant 变更清单
- [ ] §1 词表只锁业务语义
- [ ] §2 三大 flow 时序清晰
- [ ] §2.1 CallStore 分派 pseudo 精确
- [ ] §3 状态机图 + 非法迁移显式（含图上标注）
- [ ] §3.4 CallStoreObserver refactor 契约完整
- [ ] §4 model + API 每处标唯一信源 + Step 1a 真机前置门标注
- [ ] §5 UI 层含 preflight + 串行契约 200ms
- [ ] §6 复用判断表 3 象限完整
- [ ] §7 边界矩阵 22 case 覆盖梳理 §8.1 全部 9 + iOS 特有 13
- [ ] §8 rules 关联清单
- [ ] §9 验收 F 全列 + R critical 8 条 + Fakes 对应表（正反双向）
- [ ] §10 待问用户分层（已答/产品/技术）
- [ ] §12 红队 checklist v2 完成

---

## §12 红队 checklist（v2 落地记录）

v2 已整合红队 30 条意见：
- **P0 全部修**：P0-1 `.networkLost` / P0-2 多观察者数组 / P0-3 §0.4 E→F 铁律变更 / P0-4 status enum 防双重定义
- **P1 全部修（除 P1-6 case 修正过重命名）**：P1-5 §2.1 pseudo · P1-7 决策收敛 · P1-8 sleep 200ms · P1-9 §2.3 显式 guard · P1-10 CommonGiftPanel · P1-11 enum-driven · P1-12 默认值真机校验 · P1-13 真机前置门 · P1-14 F 全列 Fakes · P1-15 mermaid 非法迁移 · P1-16 步骤 D 顺序 · P1-6 B10 case 修正
- **P2 大部分修**：P2-17 Bool 派生 · P2-18 refreshRtcToken 重试 · P2-19 超时保守 reject · P2-20 preflight 挂载 · P2-22 量化 rollback · P2-23 加 Q10 · P2-24 line:82 精确 · P2-25 回归 F1 · P2-26 preflight 引用移除
- **P3 全部修**：P3-27 合并 · P3-28 加单测行数 · P3-29 正向表述 · P3-30 checkbox 全空

### v2 已知 gap 状态（更新至 2026-07-14 19:45）

- [ ] ⚠️ **Step 1a 唯一剩余前置门**：真机 curl **一次** queryCall + getPartyCallGiftList，log 落盘 → 校准 model 字段（P1-13 · **需用户配合**）
- [x] ✅ Step 1a preflight PartyRoomView 挂载方式（NavigationStack push，无需 hoist · P2-20 verified）
- [x] ✅ Step 1a preflight CommonGiftPanel（无相机自持 · Store 大量 @Published sheet lifecycle · 可复用 · §6B verified）
- [x] ✅ Step 1a preflight GiftEffectSceneModifier（**Q10 决策由现有 modifier 承担 · 零额外 impl** · §7 B22 verified）
- [x] ✅ Q3/Q7/Q8/Q9/Q10 已答（§10.1/§10.2 更新）

---

## 附录 A: spec 写作自检记忆

- 词表锁业务语义，不锁 protocol 名 ✓
- H5/安卓二次校验强制 ✓
- 状态机含合法态 + 非法迁移显式标记 ✓
- 验收清单正向 + 反向对应到具体测试载体 ✓
- 复用候选标记（三象限：可复用/preflight/新写）✓
- 待问用户清单分层（已答/产品/技术）✓
- rules 关联清单每条标应用点 ✓
- 红队意见 P0/P1 全部处理并记录 ✓
- 关键真机前置门明示（Step 1a 起草前）✓

---

## 附录 B: 版本历史

| 版本 | 日期 | 变更 |
|---|---|---|
| v1 | 2026-07-14 18:30 | 初稿；D-1/D-2 决策已含；待红队评审 |
| **v2** | **2026-07-14 19:30** | **整合红队 30 条意见（4 P0 + 12 P1 + 10 P2 + 4 P3）+ P0-2/P1-7 用户决策**；核心变更：CallStore observer 多数组 refactor / status enum 防双重定义 / sleep 200ms / CommonGiftPanel 复用 / enum-driven sheet / 真机 curl 前置门** |
