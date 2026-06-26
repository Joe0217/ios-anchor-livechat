# SwiftUI 相机预览 / RTC 渲染稳定性

## 1. switch case 内重复出现的子 View 必须用 if 链承载

SwiftUI 把 `switch` case 内的每个分支视为**不同位置**的 view，跨 case 切换会
触发 `dismantleUIView` + 重建（含 UIViewRepresentable 包装的 MTKView /
AgoraRtcVideoCanvas 持有 view）。直播私 call 流程中 CallFaceTimeView 横跨
`.calling / .connecting / .connected` 三态——必须放在**同一 if 分支**或用
`.id(...)` 强制 identity 稳定，**不能写成多个 switch case 分别 return 同名
子 View**。

正例：
```swift
if shouldShowWaiting {
    CallWaitingView(store: store)
} else if isInCallOrConnecting {
    CallFaceTimeView(store: store, liveCamera: liveCamera, liveBeauty: liveBeauty)
}
```

反例：
```swift
switch store.state {
case .calling: CallWaitingView(store: store)
case .connecting: CallFaceTimeView(store: store, ...)
case .connected: CallFaceTimeView(store: store, ...)   // ❌ 与上一行不同位置
}
```

## 2. UIViewRepresentable 包装的强持有 UIView 单例禁止反复 makeUIView

MTKView / `AgoraManager.remoteView` 这类**持外部强引用**的 UIView 单例，被
父结构 reload 触发反复 makeUIView 会导致：
- MTKView：实例切换 → `camera.onFrame` 闭包目标空窗 → **本端画面卡帧**
- AgoraRtcVideoCanvas.view：layer 引用失效 → SDK 远端首帧渲染丢失 → **对端黑屏**

定位思路：若发现 makeUIView 在通话过程中被调多次，先排查上层 switch case
跨分支重建（见规则 1），再考虑加 `.id()` 锁 identity。

### 正解模式：按业务 key 在 manager 侧维 UIView 池（E v4 派对房真机验证）

派对房一房多视频位（≤13 个）场景，`.id()` 不足以解决——多 representable
实例必须各自取**独立稳定 UIView**。正确解法：

1. **manager 侧**（如 `PartyRTCEngine`）持 `[BizKey: UIView]` 池字典：
   ```swift
   private var seatIndexToView: [Int: UIView] = [:]
   @MainActor func acquireRemoteView(seatIndex: Int) -> UIView {
       if let v = seatIndexToView[seatIndex] { return v }   // 已存在直接返
       let v = UIView()                                       // 否则懒建入池
       seatIndexToView[seatIndex] = v
       return v
   }
   ```
2. **representable 侧** `makeUIView` 调 `manager.acquireRemoteView(key)`、
   `updateUIView` 留 **no-op**（实例不变无需更新）：
   ```swift
   struct PartyRemoteVideoView: UIViewRepresentable {
       let seatIndex: Int
       let engine: PartyRTCEngine
       func makeUIView(context: Context) -> UIView {
           engine.acquireRemoteView(seatIndex: seatIndex)
       }
       func updateUIView(_ uiView: UIView, context: Context) {}
   }
   ```
3. **绑定/清理** 是 manager 内 `bindRemoteVideo(key:, uid:)` 幂等接口：
   - 同 (key, uid) 重入 = no-op
   - 同 key 不同 uid（换人）= 先用旧 uid `setupRemoteVideo(view:nil)` 清旧，再绑新
   - 退场景统一 `releaseAllRemoteViews()` 清池
4. **SwiftUI redraw 怎么扛**：representable 即使被父结构刷 100 次，
   `acquireRemoteView` 都返同一个 UIView 实例 → AgoraRtcVideoCanvas.view
   引用稳定 → SDK 不丢首帧。

**关键不变量**：UIView 实例的生命周期与 **业务上下文（房间/通话）一致**，
而**不**与 SwiftUI view 生命周期一致。SwiftUI 是"声明式视图描述"，UIView 是
"持流的物理容器"——后者必须脱离前者的重建周期单独管理。

