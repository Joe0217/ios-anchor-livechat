# anchor-livechat-h5 主播端 · 全功能业务梳理（iOS 原生重建蓝图）

> 生成时间：2026-06-16　|　用途：H5 主播端 → iOS(Swift) 原生重建的完整功能与业务逻辑参照
> 本目录基于真实源码逐模块深度梳理，`modules/` 下为 9 份分模块详档，本文为全局总览与索引。

---

## 一、项目定位

H5 移动端**主播端**应用，webview 内嵌于原生壳运行，面向主播用户。核心业务：**1对1 视频/语音通话、直播、PK、美颜、礼物收益、IM 消息、数据统计**。原生壳通过 URL 加密参数注入登录态，H5 通过极少量 JSBridge 与原生通信（支付、退登）。

iOS 重建目标：用 Swift 原生复刻全部业务，音视频用 Agora Native SDK，美颜用相芯 NamaSDK 原生 SDK，IM 用云信 NIM 原生 SDK，从而摆脱 webview 的性能与美颜管线限制。

---

## 二、模块地图（9 大业务域）

| # | 模块 | 详档 | 核心职责 | 重建复杂度 |
|---|------|------|----------|-----------|
| 01 | 通话(Call) | [01-通话call.md](modules/01-通话call.md) | 1对1 视频通话状态机、信令、计费、假人通话 | ★★★★★ |
| 02 | 直播 + PK | [02-直播live与PK.md](modules/02-直播live与PK.md) | 开播推流、公屏、PK 玩法、下播结算 | ★★★★★ |
| 03 | 美颜 + 音视频底层 | [03-美颜与音视频底层.md](modules/03-美颜与音视频底层.md) | 相芯美颜管线、Agora 轨道、设备分档降级 | ★★★★★ |
| 04 | IM 消息与会话 | [04-IM消息与会话.md](modules/04-IM消息与会话.md) | 云信 NIM + Agora RTM 双通道、消息分发 | ★★★★☆ |
| 05 | 礼物与虚拟道具 | [05-礼物与虚拟道具.md](modules/05-礼物与虚拟道具.md) | 礼物动画队列、钻石福袋、座驾/头像框 | ★★★★☆ |
| 06 | 钱包/支付/邀请 | [06-钱包支付与邀请.md](modules/06-钱包支付与邀请.md) | 收益钻石、提现风控、Airwallex、返佣 | ★★★☆☆ |
| 07 | 任务/引导/数据统计 | [07-任务引导与数据统计.md](modules/07-任务引导与数据统计.md) | 任务中心、新手引导、数据看板、埋点 | ★★★☆☆ |
| 08 | 社交/圈子/排行 | [08-社交圈子与排行.md](modules/08-社交圈子与排行.md) | 朋友圈动态、关注粉丝、排行榜、用户主页 | ★★★☆☆ |
| 09 | 账号/设置/基建 | [09-账号设置与基建.md](modules/09-账号设置与基建.md) | 登录鉴权、JSBridge、路由权限、i18n、网络监控 | ★★★★☆ |

---

## 三、技术栈 → iOS 原生映射

| H5 技术 | 作用 | iOS 原生替代 |
|---------|------|-------------|
| agora-rtc-sdk-ng / agora-rtm | 音视频 / 通话信令 | **Agora Native SDK (RTC + RTM/Signaling)**，joinChannelEx 支持多频道(PK) |
| nim-web-sdk-ng | IM 聊天/系统消息/聊天室 | **云信 NIM iOS SDK** |
| NamaSDK(相芯) + mediapipe + face-api.js | 美颜 / 人脸检测 / 活体 | **相芯 NamaSDK iOS 原生**（CVPixelBuffer 直通，无需 canvas 绕行）；活体可用原生人脸框架 |
| svgaplayerweb / yyeva | 礼物动画(SVGA / MP4 透明) | **SVGAPlayer-iOS** + YYEVA iOS / MP4 alpha 播放器 |
| ali-oss + STS | 图片/视频上传 | **AliyunOSSiOS SDK + STS Federation** |
| airwallex-payment-elements | 支付 | 原生 IAP / Airwallex iOS SDK（多为遗留代码，优先级低） |
| crypto-js (AES) | 请求加解密 | **CryptoKit / CommonCrypto**（注意密文编码歧义，见风险点） |
| vue-i18n + RTL | 多语言(英/阿/土) | **Localizable.strings + 语义化布局**（阿拉伯语 RTL，用 leading/trailing 而非 left/right） |
| ThinkingData(数数) 埋点 | 行为埋点 | **ThinkingData iOS SDK** |
| Pinia + 持久化 | 状态管理 | 原生状态层 + UserDefaults/Keychain |
| postcss-mobile-forever | 375 基准适配 | Auto Layout（无需移植） |

