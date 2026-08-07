# Hily 原生 iOS 主播端项目规范

## 项目定位
H5 主播端（`anchor-livechat-h5`：1v1 视频通话、直播、PK、美颜、礼物收益）的 **Swift 原生重建**。
工程名 `ios-anchor-livechat`，App 显示名 **Hily**，由验证级 POC 升级为正式工程，正按里程碑演进为生产应用。

**协作模式**：Claude 全程写代码，用户只决策 + 真机测试。方案按"模块解耦、每步可独立真机验证"组织。

## 技术栈
- Swift 5 + SwiftUI，iOS 16，仅 iPhone，竖屏
- 工程生成：xcodegen（`project.yml` → `Hily.xcodeproj`，工程文件不入库）
- 依赖混合形态：
  - **CocoaPods**：声网 `AgoraVideo_Special_iOS` 4.5.2.9.BASIC + 云信 `NIMSDK_LITE` 10.10.0（构建走 `.xcworkspace`）
  - **embedded framework**：相芯 `FURenderKit.framework`（arm64 device-only）+ OC 桥接
- 状态管理：SwiftUI + ObservableObject；DI 用构造注入 + 薄 `AppEnvironment` 容器（不引入 TCA/Swinject）
- 美颜管线：`AVCaptureSession`(前置/BGRA) → `BeautyRenderer`(相芯/直通可热替换) → `MetalPreviewView`(Metal+CoreImage)；前后皆 `CVPixelBuffer`，预览路径不变

## 构建工作流（关键，顺序不可乱）
```bash
xcodegen generate                 # 1. 由 project.yml 生成 Hily.xcodeproj
LANG=en_US.UTF-8 pod install      # 2. 涉及 Pod 变更时；生成/更新 Hily.xcworkspace
open Hily.xcworkspace             # 3. 必须用 workspace，否则云信找不到模块
```
- 改了 `project.yml` 的依赖/源文件后必须重新 `xcodegen generate`，再 `pod install`
- ⚠️ **xcodegen generate 后必须跟 pod install**：xcodegen 重写 .xcodeproj 会**清掉** `pod install` 加进去的 `[CP] Copy XCFrameworks` script phase + Embed Frameworks phase；漏跑 pod install 直接 build 会得 `No such module 'AgoraRtcKit'` + 真机 `dyld: Library not loaded`，命令行 build 可能因 DerivedData stale 缓存侥幸过、但 Xcode Clean Build 后立刻暴露
- 真机运行：Signing 选个人 Apple ID（免费团队）；美颜/相机必须真机（模拟器无摄像头）

## 不可触碰的约束
- **bundleId 必须与 FaceUnity authpack 保持一致**：切换 Bundle ID 时必须同步申请并替换对应授权证书，否则美颜会失效
- **声网包版本号必须精确写全 `4.5.2.9.BASIC`**：`.BASIC` 被 CocoaPods 当 prerelease，用 `~>` 或省略命不中
- `Vendor/FaceUnity/` 的 `FURenderKit.framework` / `authpack.h` / `bundles/` 是商业授权，**禁止入库**（已 gitignore）
- `Pods/`、`.spm/` 是可再生缓存，禁止入库（`Podfile.lock` 已锁版本）

## 工程结构
```
Sources/
├─ HilyApp.swift              # @main 入口
├─ Core/                      # AppConfig（环境/密钥）· CryptoUtil（AES）
├─ Networking/                # APIClient（主接口）
├─ Auth/                      # SessionStore · AuthService · AuthModels · LoginView
├─ Camera/                    # CameraManager · CameraPreview · MetalPreviewView
├─ Beauty/                    # BeautyRenderer（相芯）· PassthroughRenderer（直通）· BeautyParameters
├─ Agora/                     # AgoraManager · AgoraConfig · RemoteVideoView
├─ Live/                      # LiveService · LivePrepareView · LiveRoomView · NIMChatroomManager
├─ Call/                      # CallPOCView（1v1，POC 级，阶段二+）
├─ Home/                      # RootView（登录态分流）· HomeView
└─ Info.plist
Vendor/FaceUnity/             # FUManager.h/.m · FUBeautyRenderer.swift · 桥接头 · framework/authpack（不入库）
docs/plan/                    # 接入技术文档、开发计划、功能审查
```