适用场景：派对房视频位（key=seatIndex）/ 1v1 通话远端（key=固定 channelId）/
直播 PK 远端（key=remoteUid）/ 任何 N 路视频流并存的场景。

## 3. CameraManager 帧分发禁止使用单闭包 onFrame；必须用 subscribers 字典

**反悔历程（v5.3.3 ~ v5.7 全部失败，v5.8 立新规则）**：

| 版本 | 方案 | 失败原因 |
|---|---|---|
| v5.3.3 ~ v5.6 | `updateUIView` 守 `onFrame == nil` 才 bindFrameSink | 通话挂断后闭包内 weak view 变 nil 但**闭包本身非 nil** → 守卫不通过 → 本端永久断流 |
| v5.7 | 去掉守卫，`updateUIView` 每次强制重绑 | SwiftUI 在 `.overlay { ... }` 内 view 消失时**不会**触发 ZStack 兄弟节点的 updateUIView → 本体永远拿不到重绑机会 → 同样断流 |

**v5.7 失败的真根因**：
1. 直播私 call 期间 LiveRoomView 本体 CameraPreview 在 ZStack 主层、CallView overlay 在 `.overlay { ... }` 修饰内
2. PIP `bindFrameSink` 后绑覆盖本体（单闭包模型）：`onFrame` 闭包 weak view = PIP MTKView、agoraRef = callStore.agora
3. 挂断 → overlay 内 PIP CameraPreview 消失 → SwiftUI 调度 PIP 的 dismantleUIView
4. **关键盲点**：本体 CameraPreview 在 ZStack 的位置/props 都未变，SwiftUI 没有理由 re-call 它的 updateUIView，本体永远拿不到重绑时机
5. onFrame 仍指向 PIP 那个 weak nil 的旧闭包 → 本端帧渲染失败 + agoraRef nil → 直播观众端断流

**真根因**：单闭包模型本质不支持"同一 CameraManager 多个并行下游"。直播私 call 期间本体（推直播 Agora）+ PIP（推通话 Agora）需要同时收帧，必须用订阅字典。

**v5.8 正确做法**：
- `CameraManager` 删 `var onFrame`，改为 NSLock + `[ObjectIdentifier: (CVPixelBuffer) -> Void]` 字典
- 暴露 `subscribe(key, sink)` / `unsubscribe(key)` API
- `captureOutput` 锁内拷贝 sink snapshot、锁外分发（避免长持锁阻塞 main queue 的 subscribe）
- `CameraPreview` 加 `Coordinator`：
  - `makeCoordinator()` 创建 Coordinator
  - `makeUIView` / `updateUIView` 调 `coordinator.attach(view:agora:)`，内部 `camera.subscribe(ObjectIdentifier(self), sink)`
  - `static func dismantleUIView(_:coordinator:)` 调 `coordinator.detach()` 精确注销
- 每个 CameraPreview view 持有独立 key → PIP dismantle 仅注销 PIP 自己那一格，本体的 sink 始终留在字典里——**不依赖任何 SwiftUI re-eval 时机**

```swift
// CameraManager.swift
private let subscribersLock = NSLock()
private var subscribers: [ObjectIdentifier: (CVPixelBuffer) -> Void] = [:]
func subscribe(_ key: ObjectIdentifier, sink: @escaping (CVPixelBuffer) -> Void) { ... }
func unsubscribe(_ key: ObjectIdentifier) { ... }

// CameraPreview.swift
func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }
static func dismantleUIView(_ uiView: MetalPreviewView, coordinator: Coordinator) {
    coordinator.detach()   // ✓ 精确注销自己那一格
}
```

反例（v5.7 失败方案，禁止回退）：
```swift
// CameraManager: var onFrame: ((CVPixelBuffer) -> Void)?   // ❌ 单闭包 PIP 覆盖本体
// CameraPreview.updateUIView { bindFrameSink(to: uiView) }   // ❌ overlay 兄弟节点拿不到重绑时机
```

## 4. MTKView 切后台保留 currentImage 作为最后一帧占位

