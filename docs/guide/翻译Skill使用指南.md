# 翻译 Skill 使用指南（/i18n）

> 本工程的 i18n 工作流入口。覆盖 en/ar/tr 三语言 `Localizable.strings` + `L10n.swift`。

## 速查表

| 我要做什么 | 命令 |
|---|---|
| 改完代码 commit 前校验三语言一致性 | `/i18n validate` |
| 在 `L10n.swift` 加了新 key，要补到 ar/tr | `/i18n sync` |
| 把某个 key 的 en 值翻译成 ar/tr | `/i18n translate <key>` |
| 检查代码里是否还有硬编码字符串没走 L10n | `/i18n audit` |

## 实战示例

### 场景 1：commit 前快速校验
```
/i18n validate
```
3 项自动校验：① en/ar/tr key 集合对齐 ② 占位符 %@/%d 数量+顺序一致 ③ L10n.swift 引用的 key 都存在。退出码非 0 不要自动修复，看清问题再决定。

### 场景 2：写完新 View 后增量加 i18n
```
1. 在 L10n.swift 加 static var newKey: String { localize("module.newKey", comment: "...") }
2. /i18n sync          → 自动在 en/ar/tr 三个 .strings 占位写入
3. /i18n translate module.newKey  → 把 ar/tr 占位翻译为真实文案
4. /i18n validate      → 确认对齐
```

### 场景 3：审计遗漏
```
/i18n audit
```
扫 Sources/**/*.swift 找 `Text("...")` / `Button("...")` 等漏走 L10n 的硬编码。自动跳过 POC 调试台和 DEBUG-only HUD。

## 关键文件

| 路径 | 用途 |
|---|---|
| [Sources/L10n.swift](../../Sources/L10n.swift) | i18n key 中转层（computed property） |
| [Sources/en.lproj/Localizable.strings](../../Sources/en.lproj/Localizable.strings) | 英文 source-of-truth |
| [Sources/ar.lproj/Localizable.strings](../../Sources/ar.lproj/Localizable.strings) | 阿拉伯语（RTL 自动镜像） |
| [Sources/tr.lproj/Localizable.strings](../../Sources/tr.lproj/Localizable.strings) | 土耳其语 |
| [Sources/Core/DebugLocaleSwitcher.swift](../../Sources/Core/DebugLocaleSwitcher.swift) | DEBUG 运行时切语言（Work 页 Hi 按钮） |
| [.claude/skills/i18n/](../../.claude/skills/i18n/) | skill 本体（SKILL.md + glossary + style guide + validate.sh） |

## 真机切语言验证

启动 app → Work 页 → 点 **Hi** 工具按钮 → 选 `System / English / العربية (RTL) / Türkçe`。文案+RTL **立即生效**，无需重启。

## 关键约束（容易踩坑）

- **只 `Hily` 保留不翻译**；SDK 厂商名 `FaceUnity` / `Agora` / `NIM` 按行业惯例保留英文（不算品牌词）
- 拼写错误**改正**（i18n key 名保持不变，只改 value）：`Cysle` → `Cycle` / `دورة` / `Döngü`
- 占位符 `%@` `%d` **数量+顺序**翻译后必须一致
- 新 key 命名：`模块.场景`（业务域，不用 `button.x` 这种 UI 控件维度）
- 修改 `Localizable.strings` 后**必跑** `validate`

## 已知 backlog

- `livePrepare.errorPrefix` / `call.errorConnectPrefix` 双 `%@` 占位符需升级为 positional `%1$@` `%2$@`（J 里程碑翻译团队复审时处理）
- ar/tr 当前是开发者占位翻译，J 里程碑前由翻译团队复审地道性
