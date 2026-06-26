---
name: review
description: Hily iOS 代码审查工作流入口。Use when 用户用 /review deep [scope] 做一次性深度审查（Workflow 5 维并行+对抗验证），或 /review loop [scope] 启动增量挖深 loop。scope: diff | all | <path>
argument-hint: <deep|loop> [diff|all|<路径>]
allowed-tools: Read, Write, Edit, Bash, Grep, Glob, Workflow, ScheduleWakeup
---

# Hily 代码审查工作流

两个核心动作 + 三种范围。基于 Workflow 深度铺底 + /loop 增量挖深的复合设计。

## 入参解析

从 `$ARGUMENTS` 解析：
- `$ARGUMENTS[0]` = mode：`deep` 或 `loop`（必填）
- `$ARGUMENTS[1]` = scope：`diff`（默认） / `all` / `<路径>`

未提供或非法 → 提示用户重新输入，不要猜。

## scope 三档解析规则

| scope | 实现 | 文件列表来源 |
|---|---|---|
| `diff`（默认） | `git diff --name-only HEAD` ∪ `git diff --name-only --cached` | 仅看 `.swift` 文件，且在 `Sources/` 下 |
| `all` | `git ls-files Sources/` | 全工程 Swift 源文件 |
| `<路径>` | 直接 ls + glob | 路径下所有 `.swift`（支持文件/目录） |

**diff 为空时退化**：审最近 1 commit 改动（`git show --name-only --pretty=format: HEAD`），并在报告里明确声明退化原因。

## 时间戳与报告路径

- 时间戳：`yyyyMMddHHmm`（用 `date +%Y%m%d%H%M`），如 `202606241430`
- deep 输出：`docs/plan/代码审查报告-<时间戳>.md`
- loop 累积：`.claude/review-state/loop-findings.md`（持续追加，跨多轮）

## mode = deep（Workflow 深度审查）

### 流程

1. **收集文件清单**（按 scope 三档）
2. **算时间戳** + 准备输出路径
3. **调 Workflow** 跑 5 维并行 finder + 3 票对抗验证：
   ```
   Workflow({
     scriptPath: "/Users/joe/Desktop/HN/ios-anchor-livechat/.claude/skills/review/scripts/deep.workflow.js",
     args: {
       scope: "<diff|all|路径>",
       files: ["Sources/...", ...],   // 真实文件路径数组
       timestamp: "202606241430",
       projectRoot: "/Users/joe/Desktop/HN/ios-anchor-livechat"
     }
   })
   ```
4. **Workflow 返回** `{ findings: [...] }`（已合并去重+投票通过）
5. **🛑 强制二次复查**（**不可跳过**）：Workflow 内的 3 票对抗只是 finder agent 互投，**不等同**于 [.claude/rules/code-review-discipline.md](../../rules/code-review-discipline.md) §1/§6 要求的"实际产品调用链路证据"。主流程必须**对每一条 finding** 做：
   - **Read 涉及文件**对应行号，确认描述与源码一致（finder 可能描述 line 与现状偏移、可能误判 add/remove 配对）
   - **Grep 实际调用方**：风险声明的触发场景在产品代码里是否有调用路径
   - **按 rule §2 三档分级**：找到产品调用证据 → **必修**；理论存在但 0 触发证据 → **建议**；无声 bug / 风格 → **信息**
   - **finder 误判直接剔除**（不进报告，或在报告里标记"finder 误判，已剔除"）
6. **主流程渲染** findings → markdown，Write 到 `docs/plan/代码审查报告-<时间戳>.md`，**报告内必须**：
   - 每条 finding 标"**复查后判定**：必修/建议/信息"，与 finder 原始 severity 分开列
   - 末尾"**复查统计**"表：原始 N 项 / 必修 X / 建议 Y / 信息 Z / 误判剔除 W
7. **报告给用户**：路径 + **复查后**必修/建议/信息计数 + 关键摘要 + finder 原始计数（透明对照）

### Workflow 维度

5 个 finder 并行，每个聚焦一个维度（对齐你 2026-06-23 已有报告的维度划分）：

| 维度 | 聚焦内容 |
|---|---|
| `ios-spec` | iOS 平台规范、Apple HIG、API 用法、生命周期、Info.plist、Privacy Manifest |
| `concurrency` | Swift Concurrency、@MainActor、weak self、actor 隔离、SDK 回调线程 |
| `memory` | 引用循环、deinit 缺失、observer 残留、CoreFoundation 跨语言桥接 |
| `swiftui-perf` | 失效风暴、@StateObject vs @ObservedObject 误用、顶层 .animation 污染、Identity 不稳定 |
| `security` | 凭据存储（Keychain vs UserDefaults）、日志泄露、网络明文、ATS、AES 密钥硬编码 |

每个发现 3 票对抗验证（视角：`correctness` / `severity-calibration` / `fix-validity`），≥2 票 isReal=true 才保留。

### 输出 markdown 格式

模板（与你已有报告兼容）：