`didEnterBackground` 内**禁止** `currentImage = nil`，仅 `releaseDrawables()`
释放 GPU 资源。回前台 setNeedsDisplay 立刻渲染最后一帧 → 真新帧
（AVCaptureSession 重启 1-2s 后到达）通过 render(_:) 自然替换，视觉无空窗
黑屏。v5.3.5 "清空让闪烁更明确"决策已在 v5.5 反悔（实测用户反馈"卡死"）。

## 5. 声网 sharedEngine 复用 singleton 时必须显式 setChannelProfile

`AgoraRtcEngineKit.sharedEngine(with:delegate:)` 第二次调用复用 singleton 并
**忽略**新 config——`channelProfile` 仍是首次创建时的值。直播
`.liveBroadcasting` 与 1v1 通话 `.communication` 切换时，必须在 sharedEngine
调用之后显式 `kit.setChannelProfile(profile)`，否则编码/丢帧策略错配。

## 6. SwiftUI onDisappear 在 ScenePhase=.background 也会触发

iOS 14+ SwiftUI 在 UIScene 切到 background 时对当前 view 调度 onDisappear
（snapshot/资源释放用），**禁止**在 onDisappear 直接 `camera.tearDown()` /
清空 onFrame——回前台走 `updateUIView` 不走 `makeUIView`，闭包不会重新赋值
（参考 CLAUDE.md v5.3.3 已知坑）。正路径：onDisappear 加守卫
`guard scenePhase != .background, store.state == .ended else { return }`。

## 7. AVCaptureSession 后台中断 reason=1/4 不进 forceEnd

`wasInterrupted(reason=1/4)` 是后台切换/iPad 多任务正常行为，CameraManager 已
过滤；**禁止**进 20s `forceEnd(.cameraFailure, endType=5)` 路径。回前台必须
监听 `AVCaptureSessionInterruptionEnded` 通知 startRunning 才生效
（willEnterForeground 时 session 还处于 interrupted，startRunning silently
fail，参考 CLAUDE.md v5.3 已知坑）。

## 8. 业务态遮罩禁止全屏覆盖本端预览（除非业务态语义就是"完全黑屏"）

直播 / 通话 / 派对房等"摄像头持续采集 + 短窗口不推流"的业务态（例：
私 call 挂断后 15s `returnLiveCountdownOverlay` 业务必须的倒计时窗口），
覆盖层 UI **禁止**使用 `Color.black.opacity(>=0.6).ignoresSafeArea()` 全屏蒙层。

根因：本端 CameraPreview 此刻仍在持续 `view.render(pixelBuffer)`（摄像头未关），
全屏蒙层把本可见的实时画面完全盖死 → 用户体感等同"画面卡死 N 秒"，
与"不推流"的真实业务语义混淆——用户无法区分"是我的设备卡了"还是"业务在等"。

正路径：用顶部/底部胶囊条或半透明卡片承载文案 + 倒计时，**保留本端画面可见**。
"不推流"由 `pushFrame` 内 `guard state == .joined` 在数据层拦截，与 UI 蒙层解耦。

唯一豁免：业务态语义就是"完全黑屏"（比如下播完成态、隐私敏感场景），
否则一律按本规则走半透明胶囊条。

## 9. nonisolated pushFrame 读 @MainActor 字段必须用 frameSnapshot 原子快照

派对房 / 直播 / 通话 RTC 封装的 `pushFrame(_ pb: CVPixelBuffer)` 入口
**永远是 nonisolated**（由 `CameraManager` 在 `videoQueue` 后台串行调用，单帧
~60Hz），但其内部需要读的 `engine: AgoraRtcEngineKit?` / `state: State` /
`videoSeatActive: Bool` 等字段又**全部在 @MainActor 写**——直接读这些字段
违反 Swift 6 严格并发；Swift 5 默认 mode 静默放行但实际是 UB，CLAUDE.md
v5.3.1 "CIImage / CVPixelBuffer 跨线程 ARC 不安全" 同源问题。

### 反例

