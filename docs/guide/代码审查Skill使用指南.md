# 代码审查 Skill 使用指南

> 主流程只需记 3 档命令；其余按问题驱动 lazy-load。

## 主流程（按节奏触发）

### 档 1：commit 前（每次，30 秒）
```
/code-review
```
覆盖 90% 日常场景：通用 bug + 清理建议。

### 档 2：feature 完成（5 分钟）
```
apple-ios/coding-best-practices        # 代码质量（SwiftUI 状态管理 / MVVM / Core Data）
apple-ios/ui-review                    # 仅当涉及 View 改动
```

### 档 3：里程碑收尾（B/C/D 等节点）
```
apple-release-review                   # 含 security/privacy/distribution/ux 4 个 checklist
superpowers:code-reviewer              # 对照里程碑 spec 整体校验
```

## 按需触发（问题驱动，不进主流程）

| 遇到什么 | 用哪个 |
|---------|-------|
| 卡顿 / 掉帧 / 重绘风暴 | `apple-performance/swiftui-debugging`，仍不定位再上 `apple-performance/profiling`（Instruments 真机 Release build） |
| 大重构前要测试兜底 | `apple-testing/tdd-refactor-guard`；缺测试用 `apple-testing/characterization-test-generator` 锚定现有行为 |
| 多语言 / 无障碍专审（en/ar/tr） | `apple-ios/assistive-access` |
| 只想清理代码（不查 bug） | `/simplify` |
| 涉及密钥 / 加解密 / token 改动 | `/security-review` |

## 删减说明（与旧版差异）

- 删除 `swiftui-pro` 主流程位：与 `apple-ios/coding-best-practices` 职责重叠，默认走 apple-ios；专门审 SwiftUI 现代 API 性能时手动调用，不进指南
- 删除 `apple-swift/*`：面向 Swift 6 / iOS 26，本项目 Swift 5 暂不适用，等升级时再看
- 删除 `apple-ios/migration-patterns` 主流程位：iOS 16 兼容不是审查节奏问题，重构时偶发，归入按需
- `api-design-checklist` 不用：本项目无对外 SDK

## Skill 装在哪

全部在 `~/.claude/skills/apple-*/`（全局，所有项目可用）。卸载直接 `rm -rf` 对应目录。
