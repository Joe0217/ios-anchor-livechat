# 01 - 1对1 视频/语音通话模块（主播端）

> 适用范围：iOS(Swift) 原生重建参考。本文基于真实源码梳理，覆盖通话状态机、信令时序、计费、假人通话、异常重连。
> 关键事实先行：**通话信令走 Agora RTM（点对点 USER 消息），音视频走 Agora RTC；NIM(云信) 仅作"辅助心灵"旁路同步（提示/UI/收益统计），不承担通话核心信令**。当前代码 audio call（CallAction.AudioCall=10）有类型定义，但消息分发 switch 中 `AudioCall` 分支为空（仅 `// TODO: audio call` 注释，无对应接收方法），实际只跑视频通话。

---

## 一、模块概述

主播端通话能力由一套**自研封装的 CallApi SDK**（`src/callApi/`，仿声网官方 CallAPI 设计）+ **编排层 `src/use/useCallApi.js`**（1900 行，同时承载直播逻辑，需拆分）驱动。

三个并行的双向信道：
1. **Agora RTM**（`CallRtmMessageManager`）—— 呼叫/接受/拒绝/挂断/取消的**主信令**，点对点 USER 通道，消息体为 `ICallMessage` JSON（UTF-8 编码为 Uint8Array）。
2. **Agora RTC**（`rtcClient`，mode=rtc / codec=h264）—— 音视频媒体面，加入频道、发布/订阅轨道、首帧解码、网络质量。
3. **NIM 自定义系统消息**（`customP2p`，`attachType` 分发）—— 旁路：对端 IM 在线探测、UI 提示文案、每分钟收益/礼物收益推送、充值等待蒙层、关注通知等。**与 RTM 信令冗余但不是信令本身**。

通话 UI 由 `App.vue` 根据 `appStore.appState` / `matchState` / `fakeUserCallStore.callStatus` 顶层条件渲染三类全屏覆盖层：待接听（`g-waitingCall`）、通话中（`g-faceTime`）、假人通话（`g-fakeUserCall/*`）。

通话场景分四类（`CALL_FRONT_GAME_TYPE_NUMBER`）：
- DIRECT(1) 直接拨打/被拨打
- MATCH(2) 匹配通话
- LIVE(3) 直播间转私聊（私call）
- BOT(4) 机器人/假人通话（**不走 RTC/RTM，纯本地播放预录视频 + 接口上报**）

---

## 二、页面与入口

### 2.1 通话覆盖层（全局挂载于 App.vue，非路由页）
| 组件 | 条件 | 作用 |
|------|------|------|
| `g-waitingCall.vue` | `matchState !== MATCHING_CALLING && appState in (calling, callConnecting)` | 待接听/拨出等待界面：头像、昵称、30s 倒计时圆环、接听/拒接按钮 |
| `g-faceTime/index.vue` | `appState === 'connected' && !isLiving` | 通话中主界面：远端视频全屏、本地美颜画中画、公屏弹幕、发消息、索要礼物、反馈、收入条 |
| `g-faceTime/topBar.vue` | 通话中顶部 | 主播信息、计时器、通话收入/礼物收入、充值等待倒计时、通话异常自检弹窗 |
| `g-fakeUserCall/callPopup.vue` | `fakeUserCallStore.callStatus === 1` | 假人来电弹窗（30s 倒计时、接听/拒接） |
| `g-fakeUserCall/fakeFaceTime.vue` | `callStatus === 2` | 假人通话中（播放预录 `fileUrl` 视频 + 计时） |
| `g-fakeUserCall/endCallPopup.vue` | `showRobotFinish` | 假人通话结束奖励弹窗 |

### 2.2 拨出入口
- **`c-callButton.vue`**：通用拨打按钮组件（首页列表/用户详情/私聊/关注列表均复用）。点击 → 校验美颜已初始化、直播结束 5s 冷却、对端在线状态(`sessionStore.getOnlineStatus`)→ 调 `openLocalCameraAndeMic('callOut', userInfo, path)`。
- 在线状态码：1=在线可呼，2=忙碌，3=离线，10000=其他状态（非明确忙碌，可能包含未知/异常，UI 层一般归并到不可呼）。

### 2.3 通话记录页（路由页）
- `src/views/communication/index.vue`：Records / Following / Followers / Friends 多 Tab（swiper）。
- `records/list.vue` + `typeTag.vue` + `recordsStatus.vue`：通话记录列表（接口 `getRecord` → `/api/chat/v4/getCallRecord`，含时长/类型/在线状态/价格）。

---

## 三、功能点清单（穷尽）

### 3.1 拨出（主叫）
1. 点击拨打 → `openLocalCameraAndeMic('callOut')` 先开本地摄像头+麦克风+美颜 → `handleStartCallOut`。
2. `apiCreateCall`(`/api/call/record/v2/createCall`) 创建通话拿 `channelId / yxAccid / videoPrice / 用户资料`。失败处理：`the user is currently unavaliable` → 忙线/离线提示。
3. `handleCallAnchor` → `callApi.prepareForCall({roomId: channelId})` → `callApi.call(remoteUserId)`。准备失败重试 1 次（重新 `initCallApi`），再失败当本地取消。
4. 进入 `g-waitingCall`，30s 倒计时（组件内 `overtime=30`），超时走 `callOff('autoend')` → 拨出态调 `callOutCancel()`、来电态调 `callInCancel()`（`overtime` 是组件本地常量，与 store 的 `callTimeOutNum=30` 同值但相互独立）。
5. 等待期间可点拒接按钮 → `callOutCancel`。
6. 计时器 `handleActiveCallInterval`（`activeCallCount`）。