```swift
final class PartyRTCEngine {
    @MainActor private var engine: AgoraRtcEngineKit?
    @Published private(set) var state: State = .idle
    @MainActor private(set) var videoSeatActive = false

    func pushFrame(_ pb: CVPixelBuffer) {  // nonisolated
        // ❌ 读 self.engine / self.state / self.videoSeatActive — 跨 queue 非原子
        guard let engine, state == .joined, videoSeatActive else { return }
        engine.pushExternalVideoFrame(...)
    }
}
```

具体炸点：`leave()` 在 @MainActor 设 `self.engine = nil` 的瞬间，
`captureOutput` 可能拿到半状态指针调 `pushExternalVideoFrame` → 崩溃，
或 channelProfile 已切换后还在用旧编码档位推帧。

### 正解：NSLock + frameSnapshot 元组

```swift
final class PartyRTCEngine {
    // ... 原 @MainActor 字段保留 ...

    /// pushFrame 跨 actor 安全的状态快照（review 202606252033 P0-1）。
    private let frameLock = NSLock()
    private var frameSnapshot: (engine: AgoraRtcEngineKit?, active: Bool) = (nil, false)

    /// 锁内取快照 → 锁外推帧；snap.engine 是局部强引用，self.engine = nil 不影响这一帧
    func pushFrame(_ pb: CVPixelBuffer) {
        frameLock.lock()
        let snap = frameSnapshot
        frameLock.unlock()
        guard let engine = snap.engine, snap.active else { return }
        engine.pushExternalVideoFrame(...)
    }

    /// 任何 @MainActor 路径写完 engine / state / videoSeatActive 后必须调
    @MainActor
    private func updateFrameSnapshot() {
        let nextEngine = engine
        let nextActive = (state == .joined && videoSeatActive)
        frameLock.lock()
        frameSnapshot = (nextEngine, nextActive)
        frameLock.unlock()
    }
}
```

调用约定（缺一不可）：

| 触发点 | 何时调 | 原因 |
|---|---|---|
| `join()` 末尾 | engine = kit 写完后 | 让 pushFrame 看到初始 (engine, false) 而非 (nil, false) |
| `didJoinChannel` 回调 | `state = .joined` 写完后 | active 从 false → true，开始推帧 |
| `enableVideoSeat()` 末尾 | `videoSeatActive = true` 写完后 | active 联动 |
| `disableVideoSeatInternal()` 末尾 | `videoSeatActive = false` 写完后 | active 联动 |
| `leave()` 入口 | **必须**先 `let wasVideoActive = videoSeatActive` → `videoSeatActive = false` → updateSnapshot → `updateChannel(publishMicrophoneTrack: false, publishCustomVideoTrack: false)` → leaveChannel | `updateChannel(publish=false)` 让远端立即感知离开（不强制等待 leaveChannel 完成）；`wasVideoActive` 局部快照供 await 后 `if wasVideoActive { engine.disableVideo() }` 区分（直读 self.videoSeatActive 是死分支）|
| `leave()` 末尾 | engine = nil 写完后 | 彻底失效 |
| `didOccurError` 内 state 变更 | `state = .failed` 写完后 | active 联动 |

### 关键不变量

1. **锁只守快照拷贝**，不守 SDK 调用——锁持有时间 ≤ 几条赋值，不会和 SDK 异步回调死锁
2. **快照里的 engine 是局部强引用**，即使 `self.engine = nil` 也不影响这一帧，sharedEngine 是 singleton 不会真销毁
3. **leave() 必须先 active=false 再做销毁动作**——这是关闭竞态窗口的核心
4. **pushFrame 完全不再读 self.xxx**——只读 frameSnapshot，唯一可被 Swift 6 严格并发接受的形态
5. **leave() 内 `videoSeatActive = false` 前必须先存 wasVideoActive 局部快照**——后续 `if wasVideoActive { engine.disableVideo() }` 才会执行；若直接 `if videoSeatActive` 是死分支，video source 不释放（二轮复查 wfpw5v1us 已纠）
6. **新增 @MainActor 字段必须同步进 frameSnapshot 元组**——G 期 PK 加 rotation/mirror/trackId 时，pushFrame 函数体 `grep self\.` 必须 0 匹配；规避方式：把元组改 `struct FrameSnapshot { ... }`，新字段强制写入 struct

