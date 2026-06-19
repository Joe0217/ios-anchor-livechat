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
- 真机运行：Signing 选个人 Apple ID（免费团队）；美颜/相机必须真机（模拟器无摄像头）

## 不可触碰的约束
- **bundleId 必须保持 `com.anchor.livechat`**：相芯 authpack 授权证书绑定它，改了美颜直接失效
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
- **请求加解密非对称**：请求体 JSON → AES-128-CBC/PKCS7 → **Base64**（上行）；响应 envelope `{code,message,result}`，`result` 是 **Hex** 密文（下行）。成功 code `'0000'`。dev key `9986sdff5s4f1123` / iv `9986sdff5s4y456a`
- **密钥随环境变（不只换域名）**：dev 主接口/bagshop 同一套；test/prod 主接口与 bagshop 各换一套。多环境配置必须把**密钥**纳入 xcconfig
- **鉴权头**：token 放 `loginToken`+`anchorToken`（值相同），`appid: 20735424`，`Ocp-Apim-Subscription-Key: 9ec52f6d03cd4d5985a6a2c8bb1ce5ee`，外加 deviceId 等。无请求签名
- **dev 域名**：`https://anchor.cphub.link`（/api）。登录 `/api/login/v4/login`，密码=两次大写 MD5：`MD5(MD5(pwd+appId))`
- **开播 token 来源**：主播加入声网的 rtcToken 来自 `/api/index/getAgoraRtmToken`（绑 uid、与 channel 无关），**不是** beginLiveRoom 返回的；频道用 beginLiveRoom/getMyLiveRoom 的 `agoraChannelId`。声网 dev AppID `4af61c7a92f447d3a582308b5817dbd2`。import 仍是 `AgoraRtcKit`
- **心跳 6s**（H5 源码 `setInterval(keepLiving, 6000)`，"10秒"是过时注释）。`callState`：0直播/1通话/2匹配/3PK，阶段一恒为 0
- **强制下播 5 原因**：`'3'`系统强制(心跳 code 1992/1006 封禁)、`'4'`断连(连续心跳失败 >6 次)、`'5'`网络差(连续 ≥30 次质量≥5；≥10 次上报埋点)、`'99'`相机错误、正常结束
- **token 策略**：存 Keychain（非 UserDefaults）；主 token + bagshop `auth_token`（用 `loginUuid` 换、401 自动续）。双 token 拼接是给 webview 传参的，**原生不需要**
- **公屏**：走 IM 登录 + 聊天室普通模式（复用 IM 长连接，非独立模式）；自定义消息 `attachType` 是**数字编码**（如 50/61/63）
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
- 调试 `print` 收敛为统一日志（`os.Logger`），生产不留裸 `print`

## 开发计划与现状
- **开发计划**：`docs/plan/iOS原生主播端-开发计划-阶段一基建与直播闭环-*.md`
  - 里程碑 A = 基建骨架 + 登录闭环（M0–M4）；B = 直播闭环（+M6）；C = 礼物动画 + sapi 双 token + 工程化收尾
- **功能审查（当前基线）**：`docs/plan/Hily原生工程-已实现功能审查-*.md`（完成度、P0–P3 缺口清单）
- **接入技术文档**：`docs/plan/原生iOS接入技术文档-*.md`（声网/云信/相芯接入细节、待确认清单）

## Git 规范
- Commit 格式：`<type>: [scope] <description>`（type：feat/fix/docs/refactor/perf/chore/build 等，全局用 `[*]`）
- 详见 `.claude/rules/git-workflow.md`
- NEVER commit/push unless explicitly asked

## 文档规范
- 项目文档统一放 `docs/plan`，中文名+日期时间命名（如 `开发计划-202606191030.md`）
- 面向产品/测试的文档禁止出现内部类名/变量名，用业务语言描述（详见 `.claude/rules/doc-output.md`）
