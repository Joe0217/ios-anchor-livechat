# Party 房私 Call 功能整理 — 安卓主播端

> 源码深挖报告 · 2026-07-14 · 基于 DM-20260616-004 需求分支 android-anchor/ 源码分析

## 本文目的

为 iOS 主播端 Party 房私 call 功能开发提供安卓端的完整行为参照。按需求文档 8 项深挖清单逐项梳理，每项给出源码位置、关键逻辑、iOS 接入需知。

---

## 1. 私 Call 方向：仅被动接听

**结论：仅被动被叫** — 无房内主动发起入口。安卓主播端 Party 房内不存在主动向某用户发起 1v1 通话的能力。

### 1.1 来电监听入口

| 文件 | 行号 | 说明 |
|------|------|------|
| `partyroom/manager/PartyRoomDataManager.kt` | 70 | `implements io.agora.onetoone.ICallApiListener` — 单例直接监听 Agora CallApi 回调 |
| 同上 | 601-641 | `onCallStateChanged()` — 收到 `CallStateType.Calling` 时进入来电处理 |
| 同上 | 651-688 | `queryPartyCall(fromUserId, channelId)` — 调用 HTTP `api/call/record/v2/queryCall` 查询 `callerType` |

### 1.2 来电判定逻辑

```kotlin
// PartyRoomDataManager.kt:662
if (callerType == 5 && appForeground && !LibApp.isCalling) {
    // PartyCall: 走接听流程
    handlePartyCallIncoming()
    ShengWangCallUtils.joinCall(fromUserId, channelId)
} else {
    // 非 PartyCall: 延迟 1s 自动拒绝
    callApi.reject(fromUserId, "reject by user in party room, callerType:$callerType")
}
```

### 1.3 没有的入口

- ❌ 无 `startCall` / `callInvite` / `createCall` 在 partyroom 目录内
- ❌ 无"点击用户头像发起私 call"入口
- ❌ 麦位右键菜单中无"发起私 call"选项
- ✅ 仅 `PartyPrivateCallSettingDialog` 是**设置页面**（开关 + 选礼物），不是发起通话

### 📌 iOS 接入参考

**spec 范围**：仅需实现"被动被叫抢占"即可（XL 工作量）。主动发起后续迭代。

---

## 2. IM 通知通道：1029（非 1028）

**关键发现：无 1028，1029 存在双重定义**

安卓源码中没有 attachType=1028。实际使用 1029，但 `NIMMsgAttachType.java` 中 **1029 被两个常量共用**：

### 2.1 NIM 常量定义

| 文件 | 行号 | 常量名 | 值 | 用途 |
|------|------|--------|-----|------|
| `common/nim/NIMMsgAttachType.java` | 376 | `PARTY_PRIVATE_CALL_NOTIFY` | 1029 | Party 房 Private Call 状态通知 |
| 同上 | 388 | `PARTY_ROOM_GIFT_DOUBLED` | **1029** | Party 房上麦收礼 gems 加倍通知 |

> ⚠️ **双重定义影响**：`PARTY_ROOM_GIFT_DOUBLED` 在 `PartyRoomVM.kt` 的 `handleIncomingChatRoomMsgList` 中没有对应的处理分支，意味着 1029 消息仅由 `PARTY_PRIVATE_CALL_NOTIFY` 分支处理。iOS 接入时直接使用 attachType=1029 接收私 call 状态通知，与安卓对齐。同时建议要求后端在下发 1029 消息时通过 `data.status` 等字段区分用途。

### 2.2 通道类型：聊天室广播（非 P2P）

| 通道 | 说明 |
|------|------|
| 聊天室自定义消息 | 通过 NIM 聊天室的 `remoteExtension.attachType=1029` 下发，房间内所有人收到 |
| 消息入口 | `PartyRoomVM.kt:786-789` → 通过 `LiveEventBusHelper` 投递 `EVENT_PARTY_CALL_NOTIFY` |
| Activity 处理 | `PartyRoomActivity.kt:1328-1334` 监听事件 → `receivePartyCallNotify(jsonString)` |

### 2.3 Payload 字段（data JSON）

```json
{
  "userId": 10001,
  "nickname": "xxx",
  "seatIndex": 3,
  "status": "calling",
  "callerUserId": 20001,
  "callerNickname": "yyy",
  "callerSeatIndex": 5,
  "partyCallOpen": 1
}
```