### 3.2 被叫（来电）
1. RTM 收到 `VideoCall` → `_receiveVideoCall` → 状态 calling/remoteVideoCall。
2. `callStateChanged(calling, remoteVideoCall)` 回调里：打开本地相机、设 `callInOrOut='in'`、`callTagPath='userdirectcall'`、`joinCallGetUserInfo(roomId)` 拉对端资料、播放系统来电铃声、上报 `h_inccall_view`。
3. `joinCallGetUserInfo`：`apiJoinCall`(`/joinCall`，3s 超时当异常) 拉资料 + 进场座驾动画(`apiGetLiveAnimation`) + NIM 回发 ONLINE(0)。
4. 进入 `g-waitingCall`（带接听按钮），30s 超时自动结束。
5. 接听 `answerCall` → `callInEnter` → `callApi.accept`；拒接 `callInCancel` → `callApi.reject`。
6. **直播私call/匹配通话自动接听**：`joinCallGetUserInfo` 中若 `liveState in (living, liveCalling)` 或 `matchState===MATCHING_CALLING` 直接 `callInEnter()`，接听前先 `livingEnd(false)` 暂停直播、若 PK 惩罚中先 `endPunishment`。

### 3.3 通话中
- 远端视频全屏 + 本地美颜画中画（`beautyCameraOnPIP`），点屏幕切换清屏(`isShowAll`)。
- 公屏弹幕 `MessageScroller`（`homeStore.talkListInCall`），本地发消息（NIM `sendImMsg`，attachType -1，带翻译/昵称/等级/气泡）。
- 收远端文本（attachType -1，调 `translateText` 翻译后入队）、收远端礼物（attachType 4，触发 svga/mp4 动画或漂浮图片）。
- 索要礼物：`askFor`（15s 冷却倒计时），收到拒绝（attachType 16）Toast。
- 收入条：通话收入(attachType 15 累加)、礼物收入(attachType 18 累加)。
- 切前后置摄像头 `switchCamera`、静音 `toggleAudioMute`。
- 反馈弹窗 `c-feedbackPopup`。
- 远端视频画中画 `g-remote-pip`（`remotePIPShowState`：locked/unlocked/close）。
- 充值等待蒙层（见 4.4）。

### 3.4 通话异常自检（topBar）
- 每 10s `tenSecondsCB`：`checkRemoteIsJoined()` 失败→弹"用户离线"；`connectionStateIsConnected()` 失败→弹"网络不稳定不计费"。
- `secondsToZero`：通话 >120s 且收入仍为 0 → 弹收入异常。
- 异常弹窗"End Call / Continue"，确认即 `handleCallOff('end')`。

### 3.5 挂断/结束
- 本地挂断 `callHangup(LOCAL_HANG_UP)` → `finishAndUpdateCall(HANG_UP)` + `handleCallOver` + NIM HANG_UP(3) + `callApi.hangup`。
- 远端挂断（RTC user-left 或 RTM Hangup）→ 状态回 prepared/remoteHangup。
- 通话结束 `g-faceTime` 卸载时上报 `h_videocall_fns`。

### 3.6 假人/机器人通话（独立链路）
- NIM attachType 133 → `handleFakeUserCall`：仅在一级页、非忙碌、匹配已结束、美颜就绪、上一通结束 >10s 时受理 → `callStatus=1` 弹来电。
- 接听 `apiFakeUserCallIn`(`/hostCallVirtualUser`，isAnswered=1) → `callStatus=2` 播放预录视频；同时 `beginLiveOpenByFakeUserCall` 用声网云录屏开播推流。
- 通话中自动挂断：`duration >= autoHangupTime`；手动挂断需 ≥10s。
- 挂断 `apiFakeUserCallOut`(`/hostCallOverVirtualUser`) + `endLiveOpenByFakeUserCall` 下播。
- NIM attachType 132 → 结束奖励弹窗 `endCallPopup`（达标显钻石奖励）。

---

## 四、业务逻辑与规则

### 4.1 通话状态机（CallApi 内部，`CallStateType`）

CallStateType 完整枚举（`src/callApi/types/index.ts:58-71`，共 6 个值）：

```
idle(0) → prepared(1) → calling(2) → connecting(3) → connected(4) ；failed(10)
```

- `prepareForCall` → prepared
- `call`(主叫) / 收到 VideoCall(被叫) → calling
- `accept`/收到 Accept → connecting
- `_checkAppendView`（收首帧/不等首帧）→ connected
- 任意挂断/取消/拒绝/超时/远端离开 → 回 prepared（destory 后）
- `failed(10)` 用于不可恢复异常（join RTC 失败等），与正常流终态分离
- `isBusy = calling | connecting | connected`

状态变更原因 `CallStateReason`（关键）：localVideoCall(30)/remoteVideoCall(32)/remoteAccepted(7)/remoteHangup(10)/remoteCancel(12)/remoteRejected(6)/remoteCallBusy(17)/callingTimeout(14)/recvRemoteFirstFrame(13)。

**前端业务状态机** `CALL_GAME_STATUS_NUMBER`（myCallStore.currentCallInfo.callGameStatus，`src/constant/call.ts:36-43`）：
INIT(0) → CALLING(1) → CALLING_ING(3 通话中) → HANG_UP(4) / CANCEL(2) / TIMEOUT(5)。这是编排层对 CallApi 状态的二次封装，用于幂等防重（已 HANG_UP/CANCEL 不再处理）。

### 4.2 信令时序（RTM 主信令）

消息体 `ICallMessage`：`{ message_version:'1.0', message_timestamp, callId(uuid), remoteUserId, fromUserId, message_action, fromRoomId, rejectReason?, rejectByInternal?, cancelCallByInternal? }`。`CallAction`：VideoCall=0 / Cancel=1 / Accept=2 / Reject=3 / Hangup=4 / AudioCall=10。

**拨出时序（主叫=主播）**：
```
主播: prepareForCall(roomId=channelId) → call()
  → callInfo.start() / setCallId(uuid) / 状态 calling(localVideoCall)
  → _autoCancelCall(true) 启动超时定时器
  → _rtcJoinAndPublish()  (创建美颜轨道 + join channel + publish)
  → RTM publish VideoCall 给对端
对端接受 → RTM 回 Accept → _receiveAccept → 状态 connecting(remoteAccepted) → _checkAppendView → connected
对端 RTC user-published → subscribe → 播放远端流 / first-frame-decoded → connected
```