## 关键集成事实（非显而易见，务必先知）
- **请求加解密非对称**：请求体 JSON → AES-128-CBC/PKCS7 → **Base64**（上行）；响应 envelope `{code,message,result}`，`result` 是 **Hex** 密文（下行）。成功 code `'0000'`。key/IV 从本地 xcconfig 注入，禁止写入源码或文档。
- **密钥随环境变（不只换域名）**：主接口、sapi 与 WebSocket 的 key/IV 均通过本地 xcconfig 管理；每个环境都必须配置完整，禁止使用源码 fallback。
- **鉴权头**：token 放 `loginToken`+`anchorToken`（值相同），另含 appid、网关订阅 key 与 deviceId 等。具体值仅由本地 xcconfig 注入，无请求签名。
- **dev 域名**：`https://anchor.cphub.link`（/api）。登录 `/api/login/v4/login`，密码=两次大写 MD5：`MD5(MD5(pwd+appId))`
- **开播 token 来源**：主播加入声网的 rtcToken 来自 `/api/index/getAgoraRtmToken`（绑 uid、与 channel 无关），**不是** beginLiveRoom 返回的；频道用 beginLiveRoom/getMyLiveRoom 的 `agoraChannelId`。声网 AppID 由本地 xcconfig 注入。import 仍是 `AgoraRtcKit`
- **心跳 6s**（H5 源码 `setInterval(keepLiving, 6000)`，"10秒"是过时注释）。⚠️ **iOS 实现取 10s / 失败 >3 次**（对齐安卓，详见 `docs/plan/archive/B-LiveStore状态机-spec-*.md` §3）。`callState`：0直播/1通话/2匹配/3PK，阶段一恒为 0
- **强制下播 5 原因（H5 历史字符串编码）**：`'3'`系统强制(心跳 code 1992/1006 封禁)、`'4'`断连(连续心跳失败 >6 次)、`'5'`网络差(连续 ≥30 次质量≥5；≥10 次上报埋点)、`'99'`相机错误、正常结束。⚠️ **iOS 实现按路线图 §三 B 升级为数字编码 4/2/5/6/7**（对齐安卓；阈值 10s/>3）。⚠️ **弱网阈值 v5 反悔为分层 10/30（"连续"语义，中间任一次质量 ≤4 即清零重计）**：连续 10 次（≈20s）降帧率 30→15fps + toast；连续 30 次（≈60s）才 forceEnd endType=7；降级期连续 5 次质量好恢复 normal。详见 `docs/plan/archive/B-LiveStore状态机-spec-*.md` §11 + §4.5
- **token 策略**：存 Keychain（非 UserDefaults）；主 token + bagshop `auth_token`（用 `loginUuid` 换、401 自动续）。双 token 拼接是给 webview 传参的，**原生不需要**
- **公屏**：走 IM 登录 + 聊天室普通模式（复用 IM 长连接，非独立模式）；自定义消息 `attachType` 是**数字编码**。⚠️ **常见误区**：50 在双端均无证据（B 不识别）、61=**合规警告**（不下播，仅 toast）、62=封禁下播、63=**进折扣池 BoostingExposure**、44=强制下播——**非礼物**；礼物真编号是 `'SEND_GIFT'`(字符串) + 数字 1/4/15/18（见 `docs/plan/archive/B-spec-H5安卓代码二次校验-*.md` §1.1）
- **签名**：免费个人团队，真实 Team ID `8J6JP98FM3`（证书 OU；括号里 L624PPWDN5 是证书 ID，非 Team ID）

## 已知坑
- `JSONSerialization.data` 对 `NSNull`（如心跳 `result:null`）会抛 OC 异常且 `try?` **不捕获** → 崩溃，须先 `isValidJSONObject` 守卫
- OC 返回 `CVPixelBufferRef` 给 Swift 要加 `CF_RETURNS_NOT_RETAINED`，否则过度释放