| 字段 | 类型 | 说明 |
|------|------|------|
| `userId` | Int | 主播 userId (被叫方) |
| `nickname` | String? | 主播昵称 |
| `seatIndex` | Int | 主播麦位 |
| `status` | String | `"calling"` 或 `"ended"` |
| `callerUserId` | Int? | 呼叫方 userId |
| `callerNickname` | String? | 呼叫方昵称 |
| `callerSeatIndex` | Int? | 呼叫方麦位（caller 也可能在麦上） |
| `partyCallOpen` | Int? | 私 call 开关状态 0/1 |

### 📌 iOS 接入参考

**必须用真机 log 校验**（参考 `.claude/rules/im-payload-real-log-over-code-assumption.md`）：
- `status` 字段的精确枚举值（是否仅有 "calling" / "ended"）
- `partyCallOpen` 是房间级还是主播级开关
- data 中是否还有其他运行时可能出现的字段（如 `duration`、`errorReason`）

---

## 3. updatePartyPrivateCall HTTP 接口契约

| 项目 | 值 |
|------|-----|
| HTTP Method | **POST** |
| Path | `sapi/weidou/v1/client/party/room/updatePartyPrivateCall` |
| 请求 Body | `{ roomId: String, enable: Int (1=开/0=关), giftId?: String }` |
| 响应 | `HttpResult<Any?>` — code=200 成功 |
| 权限 | 后端校验（房主/房管/平台管理员） |
| 触发方 | `PartyPrivateCallSettingDialog.kt:174` → `HttpHelper.updatePartyPrivateCall()` |

### 3.1 源码路径链

```
PartyPrivateCallSettingDialog.openOrClosePrivateCall()
  → HttpHelper.updatePartyPrivateCall(roomId, enable, giftId)  // partyroom/http/HttpHelper.kt:1039
    → httpService.updatePartyPrivateCall(params)               // ApiService.kt:468
      → POST sapi/weidou/v1/client/party/room/updatePartyPrivateCall
```

### 3.2 礼物列表接口（两个 scene）

| 接口 | Path | scene | 用途 |
|------|------|-------|------|
| 选择礼物 | `sapi/weidou/v1/client/party/room/getPartyCallGiftList` | 2 | 主播设置弹窗加载可选礼物列表 |
| 通话送礼 | 同上 | 1 | 通话中发送 party call 专属礼物 |

---

## 4. 来电响铃 → 下麦时序（核心端到端流程）

### 4.1 时序图

```
┌──────────┐     ┌──────────────────┐     ┌──────────────┐     ┌──────────┐     ┌─────────────────────┐
│  Agora   │     │ PartyRoomData    │     │ RtcEngine    │     │  后端API  │     │ ShengWang1V1Call    │
│ CallApi  │     │ Manager          │     │ Manager      │     │          │     │ Activity            │
└────┬─────┘     └───────┬──────────┘     └──────┬───────┘     └────┬─────┘     └──────────┬──────────┘
     │                   │                       │                  │                        │
     │ Calling           │                       │                  │                        │
     │──────────────────>│                       │                  │                        │
     │                   │                       │                  │                        │
     │                   │ queryCall              │                  │                        │
     │                   │──────────────────────────────────────────>│                        │
     │                   │                       │                  │                        │
     │                   │ { callerType: 5 }      │                  │                        │
     │                   │<──────────────────────────────────────────│                        │
     │                   │                       │                  │                        │
     │                   │ callerType==5 && !isCalling              │                        │
     │                   │                       │                  │                        │
     │                   │ handlePartyCallIncoming()                │                        │
     │                   │──┐                    │                  │                        │
     │                   │  │ removeListener     │                  │                        │
     │                   │  │ releaseBeauty()    │                  │                        │
     │                   │  │───────────────────>│                  │                        │
     │                   │  │ stopPreview()      │                  │                        │
     │                   │  │───────────────────>│                  │                        │
     │                   │  │ downSeat()         │                  │                        │
     │                   │  │───────────────────>│                  │                        │
     │                   │  │ updateAutoSubscribe(false)            │                        │
     │                   │  │───────────────────>│                  │                        │
     │                   │  │ updateMedia(mic/camera off)           │                  │        │
     │                   │  │──────────────────────────────────────>│                  │        │
     │                   │  │                    │                  │                  │        │
     │                   │  │ delay(5000ms)      │                  │                  │        │
     │                   │  │··················· ·                  │                  │        │
     │                   │  │ applyDownSeat()    │                  │                  │        │
     │                   │  │──────────────────────────────────────>│                  │        │
     │                   │  │                    │                  │                  │        │
     │                   │  │ joinCall(fromUserId, channelId)       │                  │        │
     │                   │  │────────────────────────────────────────────────────────────────>│
     │                   │  │                    │                  │                  │        │
```