### Swift 6 严格并发 Sendable 声明（必备）

§9 代码块照搬到 Swift 6 strict mode **无法编译**——关键是搞清每个声明的作用，**不要照搬却归错原因**。

```swift
// 1. 类标 @unchecked Sendable（混合 @MainActor 字段 + nonisolated pushFrame 时让 Swift 6 strict 不报"类不可跨 actor 传递"）
//    + Sendable 类型内的 @Published 字段要求配 @MainActor isolation，否则 Sendable 一致性会被破坏
final class PartyRTCEngine: NSObject, ObservableObject, @unchecked Sendable {
    @MainActor @Published private(set) var state: State = .idle  // @MainActor 必备
    // ...
}

// 2. frameSnapshot **必须**是 struct + 显式 @unchecked Sendable
//    单字段 nonisolated(unsafe) var engine 不够 —— pushFrame 内 (engine, active) 双字段联合判定需要原子拷贝
private struct FrameSnapshot: @unchecked Sendable {
    let engine: AgoraRtcEngineKit?
    let active: Bool
}
private var frameSnapshot: FrameSnapshot = FrameSnapshot(engine: nil, active: false)
```

**关于 `@preconcurrency import AgoraRtcKit`**：

只对**参数/返回值**降级 strict 模式的"跨 actor 传递非 Sendable 类型"警告；**对存储字段（`var engine: AgoraRtcEngineKit?`）不生效**。真正让 `frameSnapshot.engine` 在 nonisolated 上下文可读的是 `FrameSnapshot: @unchecked Sendable`。F/G 期工程师误以为加了 `@preconcurrency import` 就能漏标 `@unchecked Sendable` → strict mode 编译失败。

**禁止的等价错解**：
- `@MainActor func pushFrame(...)` — hop 到 main 后帧延迟堆积，60Hz 排队 100ms+
- `Task { @MainActor in engine.pushExternalVideoFrame(...) }` — 同上 + Task 创建开销
- `assumeIsolated(to: MainActor.shared)` — 运行时崩溃（pushFrame 实际在 videoQueue）
- `nonisolated(unsafe) var engine` — 单字段标注不够，pushFrame 需要 (engine, active) **联合原子读** 才正确

### deinit / await 跨边界禁区

```swift
deinit {
    // ❌ 禁止：deinit 在哪个线程不确定，调 @MainActor 方法会跨 actor hop
    // updateFrameSnapshot()

    // ❌ 禁止：deinit 持锁 + ARC 析构子对象触发回调 = 死锁 UB
    // frameLock.lock(); frameSnapshot = .init(); frameLock.unlock()

    // ✅ 唯一允许：解 SDK delegate 引用（同步原子）
    if engine?.delegate === self { engine?.delegate = nil }
}
```

**`leave()` 内 `await` 跨边界规则**（按场景分级）：
- 永远禁止：在 await 之间持锁——NSLock 跨 await 是未定义行为（无论单/共享 owner）
- 单 owner 场景（如 PartyRTCEngine 当前结构）：`join()` 用 `guard engine == nil else { return }` 已阻断重入，**无需** `await` 回来 re-guard `self.engine === preservedSnapshot`——加 guard 写出 dead code
- **共享 owner 场景**（G 期 PK 抽 `RTCSharedEngineGuard` 之后，多个并发 owner 可能竞争同一 engine）：必须 `let preservedEngine = self.engine; await ...; guard self.engine === preservedEngine else { return }`——防 await 期 owner 被替换

### sharedEngine 跨场景失效（与 §5 协同）

`AgoraRtcEngineKit.sharedEngine(with:)` 是**进程级 singleton**，三场景（派对房 / 直播 / 1v1 通话 / PK）**复用同一指针**。

