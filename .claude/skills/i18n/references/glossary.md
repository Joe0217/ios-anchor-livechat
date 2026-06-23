# Hily 项目术语词汇表

翻译时**必读**。负责：
1. 确保品牌词、产品名词不被误翻
2. 业务术语跨语言一致（避免同义词漂移：直播 ≠ 视频流 ≠ 在线广播）
3. 保留 H5 历史拼写（含已知 typo）

## 一、品牌词 / 专有名词（**永远保留原样，不翻译**）

| 词 | 说明 |
|---|---|
| `Hily` | App 显示名，bundle ID `com.anchor.livechat` 绑定 |
| `FaceUnity` | 美颜 SDK 品牌名 |
| `Agora` / `声网` | RTC SDK 品牌名（中文 strings 中也不翻成"声网"） |
| `NIM` / `云信` | IM SDK 品牌名 |
| `Prime` | 高级用户分段名（liveList.segment.prime） |
| `Cysle` | ⚠️ **H5 原始拼写错误**（应为 Cycle/Circle，但 H5 写错且已上线，保留以避免数据/埋点断裂） |
| `dev · anchor.cphub.link` | 环境提示，保留原文 |
| 占位符：`%@` `%d` `%1$@` `%2$@` 等 | C 风格 format specifier，**位置和数量必须保留** |

## 二、业务术语三语言对照表

| 中文/概念 | en | ar | tr |
|---|---|---|---|
| 主播 | Anchor / Host | المضيف | Yayıncı |
| 直播 | Live / Live streaming | بث / بث مباشر | Canlı / Yayın |
| 开播 | Go Live | بدء البث | Yayını Başlat |
| 下播 | End Live | إنهاء البث | Yayını Bitir |
| 强制下播 | Force end / Force-ended | إنهاء قسري | Zorla sonlandırma |
| 直播间 | Live room | غرفة البث | Yayın odası |
| 美颜 | Beauty / Beauty filter | الفلتر | Güzelleştirme / Güzellik |
| 磨皮 | Smooth | نعومة | Pürüzsüz |
| 美白 | Whiten | تبييض | Beyazlat |
| 大眼 | Eye Enlarge | تكبير العيون | Göz Büyüt |
| 瘦脸 | Face Thin | تنحيف الوجه | Yüz İnceltme |
| 礼物 | Gift | هدية | Hediye |
| 公屏（聊天室） | Chatroom | غرفة الدردشة | Sohbet odası |
| 通话 / 1v1 | Call | مكالمة | Arama |
| 私 call（直播态私聊） | Private call | مكالمة خاصة | Özel arama |
| 接听 | Accept | قبول | Kabul Et |
| 拒接 | Reject | رفض | Reddet |
| 挂断 | Hang up | إنهاء | Kapat |
| 频道（声网/NIM channel） | Channel | القناة | Kanal |
| 心跳 | Heartbeat | نبضات / Heartbeat | Heartbeat |
| 在线 / 在线态 | Online | متصل | Çevrimiçi |
| 离线 | Offline | غير متصل | Çevrimdışı |
| 匹配 | Match | مطابقة | Eşleş |
| 任务 | Task | مهمة | Görev |
| 收益 | Income / Earnings | أرباح | Gelir |
| 提现 | Withdrawal | سحب | Çekim |
| 钻石（虚拟货币） | Diamonds | الماس | Elmas |
| 等级 | Level | المستوى | Seviye |
| 排行榜 | Leaderboard | لوحة الصدارة | Lider Tablosu |
| 观看者 / 观众 | Viewer | مشاهد | İzleyici |
| 关注 / 粉丝 / 朋友 | Following / Followers / Friends | متابَع / متابعون / أصدقاء | Takip / Takipçi / Arkadaşlar |
| 邀请 | Invite | دعوة | Davet |
| 背包（道具） | Backpack | الحقيبة | Çanta |

## 三、错误码与系统消息

| 场景 | 一致性要求 |
|---|---|
| 网络断连 | en "Connection lost" / 不要写成 "Disconnected" 或 "Network broken"，避免与"网络较差"混淆 |
| 账号违规 | en 用 "Account violation"，**不要**用 "Banned"（过激）或 "Suspended"（语义不准） |
| 网络较差 | en 用 "Network too weak" / "Network unstable"，区分于"完全断连" |
| 相机权限 | 三语言均用"权限"概念，不写成"允许使用" |

## 四、占位符（C 风格 format string）规则

| 类型 | 含义 | 示例 |
|---|---|---|
| `%@` | NSObject（字符串等） | `String(format: L10n.x, "abc")` |
| `%d` | Int | `String(format: L10n.x, 5)` |
| `%1$@`, `%2$@` | positional：第 N 个参数 | RTL 语言/不同语序需调换 placeholder 位置时用 |

**强制规则**：
- 翻译后占位符**数量必须不变**（验证脚本会自动检查）
- 简单单 placeholder（一个 `%@` 或 `%d`）可保留为非 positional
- 双以上 placeholder 且语序在某语言里不同 → **改为 positional 形式**（`%1$@` `%2$@`），让 RTL 语言可以调换位置而不动代码
- 不能新增 placeholder（代码层 `String(format:)` 参数数固定）

**Hily 已知需改 positional 的两个 key**（J 里程碑前由翻译团队处理）：
- `livePrepare.errorPrefix` = `"Failed: %@ (%@)"` —— 阿拉伯语 RTL 渲染时双 `%@` 视觉顺序与英文反，应升级 positional
- `call.errorConnectPrefix` = `"Connect failed: %@ (%@)"` —— 同上

## 五、不可翻译的字符串字面量

下面这些 key 的值是技术字符串，**所有语言保持完全相同**：

| key | 值 | 原因 |
|---|---|---|
| `auth.envHint` | `dev · anchor.cphub.link` | 环境标识，不翻译 |
| `live.subTab.cysle` | `Cysle` | H5 历史拼写 |
| `liveList.segment.prime` | `Prime` | 产品分段品牌词 |
