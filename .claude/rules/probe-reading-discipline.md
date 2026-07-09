# 侦察阶段阅读节制

> 来源：2026-07-08 会话——"审查未完成功能"型请求触发 explore agent 综合 3 份大文档（路线图 / 执行追踪 / 已实现审查），得出的"里程碑状态"过时不准（工程实际比文档超前）；真实决策靠 4 条 `ls Sources/{...}` 就能得到，agent 综合的几万 token 全废。同会话 AskUserQuestion 前 `head -80` 读 2 份 spec 判断规模，用户没按推荐选，head 信息未参与决策。

## 规则

**动手读前问自己**：这份文档的结论若被用户否决/覆盖，代价是什么？代价 = 已烧 token。

三个具体守则：

### 1. 判断"是否已落地/是否存在" → 用 `ls / grep / find`，不综合文档

- 文档滞后于工程是**常态**（协作者 commit 后不同步路线图）
- `ls Sources/<模块>/` + `grep -l <关键 symbol>` 一两条命令就能拿到真实答案
- **禁**默认调 explore agent 综合"路线图 + 执行追踪 + 已实现审查"三份大文档判断状态——agent 输出可能被过时文档污染

### 2. 规模判断 → `wc -l`，不 `head`

- 判断 spec 是 B 档还是 A 档（是否复杂）只需要行数 + 文件大小
- 读 80 行的价值一般 < 直接问用户"这份 spec 你想让我做吗"
- 只有决定要做**之后**才全读

### 3. AskUserQuestion 前的探测阅读要极简

- 只读**决策必需**的最小信息
- 备选方案 ≤4 个且差异明显时可以直接问，不侦察
- 若备选方案本身是"读 X 或读 Y"，那就 wc -l 拿元数据后问，不预读内容

## Why（真实代价）

**2026-07-08 会话**：
- explore agent 综合 3 份大文档（路线图 + 执行追踪 + 已实现审查）→ 输出的里程碑状态表把 B/C/H-2/I 4 份 spec 标"已启动"，实际这 4 份都已**落地代码**
- 真实判断路径：`ls Sources/Message/Chat/ Sources/Profile/EditProfile/ Sources/Live/LiveResult*` 4 条 grep 就够
- 浪费：agent context 数万 token；用户看到的推进方案基于**过时结论**（我先按 agent 判断得出错误优先级，再自己 grep 纠正）

## How to apply

侦察前 checklist：

- [ ] 这个问题能不能用 1-2 条 `ls/grep/find` 直接回答？能 → 不调 agent
- [ ] 我要读的这份文档，会不会已经**过时**？（凡是"路线图 / 追踪 / 状态快照"类文档，几乎必定滞后）
- [ ] 我读的内容若被用户否决，代价是什么？大 → 先问再读；小 → 直接读
- [ ] AskUserQuestion 之前，我读的信息**是否会真实参与决策**？不会 → 别读

## 与既有规则关联

- [code-review-discipline.md](code-review-discipline.md) §7 "工具产出 ≠ 二次复查" —— 同源精神：agent 输出不能替代自己 grep 验证
- [feature-pipeline-complexity-tier.md](feature-pipeline-complexity-tier.md) —— B 档"确认点用陈述+反驳指引"，本 rule 补"确认前的侦察也要节制"
- [root-cause-investigation.md](root-cause-investigation.md) —— 追根因优先看日志证据链头；本 rule 补"跨模块侦察优先 grep 工程代码"

## 不适用场景

- 需要跨模块理解的架构设计 → 全量读文档合理
- 多轮 grep 才能拼出的信息（如"这个字段的所有调用方 + 语义演进"）→ 用 explore agent
- 用户明示"审查全量"/"深度理解某模块" → 授权全读