**被叫时序（被叫=主播，用户来电）**：
```
RTM 收 VideoCall → _receiveVideoCall
  → 校验 _isCallingUser；并发保护：若已有 callFrontGameType/callStartTime 直接 return
  → setCallId / remoteUserId / roomId=fromRoomId
  → _autoCancelCall(false) / 状态 calling(remoteVideoCall)
  → (autoAccept 时直接 accept)
主播点接听 accept()
  → 状态 connecting(localAccepted) / callInfo.add('acceptCall')
  → RTM publish Accept + _rtcJoinAndPublish + _checkAppendView
```

**取消/拒绝/挂断**：均为"先改本地状态 + RTM publish 对应 action + destory()"并行。
- 忙线自动拒绝：收到非当前通话用户的 VideoCall → `_autoReject`（Reject + rejectByInternal=Internal）→ 对端识别为 remoteCallBusy。
- 超时：`_autoCancelCall` 定时器（`callTimeoutMillisecond = callTimeOutNum*1000 = 30s`），到点若仍 calling/connecting → publish Cancel(cancelByInternal=Internal) + destory，事件 callingTimeout/remoteCallingTimeout。

**RTC 端事件**（`_listenRtcEvents`）：user-joined（记录远端入频道）、user-left（忙碌中→destory+remoteHangup）、user-published（subscribe+播放，更新 `remoteTrackState`）、user-unpublished、network-quality（2s 一次）、client-banned/connection-state-change（UID_BANNED/IP_BANNED → 强制下播 `isCompelLiveEnd='3'`）。

### 4.3 NIM 辅助信令（旁路，`message.js onSysMsg` 按 attachType 分发）

发送：`sendCustomSysMsg(yxId, roomId, type)` → `attach={attachType:-3, channelId, type}`，type 取 `CALL_NIM_TYPE_NUMBER`：ONLINE='0' / REJECT='1' / CANCEL='2' / HANG_UP='3' / CONNECTED='4'。
- 接通时（connected）发 CONNECTED(4)；接听/拒接/挂断/取消时各发对应 NIM 消息。

接收（call 相关）：
| attachType | 说明 | 处理 |
|---|---|---|
| -3 (内嵌 type) | 通话控制旁路 | type 0=对端 IM 在线探测（校验 `channelId === targetChannelId` 后置 `targetIMStatus`）；1=对端拒绝 Toast；2=对端取消（**源码处理被刻意注释**，统一交 RTM，仅占位防双链路重复）；3=对端挂断（置 `hangupReason`，状态机处理也被注释，仅弹 Toast 与回写原因，统一交 RTM） |
| -1 | 远端发来文本 | 解码+翻译入 talkListInCall |
| 4 | 远端送礼 | 入 talkListInCall 触发动画 |
| 15 | 每分钟预估收入 | `callIncome += attach.num` |
| 18 | 礼物预估收入 | `callGiftIncome += attach.num` |
| -6 | 充值等待状态 | `callWaitState = attach.type`（见 4.4） |
| 90 | 用户充值成功 | `callWaitBonus/Total` 累加，`callWaitState=PAY_SUCCESS` |
| 83 | 私call进场座驾动画 | 播放进场动画 |
| 133/132 | 假人来电/结束 | 见 3.6 |
| 61/62/44 | 直播合规警告/封禁/强制下播 | 直播相关 |

> 源码 `src/stores/modules/message.js:703-753` 中 `-3` 旁路的 case 2（远端取消）与 case 3（远端挂断）实际状态机处理被**刻意注释掉**——统一交 RTM 在 `useCallApi` 的 `callStateChanged` 处理，避免双链路重复触发挂断/取消。NIM 仅负责弹 Toast、同步 `hangupReason`、回写 `targetIMStatus`。

### 4.4 计费逻辑

**核心：客户端不直接扣费，扣费在用户端/服务端。主播端只接收收益推送 + 上报接通率/时长。**
- 收入实时显示：NIM attachType 15（每分钟通话收益累加 `callIncome`）、18（礼物收益累加 `callGiftIncome`），topBar 展示 `giftIncomeTotal = callIncome + callWaitBonusTotal`。
- **接通率/计费节点上报 `callRate`**(`/api/chat/callRate`)，参数：`channelId, callType(1被叫/2主叫), category(1接听/2拒接/3超时未接/4取消), answerTime(秒), userType(1用户/2主播), abnormal(0/1)`。在每个状态切换点调用（接通=category1、拒接=2、超时=3、取消=4）。**超时分支 `answerTime` 硬编码为 30（非真实等待秒数，源码 `src/use/useCallApi.js:544`）**，iOS 复刻接通率漏斗时必须保持同样的 30 秒口径，否则后台统计断裂。
- 历史扣费接口存在但通话主流程已注释：`apiBeginCall`(`/beginCallV2`)、`callDeductionFee`(`/callDeductionFee` 心跳)、`apiCallOver`(`/callOver`)、`apiMissCall`(`/missCall`) —— iOS 重建时确认服务端是否仍依赖。
- **充值等待蒙层（计费暂停机制）**：用户余额不足时服务端推 NIM -6（`callWaitState`=START_PAY '1' / CALL_TIME_END '3' / PAY_CANCEL '4'，全集见 `src/constant/call.ts:55-60`，PAY_CANCEL 表示用户撤销充值）→ topBar 锁定远端画中画(`REMOTE_PIP_SHOW_STATE.LOCKED`)、暂停计时(`callStopTime`)、起 `call_wait_time`(默认60s)倒计时，兜底续时 5s 仍未充值则自动 `handleClose('end')` 强制挂断（源码 `topBar.vue:140-148`），iOS 最长等待时长 = waitingTimeConfig + 5。用户充值成功推 90/PAY_SUCCESS '2' → 补偿暂停时长到 `callingStartTime`、解锁、弹钻石奖励弹窗。
- `videoPrice`：通话原价，createCall/joinCall 返回，仅展示。
- 直播私call 5 分钟横幅：`After ~300s, call income per minute = your call price`（`g-faceTime` `streamerCountdown`）。

