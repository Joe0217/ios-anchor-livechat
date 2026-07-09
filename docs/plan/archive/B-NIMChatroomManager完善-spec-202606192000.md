# Hily B 里程碑 · B-NIMChatroomManager 完善 spec

> 关联：
> - 路线图：`iOS主播端-全量上线里程碑路线图-202606191532.md` §三 B 公屏闭环
> - 二次校验：`B-spec-H5安卓代码二次校验-202606192000.md`
> - 兄弟 spec：`B-LiveStore状态机-spec-202606192000.md` §12 对外接口契约（v3 已补 `adjustOnlineCount(by:)` + §2.5 优先级仲裁）
> - 现状基线：`Sources/Live/NIMChatroomManager.swift`（139 行）
>
> **范围**：B 里程碑 13 项 P0 缺口中的 NIMChatroomManager 一项 + 4 处子项
>
> **修订记录**：
> - v1 2026-06-19 初稿
> - v2 2026-06-19 按 3 角度对抗 review 修订（4 阻塞 + 9 一般）：NIMSDK API 真实命名（grep header 验证）/ forceEnd 多源优先级仲裁 / setupOnce 不重复 add delegate / GiftAnimationQueueProtocol 引入 / onRecvMessages 拆 sub-func / @MainActor 隔离注释 / payload 字段 ⚠️ 待确认标注 / 埋点子分类

---

## §1 H5/安卓代码二次校验引用

直接引用 `B-spec-H5安卓代码二次校验-202606192000.md`。关键事实补充：

- **NIMSDK 10.10.0 真实 API**（v2 grep `Pods/NIMSDK_LITE/.../Headers/` 验证）：
  - `NIMChatroomConnectionState`：4 态 `Entering(0) / EnterOK(1) / EnterFailed(2) / LoseConnection(3)`
  - `NIMCustomAttachment` 协议方法：`- (NSString *)encodeAttachment;`（不是 `encode`）
  - 注册 decoder API：`+ (void)NIMCustomObject.registerCustomDecoder:(id<NIMCustomAttachmentCoding>)decoder;`（**类方法**，不是 `NIMSDK.shared().register(...)`）
  - `NIMCustomAttachmentCoding` 协议方法：`- (id<NIMCustomAttachment>)decodeAttachment:(NSString *)content;`
  - delegate `chatroom(_:connectionStateChanged:)` 真实签名
- **attachType 既有字符串也有数字**：H5 `'SEND_GIFT'` 是字符串、`4/15/18` 是数字。iOS 解析时**先尝试 Int，再尝试 String**
- **NIMNotificationObject.content** 类型：`NIMNotificationContent` 协议；聊天室场景 cast 为 `NIMChatroomNotificationContent` 后读 `eventType`（`.enter/.exit`）+ `ext`（额外字段）
- **共享 MessageDispatcher 抽象时机**：路线图 §五"NIMMessageDispatcher | E 完成后"——B **不抽** Dispatcher，直接 switch attachType

---

## §2 NIMChatroomManager 角色调整

### 2.1 onlineCount 字段所属转移

| 现状 | 目标 | 理由 |
|---|---|---|
| `NIMChatroomManager.@Published var onlineCount: Int` (`L16`) | **LiveStore.@Published var onlineCount: Int** | 兄弟 spec §2.3 已定义；避免双源 |

NIMChatroomManager 持有 `weak var liveStore: LiveStore?`，进出房消息通过 `liveStore?.adjustOnlineCount(by:)` / `setOnlineCount(_:)` 写入。

### 2.2 messages 字段保留

`messages: [ChatMessage]` 继续由 NIMChatroomManager 持有——公屏 UI 直接 `@ObservedObject` 绑定。

公屏队列是 UI 数据流；LiveStore 是业务状态——两者正交。

### 2.3 NIMChatroomManager 构造

```swift
@MainActor
final class NIMChatroomManager: NSObject, ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var connected = false
    @Published var reconnecting = false                          // §3 新增

    weak var liveStore: LiveStore?                               // §2.1 上行 callback
    weak var giftAnimationQueue: GiftAnimationQueueProtocol?     // §7.3 H 钩子（B 阶段为 nil）
    private weak var analytics: AnalyticsClient?

    private var roomId = ""
    private var cachedNickname = ""                              // §3.3 重连需要
    private var enterAttemptCount = 0
    private static var didSetup = false

    private let complianceParser: ComplianceMessageParser
    private let giftParser: GiftMessageParser
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "Chatroom")
}
```

