# SF Symbol 使用需 pre-flight 验证

> 来源：K 里程碑 2026-07-02 用户反馈"Red Ribbon 没有图标"—— 代码 `Image(systemName: "ribbon")` 在 iOS 系统 SF Symbol 库里**不存在**，Image 静默渲染为空

## 规则

**任何** `Image(systemName: "<name>")` 或 `Label(_, systemImage: "<name>")` **在提交前必须验证 name 是有效 SF Symbol**。SwiftUI 对无效 systemName **不报错**，只渲染为**空视图**（占位不显示）—— 用户视觉体验：图标位置空白 + Button 只有 stroke 边线 + label 悬空。

## Why

SF Symbol 命名有多个陷阱：
1. **相似但不存在的名字**：`ribbon`（无）vs `giftcard.fill`（有）vs `star.fill`（有）
2. **变体后缀不一致**：`.fill` `.circle` `.slash` `.circle.fill` 不是所有 symbol 都全套支持
3. **iOS 版本差异**：iOS 16 支持 4000+；iOS 17/18 陆续新增；工程 target iOS 16 下用 iOS 17-only symbol 会静默 fallback（在低版本 iOS 上是空）
4. **拼写陷阱**：`heart.fill` ✓，`hearts.fill` ✗；`chevron.left` ✓，`chevron.left.circle.fill` ✓，但 `chevron.leftcircle.fill` ✗
5. **AI 猜测风险**：SF Symbol 名字与自然语言词汇高度重合但不 100% 对应；`ribbon` / `bow` / `bowtie` 直觉存在实际都无

**K 期真犯**：`iconSymbol: "ribbon"` 在 [BeautyStickerCatalog.swift](../Sources/Beauty/Settings/BeautyStickerCatalog.swift) 里，用户真机看到"Red Ribbon 无图标"才发现。

## How to apply

写 `Image(systemName:)` 时按优先级选择：

### 高置信度直接用（无需查）
- **系统操作类**：`xmark` / `checkmark` / `plus` / `minus` / `arrow.up` / `chevron.right` / `magnifyingglass` / `trash` / `gear` / `ellipsis`
- **通信类**：`envelope` / `envelope.fill` / `phone` / `phone.fill` / `message` / `bell` / `bell.fill`
- **通用形状**：`circle` / `circle.fill` / `square` / `triangle` / `star` / `star.fill` / `heart` / `heart.fill`
- **人物/头像**：`person` / `person.fill` / `person.circle` / `person.crop.circle`

### 需要具体图形时（**必须**验证）

选项 A（推荐）：Xcode 里 **SF Symbols.app**（Apple 官方免费工具）搜关键字确认存在 + 支持的 iOS 版本

选项 B（无 SF Symbols.app）：命令行验证：
```bash
# 在项目里跑一次真机 build，若 log 出现 `Could not find image named "ribbon"` 类警告即无效
# 或直接用一个已知有效 fallback（例：`questionmark.circle.fill`）代替不确定 name
```

选项 C（保守）：**用工程内已使用的 SF Symbol name**（grep 现有代码）
```bash
grep -rho 'systemName: "[^"]*"' Sources | sort -u
# 从现有 200+ 使用点里选一个语义匹配的
```

### AI/Claude 生成代码时的额外约束

Claude 在生成 SwiftUI 代码时，`Image(systemName: "...")` **优先选**上面"高置信度"列表 + 工程内已用过的 name。对**罕见/不常见语义**（如 ribbon / bow / mustache / crown / trophy），**必须**：
- 或 grep 工程验证已用过
- 或明示"未验证，请用户 SF Symbols.app 确认"（并在 comment 里标 TODO）

**绝不**凭直觉猜测 SF Symbol 名字直接用。

## 具体检查项（K 期发现）

**BeautyStickerCatalog / BeautyParamCatalog / BeautyFilterCatalog** 里的 SF Symbol name 若未来加新项：
- 一次性 grep 全项目已用 SF Symbol：`grep -rho 'systemName: "[^"]*"' Sources | sort -u > /tmp/used-symbols.txt`
- 新加 name 若不在此表 → 必须 SF Symbols.app 验证

## 不适用

- 使用 Assets.xcassets 里的 asset image（不走 systemName）
- 使用 emoji 或 Text（Unicode 符号）代替 icon

## 历史教训

- **2026-07-02 K 里程碑贴纸 Red Ribbon**：`iconSymbol: "ribbon"` 空渲染，用户视觉发现"没图标"才修。同批修还有一个**未发现**的问题：其他贴纸 `pawprint.fill` / `star.circle.fill` 等**可能也无效**（未逐一 SF Symbols.app 验证）——修完 Red Ribbon 后未系统性 audit，属于**打补丁思维**（对齐 [root-cause-investigation.md](root-cause-investigation.md) §3 反复修过高发区）。**后续**：新加 icon 前先 grep + SF Symbols.app 双验证。
