# 跑 xcodebuild build/test 需筛日志时必拆两步 Bash 调用

> 来源：2026-07-13 会话用户反馈"xcodebuild + grep + head 复合命令反复被 Claude Code 询问权限"—— `Bash(xcodebuild *)` 通配对含 pipe/重定向的复合命令**不生效**，每次改 grep pattern 都要手加 local 白名单。

## 规则

**跑 xcodebuild build/test/clean 后想筛 error/warning/BUILD 状态时，禁止**在一条 Bash 调用里用 `|` 管道拼 grep/head。**必须**拆成两步：

```bash
# ❌ 反例（每次 grep pattern 一变都触发权限询问）
xcodebuild -workspace Hily.xcworkspace -scheme Hily ... build 2>&1 \
  | grep -E "error:|warning:.*LoginView|BUILD SUCCEEDED" | head -30

# ✅ 正例：拆两条独立 Bash 调用
# Bash 1: 命中 Bash(xcodebuild *) 通配，不问
xcodebuild -workspace Hily.xcworkspace -scheme Hily ... build 2>&1 > /tmp/hily-build.log
# Bash 2: grep/head 自动允许，不问
grep -E "error:|warning:.*LoginView|BUILD SUCCEEDED" /tmp/hily-build.log | head -30
```

## Why

Claude Code 权限系统对**含 `|` 管道 + `2>&1` 重定向 + 换行续行**的复合命令走**整体精确匹配**（非逐段通配）：

- `Bash(xcodebuild *)` 通配只对**单条独立** xcodebuild 命令生效
- 一旦拼 `| grep ... | head`，整体被视为复合命令 → 通配失效 → 每次 grep pattern 变化都触发新的精确匹配 → 反复询问
- 用户 `.claude/settings.local.json` 里的两条 `Bash(xcodebuild ... 2>&1 > /tmp/hily-warn.log; grep -E ...)` 精确条目就是撞过这坑手加的历史遗留

**代价对比**：
- 拆两步：多一次 Bash 调用（<100ms 开销）
- 不拆：每次改 grep pattern 都要手加 local 白名单 or 每次询问

## 触发条件

任一命中即拆：

- [ ] 命令含 `xcodebuild ... build/test/clean`
- [ ] 命令含 `|` 管道 或 `2>&1` 重定向 或 `\` 换行续行
- [ ] 需要 grep/head/tail/awk/sort 筛选 xcodebuild 输出

## How to apply

**标准 build + 筛日志模板**：

```bash
# Step 1: build（一定命中 Bash(xcodebuild *) 通配）
xcodebuild -workspace Hily.xcworkspace -scheme Hily \
  -configuration Debug -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 > /tmp/hily-build.log

# Step 2: 筛选（grep/head 自动允许）
grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" /tmp/hily-build.log | tail -50
```

**test 同理**：

```bash
# Step 1
xcodebuild -workspace Hily.xcworkspace -scheme Hily test \
  -destination 'platform=iOS Simulator,name=iPhone 15' 2>&1 > /tmp/hily-test.log
# Step 2
grep -E "Test Case.*(passed|failed)|error:|Executed " /tmp/hily-test.log | tail -40
```

## 不适用

- xcodebuild 单条命令无需筛日志（直接跑，Bash 通配放行）
- xcodegen generate / pod install（无输出量问题，短命令直接跑）

## 与既有规则关联

- [xcodegen-podinstall-binding.md](xcodegen-podinstall-binding.md) —— 构建工作流铁律；本 rule 补"筛构建日志的命令形式"
- [probe-reading-discipline.md](probe-reading-discipline.md) —— 侦察节制思维；本 rule 是"Bash 调用节制"的具体应用