### 2.4 与 LiveStore 的契约（调用方向）

```
LiveStore  ──(enter/leave 命令)──>  NIMChatroomManager
NIMChatroomManager  ──(adjustOnlineCount / setOnlineCount / warn / forceEnd / markBoostingExposure)──>  LiveStore
NIMChatroomManager  ──(messages @Published)──>  LiveRoomView（UI 绑定）
```

**消歧**：NIMChatroomManager **永不直接调** `LiveService.endLiveRoom` —— 强制下播一律通过 `liveStore.forceEnd(reason:)`（兄弟 spec §2.5 CAS + §2.5b 优先级仲裁保证仅最高优先级源触发一次接口）。**反之** LiveStore 自身用户主动下播路径（兄弟 spec §10.1）仍直接调 `LiveService.endLiveRoom(endType: 1)`。

---

## §3 connectionStateChanged 重连

### 3.1 NIMChatroomConnectionState 枚举（NIMSDK 真实定义）

```swift
// NIMChatroomManagerProtocol.h L136-152
public enum NIMChatroomConnectionState: NSInteger {
    case Entering        = 0       // 进入中
    case EnterOK         = 1       // 进入成功
    case EnterFailed     = 2       // 进入失败
    case LoseConnection  = 3       // 失去连接
}
```

> **v1 误写为 5 态 unknown/connecting/connected/unconnected/disconnected——已纠错为真实 4 态**（grep NIMSDK header 验证）

### 3.2 状态机响应（替换现状 `L136-138` 空回调）

```swift
extension NIMChatroomManager: NIMChatroomManagerDelegate {
    func chatroom(_ roomId: String, connectionStateChanged state: NIMChatroomConnectionState) {
        guard roomId == self.roomId else { return }
        logger.info("NIM chatroom state: \(state.rawValue)")
        switch state {
        case .EnterOK:
            connected = true
            reconnecting = false
            enterAttemptCount = 0
            pushSystem(L10n.imChatroomReconnected)               // 公屏「已重连」
        case .Entering:
            reconnecting = true
            pushSystem(L10n.imChatroomReconnecting)
        case .EnterFailed:
            connected = false
            reconnecting = false
            scheduleReenter()                                    // §3.3
        case .LoseConnection:
            connected = false
            reconnecting = false
            scheduleReenter()                                    // §3.3
        @unknown default:
            break
        }
    }
}
```

回调在 main thread（NIMSDK 保证）；NIMChatroomManager 已 `@MainActor` 隔离（§2.3），直接读写 @Published 字段无需 `DispatchQueue.main.async` 包裹。

### 3.3 重连策略：1s/2s/4s 三连退避，>3 次失败 → forceEnd

```swift
private func scheduleReenter() {
    guard !roomId.isEmpty else { return }                        // 已 leave 不重连
    enterAttemptCount += 1
    if enterAttemptCount > 3 {
        analytics?.track("im_reconnect_failed",                  // §11 埋点子分类
                         properties: ["roomId": roomId])
        Task { @MainActor in
            await liveStore?.forceEnd(reason: .disconnected)     // endType=4 走兄弟 spec §12
        }
        return
    }
    let delay = pow(2.0, Double(enterAttemptCount - 1))          // 1, 2, 4 秒
    Task { [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        await MainActor.run {
            guard let self, !self.roomId.isEmpty else { return }
            self.enterChatroom(roomId: self.roomId, nickname: self.cachedNickname)
        }
    }
}
```

**`cachedNickname` 字段**：`enter(...)` 调用时缓存到 `self.cachedNickname` 供重连使用（avoid 调用方丢失 nickname 上下文）。

### 3.4 埋点子分类

`im_reconnect_failed` 与 HeartbeatController 的 `heartbeat_failed` 区分——两者均最终触发 endType=4，但运维需要拆分定位（公屏服务 vs 业务心跳服务）：