危险场景：
1. PartyRTCEngine joined（frameSnapshot=(kit, true)）
2. 另一场景（如直播 LiveRoom）拿同一 sharedEngine 调 `setChannelProfile(.liveBroadcasting)` 切换
3. PartyRTCEngine.self.engine 指针**没变**，frameSnapshot 也**没变**
4. pushFrame 继续推帧——**推到了直播频道**（编码档位、订阅策略全错）

frameSnapshot **侦测不到这种"外部改 SDK 内部状态"**——指针对照是不够的。

正路径（与 §5 协同强制）：
- 任一场景做 `setChannelProfile` 前必须**所有其他场景 active=false → updateFrameSnapshot → setChannelProfile → 配套 encoder 配置 → 自己 active=true**
- G 期开始多场景频繁切换前，必须抽 `RTCSharedEngineGuard` 共享基建（路线图 §五候选）：单一 owner 持锁 + 切换前广播失活

### inflight 帧窗口（设计上接受）

锁取快照后到 SDK pushExternalVideoFrame 之间窗口（< 1ms）内若 leave() 已开始 → snap.engine 推帧到正在 leave 的 channel。

**SDK 行为（经验观察，非文档合约）**：
- sharedEngine 不销毁（指针永远有效，无 EXC_BAD_ACCESS）——这是 D v5.4 立的"leave 不调 destroy"铁律保证的
- 推到正在 leave 的 channel：dev 真机长期观察未触发崩溃 / 未引起远端异常画面
- **注意**：`updateChannel(publishCustomVideoTrack=false)` 是异步派发到 SDK worker thread，**不保证主线程返回后即时生效**；AgoraRtcKit 4.5.x **无公开**"leaveChannel 中 push 帧静默丢弃"契约
- SDK 升级（4.5.x → 4.6.x 或换厂）必须**重新真机验证** inflight 帧窗口的实际容忍度，不可机械沿用本节假设

**这是设计上接受的窗口**——不要为消除 1ms 内 1 帧加更大的锁让 main 阻塞。如果未来发现 SDK 真销毁、或新版本不再容忍此 inflight，则必须升级到 PartyStore 退房路径"先 cm.tearDown 同步 + grace 200ms + 再 rtc.leave"模型（v5.8 同精神）。

如果未来 sharedEngine 真销毁（destroy()）会崩，所以 D v5.4 已立铁律 "leave 不调 destroy"——这条铁律必须维护。

### 与 §3 subscribers 字典的衔接

§3 的 sink 闭包内调 pushFrame，必须用 `[weak rtc]` 弱引用：

```swift
// ✅ 正：sink 闭包 weak capture 上游 RTC，让退房路径能正常释放
cm.subscribe(ObjectIdentifier(self)) { [weak rtcRef] pixelBuffer in
    rtcRef?.pushFrame(pixelBuffer)
}

// ❌ 反：strong capture 致 PartyRTCEngine 漏释
cm.subscribe(ObjectIdentifier(self)) { pixelBuffer in
    rtcRef.pushFrame(pixelBuffer)  // strong capture
}
```

**真正泄漏对象**：sink 闭包 strong capture 的是 `PartyRTCEngine` 自身（不是 `frameSnapshot.engine` 内的 sharedEngine——后者本就是进程级单例常驻）。strong capture 会让 PartyRTCEngine 实例无法在 PartyStore 退房后释放，除非 cm.tearDown / cm.unsubscribe 显式移除 sink。这与 §3 v5.8 "subscribers 字典 + Coordinator dismantle 精确注销" 模式协同——前者管 retain，后者管注销。

### 适用场景

- 派对房 `PartyRTCEngine.pushFrame`（E v4 已落地 + 二轮复查加固）
- 直播 `AgoraManager.pushExternalVideoFrame`（B 期未实装外部源，G PK 期会用 → 接入时按本模式）
- 1v1 通话 `AgoraManager.pushExternalVideoFrame`（C 期同上）
- 直播 PK `AgoraManager.joinPKOpposite` 后的外部源（G 期落地时按本模式）

不要再用 "guard let engine, state == .joined" 这种直读字段的写法——所有"@MainActor 字段 + background queue 入口"组合一律 frameSnapshot。