---

## 四、跨模块基础设施（务必先建）

这些是所有业务域的公共底座，建议**最先实现并验证**：

1. **登录态与鉴权**（详见 09）
   - 登录态主要由原生经 URL `openParams` 注入：AES 加密的 `{token, loginUuid, timestamp}`
   - 双 token 体系：主 token + bagshop `auth_token`（虚拟道具二级接口，需 loginUuid 换取、401 自动续）
   - ⚠️ AES 密文编码歧义：加密 `.toString()`（Base64）但解密用 `enc.Hex.parse`，重建前**必须与服务端确认密文实际编码**；主接口与 bagshop 用不同密钥
   - 鉴权头生成、token 变更即清缓存

2. **请求层**：统一加解密、拦截器统一注入鉴权头、业务码判定（主接口 `'0000'`、sapi 为 `'200'`）、二级 API(sapi) 独立后端与 exchangeToken；后端将 Long 序列化为 string 防精度丢失，前端按 string 接收

3. **IM 双通道**（详见 04）
   - 聊天/系统通知/聊天室 → **NIM**；通话信令 → **Agora RTM**（Uint8Array 二进制）
   - 职责分离（勿误为"双通道并存"）：通话**信令**走 Agora RTM（仅 6 种 CallAction）；**礼物/收益/充值奖励**走 NIM sysMsg（attachType 4/15/18/90）
   - 两个独立分发入口：P2P 系统消息走 `message.js` 的 `onSysMsg`（约 30 个 attachType 分支）；聊天室/PK 消息（50/56/97-100 等）走 `live.js` 的 `chatroomLiveChatRecordMsg`/`handlePkMessage`，勿混为一张表，均需 1:1 复刻
   - Flame/Stranger 会话分类依赖会话扩展字段（前端读 `session.extra`，服务端字段名为 `ext`），须与安卓字段严格一致

4. **音视频 + 美颜管线**（详见 03）
   - iOS 原生链路大幅简化：`CVPixelBuffer → 相芯 NamaSDK → Agora pushExternalVideoFrame`（无需 Web 的 MediaStreamTrackProcessor + canvas captureStream 绕行）
   - 设备分档（HIGH/MID/LOW）决定分辨率/帧率/码率，美颜数值映射 reflexMap 需精确复刻

5. **埋点**：ThinkingData `reportShuShuCustomEvent`，关键事件清单见 07

6. **路由权限分流**：按 `userType`(2=主播 / 9=代理 / 其他=受限) 分流，受限态页面（mineRestricted/newsRestricted）

---

## 五、建议重建顺序（依赖驱动）

```
阶段一 基建（无业务）
  └ 鉴权/请求加解密 → IM(NIM)登录 → Agora 初始化 → 美颜管线 → 埋点 → 路由权限/i18n

阶段二 核心营收链路（主播赖以工作）
  └ 通话(01) ──依赖──> IM信令+RTC+美颜+礼物
  └ 直播+PK(02) ──依赖──> RTC多频道+聊天室+礼物+美颜
  └ 礼物动画(05) ──被 01/02 依赖

阶段三 收益与留存
  └ 钱包/提现(06) → 数据统计(07) → 任务/引导(07)

阶段四 社交与外围
  └ 社交圈子/排行(08) → 个人中心/设置(09) → 邀请(06)
```