### 4.5 通话时长口径
- `callStartTime`：拨出/待接通起始（用于接通率 answerTime）。
- `callConnectTime`：开始连接声网时间。
- `callingStartTime`：正式进入通话房间时间（`g-faceTime` onMounted 设，计时器/结束上报 dura 基准）。
- `getDuration(ts)` 计算秒数。

### 4.6 加解密约定（请求/响应链路）

`src/utils/crypto.js:17-38` 实现的 AES-128 CBC 加解密走**不对称的输出/输入格式**：

- **加密**：`aesHexEncrypt(data, ...)` 实际返回的是 `CryptoJS` 默认的 OpenSSL Base64 字符串（`encrypted.toString()`，注释中预留的 Hex 输出被注掉）。函数名带 `Hex` 仅是历史命名，**实际输出 Base64**。
- **解密**：`aesHexDecrypt(encryptedHex, ...)` 入参是 Hex 字符串，先用 `CryptoJS.enc.Hex.parse` 还原 `ciphertext`，再解密；解密后尝试 `JSON.parse`，失败则原样返回字符串。

KEY/IV 通过 `validateKey` 严格校验 16 字节，缺省值取 `VITE_AES_KEY` / `VITE_AES_IV`。iOS 复刻时务必遵守"出 Base64、进 Hex"的不对称约定，否则与后端互通会断链；若 iOS 端需要统一 Hex 双向，须同步推动后端约定。

#### 三套密钥/算法对照（iOS 必读）

主请求/响应链路之外，主播端还有两套独立算法散落在心跳与启动参数解密里，iOS 须按用途选用：

| 用途 | 算法 | key | 编码 |
|------|------|-----|------|
| 主请求体上行 | AES-128-CBC | VITE_AES_KEY | Base64 |
| 主响应体下行 | AES-128-CBC | VITE_AES_KEY | Hex |
| 心跳 WebSocket | AES-128-**ECB** | 硬编码 `9976kk4322578894` | Hex |
| openParams/webParams 解密 | AES-CBC | `VITE_AES_KEY` 兜底 `9986sdff5s4f1123` | Hex（`aesHexDecrypt`） |

其中心跳专用算法定义在 `utils/index.js encryptAes`：key 固定 `9976kk4322578894`（16 字节 UTF-8），**模式 ECB**（无 IV，传入的 iv 参数被忽略）、PKCS7 padding，输出 `encrypted.ciphertext.toString()`（裸 ciphertext 的 Hex，无盐前缀），iOS 上报心跳必须用此套，与主请求体的 CBC/Base64 互不通用。

---

## 五、数据与接口

### 5.1 API（`src/api/call/index.ts` 等）
| 函数 | URL | 用途 |
|---|---|---|
| `apiGetAgoraRtmToken` | `/api/index/getAgoraRtmToken` | 取 rtcToken+rtmToken（万能token，channel空） |
| `apiCreateCall` | `/api/call/record/v2/createCall` | 拨出创建通话，返回 channelId/yxAccid/videoPrice/资料 |
| `apiJoinCall` | `/api/call/record/v2/joinCall` | 加入/拉对端信息 |
| `apiBeginCall` | `/api/call/record/v2/beginCallV2` | 开始通话(主流程已注释) |
| `apiCallOver` | `/api/call/record/v2/callOver` | 结束通话(已注释) |
| `apiMissCall` | `/api/call/record/v2/missCall` | 未接(已注释) |
| `callDeductionFee` | `/api/call/record/v2/callDeductionFee` | 通话心跳扣费(已注释) |
| `callRate` | `/api/chat/callRate` | **接通率/计费节点上报(主用)** |
| `getRecord` | `/api/chat/v4/getCallRecord` | 通话记录列表 |
| `missedCallsReport` | `/api/chat/missedCallsReport` | 未接来电上报 |
| `forwarding` | `/api/anchor/callForwarding` | 呼叫转移 |
| `callEvaluation` / `getComment` / `apiGetFeedbackType` / `apiGetCallBadLabel` | `/api/chat/V2/callEvaluation`、`/api/chat/getComment`、`/api/chat/getFeedbackType`、`/api/chat/getCallLabel` | 通话评价/好评差评标签 |
| `apiHasExceededCallLimit` | `/api/user/hasExceededCallLimit` | 主播通话限制策略 |
| `apiFakeUserCallIn` | `/api/homeTraffic/hostCallVirtualUser` | 假人来电接听/挂断上报 |
| `apiFakeUserCallOut` | `/api/homeTraffic/hostCallOverVirtualUser` | 假人通话结束上报 |
| `apiGetLiveAnimation` | `/api/live...` | 进场座驾动画 |
| 匹配 `getStartMatch`/`getMatchList`/`getStartMatchRobot`/`toggleMatch`/`getMatchCanOpen` | `/api/match/v3/match`、`/api/match/pool/matchList`、`/api/match/userReqMatchRobot`、`/api/match/pool/open`、`/api/match/pool/isOpen` | 匹配/匹配池/匹配机器人 |