| 来源 | 埋点 key | 触发条件 |
|---|---|---|
| 公屏重连 | `im_reconnect_failed` | NIM 进房失败累计 >3 次 |
| 业务心跳 | `heartbeat_failed` | `/api/agora/liveHeartBeatV2` 连续失败 >3 次 |

`endType=4` 写入后端时附带 `subSource` 字段区分（implement 阶段后端确认 key 名）。

### 3.5 IM 长连接重登（B 不实现）

`NIMSDK.shared().loginManager` 自带断网重连；NIMChatroomManager 仅处理聊天室级别 reconnect。IM 登录态由 `NIMLoginManagerDelegate.onLogin` 监听归 C 里程碑 RTM 重连大脑统一抽象。

---

## §4 leave 复位

### 4.1 现状 (`L81-88`)

```swift
func leave() {
    guard !roomId.isEmpty else { return }
    NIMSDK.shared().chatManager.remove(self)
    NIMSDK.shared().chatroomManager.remove(self)
    NIMSDK.shared().chatroomManager.exitChatroom(roomId, completion: nil)
    roomId = ""
    connected = false
}
```

### 4.2 补全

```swift
func leave() {
    guard !roomId.isEmpty else { return }
    let exitId = roomId
    NIMSDK.shared().chatManager.remove(self)
    NIMSDK.shared().chatroomManager.remove(self)
    NIMSDK.shared().chatroomManager.exitChatroom(exitId, completion: nil)
    roomId = ""
    cachedNickname = ""
    connected = false
    reconnecting = false
    enterAttemptCount = 0
    messages.removeAll()                                          // 公屏清空
    liveStore?.setOnlineCount(0)                                  // 通知 LiveStore 复位
    liveStore = nil
}
```

`exitChatroom(_:completion:)` 非 await 返回；不阻塞 leave。LiveStore.teardown 调 `nim.leave` 后即 await endLiveRoom——leave 失败不阻塞下播流程。

---

## §5 LiveCustomAttachment（自定义 attachment 解析层）

### 5.1 NIMCustomAttachment 协议（真实方法名 `encodeAttachment`）

```swift
final class LiveCustomAttachment: NSObject, NIMCustomAttachment {
    let attachType: AttachType
    let payload: [String: Any]

    init(attachType: AttachType, payload: [String: Any]) {
        self.attachType = attachType
        self.payload = payload
    }

    // NIMCustomAttachment 协议真实方法（grep NIMCustomObject.h L43）
    func encodeAttachment() -> String {
        let dict: [String: Any] = ["attachType": attachType.raw, "data": payload]
        guard JSONSerialization.isValidJSONObject(dict),         // CLAUDE.md NSNull 守卫
              let data = try? JSONSerialization.data(withJSONObject: dict),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }
}
```

> v1 误写 `encode()`——v2 已纠错为 `encodeAttachment()`（grep `NIMCustomObject.h:43` 验证）

### 5.2 AttachType 枚举（B 阶段子集）

```swift
enum AttachType: Equatable {
    // ─── 合规/强制（B 里程碑必须识别）─────────
    case forceEndLive            // 44 — 强制下播
    case complianceWarning       // 61 — 合规警告 toast
    case banned                  // 62 — 封禁下播
    case boostingExposure        // 63 — 进折扣池

    // ─── 礼物（B 阶段解析占位，H 接动画）──
    case sendGift                // 'SEND_GIFT' 字符串 / 数字 1
    case liveCallGift            // 4 — 通话/直播礼物
    case backpackGift            // 15 — 背包礼物
    case privilegeGift           // 18 — 特权礼物

    // ─── 未识别 ──────────────────────────────
    case unknown(raw: String)

    var raw: String {
        switch self {
        case .forceEndLive: return "44"
        case .complianceWarning: return "61"
        case .banned: return "62"
        case .boostingExposure: return "63"
        case .sendGift: return "SEND_GIFT"
        case .liveCallGift: return "4"
        case .backpackGift: return "15"
        case .privilegeGift: return "18"
        case .unknown(let raw): return raw
        }
    }

    init(raw: Any?) {
        // 先尝试 Int，再尝试 String（H5/安卓字段两种形态）
        if let n = (raw as? NSNumber)?.intValue {
            switch n {
            case 1: self = .sendGift
            case 4: self = .liveCallGift
            case 15: self = .backpackGift
            case 18: self = .privilegeGift
            case 44: self = .forceEndLive
            case 61: self = .complianceWarning
            case 62: self = .banned
            case 63: self = .boostingExposure
            default: self = .unknown(raw: "\(n)")
            }
            return
        }
        if let s = raw as? String {
            switch s {
            case "SEND_GIFT": self = .sendGift
            default: self = .unknown(raw: s)
            }
            return
        }
        self = .unknown(raw: "nil")
    }
}
```

