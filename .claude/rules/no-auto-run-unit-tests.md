# 禁止自动运行 xcodebuild test / swift test

> 来源：2026-07-17 F-1a Task 1 完成后自动跑 `xcodebuild test` 撞上 HilyTests target 的 pre-existing broken（非本任务范围的 10 errors，属另一会话未收尾），耗时 240s + 无从修复。用户显式指令："不要自动跑单元测试"。

## 规则

impl 阶段完成一个 task 后，**默认禁止**自动运行 `xcodebuild test` / `swift test` / `xctest` 等测试执行命令。

**允许**的验证方式（顺序从轻到重）：

1. **`xcrun swiftc -parse`** 单文件语法+类型检查（<5s，无 SDK 依赖代码用）
2. **`xcodebuild build`** 编译验证（不跑测试；用于确认改动没破坏构建）
3. **让用户自己在 Xcode 里 Cmd+U 跑测试**（用户端观察比 log 更直观）
4. **真机验证**（对 UI/RTC/IM 类改动，比单测覆盖更真实）

**只有用户明确要求"跑测试"/"跑 xcodebuild test"/"验证 test 通过"时**，才允许运行测试执行命令。

## Why

**具体触发场景**（F-1a Task 1 真犯）：
- Task 1 PartyBattleTypes.swift 代码就位 + 5 XCTest 就位
- 自动跑 `xcodebuild test -only-testing:HilyTests/PartyBattleTypesTests` → 240s 后失败
- 失败原因是 **HilyTests target 里其他文件 pre-existing broken**（`AppToastCenter/L10n/PartyAPI/ImageUploader not in scope` + `PartyRoomInfoDecodeTests` 缺 11 args）
- 与 Task 1 完全无关，属 uncommitted-broken-hands-off rule 领域"另一会话未收尾"
- 我按 rule 不能顺手修 → **验证阻塞 → 每 task 完成后都会撞同款问题** → 循环卡死

**核心矛盾**：
- 多会话协作项目里，主分支任意时刻可能有另一会话的半成品未 commit
- test target 是"全 target 依赖"的（任一 whitelist source 挂全 target 挂）
- 自动跑测试变成"测别人有没有干完"，不是"测我干得对不对"

**正解**：
- 单文件语法检查（swiftc -parse）足以捕捉 90% 的 Task 1-11 数据/model/service 层错误
- 剩余 10% 语义错误由用户在 Xcode Cmd+U 跑测试或真机验证时暴露
- 每 task 都跑全 target 测试是"过度自动化" → 阻塞频发 + 耗时长

## How to apply

**每 task 完成后**：
- [ ] 写测试代码（TDD 铁律仍在，测试代码质量不变）
- [ ] **不**跑 `xcodebuild test` / `swift test` 除非用户明说
- [ ] 若代码是纯 Foundation（无 SDK 依赖）→ 跑一次 `xcrun swiftc -parse` 验证语法（5s 内）
- [ ] 若代码依赖 SDK/framework → 跑一次 `xcodebuild build` 编译验证（不跑测试）
- [ ] 提示用户："Task N code 就位 + 语法/编译通过；如需跑测试请 Xcode Cmd+U 或明说"

**用户明说"跑测试"时**：正常跑 xcodebuild test，遇到非本 task 范围的 broken 按 uncommitted-broken-hands-off rule 停下报告，不顺手修。

## 与既有规则关联

- [uncommitted-broken-hands-off.md](uncommitted-broken-hands-off.md) —— 遇到 pre-existing broken 停下不修；本 rule 是**上游预防**（不自动触发到 broken 场景）
- [verification-before-completion](../..) skill —— "evidence before assertions"；本 rule 明示"evidence"不必是"xcodebuild test 通过"，`swiftc -parse` 或用户 Cmd+U 或真机验证都是有效 evidence
- [xcodebuild-log-filter-split.md](xcodebuild-log-filter-split.md) —— 若确实要跑测试，命令拆两步；本 rule 补"默认不跑"

## 不适用

- 用户明确要求跑测试
- CI/pre-commit hook 里的自动测试（那属工程配置层，不是我 impl 阶段行为）
- feature-pipeline skill 里明示"每验收门必跑测试"的 milestone DoD（如 F-1a §9.1 真机 DoD 由用户手动跑，非我自动）
- code-review skill 跑深度评审时的编译验证

## 历史教训

- **2026-07-17 F-1a Task 1**：Task 1 完成自动跑 xcodebuild test → 撞 HilyTests target 10 errors（全在 F-1a 范围外）→ 240s 白花 → 用户明确说"不要自动跑单元测试"。本 rule 沉淀让未来所有 iOS impl 任务默认走轻量验证路径。