### 5.2 Pinia Store
- **`myCall.js`(useMyCallStore)**：核心。`rtcToken/rtmToken/callTimeOutNum(30)`、`currentCallInfo`(全字段见源码：callGameType/callInOrOut/callEscObj/callFrontGameType/callGameStatus/callUserId/videoPrice/channelId/yxAccid/各时间戳/targetChannelId/targetIMStatus/hangupReason/callIncome/callGiftIncome/remoteTrackState/callWaitState/callWaitBonus(Total))、`lastCallInfo`、`showVideoCallAgora/showAgoraLive/cameraFlag`。Actions：`initCurrentCallInfo` / `updateOverCallInfo`(转存 lastCallInfo 并重置) / `handleGetAgoraRtmToken`。仅持久化 `lastCallTime`。
  - **`targetChannelId` + `targetIMStatus` 双层验证**：源码 `src/stores/modules/myCall.js:33-34` 定义，`message.js:712-715` NIM `attachType=-3` case 0（对端 IM 在线探测）会先校验 `attach.channelId === targetChannelId` 再更新 `targetIMStatus`（1=双方在线），避免上一通残留消息污染当前通话状态。iOS 复刻 NIM 旁路时须保持同样的"通道+在线态"双字段配对。
- **`fakeUserCall.js`**：`fakeUserCallInfo/callStatus(0未开始/1推送/2接听/3结束)/endCallInfo/startCallTime/endCallTime`，`hangupCall`/`setCallStatus`。
- 关联：`appStore`(appState/liveState/matchState/isBusy/isFakeUserCalling/nim)、`beautyStore`(美颜相机/PIP)、`giftStore`、`homeStore`(talkListInCall)、`liveStore`、`audioStore`(铃声)、`sessionStore`(在线状态/会话标记)。

### 5.3 NIM attachType（call 域）
见 4.3 表。发送侧 `CALL_NIM_TYPE_NUMBER`(0-4) 嵌 attachType -3；充值类 `CALL_PAY_NIM_TYPE_NUMBER`(1发起/2成功/3计时暂停/4取消) 嵌 attachType -6。

### 5.4 Agora SDK 用法
- RTC：`createClient({mode:'rtc',codec:'h264'})`、`join/leave/publish/unpublish/subscribe`、事件 user-joined/left/published/unpublished/network-quality/token-privilege-will-expire/connection-state-change/client-banned。轨道：`createMicrophoneAndCameraTracks` + 美颜 canvas `captureStream` → `createCustomVideoTrack`。
- RTM：`new RTM(appId, uid, {presenceTimeout:5,heartbeatInterval:10})` → `login` → `publish(uid, Uint8Array, {channelType:'USER'})`、事件 message/status/token 续期。
- 直播复用同一 callApi（`_startLive`），另有 `rtcLivingClient`(mode:live,codec:vp9,role:host)、`rtcOtherLiveClient`(role:audience) 用于客态看播。

---

## 六、依赖的 SDK 与原生能力

1. **Agora RTC SDK**（音视频，h264 硬编优先）— iOS 用 AgoraRTCKit。
2. **Agora RTM 2.x**（信令）— iOS 用 AgoraRtmKit；注意 2.1.10 用 `status` 事件无 linkState。
3. **NIM 云信 IM SDK**（系统消息旁路、聊天室）。
4. **NamaSDK(相芯) 美颜** + MediaPipe/face-api 人脸检测 — H5 走 canvas+Worker+MediaStreamTrackProcessor 链路，iOS 应直接用相芯原生 SDK 接 RTC 自定义视频源（见 MEMORY 原生集成事实）。
5. 原生能力：相机/麦克风权限、系统来电铃声播放、前后置切换、安全区适配、保活/后台音视频。

---

## 七、边界与异常处理

- **RTM 重连大脑 `useRtmReconnect`**：3 次快速重试(1s/2s/4s) → 失败后 5s 慢重试不止；token 失效(-10005/-10026)刷新 token 后重连；掉线(-10002/-11024/-11026/-11028)直接重连。**不弹窗不主动挂断**，UI 决策交 topBar 自检。同 uid 异地登录 → 强制登出。
  - **RTM 重连静默 vs topBar 自检弹窗职责分离**：RTM 重连过程对用户完全静默（不弹窗）；但 topBar 每 10s 自检 `checkRemoteIsJoined()` 与 `connectionStateIsConnected()` 仍会按规则弹「用户离线 / 网络不稳定不计费」异常窗——两套异常处理职责独立（一个是"信令链路自愈"，一个是"通话体验异常告警"），iOS 复刻须分清边界，不要让重连过程意外触发自检弹窗，也不要让自检接管重连。
- **相机/麦克风错误** `_handleMediaPermissionError`：映射 `CameraErrorMessage`（PERMISSION_DENIED 等），忙碌中设 `beautyErrorMsg`，否则 Toast；上报 `cameraError`。视频轨/美颜轨 `ended` 事件经 AbortController 监听。
- **并发保护**：被叫已通话中再来电直接 return；忙线自动拒绝(Internal busy)；prepareForCall 在 connecting/connected 先 destory，其余 busy 抛错。
- **状态幂等**：`callGameStatus` 防重复挂断/取消；`channelError`(channelId 不匹配)校验。
- **超时**：拨打 30s 自动结束；joinCall 3s 超时当异常。
- **首帧**：`firstFrameWaittingDisabled:true`（收 accept/点 accept 即视为接通，不等首帧，弱网下可能黑屏）。
- **CallApi 初始化失败**：`handleCallAnchor` prepare 失败重试 1 次重新 initCallApi，再失败当本地取消。
- **RTM 消息管理器生命周期**：`rtmClient` 跨通话复用，每通话 new `CallRtmMessageManager` 前必须 `destroy()` 旧实例，否则监听器泄漏 N 倍回调（源码重点注释）。
- **资源清理**：destory 关闭 audio/video/beauty 轨道、leave 频道、清定时器、清 view、reset callInfo。
- **设备分档**：`resolveCallEncoderConfig` 按 HIGH/MID/LOW 三档（统一 540p，fps 24/24/15，bitrate 1500/1000/800）降负缓解发烫。

---

## 八、iOS 重建注意事项

