---
description: 设计稿 + 切图 → SwiftUI 高保真还原（本工程专用流程，含 token 提取/资源导入/审查/构建验证）
argument-hint: <屏幕名> <设计稿图片路径> <切图目录> [切图位置说明]
---

# 设计稿还原（Design → SwiftUI）

你要把一张 UI 设计稿 + 一组 icon 切图，高保真还原为符合本工程约定的 SwiftUI 界面。
目标：**首轮 ≥95% 还原度**，结构/间距/配色对齐设计稿，可编译，遵守工程纪律。

## 输入

从 `$ARGUMENTS` 解析（缺任一项先问，不要猜）：
- **屏幕名**：用于命名 View / 模块目录（如 `Work` → `WorkView`）
- **设计稿图片路径**：完整还原目标图
- **切图目录**：通常含 `@1x/@2x/@3x` 三套 PNG
- **切图位置说明**（可选）：标注图或文字，说明每张切图对应 UI 哪个元素；图上的标注序号/红框不是 UI 元素，忽略

## 流程（用 TodoWrite 跟踪，逐项推进）

### 1. 侦察（先读后写，禁止跳过）
- Read 设计稿原图，看清整体布局、层级、文字、配色
- 列切图清单：`ls -la <切图目录>`；识别空占位切图（极小字节数 = 透明占位，跳过）
- 摸清工程现状（决定复用还是新建）：
  - 配色体系：是否已有 `Sources/DesignSystem/Theme.swift`
  - i18n：`Sources/L10n.swift` + `Sources/en.lproj/Localizable.strings` 的现有 key 模式
  - 资源：是否已有 `Sources/Assets.xcassets`
  - 导航：当前 `RootView` / `MainTabView` 结构，新屏如何接入

### 2. 切图导入 Assets.xcassets
按 iOS 规范导入（每个 imageset 含 @1x/@2x/@3x + Contents.json）。资源放 `Sources/Assets.xcassets`，
`project.yml` 的 `sources: - Sources` 会自动纳入。映射「切图基名 → 干净 asset 名（camelCase）」后用脚本批量生成：

```bash
export LANG=en_US.UTF-8
SRC="<切图目录>"; DST="Sources/Assets.xcassets"
mkdir -p "$DST"
# 映射表：<切图base>|<assetName>，每行一项
MAP='Calls Today|statCalls
Hi|toolHi'   # ……按实际填写
while IFS='|' read -r base name; do
  [ -z "$base" ] && continue
  set="$DST/$name.imageset"; mkdir -p "$set"
  for sc in "" "@2x" "@3x"; do cp "$SRC/$base$sc.png" "$set/$name$sc.png"; done
  printf '{\n  "images":[\n    {"idiom":"universal","filename":"%s.png","scale":"1x"},\n    {"idiom":"universal","filename":"%s@2x.png","scale":"2x"},\n    {"idiom":"universal","filename":"%s@3x.png","scale":"3x"}\n  ],\n  "info":{"author":"xcode","version":1}\n}\n' "$name" "$name" "$name" > "$set/Contents.json"
done <<< "$MAP"
```

⚠️ **首次新建 Assets.xcassets 必须加一个空 `AppIcon.appiconset`**，否则构建报
`None of the input catalogs contained ... "AppIcon"`：
```bash
mkdir -p "$DST/AppIcon.appiconset"
printf '{\n  "images":[{"idiom":"universal","platform":"ios","size":"1024x1024"}],\n  "info":{"author":"xcode","version":1}\n}\n' > "$DST/AppIcon.appiconset/Contents.json"
```

### 3. 提取设计 token
从设计稿提取：配色 hex、渐变（含 stop 顺序+方向）、字号(pt)+字重、间距、圆角、卡片样式。
- 切图本身已含图标艺术，**不要重画图标**，只提取布局/间距/排版/颜色
- 需要看清局部时可裁剪放大读图，但 **本机 `sips --cropOffset` 不可靠（`-c` 会居中裁剪），裁完务必 Read 确认裁对了区域再信**；PIL 通常未安装
- 可选：用 Workflow 多 agent 分区提取交叉校验。**务必在 prompt 里禁止 agent 用 Bash/sips/python 做像素采样循环**（曾导致 agent 死循环卡住整个 workflow）；若某 agent 卡住，TaskStop 后从 jsonl 收割其余已完成结果，合成自己来做
- 装饰性渐变（彩虹/徽章/头像环）精确 hex 非关键，按设计意图取色，验收时再微调