> **故意不识别 attachType=50**：B-spec H5/安卓二次校验已确认 50 双端无 file:line 证据，B 阶段不实现，归入 `.unknown` 仅 logger 留痕。

### 5.3 Decoder + 注册（NIMCustomObject 类方法）

```swift
final class LiveCustomAttachmentDecoder: NSObject, NIMCustomAttachmentCoding {
    // NIMCustomAttachmentCoding 协议真实方法（grep NIMCustomObject.h L99-131）
    func decodeAttachment(_ content: String?) -> NIMCustomAttachment? {
        guard let content,
              let data = content.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let attachType = AttachType(raw: dict["attachType"])
        let payload = (dict["data"] as? [String: Any]) ?? [:]
        return LiveCustomAttachment(attachType: attachType, payload: payload)
    }
}

// NIMChatroomManager.setupOnce 内：
static func setupOnce() {
    guard !didSetup else { return }
    didSetup = true
    let option = NIMSDKOption(appKey: AppConfig.nimAppKey)
    NIMSDK.shared().register(with: option)
    NIMCustomObject.registerCustomDecoder(LiveCustomAttachmentDecoder())   // ← 类方法，全局注册仅一次
}
```

> **v1 误写为 `NIMSDK.shared().register(decoder, for: messageType)` + setupOnce 中 add 自身为 delegate**——v2 已纠错：
> - 注册 API 是 `NIMCustomObject.registerCustomDecoder(_:)`（类方法），无 `messageType` 参数
> - setupOnce **不 add 自身**（self 是 static 上下文无效）；delegate 注册仍在 `enter(...)` 内（`L36-37`）的 `NIMSDK.shared().chatManager.add(self)`，避免重复 add

---

## §6 ComplianceMessageParser（44/61/62/63 → LiveStore action）

### 6.1 入口（方法级 @MainActor 隔离）

```swift
struct ComplianceMessageParser {
    weak var liveStore: LiveStore?
    let logger: Logger

    /// 方法级 @MainActor 隔离：调用方需在 main actor 上下文 await（onRecvMessages 已 @MainActor）
    /// 返回 true 表示已处理；false 表示需要继续走礼物 Parser
    @MainActor
    func parse(_ attachment: LiveCustomAttachment) async -> Bool {
        switch attachment.attachType {
        case .forceEndLive:        // 44
            logger.warning("NIM attachType=44 force end live")
            await liveStore?.forceEnd(reason: .disconnected)        // endType=4
            return true
        case .complianceWarning:   // 61
            let msg = (attachment.payload["content"] as? String) ?? L10n.complianceWarningDefault
            // ⚠️ payload key "content" 待 §12 后端样本确认
            liveStore?.warn(message: msg)                           // 3s toast
            return true
        case .banned:              // 62
            logger.warning("NIM attachType=62 banned")
            await liveStore?.forceEnd(reason: .banned)              // endType=2
            return true
        case .boostingExposure:    // 63
            let enabled = ((attachment.payload["status"] as? NSNumber)?.intValue ?? 0) == 1
            // ⚠️ payload key "status" 待 §12 后端样本确认
            liveStore?.markBoostingExposure(enabled)
            return true
        default:
            return false
        }
    }
}
```

### 6.2 接 LiveStore §12 入口对照