## 编码规范
- Swift 类型用 UpperCamelCase，方法/属性 lowerCamelCase；文件名 = 主类型名
- View 只读 `@Published`；副作用（计时器/心跳/强制下播）全收敛进 Store/Controller，不写在 View
- 全局只放跨页面共享状态（登录态/路由）；直播状态收敛进 `LiveStore`
- 大型 SDK 能力延迟初始化（美颜资源、声网引擎按需创建），不阻塞启动
- 错误处理：禁止空 `catch`；SDK 错误区分网络/业务，网络错误触发重连（详见 `.claude/rules/error-handling.md`）
- **AVCaptureSession 后台中断**（v5.2 已知坑）：`wasInterrupted(reason=1/4)` 是后台切换/iPad 多任务正常行为，**禁止**进 20s `forceEnd(.cameraFailure)` 路径（会导致用户切后台 20s+ 自动下播）；CameraManager 已过滤；回前台监听 `UIApplication.willEnterForegroundNotification` 主动 `session.startRunning()` 恢复推流
- **AVCaptureSession.startRunning 在 isInterrupted 状态 silently fail**（v5.3 已知坑）：`willEnterForeground` 时 session 还处于 interrupted，调 `startRunning()` 不报错也不生效；必须在 `AVCaptureSessionInterruptionEnded` 通知里 startRunning 才有效——CameraManager.handleInterruptionEnded 已补；willEnterForeground 作防御兜底
- **MTKView 切后台后画面卡住**（v5.3 已知坑）：MTKView 在 `didEnterBackground` 时 CADisplayLink 暂停 + `currentDrawable` 释放；回前台立即 `setNeedsDisplay()` 时 drawable 仍 nil 导致 `draw(_:)` 空跑，画面持续显示最后一帧；MetalPreviewView 已加 `releaseDrawables()` + 延迟 300ms `setNeedsDisplay` 恢复
- **CIImage / CVPixelBuffer 跨线程 ARC 不安全**（v5.3.1 已知坑）：相机帧回调在 background queue（captureOutput），UI 渲染在 main queue；引用类型字段 `currentImage: CIImage?` 在两 queue 写读不是原子，可读到撕裂指针 EXC_BAD_ACCESS——所有引用类型字段（含 closure）必须**单一 queue 读写**；预览管线一律 main queue 串行
- **@StateObject CameraManager 延迟 deinit 致摄像头灯不熄**（v5.3.1 已知坑）：SwiftUI 持有 @StateObject 引用，view dismiss 后 deinit 不立即调用；observer 仍响应 willEnterForeground 自动重启已离开 session——必须在 onDisappear 显式调 `camera.tearDown()` 同步 removeObserver + 清闭包 + stop session
- **声网 SDK 在 app 后台时持续发 networkQuality 回调，回前台后 backlog 一次性串行触发 forceEnd**（v5.3.2 已知坑）：声网 SDK 用自己线程，回调 dispatch 到 `@MainActor` 时 main 在后台挂起 → backlog 排队 → 回前台瞬间一次性执行 30+ 次 `report()` → `consecutiveBadCount` 飞速到 30 → 误下播 endType=7。`NetworkQualityMonitor` + `HeartbeatController` 必须监听 `UIApplication.didEnterBackground/willEnterForeground`，**后台静默 + 回前台 5s 冷却丢弃 backlog**
- **SwiftUI 在 ScenePhase=.background 时也会触发 view 的 onDisappear**（v5.3.3 真根因坑）：iOS 14+ SwiftUI 在 UIScene 切到 background 时对当前 view 调度 onDisappear（资源释放/snapshot 用），**禁止**在 onDisappear 直接 `camera.tearDown()`（清空 `camera.onFrame=nil`）；回前台 SwiftUI 走 `updateUIView` 不走 `makeUIView`，onFrame 永远不会重新赋值——画面卡 + 推流断 + 60s 后弱网误下播。修复必须双保险：(1) `CameraPreview.updateUIView` 内 `if camera.onFrame == nil { rebind }` 兜底；(2) `LiveRoomView.onDisappear` 加 `guard scenePhase != .background, store.state == .ended else { return }` 阻止切后台时误清
- **iOS 限制：app 后台无法访问相机**（产品共识，v5.3.4/v5.3.5 已还原暂不处理）：业界主流直播 App 切后台一律视频暂停 + 音频继续——iOS 隐私硬性限制相机后台采集，无 API 绕开；画中画（PiP）适合显示**远端视频**，不适合**采集本端相机**。后台保持推流方案（`Info.plist UIBackgroundModes: audio` + `AVAudioSession` 后台音频 / `CameraManager` 1Hz `lastFrame` relay 占位帧）暂未启用，留 H/J 里程碑评估
- 调试 `print` 收敛为统一日志（`os.Logger`），生产不留裸 `print`
- **国际化（en/ar/tr）**：布局用语义化方向 `leading`/`trailing` 而非 `left`/`right`（阿拉伯语 RTL 自动镜像）；字符串走 `Localizable.strings`，禁止硬编码中文/英文
- **时区**：任务重置/倒计时等业务用 `Asia/Shanghai`（UTC+8）固定时区，**不用设备本地时区**（H5 行为）