1. **信令归属务必厘清**：通话核心走 **Agora RTM 点对点**，NIM 只是旁路同步/UI/收益。iOS 必须实现 RTM 的呼叫/接受/拒绝/挂断/取消/忙线自动拒绝六类消息收发与状态机，NIM 旁路可选但收益推送(15/18)、充值等待(-6/90)、假人(132/133)、座驾动画(83)需对接。
2. **状态机双层**：底层 CallApi 状态(idle→prepared→calling→connecting→connected，外加 failed 不可恢复终态) + 业务层 callGameStatus(防重幂等)，建议 iOS 用单一状态机 + 显式 guard 合并，避免 H5 这种双层易错结构。
3. **计费在服务端/用户端**：主播端不扣费，只上报 `callRate` 接通率节点 + 展示 NIM 推送收益。务必复刻 callRate 的 category/callType/userType/abnormal 语义；超时分支 `answerTime=30` 是硬编码常量，iOS 复刻保持一致，否则后台漏斗统计断裂。
4. **充值等待蒙层**是易漏复杂点：计时暂停 + 画中画锁定 + 兜底续时 + 充值成功补偿时长 + 钻石奖励，时序敏感。
5. **假人通话是独立链路**：不连 RTC/RTM，本地播放预录 `fileUrl` 视频 + 声网云录屏开播 + 三个接口上报；受理条件严格（一级页/非忙/匹配结束/美颜就绪/距上通>10s）。
6. **音频通话半实现**：`CallAction.AudioCall=10` 常量存在（`src/callApi/types/index.ts:365-372`），发送侧可用；但接收方 switch 分支为空（`src/callApi/core/callApi.ts:397-399` 仅 `// TODO: audio call` 注释，无对应接收方法）。结论：**发送可用、接收无处理**，整链路实际只跑视频通话。iOS 要做语音通话需补全接收侧分支与对应音频轨配置。
7. **首帧策略**：H5 因美颜 canvas 链路用 `firstFrameWaittingDisabled:true` 不等首帧。iOS 原生 RTC 接相芯可考虑恢复等首帧以避免接通黑屏。
8. **直播与通话共用 callApi 实例**：直播私call 接听前 `livingEnd(false)` 暂停直播保留 callId/remoteUserId（destory(false)），通话结束回直播。iOS 设计需保留"直播↔通话"切换的会话连续性。
9. **超时/重连阈值**：拨打超时 30s、RTM 重试 1s/2s/4s+5s、joinCall 3s、假人来电 30s、索礼冷却 15s、假人最短通话 10s、直播结束拨打冷却 5s。
10. **token**：rtcToken/rtmToken 同接口下发(万能token)，RTC `token-privilege-will-expire` 与 RTM token 续期都要处理。
11. **编码档位**：按设备分档 H264 540p，iOS 可直接用硬编 + 相芯输出，无需 H5 的 canvas captureStream 妥协方案。
12. **加解密互通**：H5 端 `aesHexEncrypt` 实际输出 Base64、`aesHexDecrypt` 输入 Hex（见 4.6）。iOS 加解密层需对齐这种不对称约定，或与后端协商统一格式后两端同步调整。

---

### 关键源码文件索引
- `src/callApi/core/callApi.ts`（状态机/RTC/轨道/信令核心）、`callMessage.ts`、`callInfo.ts`、`types/index.ts`
- `src/callApi/messageManager/rtm.ts`、`base.ts`（RTM 信令通道）
- `src/use/useCallApi.js`（编排层，含拨出/接听/挂断/计费上报/直播）
- `src/use/useRtmReconnect.js`（重连）、`src/use/useMatch.js`、`src/use/useCallRobot.js`
- `src/stores/modules/myCall.js`、`fakeUserCall.js`、`message.js`(onSysMsg attachType 分发)
- `src/api/call/index.ts`、`type.ts`、`src/api/match/`、`src/api/datePreview/`
- `src/constant/call.ts`（全部枚举）
- `src/components/global/g-waitingCall.vue`、`src/components/g-faceTime/*`、`src/components/g-fakeUserCall/*`、`src/components/common/c-callButton.vue`
- `src/views/communication/*`
- `src/utils/crypto.js`（AES 加解密：出 Base64、进 Hex）

---

## 九、通用组件与基建补遗（整合）

> 本章补齐前述章节未单列的通话覆盖层子组件、远端画中画细节、代理拦截、假人通话 UI、RTM 信令重连大脑、补齐枚举、匹配防作弊、拨号动作按钮等。来源：阅读 `components/g-faceTime/*`、`components/g-fakeUserCall/*`、`components/global/*`、`components/common/*`、`use/useRtmReconnect.js`、`use/useMatch.js`、`constant/call.ts`、`constant/match.ts`、`constant/rtmMonitor.ts`。

### 9.1 待接听 / 通话内子组件

#### 9.1.1 g-waitingCall 本地 30s 倒计时与圆环
- 文件：`src/components/global/g-waitingCall.vue`
- 关键逻辑：
  - `overtime=30` 为组件本地常量（与 store `callTimeOutNum` 同值但独立）；`van-circle` 进度速率 `100/overtime`。
  - 超时 → `callOff('autoend')` + Toast `${nickname} no response`。
  - 来电态（`callInOrOut==='in'`）才显示接听按钮；接听 `answerCall` 先 `beautyStore.setShowCamera(true)` 再 `callInEnter`。
  - 埋点：`h_inccall_reject` / `h_inccall_end`（type=hangup/autoend/reject）/ `h_inccall_asnwer`，均带 `dura`（等待时长）。
  - `onMounted` 设 `callStartTime=Date.now()`，作为接通率 `answerTime` 基准，与 4.5 计时口径一致。

#### 9.1.2 充值等待提示横幅（waitRechargeTips + waitRechargeLock）
- 文件：`src/components/g-faceTime/waitRechargeTips.vue`、`waitRechargeLock.vue`
- 关键逻辑：
  - `Teleport to="body"`，fixed 40vh，毛玻璃；锁/解锁双头像（lock/unlock 不同图标）。
  - 奖励钻石数读 `appStore.AppConfig.call_config.anchor_call_balance_reward_on_low`（默认 100）。
  - 倒计时 `time` 由父级（topBar 计费暂停机制）传入，是 4.4 节充值等待状态机的 UI 层落地。

