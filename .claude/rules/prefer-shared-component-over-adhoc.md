# 已有公共组件的能力必须优先复用 · 禁止 ad-hoc 造轮子

> 来源：2026-07-10 Profile Album 相册图片/视频预览用 Profile 私有 `MediaPreviewView`（单张 + AsyncImage + AVKit 拼装、无 LRU、无横滑翻页、无下拉关闭），而项目已有公共组件 `MediaGalleryView`（Sources/Core/MediaGallery/，20MB LRU + 横滑 + 页码 + 下拉关闭 + 视频秒开）供朋友圈用；用户明示"应该用公共预览组件"后一次性替换。这是本项目**第 2 次**同类问题——[cross-scene-component-reuse-preflight](cross-scene-component-reuse-preflight.md) 治 "复用现有组件前 preflight"，本 rule 治 **"能不能复用" 的判定** —— 有公共组件时不允许写私有版本。

## 规则

写新 View / Store / Service / Helper 前，**必须**先 grep 项目里是否已有承担同职能的公共组件；有则**必须复用**，除非能明示复用不满足需求的具体点。

**判定"公共"的信号**：
- 位于 `Sources/Core/` / `Sources/DesignSystem/` / `Sources/Networking/` / `Sources/Components/` 等横向层目录
- 名字以 `Cached*` / `Common*` / `Shared*` / `Media*` / `App*` 开头，或不带业务前缀（`ProfileMediaGrid` 是业务的，`MediaGalleryView` 是公共的）
- 类型注释含 "**公共组件**" / "统一 XX" / "跨业务场景复用" / "共享"
- 已被 ≥2 处业务模块使用（`grep -rn ClassName Sources/` 结果跨越多个业务目录）

## Why

**具体错例**（本次真犯）：
```swift
// Sources/Profile/MediaPreview/MediaPreviewView.swift（本次已删）
struct MediaPreviewView: View {
    let item: MediaAsset          // ❌ 私有输入类型
    let isVideo: Bool             // ❌ caller 需自己判 mp4/mov
    let onDismiss: () -> Void
    // 内部：AsyncImage + AVPlayer(url:) 拼装
    // 缺 LRU、缺横滑翻页、缺下拉关闭、缺失败重试、缺 VoiceOver escape
}

// Sources/Core/MediaGallery/MediaGalleryView.swift（早在朋友圈就已就位）
struct MediaGalleryView: View {
    let urls: [String]            // ✅ 通用 URL 列表
    let startIndex: Int
    // 内部：MediaGalleryCache 20MB LRU + 自动判视频扩展名 + TabView 横滑 + 页码 +
    //       下拉关闭手势 + AVPlayerItem.failed retry + VoiceOver escape action
}
```

**代价**（每一条都真犯）：
1. **能力落后**：私有版无 LRU → 反复下载消耗流量；无横滑 → 用户只能看单张退出再点下一张；无下拉关闭 → UX 断层
2. **bug 漂**：公共组件里已修的 bug（AVURLAsset preload 主线程阻塞 / VoiceOver a11y label / AVPlayerItem.failed 检测），私有版都得重踩一遍
3. **审查漏网**：`code-review` skill 关注 diff 内新增代码是否合理，**不会**告诉你"这个功能项目里其实已有更好的版本"
4. **抽公共时冲突**：H 里未来若要抽 "全项目统一预览"，会发现每个业务都写了半吊子版本，抽公共变成大重构

## How to apply

### 写新组件前：先 grep

以下场景**必须**先 grep 再动手：

| 意图 | grep 关键词 |
|---|---|
| 图片/视频预览 / 全屏 | `MediaGallery` / `Preview` / `FullScreen` |
| 头像 / 用户 icon 展示 | `Avatar` |
| 远端图 + 缓存 | `CachedAsyncImage` / `ImageCache` |
| 视频缩略图 / 首帧 | `VideoThumbnail` / `Thumbnail` |
| 上传（OSS / 图片 / 视频） | `Upload` / `ImageUploader` |
| Loading 转圈 / 空态 / 错误态 | `Loading` / `Empty` / `Error` |
| 手势返回 | `SwipeBack` / `SwipeToPop` |
| Toast / Banner / 底部弹层 | `Toast` / `Banner` / `Sheet` |
| Cell / Button 通用样式 | `Cell` / `Button` / `Chip` / `Capsule` |
| 时间格式化 / 数字格式化 | `Formatter` / `Extension`（尤其 `String+` / `Date+` / `Int+`） |
| 网络请求 / API 封装 | `APIClient` / `Service` |

grep 命令模板：
```bash
grep -rn "关键词" Sources/Core Sources/DesignSystem Sources/Networking 2>/dev/null | head -10
# 若命中 → 点开源码看接口是否满足
# 若未命中 + 该职能有 3+ 处已实现私有版本 → 抽公共是更好选择
```

