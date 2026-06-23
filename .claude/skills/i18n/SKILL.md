---
name: i18n
description: Hily 项目 iOS i18n 管理（en/ar/tr 三语言 Localizable.strings）。Use when 用户提到"多语言/i18n/翻译/Localizable.strings/L10n/校验语言文件/同步翻译/审计硬编码文案"，或当用户用 /i18n validate / sync / translate / audit 时。
argument-hint: [validate|sync|translate|audit] [可选 key 名]
allowed-tools: Read, Edit, Write, Bash(bash .claude/skills/i18n/scripts/*), Grep, Glob
---

# Hily i18n 管理

Hily iOS 项目的 i18n 工作流入口。覆盖三个语言（en/ar/tr）的 `Localizable.strings` + `L10n.swift` 中转层。

## 项目 i18n 架构（必读）

| 路径 | 用途 |
|---|---|
| [Sources/L10n.swift](../../../Sources/L10n.swift) | i18n key 中转层。每个字段是 `static var ... { localize("key.path", comment: "...") }` 形式 |
| [Sources/en.lproj/Localizable.strings](../../../Sources/en.lproj/Localizable.strings) | 英文 source-of-truth |
| [Sources/ar.lproj/Localizable.strings](../../../Sources/ar.lproj/Localizable.strings) | 阿拉伯语（RTL，自动镜像） |
| [Sources/tr.lproj/Localizable.strings](../../../Sources/tr.lproj/Localizable.strings) | 土耳其语 |
| [Sources/en.lproj/InfoPlist.strings](../../../Sources/en.lproj/InfoPlist.strings) | 相机/麦克风权限弹窗文案（ar/tr 同名同位置） |
| [Sources/Core/DebugLocaleSwitcher.swift](../../../Sources/Core/DebugLocaleSwitcher.swift) | DEBUG 运行时切语言（Work 页 Hi 按钮触发） |

**关键设计**：
- `localize()` 函数在 DEBUG 路由到 `DebugLocaleStore.shared.subBundle`，Release 走 `NSLocalizedString` —— 切语言**无需重启**
- 调用方语法 `L10n.fooBar`（computed property）
- View 调用 `Text(L10n.foo)` / `Button(L10n.foo)`；Service 调用 `errorMessage = L10n.foo`

## 四个 action

执行哪个 action 由 `$ARGUMENTS[0]` 决定：

### `validate` — 校验三语言一致性
**何时**：commit 前、新增 key 后、收到翻译团队回复后

跑 `bash .claude/skills/i18n/scripts/validate.sh`，校验：
1. en/ar/tr 三个文件 key 集合是否完全一致
2. 每个 key 的占位符（%@ / %d / %1$@ 等）数量+顺序一致
3. `L10n.swift` 引用的所有 key 都在 strings 文件存在

**报告结果给用户**。脚本退出码非 0 时**不要**自动修复，先把问题列出来让用户判断（可能是 key 重命名/弃用）。

### `sync` — 新增 key 同步到三语言文件
**何时**：用户在 `L10n.swift` 加了新字段，但 strings 文件还没补 key

工作流：
1. Grep `L10n.swift` 找出所有 `localize("xxx", ...)` 的 key
2. Diff 出 `en.lproj/Localizable.strings` 里**缺失**的 key
3. 询问用户每个缺失 key 的 en 值
4. 同时写入 en/ar/tr 三个文件（ar/tr 暂用 en 占位，标 `// TODO: translate`）
5. 自动跑 `validate` 校验对齐
6. 提示用户后续可用 `/i18n translate <key>` 把占位翻译为真实 ar/tr

### `translate` — AI 翻译指定 key 到 ar/tr
**何时**：sync 后占位翻译需要变成真实翻译；或翻译团队接手前的草稿

参数：`$ARGUMENTS[1]` 是 key 名（如 `auth.title`），可同时传多个，逗号分隔。

工作流：
1. **必读** [references/glossary.md](references/glossary.md)：项目术语词汇表、品牌词不翻译列表、占位符规则
2. **必读** [references/translation-style.md](references/translation-style.md)：ar/tr 风格指南
3. 从 `en.lproj/Localizable.strings` 读 en 值
4. 按 glossary + style guide 草翻 ar / tr，注意：
   - 占位符 `%@` / `%d` 数量和位置不变
   - 品牌词（Hily/FaceUnity/Prime/Cysle 等）保留原样
   - 长度控制：按钮 ≤ en × 1.5，错误提示 ≤ en × 1.8
   - 双 placeholder 且语序可能跨语言不同 → 升级到 positional `%1$@ %2$@`
5. 写入 `ar.lproj` 和 `tr.lproj`，替换占位
6. 跑 `validate` 校验占位符对齐
7. 提示用户：「占位翻译完成。J 里程碑前请翻译团队复审地道性」

### `audit` — 扫描代码硬编码文案
**何时**：合并新 feature 前检查是否有遗漏的 i18n / 加新 View 后

工作流：
1. Grep `Sources/**/*.swift` 寻找硬编码 UI 文案：
   ```
   Text\("[^"]+"\)
   Button\("[^"]+"\)
   Label\("[^"]+",
   prompt: Text\("[^"]+"\)
   .alert\("[^"]+"
   ```
2. 排除：
   - `// comment` 内字符串
   - `Text(L10n.xxx)`（已 i18n）
   - `Text("\(...)")`（纯插值）
   - `Image(systemName: "xxx")` SF Symbol 名
   - **POC 调试台**：`Sources/Home/POCDebugView.swift` 与 `Sources/Home/HomeView.swift` 的 POC 浮按钮，上线前删除（comment 标明），跳过
   - **调试 HUD/日志**：`debugNetworkPanel` 这种 DEBUG-only 视图
3. 把找到的硬编码列表（路径:行号 + 字符串内容）报告给用户
4. 询问每条：(a) 抽进 L10n（自动建议 key 名）/ (b) 标 DEBUG-only 不处理 / (c) 跳过
5. 用户决策后批量更新代码 + `L10n.swift` + 三语言 strings 文件

## 通用约定

- **任何修改 `Localizable.strings` 后都要跑 `validate`**
- **新 key 命名**：`模块.场景` lowerCamelCase 拼接（如 `auth.email`, `liveRoom.endLive`）；不要用 `button.x` / `field.x` 这种 UI 控件维度，用业务域维度
- **修改 `L10n.swift` 时**保持 `comment` 字段含中文释义（便于阅读）；computed property 形式 `static var xxx: String { localize("k", comment: "…") }`
- **不要碰** Sources/Home/POCDebugView.swift 和 Sources/Home/HomeView.swift 的 POC 浮按钮 — 这两处中文文案故意保留（comment 明示上线前整体删除）
- **commit 时**修改了 strings/L10n.swift → 必须同时提供「修改影响清单」（哪些 view 受影响），便于 reviewer 真机抽验 ar/tr

## 参考

- [references/glossary.md](references/glossary.md) — Hily 项目术语词汇表（品牌词、业务术语、占位符规则）
- [references/translation-style.md](references/translation-style.md) — ar / tr 风格指南
- [scripts/validate.sh](scripts/validate.sh) — 三语言 + L10n.swift 校验脚本
- [CLAUDE.md 国际化条款](../../../CLAUDE.md) — 项目层级 i18n 约定（布局用 leading/trailing、时区固定 Asia/Shanghai 等）

## 验收标准

action 执行完后必须满足：
- [ ] `bash .claude/skills/i18n/scripts/validate.sh` 退出码 0
- [ ] `xcodebuild ... build` SUCCEEDED（如果改了 L10n.swift 或 View）
- [ ] 给用户列出受影响的 View 文件路径 + 行号
- [ ] 提示「翻译团队复审项」（首次 ar/tr 落地或新加双 placeholder format key）