#### 9.1.3 通话公屏弹幕样式分支（messageScroller）
- 文件：`src/components/g-faceTime/messageScroller.vue`（与 `liveSetting/components/messageScroller.vue` 同名但不同实现）
- 关键逻辑：
  - `item.giftImg` → 礼物缩略图 + 数量；
  - `item.chatBubble` → `border-image` 自定义气泡 URL 单行；
  - 否则默认气泡，有 `content.translated` 时 `<hr>` 分隔原文与译文两行；本人 `user==='her'` 与对端不同色。

#### 9.1.4 收入展示行（topBarIncome）
- 文件：`src/components/g-faceTime/topBarIncome.vue`（纯展示：图标 + 数字 + 钻石图标，通话/待接顶部通用收入小组件）。

#### 9.1.5 直播私 call 进场动画层（livingCallAnimation）
- 文件：`src/components/g-faceTime/livingCallAnimation.vue`
- 关键逻辑：CSS rotateAndMove 1s，双头像中心对撞，用于直播转私聊的过场动画。

#### 9.1.6 匹配人脸检测异常弹窗（noFacePop）
- 文件：`src/components/g-faceTime/noFacePop.vue`
- 关键逻辑：`v-model:show` 控制，`close-on-click-overlay=false`，文案 `faceRecognition.face not detected`，仅"确认"关闭；属于美颜/人脸检测的 UI 兜底。

### 9.2 远端画中画补充

- 文件：`src/components/global/g-remote-pip.vue`
- 关键逻辑：
  - **不重新订阅流**，而是直接从 `REMOTE_VIEW_ELEMENT.querySelector('video').srcObject`（MediaStream）赋给 PIP `<video>`（复用远端主视图的流）。
  - 默认位置 `defaultX = 视宽 - 100*(视宽/375) - 12`，`van-floating-bubble` 支持 xy 拖拽。
  - `remotePIPShowState` 为 LOCKED/CLOSE → 隐藏并 `clearPIPVideo`（srcObject=null + pause + load 重置）；其余态 nextTick 重建流。
  - 点击 PIP（非隐藏态）→ `beautyStore.beautyCameraOnPIP=true`（切回本地美颜大图）。
  - 隐藏态遮罩：CLOSE 显示"关闭摄像头"图标；UNLOCKED/其它显示"Recharging..." 动图。
  - iOS 注意：从直播私 call 切入时 video 元素可能不存在（源码 `console.error('未找到 video 元素')` 兜底）。
- 与 4.4 节充值等待状态机配对：充值锁定期间三态遮罩驱动 UI；iOS 复刻 PIP 时务必复用而非新建视频流。

### 9.3 代理账号登录拦截

- 文件：`src/components/global/g-agencyLoginPop.vue`，触发 `userStore.isAgency` 为真（App.vue 顶层）。
- 关键逻辑：`close-on-click-overlay=false`，唯一按钮 `Sign out` → `isAgency=false` + `appStore.logOut()`。文案固定英文「请用代理 App 登录」。
- iOS 复刻要点：代理账号（userType=9）命中即弹不可关闭弹窗，仅允许登出，与正常通话/直播流程互斥。

### 9.4 假人通话子组件

#### 9.4.1 假人来电弹窗（callPopup）
- 文件：`src/components/g-fakeUserCall/callPopup.vue`
- 关键逻辑：
  - **30s 本地倒计时**到 0 自动挂断；接听 `useThrottleFn 3000ms` 防重、挂断同样节流。
  - `onMounted` 即 `beginLiveOpenByFakeUserCall`（弹窗出现就开始云录屏推流，不等接听）；挂断/失败 `endLiveOpenByFakeUserCall`。
  - 埋点 `anchor_event`：`offical_robot_popup_show` / `_click`(btn=Answer/Reject)，带 video_id/record_id。
  - 接听后 `beautyStore.isHidden=false` + `setShowCamera(true,false)`。

#### 9.4.2 假人通话结束奖励弹窗（endCallPopup）
- 文件：`src/components/g-fakeUserCall/endCallPopup.vue`
- 关键逻辑：按 `endCallInfo.type` 区分达标（Congratulations + 奖励钻石数 + 高时长背景图）与未达标（Keep it up + 短时长背景图）两套 UI；埋点 `offical_robot_reward_show` / `_noReward_show`；时长 `formatSeconds(callTime,'mm:ss')`。

### 9.5 RTM 信令重连机制

`agora-rtm 2.1.10` 的信令层重连状态机，是七章 RTM 重连大脑的展开实现，与 RTC 音视频网络监控两套独立：

- 文件：`src/use/useRtmReconnect.js`
- 关键逻辑：
  - **快速重试**：延迟 `[1000, 2000, 4000]`（累计 7s 覆盖瞬时抖动）。
  - **慢重试**：快速用尽后 5000ms/次后台无限重试。
  - **token 主动续期**：TTL 24h、提前 30s 续；被动监听 `tokenPrivilegeWillExpire` 与 `status=token expired`（宽松大小写匹配）。
  - **致命态 SAME_UID_LOGIN**：账号被同 UID 顶替 → 延迟 500ms 触发外部登出（给埋点 flush 留窗口，否则 reload 取消 in-flight 丢点）。
  - **浏览器事件驱动**：`online` / `visibilitychange=visible` → 重置计数立即重连；`offline` → SUSPENDED。
- 重连状态枚举 `RTM_RECONNECT_STATE`（同文件）：`IDLE / CONNECTING / CONNECTED / RECONNECTING（快速重试）/ DISCONNECTED（慢重试）/ SUSPENDED（离线后台）`。
- 埋点常量（`src/constant/rtmMonitor.ts` + `utils/rtmMonitor.ts`）：
  - 事件：`rtm_login / rtm_reconnect / rtm_fatal`，统一走 `reportShuShuCustomEvent('c_log', { eventName, ... })`。
  - 自动注入上下文：userId / roomId / callId / net（wifi|4g|unknown，从 `navigator.connection` 推断）/ online / visible。
  - 运行时关闭开关：`window.__rtmMonitor.setEnabled(false)`。
  - FATAL reason：`login_max_retries / send_message_fatal / same_uid_login`。