### 4.2 分时刻明细

| 时刻 | 事件 | UI 变化 | RTC 动作 | 麦位状态 |
|------|------|---------|----------|----------|
| T0 | `onCallStateChanged(Calling)` 到达 | 无弹层（无UI打扰） | 暂无 | 麦位保留 |
| T0 + Δ | `queryCall` HTTP 返回 callerType==5 | 无弹层 | — | 麦位保留 |
| T0 + Δ + 1 | `handlePartyCallIncoming()`：removeListener → releaseBeauty → stopPreview → downSeat(AUDIENCE) → updateAutoSubscribe(false) | 预览停止 | 停止本地预览、角色切AUDIENCE、取消自动订阅 | RTC已下麦，麦位仍保留（服务端未通知） |
| T0 + Δ + 2 | `updateMedia` (mediaType=3视频位/1语音位, enabled=0) | 无 | — | 服务端更新媒体状态 |
| T0 + 5s | `delay(5000L)` 到期 → `applyDownSeat` HTTP | 气泡5s后消失（1001麦位变更消息到后清除） | — | 服务端下麦 → 1001通知 → **麦位清空** |
| T0 + 5s + Δ | `ShengWangCallUtils.joinCall()` → `ShengWang1V1CallActivity.start()` | 跳转1v1通话UI | 加入声网 call RTC 频道 | 已清空 |

### 4.3 关键源码定位

| 步骤 | 文件 | 行号 |
|------|------|------|
| ICallApiListener 注册 | `PartyRoomDataManager.kt` | 70 (implements) |
| 注册时机 | 同上 | 457-458 (initObserver) |
| onCallStateChanged | 同上 | 601-641 |
| queryPartyCall | 同上 | 654-688 |
| handlePartyCallIncoming | 同上 | 694-738 |
| releaseBeauty | `RtcEngineManager.kt` | 234-241 |
| stopPreview | 同上 | 229-231 |
| downSeat (setClientRole AUDIENCE) | 同上 | 52-54 |
| updateAutoSubscribe | 同上 | 108-115 |
| joinCall | `ShengWangCallUtils.kt` | 111-152 |

### 4.4 LibApp.isCalling 守卫状态

| 位置 | 文件 | 行号 | 读写 |
|------|------|------|------|
| 定义 | `LibApp.java` | 26 | `public static volatile`, 默认 false |
| 查询来电前判断 | `PartyRoomDataManager.kt` | 662 | R: 仅在 !isCalling 时接受来电 |
| 进入1v1通话时设置 | `ShengWang1V1CallActivity.kt` | — | W: 通话 Activity start 时设为 true |
| 通话结束时清除 | `ShengWang1V1CallActivity.kt` | — | W: 通话 Activity finish 时设为 false |
| 麦位更新时判断 | `PartyRoomDataManager.kt` | 1192 | R: 通话中跳过麦位 UI 更新 |
| joinCall 入口检查 | `ShengWangCallUtils.kt` | 113-115 | R: 已通话则 rejectByBusy |

---

## 5. onCallEnd → 回 Party 房恢复流程

### 5.1 恢复入口

| 文件 | 行号 | 机制 |
|------|------|------|
| `PartyRoomDataManager.kt` | 432-438 | 监听 `EVENT_1V1_CALL_END` 事件 → 调用 `onCallEnd()` |
| 同上 | 568-575 | `onCallEnd()` 实现 |
| 事件触发方 | `Const.java:440` | `EVENT_1V1_CALL_END = "event_1v1_call_end"` — 声网1v1结束时由 `ShengWang1V1CallActivity` 发出 |

### 5.2 onCallEnd() 步骤