| attachType | Parser action | LiveStore 入口（兄弟 spec §12） | 副作用 |
|---|---|---|---|
| 44 | `await liveStore.forceEnd(.disconnected)` | `forceEnd(.disconnected)` → tryEnterForceEnding CAS + §2.5b 优先级仲裁 | endLiveRoom(endType=4) |
| 61 | `liveStore.warn(message:)` | `warn(message:)` → 设 warningToast 3s | UI 顶部条幅 toast |
| 62 | `await liveStore.forceEnd(.banned)` | `forceEnd(.banned)` → CAS + 仲裁 | endLiveRoom(endType=2) |
| 63 | `liveStore.markBoostingExposure(enabled)` | `markBoostingExposure(_:)` | 字段更新（H 接 UI） |

**多源 forceEnd 优先级仲裁**（兄弟 spec §2.5b 新增）：
`banned > noPermission > cameraFailure > weakNetwork > disconnected` —— 同时收到 1992（banned/2）+ NIM 44（disconnected/4），endType 取 banned/2（最高优先级），文案稳定可复现。

### 6.3 payload 字段约定（待后端确认）

| attachType | payload key | 类型 | 默认值 | 状态 |
|---|---|---|---|---|
| 61 | `content` | String | `L10n.complianceWarningDefault` | ⚠️ 待 dev 真实样本对齐 |
| 63 | `status` | Int (0/1) | 0 | ⚠️ 待 dev 真实样本对齐 |
| 44/62 | （无业务字段） | — | — | ✅ 仅 attachType 触发 |

字段名 H5/安卓双端确认后再锁；implement 阶段后端抓包对齐。

---

## §7 GiftMessageParser（SEND_GIFT + 1/4/15/18 → 公屏占位 + H 钩子）

### 7.1 解析模型

```swift
struct GiftMessage {
    let giftId: Int
    let giftName: String
    let giftCount: Int
    let diamond: Int
    let senderName: String
    let senderAvatar: URL?
    let receiverName: String?
    let attachType: AttachType
}
```

### 7.2 Parser 实现

```swift
struct GiftMessageParser {
    let logger: Logger

    func parse(_ attachment: LiveCustomAttachment) -> GiftMessage? {
        switch attachment.attachType {
        case .sendGift, .liveCallGift, .backpackGift, .privilegeGift:
            break
        default:
            return nil
        }
        let p = attachment.payload
        return GiftMessage(
            giftId: (p["giftId"] as? NSNumber)?.intValue ?? 0,
            giftName: (p["giftName"] as? String) ?? "",
            giftCount: (p["giftCount"] as? NSNumber)?.intValue
                       ?? Int((p["giftCount"] as? String) ?? "") ?? 1,    // String→Int 容错
            diamond: (p["diamond"] as? NSNumber)?.intValue ?? 0,
            senderName: (p["senderName"] as? String) ?? "",
            senderAvatar: (p["senderAvatar"] as? String).flatMap(URL.init),
            receiverName: p["receiverName"] as? String,
            attachType: attachment.attachType
        )
    }
}
```

### 7.3 GiftAnimationQueueProtocol（H 钩子，B 注 nil mock）

```swift
protocol GiftAnimationQueueProtocol: AnyObject {
    func enqueue(_ gift: GiftMessage)
}
```

NIMChatroomManager 持有 `weak var giftAnimationQueue: GiftAnimationQueueProtocol?`（§2.3）。

B 阶段：`giftAnimationQueue = nil` —— `enqueue` 调用空跑，仅公屏文本占位。
H 阶段：注入真实 `GiftAnimationPlayer`，承接 SVGA+MP4 队列。

### 7.4 B 阶段渲染策略（仅文本占位）

NIMChatroomManager 调用方：

```swift
if let gift = giftParser.parse(attachment) {
    let text = "\(gift.senderName) \(L10n.sendGiftAction) \(gift.giftName) × \(gift.giftCount)"
    push(text, system: false)
    giftAnimationQueue?.enqueue(gift)                       // B 为 nil，H 接管
}
```

### 7.5 字段缺失容错

- `giftId == 0` → 渲染占位 + logger.warning（后端数据脏）
- `giftCount` 缺失 → 默认 1
- `senderName` 缺失 → 显示 `L10n.anonymous`

不抛错——单条礼物消息缺字段不应中断公屏流。

---

## §8 onRecvMessages 分发改造（含 sub-func 拆分）

### 8.1 NIMNotificationContent 类型澄清