### 9.6 通话/匹配枚举常量

通话核心枚举集中在 `src/constant/call.ts`（4.1 节已展开 CallStateType/CALL_GAME_STATUS_NUMBER），此处补齐其它常用枚举：

#### 9.6.1 通话场景与状态（call.ts）
- **CALL_GAME_TYPE_NUMBER**（接口侧字符串）：DIRECT `'1'` / MATCH `'2'` / MATCH_POOL `'3'` / LIVE `'4'`
- **CALL_FRONT_GAME_TYPE_NUMBER**（前端数字）：DIRECT 1 / MATCH 2 / LIVE 3 / BOT 4
- **CALL_ANCHOR_STATUS_NUMBER**：LIVE -1 / ONLINE 1 / BUSY 2 / OFFLINE 3 / OTHER 10000
- **CALL_NIM_TYPE_NUMBER**（云信信令 type）：ONLINE `'0'` / REJECT `'1'` / CANCEL `'2'` / HANG_UP `'3'` / CONNECTED `'4'`
- **CALL_PAY_NIM_TYPE_NUMBER**（attachType -6 嵌套）：START_PAY `'1'` / PAY_SUCCESS `'2'` / CALL_TIME_END `'3'` / PAY_CANCEL `'4'`
- **CALL_OVER_REASON_NUMBER**（通话结束原因 1~11）：本地挂断/远端挂断/用户余额不足/心跳失败/扣费余额不足/用户弱网/主播弱网/扣费失败/用户被踢/beginCall 报错/并发取消
- **CALL_ANCHOR_ALL_LV_NAME**：1=S 2=A 3=B 4=C 5=D 6=F 7=SS 8=NEW（注意与 `useUserLevelHooks` 的 0-7 图标索引是两套不同口径，iOS 勿混用）
- **REMOTE_PIP_SHOW_STATE**：`locked` / `unlocked` / `close`（远端画中画显隐三态，对应 9.2 节）

#### 9.6.2 匹配枚举（match.ts）
- **MATCH_STATE**：`matching` / `matchingCalling` / `matchingEnded` / `matchingLeft`
- **MATCH_POPUP_SHOW_TIME**：10 分钟（匹配弹窗展示时长）

### 9.7 useMatch 匹配防作弊

- 文件：`src/use/useMatch.js`
- 关键逻辑：
  - **随机人脸检测时间数组**：生成 3 个递增随机秒数（首个 2-23s，后续间隔 ≥3s，上限 30s），用于匹配中随机抽检是否真人。
  - **canvas 截图取证**：`captureCanvasScreenshot` 把当前画面转 jpeg(0.8) 上传 OSS（无脸时取证 `match_no_face.jpeg`）。
  - **当天首开判断**：localStorage `match_today_date` 按 `YYYY-M-D` 记录，控制每日首次匹配引导。
- iOS 复刻要点：随机抽检节奏与截图取证是合规链路，必须保留；本地标记按账号维度迁移到 `UserDefaults`。

### 9.8 通话动作型按钮（拨打/接听/开播）

通话发起前的统一动作按钮，封装多重前置校验。

#### 9.8.1 拨打按钮（前置校验链）
- 文件：`src/components/common/c-callButton.vue`
- 校验顺序：
  1. 美颜未初始化（`beautyStore.inited` 为 false）→ toast `beautySetting.Beauty wait`，不拨打。
  2. **直播结束 5 秒内禁止拨打**（`Date.now() - liveStore.liveStartTime < 5000`）→ toast 等待，避免相机未释放。
  3. 取对端在线状态 `getOnlineStatus`：仅 `1`（在线）才拨打；`2/10000` 提示 is busy，其余 is not online。
  4. 匹配中（`matchState===MATCHING`）主动拨打 → 置 `MATCHING_LEFT`（中途离开匹配池）。
  5. 调 `openLocalCameraAndeMic('callOut', userInfo, path)`，上报 `h_outcall_view`（userlvl 来源因页面而异）。
- iOS 复刻要点：「美颜就绪 + 直播结束冷却 5s + 在线态校验 + 匹配状态切换」四道前置校验必须完整复刻。

#### 9.8.2 联系按钮组（聊天 + 视频，含权限控制）
- 文件：`src/components/common/c-communication-btns.vue`（聚合 `c-goToChat` + `c-callButton`）
- 关键逻辑：`showVideo='true'` 强制显示视频按钮；`'auto'`（默认）按 `userStore.anchortCallAuth` 主播通话权限决定是否显示。
- iOS 复刻要点：视频按钮可见性受主播 callAuth 权限位控制。

#### 9.8.3 跳聊天按钮（埋点来源透传）
- 文件：`src/components/common/c-goToChat.vue`
- 关键逻辑：点击前把 `trackAnchorStart` 写入 `useSessionStore().trackAnchorStart`，再 `router.push('/chat', { to, taPath, path })`。
- iOS 复刻要点：聊天来源埋点需在跳转前落到全局态。

#### 9.8.4 开播按钮（权限码分支）
- 文件：`src/components/common/c-goLive.vue`
- 关键逻辑：先 `checkIMOnline()`；匹配中置 `MATCHING_LEFT`；调 `checkLiveBroadcastPermission`：
  - code `2001` 无直播权限 → 弹自定义「Go Live!」遮罩（文案来自 message）。
  - code `1992` 直播被禁 → 解析 message.keyword 弹 alertDialog 警告。
  - 正常 → 首播去 `/liveRule?type=3`，否则 `/liveSetting`。
  - 按钮图按语言切换（`setLanguageImg` ar/en）。
- iOS 复刻要点：2001/1992 两个业务码分支与首播引导跳转规则需保留。