### 4. 接入方式决策
若新屏涉及**导航结构变更**（新建 TabBar、替换现有页、改 RootView）——这是架构决策，**先用 AskUserQuestion 问**清楚（如：新建壳并保留现有调试入口 / 只做独立 View 用 Preview 验收 / 直接替换）。纯独立子视图则直接做。

### 5. 建 / 复用 Theme
已有 `Sources/DesignSystem/Theme.swift` 则扩展它（新增 token），没有才新建。结构：`Palette`(配色) / `Metric`(间距) / `Radius`(圆角) / `Typography`(字号) / `Gradients`(渐变+光谱)，外加 `Color(hex:)` 便捷构造。

### 6. 写 View（严守工程约定）
- 模块目录：`Sources/<屏幕名>/`，子视图拆到 `Components/`，**一个类型一个文件**
- 数据：`@MainActor ObservableObject` VM 持占位数据；父用 `@StateObject` 持有、子用 `@ObservedObject` 接收；**View 只读 @Published**，计时器/网络/状态机等副作用收敛进 VM/Store
- i18n：所有用户可见文案（含 a11y 的 value）走 `L10n` → `Localizable.strings`，**禁止硬编码中/英文**
- 布局用语义化 `leading`/`trailing`（阿语 RTL 自动镜像），禁 `left`/`right`
- 日志用 `os.Logger`，禁裸 `print`；禁空 `catch`
- 无障碍：装饰性图标 `.accessibilityHidden(true)`（有相邻文字标签时）；图标按钮加 `accessibilityLabel`
- 为保真可用固定字号 `.system(size:)`（设计稿像素对齐优先于 Dynamic Type，属有意取舍）
- 整屏加 `.preferredColorScheme(.dark)`（若设计为深色）；给主 View 加 `#Preview`

### 7. 补 L10n
新文案同时加到 `Sources/L10n.swift`（`NSLocalizedString` 静态常量）和 `Sources/en.lproj/Localizable.strings`，key 命名 `模块.场景`（lowerCamelCase）。

### 8. 审查（两道）
- 调用 `swiftui-pro` skill 审查（注意：该 skill 默认 iOS 26/Swift 6，**本工程是 iOS 16/Swift 5**，只采纳 iOS 16 兼容建议）
- 派 `superpowers:code-reviewer` agent 独立复核（布局正确性/状态流/iOS16 兼容/越界/约定），**prompt 里禁止像素采样循环，图最多 Read 一次**
- 按反馈修正后重新构建

### 9. 构建验证
本工程依赖相芯 `FURenderKit.framework`（**arm64 device-only**），**模拟器无法链接**；真机需签名。
验证编译用 device 通用架构 + 跳过签名（按 CLAUDE.md 构建流，顺序不可乱）：
```bash
xcodegen generate                 # 加了新文件/资源后必须；会重置 Pods 链接
LANG=en_US.UTF-8 pod install      # 因上一步重置，必须重新整合
xcodebuild -workspace Hily.xcworkspace -scheme Hily -configuration Debug \
  -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|BUILD SUCCEEDED|BUILD FAILED"
```
目标 `** BUILD SUCCEEDED **`。

### 10. 交付说明
诚实说明限制与待确认项：
- **本机无法渲染**（device-only framework 挡住模拟器）→ 最终视觉验收需用户在 Xcode Preview / 真机做
- 无切图的元素（如头像）→ 用了什么占位，待替换
- 单态切图（如只有 ON 态的开关）→ 行为说明
- 装饰渐变色值 / 圆角 ±2pt 为估值，列出可微调点

## iOS 16 兼容硬规则
- `foregroundStyle()` 优先于 `foregroundColor()`；**但 Text 插值片段着色用 `foregroundColor`**（返回 Text 的 `foregroundStyle` 是 iOS 17+）
- **禁 Text `+` 拼接**，用插值：`Text("\(a)\(b)")`，片段是各自 styled 的 `Text`
- `ForEach` 不能直接吃 `enumerated()`（Sequence 非 RandomAccessCollection）→ 用 `Array(seq.enumerated())` 或 `indices`
- 隐藏滚动条用 `.scrollIndicators(.hidden)`，非 `showsIndicators: false`
- 圆角用 `clipShape(RoundedRectangle(cornerRadius:style:.continuous))`
- 不引入第三方库

## 反模式（不要做）
- 不重画切图已提供的图标
- 不在 View 里写副作用
- 不硬编码文案 / 不用 left/right
- 不让审查 agent 跑像素采样循环
- 不跳过 xcodegen→pod→build 验证就声称完成
- 不声称"像素完美"——声称"高保真 + 列出待验收点"，由用户真机拍板