## 实现纪律（铁律）
- **改 H5 行为前必须读 H5 源码**：`docs/plan/` 的梳理文档（9 模块详档、安卓对照、功能审查、接入技术文档）是**辅助参考、不是权威真相**；H5 项目存在大量死代码（视频录制 / USDT / discount.js / gifts.js mock / circleCache / `_receiveAudioCall` 等已确认废弃，详见路线图 §六），照搬会污染原生重建
- **每个里程碑 spec 第一节必做"H5/安卓代码二次校验清单"**：规则详见 `docs/plan/iOS主播端-全量上线里程碑路线图-*.md` §六。文档与源码冲突时**信源码**；拿不准时追踪调用链或问用户，不默认保留

## 开发计划与现状（文档地图）

**总规划（权威，2026-06-19 起）**
- `docs/plan/iOS主播端-全量上线里程碑路线图-*.md` — **10 个里程碑 A→J**，含依赖图、共享基建抽取时机、文档校验机制、风险与开工前对齐清单
  - A 基建+登录（60% 已落地）/ B 直播闭环产品化 / C 1v1 仅视频从 POC 升生产 / D 直播↔通话切换（转私 call）/ E 派对房 MVP / F 派对房完整玩法 / G 直播 PK / H 礼物+虚拟道具+IM 完善 / I 收益与外围 / J 机器人+转盘+埋点+i18n+Crash+收尾
  - **B/C/E 三轴可并行**；J 必须最后串行
  - 心跳 **10s/失败>3 次**、endType **数字 4/2/6/7/5**、弱网 **≥10 次 + 采集失败>20s** 全部对齐安卓；音频通话/虚拟来电不做
- `docs/plan/路线图执行追踪-*.md` — 各里程碑启动/完成/阻塞实时跟踪

**现状基线**
- `docs/plan/Hily原生工程-已实现功能审查-*.md` — 60% 完成度快照、P0–P3 缺口清单、源码文件清单

**SDK 接入参考**
- `docs/plan/原生iOS接入技术文档-*.md` — 声网/云信/相芯接入参数、密钥、API 端点、待确认项

**功能蓝本（必读）**
- `docs/plan/iOS重建-功能梳理-20260616/README.md` + `modules/01-09.md` — H5 视角 9 模块详档，**除派对房外全部以 H5 为准**
- `docs/plan/安卓主播端梳理/02-04-派对房.md` — 派对房唯一蓝本（H5 无派对房代码）
- `docs/plan/安卓主播端梳理/04-iOS对齐安卓-派对房+机器人转盘+心跳-决策规格.md` — 派对房/机器人/转盘/心跳决策源头

> ⚠️ **安卓其他模块梳理已迁出项目**（2026-07-07）：直播/1v1/PK/IM/变现/任务/数据/账号/美颜/社交/长尾/差异分析共 14 份迁至 `~/Documents/claudeDocs/Hily-安卓主播端梳理-归档-202607072000/`。除派对房外其他功能一律以 H5 为准；如需查历史决策的安卓信源，去归档目录查。

## Git 规范
- Commit 格式：`<type>: [scope] <description>`（type：feat/fix/docs/refactor/perf/chore/build 等，全局用 `[*]`）
- 详见 `.claude/rules/git-workflow.md`
- NEVER commit/push unless explicitly asked

## 文档规范
- 项目文档统一放 `docs/plan`，中文名+日期时间命名（如 `开发计划-202606191030.md`）
- 面向产品/测试的文档禁止出现内部类名/变量名，用业务语言描述（详见 `.claude/rules/doc-output.md`）