### 满足度判定：3 类

grep 命中公共组件后，看接口：

- **完全适用**（≥90% 匹配）→ **直接用**。任何拼装私有版本的动作都是浪费
- **参数不通** / **默认行为不合适** → **加参数** / **加可选 hook** 扩展公共组件（改动量通常 <20 行）；不要另起私有版
- **业务定制点太多**（改公共组件影响面 >3 个业务） → 才允许**基于公共组件二次封装**（thin wrapper 加业务前缀，如 `ProfileMediaGalleryTrigger`）。**禁止**从头拼装

### 写私有版本前必须回答 3 个问题

若判定"公共组件不够用要新写"，写代码前先在 commit message / PR description 里回答：

1. **公共组件是什么**？（grep 结果 + 类名）
2. **具体不满足哪一点**？（具体到接口不通 / 特定行为差异 / 性能不达标 + 数据）
3. **为什么不扩展公共组件**？（改动量 / 影响面 / 是否触发跨业务回归）

3 个问题任一答不上来 → 停下 → 用公共组件。

### 命名信号规避误判

- 名字带业务前缀（`ProfileXxx` / `LiveXxx` / `PartyXxx`）= **业务私有**，跨业务复用要谨慎（配合 [cross-scene-component-reuse-preflight](cross-scene-component-reuse-preflight.md) preflight）
- 名字**不带**业务前缀且在横向层目录 = **公共**，允许自由复用

## 具体到本工程已知的公共组件（截至 2026-07-10）

| 职能 | 公共组件 | 位置 | 已用者示例 |
|---|---|---|---|
| 图片/视频全屏预览 | `MediaGalleryView` + `MediaGalleryContext` | [Sources/Core/MediaGallery/](../../Sources/Core/MediaGallery/MediaGalleryView.swift) | CircleView / ProfileView（本次接入） |
| 图片/视频 LRU 缓存池 | `MediaGalleryCache` | 同上 | MediaGalleryView 内部；业务不直调 |
| 远端图 + LRU | `CachedAsyncImage` + `ImageCache` | Sources/Core/ | 全项目通用 |
| 头像展示（三色环 / 装饰） | `AvatarView` / `AvatarRing` | Sources/Core/ / DesignSystem | UserProfileView / ProfileView |
| 视频首帧缩略图 | `VideoThumbnailImage` | Sources/Message/Chat/UI/VideoThumbnailLoader.swift（未来抽到 Core） | ChatDetailView / MediaPickerSheet |
| 通用上传 + 压缩预设 | `ImageUploader` + `Sources/Core/Upload/` | Sources/Core/Upload/ | 反馈 / 头像 / 相册 / 朋友圈 |
| 手势返回（隐藏 back 但保留 swipe） | `.swipeToPopEnabled()` / `.enableSwipeBack()` | Sources/Core/UI/SwipeToPopHelper.swift / Sources/DesignSystem/SwipeBackEnabler.swift | 全项目 push 页 |
| 用户身份 → String/Int 双兼容 decode | Codable init 模板（写在 ios-decode-userid-compat rule） | - | Profile / User / Live |

新加公共组件时（横向层新增）**必须**回来更新本表，让下次决策有源可查。

## 与既有规则关联

- [cross-scene-component-reuse-preflight.md](cross-scene-component-reuse-preflight.md) —— "决定复用现有 View 前 preflight 检查自持依赖"；本 rule 是**上一层**："先决定是否有可复用的"；两者组合：先本 rule 判"能不能复用"，再 preflight 判"复用是否安全"
- [single-target-public-hygiene.md](single-target-public-hygiene.md) §2 "工具扩展禁重复造轮子" —— 同源精神，本 rule 从工具扩展扩到全 UI/Service 层
- [code-review-discipline.md](code-review-discipline.md) §7 "工具产出 ≠ 二次复查" —— 本 rule 补一层：code-review 只看 diff 内代码合理性，不判"是否本该用公共组件"，需要写代码者自己 grep

## 不适用

- **一次性内部辅助 struct**（fileprivate 或函数内 struct）—— 不跨文件用，无沉淀价值
- **完全新领域的组件**（项目里第一次做的类型，如首次加"AR 滤镜"）—— grep 命不中就是命不中
- **公共组件被明确标"deprecated"** —— 有更新版正在替换过渡期

## 历史教训

- **2026-07-10 Profile Album 相册预览**：项目里 CircleView 已在用 `MediaGalleryView`（横滑 + LRU + 下拉关闭）为公共组件，Profile Album 却私有实现 `MediaPreviewView`（单张 + 无缓存），用户显式指出"应该用公共组件"。此前实现者未 grep `MediaGallery` / `Preview` 就直接拼装。本 rule 沉淀让未来所有新 UI/Service 写代码前**先 grep**，避免公共组件低使用率 + 私有版本满天飞。