```markdown
# Hily iOS 主播端 代码审查报告

> 审查时间：<timestamp 转日期>
> 审查范围：<scope 描述，如 "diff（17 个未提交文件）" 或 "Sources/ 全量"> 
> 审查方式：5 维度并行 + 3 票对抗验证 / 由 /review deep 自动生成
> 审查依据：CLAUDE.md + .claude/rules/*

## 一、概览
<计数表：P0 / P1 / P2>

## 二、P0（必须改）
### P0-1 <title>
- 文件：<file:line>
- 维度：<dimension>
- 风险：<risk>
- 修复：<fix>

## 三、P1（应该改）
...

## 四、P2（可以改）
...
```

## mode = loop（/loop 增量挖深）

### 流程

1. **找最新审查报告**：`ls docs/plan/代码审查报告-*.md | sort | tail -1`
   - 不存在 → 提示用户先跑 `/review deep <scope>`，**不要自动触发**（避免误烧 token）
2. **读 baseline**：最新报告 + `.claude/review-state/loop-findings.md`（如存在）
3. **启动 /loop 动态模式**（用 ScheduleWakeup 自我调度）：
   - 每轮调用 `scripts/loop-prompt.md` 模板生成单轮 prompt
   - 单轮内：选一个未深挖的维度/角度 → 跑 swiftui-pro 或 /code-review high → LLM 语义去重 → append `.claude/review-state/loop-findings.md`
4. **退出条件**（满足任一）：
   - 用户中断
   - token 预算耗尽（用户用 `+500k` 等指令传入 budget）
   - 连续 2 轮 0 新增
5. **退出时打印**：
   - 本轮 loop 共新增 N 条
   - 提示「`.claude/review-state/loop-findings.md` 是 loop 累积，建议人工 merge 到 docs/plan/，或下次跑 /review deep 自动归并」

### 单轮间隔

用 ScheduleWakeup 动态模式，建议 600~1200s（避免 5 分钟 cache 边界），由 Claude 自己根据本轮收获多少决定：
- 本轮发现 ≥3 条 → 加快（600s）
- 本轮发现 0~2 条 → 放慢（1200s）

### loop 单轮 prompt 模板

详见 [scripts/loop-prompt.md](scripts/loop-prompt.md)。核心约束：
- prompt 内必须显式列出 baseline 已覆盖的发现摘要（标题 + 文件名）
- 明确告知 LLM「请挖未覆盖角度」
- 语义去重：让 LLM 判断「这个新发现是否等价于已知第 X 项」，等价则跳过

## 与已有审查报告的衔接

- 你 2026-06-23 已生成 `docs/plan/代码审查报告-202606231230.md`（33 项），**无需 import**
- `/review loop diff` 启动时会自动 pick 这一份作为 baseline
- 下次 `/review deep` 会生成新报告（新时间戳），旧报告保留作为归档

## 不做什么（明确边界）

| 用户可能期待但本 skill 不做 | 替代方案 |
|---|---|
| 自动修复发现 | 用 `/code-review --fix` |
| 状态查询子命令 | `cat docs/plan/代码审查报告-*.md` 或 `cat .claude/review-state/loop-findings.md` |
| 清空 baseline | `rm .claude/review-state/loop-*.md` |
| 导入旧报告 | 自动读 `docs/plan/` 最新一份，无需迁移 |
| 修复回归验证（自称已修自动验证） | M2 范围，本版不做 |
| 跨分支同步 baseline | 用户单兵作战、当前都在 main，per-branch 无收益 |

## 验收标准

执行完后必须满足：
- [ ] `deep` 模式：`docs/plan/代码审查报告-<时间戳>.md` 已生成，markdown 合法可读
- [ ] `deep` 模式：报告头部含 scope 描述 + 审查方式说明
- [ ] `deep` 模式：所有 finding 均通过 ≥2 票对抗验证（Workflow 内部保证）
- [ ] `deep` 模式：**Workflow 返回后已对每条 finding 做二次复查**（Read 源码 + Grep 调用方），报告内含"复查后判定"列 + 复查统计表（含误判剔除数）
- [ ] `loop` 模式：每轮新增条目 append 到 `.claude/review-state/loop-findings.md`
- [ ] `loop` 模式：退出时打印汇总 + 后续操作提示
- [ ] 任何模式：不修改 Sources/ 下任何源码（review 是只读的）
- [ ] 任何模式：报告里出现的文件路径都加 markdown 链接 `[file](file)` 方便点选

## 参考

- [scripts/deep.workflow.js](scripts/deep.workflow.js) — 5 维 finder + 3 票 verifier Workflow 脚本
- [scripts/loop-prompt.md](scripts/loop-prompt.md) — loop 单轮 prompt 模板
- [docs/plan/代码审查报告-202606231230.md](../../../docs/plan/代码审查报告-202606231230.md) — 当前 baseline（人工产出，loop 首启基线）
- [CLAUDE.md](../../../CLAUDE.md) — 项目规范主入口
- [.claude/rules/](../../rules/) — 项目细则（i18n / 错误处理 / SwiftUI camera preview / 编码完整性 / git 工作流 / 文档输出）