> 通话(01) 与 直播(02) 共用同一 callApi 实例与美颜实例，私 call 接听前会暂停直播保留会话，**切换连续性**是核心难点，建议两模块同期设计。

---

## 六、全局关键风险与踩坑汇总

> 从各模块详档提炼，iOS 重建时高优先级关注：

| 风险点 | 模块 | 说明 |
|--------|------|------|
| AES 密文编码歧义 | 09 基建 | 加密 Base64 / 解密 Hex，与服务端确认后再实现，否则全链路鉴权失败 |
| 信令双通道归属 | 01/04 | 通话信令走 RTM，NIM 仅旁路；-3 旁路状态被刻意注释防重复，勿误接 |
| 双层/三层状态机 | 01/02 | 通话底层 CallApi 状态 + 业务 callGameStatus；直播 frontStatus/pkStatus/liveState 交叉，易卡死 |
| 心跳为状态权威源 | 02 | 6s 心跳 callState 推导封禁/断连/弱网强制下播，须 1:1 复刻判定阈值 |
| PK 多频道并发 | 02 | 同时推本地 + 订阅对手频道(joinChannelEx)，PK 期间暂停网络监控防误判 |
| 充值等待蒙层时序 | 01 | 计时暂停+画中画锁定+兜底续时+充值补偿+钻石奖励，时序最敏感 |
| 假人通话独立链路 | 01 | 不连 RTC/RTM，本地播预录视频+云录屏开播+三接口上报 |
| 美颜数值映射 reflexMap | 03 | UI 值↔相芯原始值 3 种映射(type1/2/3)，磨皮/下巴/额头需精确换算 |
| 钻石福袋状态机 | 05 | 三态机+FIFO 队列+IM 乱序缓存+三重因果守卫+延迟移除，与安卓对齐 |
| 动画播放队列 | 05 | 模块级数组绕过响应式，单实例串行，PK 期价格降序重排 |
| 提现强风控链 | 06 | 是否需人脸由后端决定；活体三动作状态机 + OSS 截图 + 后端比对 |
| 倒计时强制 UTC+8 | 07 | 任务重置用北京时间，iOS 须用 Asia/Shanghai 而非本地时区 |
| 奖励异步 IM 链路 | 07 | 新手任务奖励经 attachType=135 推送后才能领取，须 IM 回调接管 |
| OSS 上传链路 | 08 | STS 凭证→压缩→put，动态发布与资料编辑共用 |
| 审核通过(58)勿登出 | 04/09 | 审核通过系统消息需配合拦截器跳过自动登出，否则旧 token 踢出 webview |

### 可降优先级 / 无需移植（各 agent 已确认的遗留代码）

- **视频录制**（vedioRecorder / useRecord）：废弃 Demo，无生产功能
- **支付充值**：USDT 分支被 return 短路、充值列表/汇率接口已注释、discount.js 整体注释 → 主播端支付几乎不用
- **gifts.js**：硬编码 mock；主播端 sendGift 基本不调用（主播只「索要」礼物不送礼）
- **circleCache**：半废弃缓存层
- **音频通话**：仅有枚举，`_receiveAudioCall` 为 TODO 空，实际只跑视频
- **第三方登录**（Apple/Google/FB）：后端就绪但 H5 未接 → 原生应补齐

---

## 七、详档阅读指引

每份模块详档统一 8 节结构：
**一、模块概述 / 二、页面与入口 / 三、功能点清单 / 四、业务逻辑与规则 / 五、数据与接口(API/store/消息类型/SDK) / 六、依赖的SDK与原生能力 / 七、边界与异常处理 / 八、iOS重建注意事项**

建议 iOS 重建团队按「阶段五（重建顺序）」逐模块精读对应详档，第四、七、八节为复刻关键。