`m.messageObject as? NIMNotificationObject` → `obj.content as? NIMChatroomNotificationContent`：
- `eventType: NIMChatroomEventType` 取 `.enter` / `.exit` 等
- `ext: String?` 额外业务字段（B 不消费）

### 8.2 主入口 + 拆 sub-func（保持 <50 行）

```swift
extension NIMChatroomManager: NIMChatManagerDelegate {
    func onRecvMessages(_ messages: [NIMMessage]) {
        var items: [ChatMessage] = []
        var delta = 0

        for m in messages {
            guard m.session?.sessionType == .chatroom else { continue }
            switch m.messageType {
            case .text:
                items.append(parseText(m))
            case .custom:
                dispatchCustom(m)
            case .notification:
                handleNotification(m, items: &items, delta: &delta)
            default:
                break
            }
        }

        guard !items.isEmpty || delta != 0 else { return }
        for it in items { push(it.text, system: it.isSystem) }
        if delta != 0 {
            liveStore?.adjustOnlineCount(by: delta)
        }
    }

    private func parseText(_ m: NIMMessage) -> ChatMessage {
        let name = m.senderName ?? ""
        let body = m.text ?? ""
        return ChatMessage(text: name.isEmpty ? body : "\(name)：\(body)", isSystem: false)
    }

    private func dispatchCustom(_ m: NIMMessage) {
        guard let obj = m.messageObject as? NIMCustomObject,
              let attachment = obj.attachment as? LiveCustomAttachment else {
            logger.warning("custom message without LiveCustomAttachment")
            return
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let handled = await self.complianceParser.parse(attachment)
            if !handled, let gift = self.giftParser.parse(attachment) {
                self.push(self.formatGiftLine(gift), system: false)
                self.giftAnimationQueue?.enqueue(gift)
            } else if !handled {
                self.logger.info("unhandled attachType: \(attachment.attachType.raw)")
            }
        }
    }

    private func handleNotification(_ m: NIMMessage, items: inout [ChatMessage], delta: inout Int) {
        guard let obj = m.messageObject as? NIMNotificationObject,
              let content = obj.content as? NIMChatroomNotificationContent else { return }
        switch content.eventType {
        case .enter:
            delta += 1
            items.append(ChatMessage(text: L10n.userJoined, isSystem: true))
        case .exit:
            delta -= 1
        default:
            break
        }
    }
}
```

主函数 18 行；三个 sub-func 各 10-15 行——全部 <50 行（CLAUDE.md 函数行数约束）。

### 8.3 处理顺序：合规先 / 礼物后

合规和礼物互斥：`complianceParser.parse` 返回 true 即吞掉消息（44/61/62/63），不再走 gift。仅当 false 才尝试 gift。

`Task { await ... }` 异步——本批 onRecvMessages 内多条 .custom 的 Task 并发；其内部各自调 `liveStore.forceEnd` 时由 LiveStore §2.5 CAS + §2.5b 优先级仲裁兜底，B 不在 NIM 层做次序保证。

### 8.4 性能与限流

- `messages` 80 条上限（`L92-93`）
- 单批 onRecvMessages 最多触发 80 次 push——主线程操作可容忍
- 礼物 burst（1s ≥10 条）不在 B 处理；GiftAnimationQueue 在 H 统一限流

---

## §9 LiveStore 协作补充（写回兄弟 spec）

本 spec 要求 LiveStore spec v3 已补的修订项（v3 已落档）：

| 修订项 | LiveStore spec 章节 | 状态 |
|---|---|---|
| `adjustOnlineCount(by:)` 入口签名 | §2.4 | ✅ v3 已加 |
| §12 NIM 触发表加 `adjustOnlineCount` 行 + `setOnlineCount(0)` 复位行 | §12 | ✅ v3 已加 |
| §2.5b **优先级仲裁**：`banned > noPermission > cameraFailure > weakNetwork > disconnected` | §2.5 | ⏳ 本 review v2 触发，待 LiveStore spec v3 同步修订 |
| §13 DoD #11 改"取最高优先级源" | §13 | ⏳ 同上 |
| §10 埋点子分类 `im_reconnect_failed` / `heartbeat_failed` | 兄弟 spec §3 / §15 风险 | ⏳ 同上 |