```
onCallEnd() {
    1. callApi.addListener(this)           // 重新注册声网来电监听
    2. RtcEngineManager.initBeauty()        // 重新初始化美颜
    3. joinPartyRoomChannel()              // 重新加入 Party 房 Agora RTC 频道
    4. RtcEngineManager.updateAutoSubscribe(true)  // 恢复自动订阅
    5. LiveEventBusHelper.post(EVENT_CLEAR_MIKE_LIST, "")  // 清空麦位面板
    6. postMikeList(mMikeList)              // 重新推送麦位列表（触发 UI 重建）
}
```

### 5.3 场景恢复矩阵

| 场景 | 是否触发 onCallEnd | RTC 是否重入 | 麦位状态 |
|------|-------------------|-------------|----------|
| 正常挂断 | ✅ | 重入 Party 频道 | 需重新上麦 |
| 对方挂断 | ✅ | 重入 Party 频道 | 需重新上麦 |
| 对方取消拨打 | ✅ (remoteCancelled → onCallEnd) | 重入 Party 频道 | 需重新上麦 |
| 通话超时 | ✅ | 重入 Party 频道 | 需重新上麦 |
| 网络异常 forceEnd | ✅ | 重入 Party 频道 | 需重新上麦 |
| 被拒（本方拒绝） | N/A（未进入通话） | 未离开，无需恢复 | 保持原麦位 |

### 5.4 关键注意事项

- 恢复后麦位**不会自动恢复到通话前的位置**，主播需手动重新上麦
- 通话中收到的公屏消息在 `PartyRoomVM` 中正常通过 NIM 聊天室监听接收，回到 Party Activity 后通过 `LiveEventBus` 回放
- 美颜 (FaceUnity) 需要 `releaseBeauty` 后再 `initBeauty`，因为 engine 可能因频道变更而失效（CaptureMode.Agora 绑定 mRtcEngine 实例）

---

## 6. 相机 & 视频位 & 美颜资源抢占

### 6.1 Party 房视频位在私 call 期间被释放

| 步骤 | 文件:行号 | 操作 |
|------|-----------|------|
| 释放美颜 | `RtcEngineManager.kt:234-241` | `mFaceUnityApi.release()` + `FURenderKit.getInstance().release()` |
| 停止预览 | `RtcEngineManager.kt:229-231` | `mRtcEngine.stopPreview()` |
| 下麦（角色切换） | `RtcEngineManager.kt:52-54` | `setClientRole(AUDIENCE)` |
| 关闭麦克/摄像头 | `PartyRoomDataManager.kt:712-713` | HTTP `updateMedia` 通知服务端 |

### 6.2 美颜 Pipeline

```
FaceUnityBeautySDK (CaptureMode.Agora，与 call 共用)
   ↓
mFaceUnityApi = createFaceUnityBeautyAPI()
   ↓
initialize(Config(ctx, mRtcEngine, FURenderKit, CaptureMode.Agora, ...))
   ↓
mFaceUnityApi.setupLocalVideo(textureView, RENDER_MODE_HIDDEN)
   ↓
mRtcEngine.startPreview()
```

### ⚠️ 时序关键点

- 释放时机：**在 joinCall 之前**释放美颜，避免两个场景争抢同一个 mRtcEngine
- 恢复时机：**在 onCallEnd → initBeauty 重新创建** FaceUnity API
- FURenderKit 会被二次初始化（`PartyRoomDataManager → initBeauty` vs `ShengWang1V1CallActivity → initBeauty`）
- **不会**同时有两个 FURenderKit 实例，因为每次先 release 再 create

### 📌 iOS 接入参考

- 参考 `.claude/rules/swiftui-camera-preview.md §5` — sharedEngine 复用 setChannelProfile 显式切换
- 参考 §9 — 跨场景 sharedEngine sink 与 pushFrame 快照
- 参考 §3 — CameraManager subscribers 字典 key 冲突
- 注意 FURenderKit 二次初始化时的 500ms setup timeout（参考 `.claude/rules/legacy-threshold-reeval.md`）

---

## 7. NIM 通道复用分析

**结论：Party 房聊天室保持 login，与私 call 并行。**

### 7.1 两条独立 NIM 通道

| 通道 | 用途 | 生命周期 |
|------|------|----------|
| 聊天室 (ChatRoom) | Party 房公屏消息、麦位通知、送礼通知、1029 私 call 状态 | 进房 login → 离房 exit（私 call 期间保持） |
| P2P + 推送 | CallApi 来电信令、shengwang RTC 信令 | 全局维持，与聊天室无关 |

### 7.2 私 call 期间聊天室行为

- 聊天室**不退**：`PartyRoomVM.exitYxChatRoom()` 仅在离房时调用，私 call 流程中不触发
- 消息仍然接收：`PartyRoomVM.handleIncomingChatRoomMsgList` 通过 NIM observer 持续接收，只是 UI 因 `LibApp.isCalling` 守卫不更新麦位（`PartyRoomDataManager.postMikeList:1192`）
- 恢复后刷新麦位：`onCallEnd` 中 `postMikeList(mMikeList)` 重新推送缓存麦位到 UI

### 7.3 断线重连

- NIM 聊天室由 SDK 内部自动重连，`PartyRoomVM.onlineStatus` 监听重连状态
- 重连成功后 `mLoadMikeList = true` → `PartyRoomDataManager.loadMikeList()` 刷新麦位

### 📌 iOS 接入参考

iOS 路线图提到 "F PartyCall NIM 通道接入时抽 SharedNIMSession"——从安卓看：
- 两条通道**物理上独立**（聊天室 vs P2P），iOS 可以公用一个 NIM SDK 实例
- 不需要"独立 NIM session"，只需确保聊天室 login 在私 call 期间不被意外 exit
- "抽公共时机"指的是通话模块的 P2P 消息收发应抽成通用组件，Party 和 Call 模块共用

---

## 8. 来电优先级 / 互斥 / 交叉场景

### 8.1 边界场景覆盖矩阵

| 边界场景 | 安卓行为 | 源码依据 |
|----------|----------|----------|
| **直播态下收到派对房来电** | `PartyRoomDataManager` 仅在 Party 房创建时注册 ICallApiListener。直播态由 `LiveCallActivity` 独立处理来电，不走 Party 房分支 | 两个 Activity 各自注册 ICallApiListener，不会冲突 |
| **Party 房内收到非 PartyCall 类型来电** | `callerType != 5` → 延迟 1s 自动 `callApi.reject(fromUserId, reason)`。注意：只判断 `callerType != 5`，不检查其他 callerType 值 | `PartyRoomDataManager.kt:669-676` |
| **私 call 通话中被踢出 Party 房** | 聊天室收到 1003 (KICKED_OUT_PARTY_ROOM) → finish PartyRoomActivity + 销毁悬浮窗。但通话界面 (ShengWang1V1CallActivity) 不受影响——通话仍继续 | `PartyRoomVM.kt:461-489` |
| **私 call 通话中 Party 房被解散** | 聊天室收到 1009 (REMOVE_ROOM_WHITE_LIST) 或房间关闭通知 → finish PartyRoomActivity + 销毁悬浮窗。通话界面不受影响 | `PartyRoomVM.kt:501-508` |
| **私 call 通话中弱网 → forceEnd** | Agora RTC `onConnectionStateChanged` → `CONNECTION_STATE_FAILED` → CallActivity 结束通话 → 发 `EVENT_1V1_CALL_END` → `PartyRoomDataManager.onCallEnd()` 重新加入 Party 频道 | `RtcEngineManager.kt:1517-1524`（Party 侧）；CallActivity 自行处理通话侧弱网 |
| **私 call 与 PartyBattle 同时触发** | PartyBattle 在 `PartyBattleController` 中独立管理。如果 Battle 正在进行时收到来电：① `queryPartyCall` 先判断 `LibApp.isCalling == false` ✓ ② `handlePartyCallIncoming` 进入 ③ Battle 状态仍在，但主播已离开 RTC 频道 → 服务端 Battle 可能继续或 forceEnd。**结论：无显式互斥，依赖时序先后；可能产生不一致** | `PartyRoomDataManager.kt:662`；`PartyBattleController.kt` |
| **私 call 开关关闭时来电** | **后端拦截**：客户端只在接收端被叫。如果房主/主播关闭了 `partyPrivateCallOpen`，后端 `queryCall` 不会返回 `callerType==5`。客户端无额外拦截逻辑 | `PartyRoomDataManager.kt:654-688`（仅依赖后端返回的 callerType） |
| **App 在后台时收到 PartyCall 来电** | `appForeground == false` → 拒绝来电。不处理后台来电抢占 | `PartyRoomDataManager.kt:662` |
| **当前已在通话中（isCalling=true）收到来电** | `LibApp.isCalling == true` → 拒绝来电。不处理并行通话 | `PartyRoomDataManager.kt:662`；`ShengWangCallUtils.kt:113-115` |