> 后 3 项作为本 spec 落档后**反向写回**的需求点，将在本 spec 评审通过后同步修订 LiveStore spec v4。

---

## §10 真机验收 DoD

> **i18n 声明**：本节所有用户可见文案必须走 `Localizable.strings`，中文仅为说明。

| # | 验收场景 | 预期 | 工具/手段 |
|---|---|---|---|
| 1 | 进房成功 | `connected = true`，公屏"已进入聊天室"，LiveStore.onlineCount = chatroom.onlineUserCount | 真机开播 |
| 2 | 公屏文本接收 | 他端发消息可见，累计 ≤80 条 | 两机对话 |
| 3 | 进出房 onlineCount | 他人进 → +1；他人出 → -1；不为负 | 多机进出 |
| 4 | leave 复位 | 退房 LiveStore.onlineCount=0 / messages=[] / cachedNickname="" / enterAttemptCount=0 | 退出再进 |
| 5 | dismiss 后 IM 静默 | 退房后他人继续发，本端无 messages 新增 | 退房验证 |
| 6 | 进房失败 retry | retryCount=3 自动重试；最终失败显示"加入聊天室失败：code=XXX" | mock 错误 roomId |
| 7 | 重连 `Entering` → `EnterOK` | 公屏"重连中..."→"已重连"；reconnecting 字段切换 | 飞行模式 5s 再开 |
| 8 | 重连失败 >3 次 → forceEnd | 触发 endType=4；埋点 `im_reconnect_failed` 上报 | mock 长断网 |
| 9 | attachType=44 强制下播 | LiveStore 进 forceEnding(.disconnected) → endType=4 | 后端推 44 |
| 10 | attachType=61 合规警告 | warningToast 显示 3s 自动消失，**不下播** | 后端推 61 |
| 11 | attachType=62 封禁下播 | 触发 endType=2 | 后端推 62 |
| 12 | attachType=63 进折扣池 | LiveStore.boostingExposure = true（无 UI） | 后端推 63 + Console |
| 13 | 礼物（SEND_GIFT/1/4/15/18） | 公屏"XX 送出 礼物名 × N" 占位文本；字段完整；giftAnimationQueue.enqueue 调用记录 | 后端推 + Console |
| 14 | attachType=50 / 未知 | logger.info 留痕，不崩溃不推公屏 | 后端推 50 |
| 15 | **多源 forceEnd 抢占（v2 优先级仲裁）**：1992 + NIM 44 同到 | endType=2（banned 优先级 > disconnected）；DoD 文案稳定可复现 | 双源 mock |
| 16 | 合规警告并发 | 1s 内连续 3 条 61，warningToast 取最后一条；3s 后自动清空 | 后端连续推 |
| 17 | setupOnce 仅注册 decoder 一次 | App 启动 + 多次进房，`NIMCustomObject.registerCustomDecoder` 仅调一次；不重复 add delegate（每次 enter 时 add，每次 leave 时 remove） | 日志 / breakpoint |

**全部 17 项通过**方可关闭 B 里程碑 NIMChatroomManager 范围。

---

## §11 实施任务清单

按依赖排序。

| # | 任务 | 影响文件 | 新/改 | 估时 | commit scope |
|---|---|---|---|---|---|
| 1 | `AttachType` 枚举 + 双向 raw 映射 | `Sources/Live/NIM/AttachType.swift`（新） | 新 | 0.3 | `feat: [IM-attach类型]` |
| 2 | `LiveCustomAttachment` (`encodeAttachment`) + `LiveCustomAttachmentDecoder` + setupOnce 内 `NIMCustomObject.registerCustomDecoder` | `Sources/Live/NIM/LiveCustomAttachment.swift`（新） | 新 | 0.5 | `feat: [IM-自定义附件]` |
| 3 | `ComplianceMessageParser` (@MainActor) | `Sources/Live/NIM/ComplianceMessageParser.swift`（新） | 新 | 0.5 | `feat: [IM-合规消息]` |
| 4 | `GiftMessageParser` + `GiftAnimationQueueProtocol` 协议 | `Sources/Live/NIM/GiftMessageParser.swift`（新） | 新 | 0.6 | `feat: [IM-礼物消息]` |
| 5 | `NIMChatroomManager` 持有 `weak liveStore` + `weak giftAnimationQueue` + parsers 注入 + `cachedNickname` 字段 | `Sources/Live/NIMChatroomManager.swift` | 改 | 0.3 | `refactor: [公屏管理]` |
| 6 | `onRecvMessages` 改造 + 拆 sub-func（parseText / dispatchCustom / handleNotification） | 同上 | 改 | 0.5 | `feat: [公屏-自定义消息分发]` |
| 7 | `connectionStateChanged` 4 态分流 + 重连 1s/2s/4s + `cachedNickname` 缓存 + 埋点 `im_reconnect_failed` | 同上 | 改 | 0.6 | `feat: [公屏重连]` |
| 8 | `leave` 复位 onlineCount + 清空 messages + reset 全字段 | 同上 | 改 | 0.2 | `fix: [公屏退房复位]` |
| 9 | LiveStore 补 `adjustOnlineCount(by:)` 入口（已在兄弟 spec v3） | `Sources/Live/LiveStore.swift` | 改 | 0.2 | `feat: [直播状态机]` |
| 10 | LiveStore 优先级仲裁（兄弟 spec §2.5b 修订） + 埋点子分类 | `Sources/Live/LiveStore.swift` + `B-LiveStore状态机-spec-*.md` | 改 | 0.5 | `feat: [直播状态机]` |
| 11 | onlineCount 字段从 NIMChatroomManager 删除（迁到 LiveStore） + LiveRoomView 数据源切换 | `NIMChatroomManager.swift` + `LiveRoomView.swift` | 改 | 0.3 | `refactor: [公屏管理]` |
| 12 | 公屏 i18n 占位 key（reconnecting / reconnected / userJoined / sendGiftAction / complianceWarningDefault / anonymous） | `Sources/Localizable.strings` (en) | 新 | 0.2 | `feat: [i18n-公屏]` |
| 13 | 裸 print → os.Logger | `Sources/Live/NIMChatroomManager.swift` | 改 | 0.2 | `refactor: [*]` |
| 14 | 真机回归 DoD 17 项 | — | 验证 | 1.0 | `chore: [*]` |

**总估时**：5.9 人/天（约 1.2 周单人）

**依赖顺序**：1 → 2 → 3 / 4 并行 → 5 → 6 → 7 → 8 → 9 → 10 → 11 → 12 → 13 → 14

可与 `B-LiveStore状态机-spec.md` 任务**完全并行**——除任务 9/10 跨 spec 边界外，文件 0 冲突。

---

## §12 风险与未决项

| 风险 | 描述 | 缓解 |
|---|---|---|
| NIMSDK 10.10.0 API 准确性 | v2 已 grep header 验证 connectionState 枚举 / encodeAttachment / registerCustomDecoder 三处 ✓ | 其余次要 API（NIMNotificationContent.ext 等）implement 第一步 read header |
| attachType 61 payload `content` / 63 `status` 字段名 | H5/安卓字段名可能不同 | 后端推真实样本到 dev 抓包对齐 |
| 礼物字段 `giftCount` 数据类型 | H5 可能字符串 "10" | §7.2 String→Int 容错已实现 |
| 重连阈值 3 次是否过严 | 线上常态弱网可能误触 endType=4 | implement 后真机观察；可调 5 次 |
| `cachedNickname` 字段初始空 | 极少数 race condition 进房还没缓存就重连 | `enter(...)` 同步缓存，scheduleReenter 守卫 `roomId.isEmpty` 后才执行 |
| `giftAnimationQueue` 在 H 接前是 nil | enqueue 调用直接空跑 | B 阶段公屏文本占位即可，无功能损失 |
| `Task { await ... }` 在 onRecvMessages 内并发 | 多条 .custom 顺序无保证 | LiveStore §2.5 CAS + §2.5b 优先级仲裁兜底，B 不在 NIM 层保证次序 |
| H5 后端可能下发 50 | 现状 message.js 不存在但安卓 02-05 未明确 | §5.2 已归入 unknown 仅 logger，不影响业务 |

未决项**不阻塞 B implement 启动**，但需在 implement 期同步推进。