### 8.2 优先级结论

- **无显式优先级机制**：完全依赖 `LibApp.isCalling` + `callerType` 时序判断
- **先到先得**：如果 PartyBattle 先开始，私 call 也会抢占（Battle 被中断）；如果私 call 先开始，PartyBattle 无法触发（isCalling 拦截）
- **PartyBattle 与 私 call 互斥建议**：iOS 端应显式加互斥守卫——Battle 进行中 或 私 call 进行中 时禁止另一个启动

---

## 附录 A：核心文件清单

| 模块 | 文件 | 行数 | 职责 |
|------|------|------|------|
| partyroom | `manager/PartyRoomDataManager.kt` | 1545 | 房间状态单例；ICallApiListener 来电监听；onCallEnd 恢复 |
| partyroom | `manager/RtcEngineManager.kt` | 344 | Agora RTC 引擎 + FaceUnity 美颜管理 |
| partyroom | `viewmodel/PartyRoomVM.kt` | 1349 | NIM 聊天室消息处理；1029 分发 |
| partyroom | `page/activity/PartyRoomActivity.kt` | ~2600 | 主界面；1029 事件监听；私 call 开关 UI |
| partyroom | `page/dialog/PartyPrivateCallSettingDialog.kt` | 221 | 私 call 设置弹窗（开关+礼物选择） |
| partyroom | `http/ApiService.kt` | 534 | Retrofit 接口声明（含 updatePartyPrivateCall 等） |
| partyroom | `http/HttpHelper.kt` | ~1080 | API 封装（updatePartyPrivateCall / getPartyCallGiftList） |
| partyroom | `entity/PartyRoomInfo.kt` | 77 | 房间实体（含 partyPrivateCallOpen / partyCallGiftId 等字段） |
| call | `agora/service/ShengWangCallUtils.kt` | 155 | 声网 1v1 通话工具（joinCall / createCall） |
| call | `agora/service/CallServiceManager.kt` | ~450 | CallApi 实例管理（callApi 初始化/销毁/IPrepareCallListener） |
| call | `agora/ui/ShengWang1V1CallActivity.kt` | ~2500 | 1v1 通话界面（含 isPartyCall / partyCall source 分支） |
| common | `nim/NIMMsgAttachType.java` | 468 | NIM 自定义消息类型常量（含 1029 双重定义） |
| common | `Const.java` | ~445 | 全局常量（EVENT_1V1_CALL_END / UPDATE_PARTY_ROOM_BUBBLE 等） |
| library | `app/LibApp.java` | ~35 | 全局状态（isCalling / partyRoomId / partyRoomSeatIndex） |
| library | `helper/LiveEventConstant.kt` | ~160 | 事件常量（EVENT_PARTY_CALL_NOTIFY 等） |

---

## 附录 B：API 完整清单

| API | Method | Path | 模块 |
|-----|--------|------|------|
| 查询来电类型 | POST | `api/call/record/v2/queryCall` | common |
| 加入通话 | POST | （Base64 编码 URL） | call |
| 更新私 call 设置 | POST | `sapi/weidou/v1/client/party/room/updatePartyPrivateCall` | partyroom |
| 获取可选礼物列表（设置用） | POST | `sapi/weidou/v1/client/party/room/getPartyCallGiftList` (scene=2) | partyroom |
| 获取可选礼物列表（通话用） | POST | `sapi/weidou/v1/client/party/room/getPartyCallGiftList` (scene=1) | partyroom |
| 进入 Party 房 | POST | `sapi/weidou/v1/client/party/room/enter` | partyroom |
| 离开 Party 房 | POST | `sapi/weidou/v1/client/party/room/exitRoom` | partyroom |
| 上麦 | POST | `sapi/weidou/v1/client/party/seat/onSeat` | partyroom |
| 下麦 | POST | `sapi/weidou/v1/client/party/seat/downSeat` | partyroom |
| 更新媒体状态 | POST | `sapi/weidou/v1/client/party/seat/updateMedia` | partyroom |

---

> Generated with Claude Code · DM-20260616-004 · 2026-07-14
