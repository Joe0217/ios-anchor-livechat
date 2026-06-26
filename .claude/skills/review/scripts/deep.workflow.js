// Hily iOS 代码深度审查 Workflow
//
// 由 .claude/skills/review/SKILL.md 的 deep 模式调用。
//
// 输入 args:
//   - scope: string                 ("diff" | "all" | "<path>")
//   - files: string[]               待审查的 .swift 文件路径数组（相对 projectRoot）
//   - timestamp: string             yyyyMMddHHmm，用于报告文件名
//   - projectRoot: string           工程根绝对路径
//
// 返回:
//   { findings: Finding[], scope, timestamp, fileCount }
//
// Finding 结构:
//   { id, severity, title, file, line, dimension, risk, fix }
//
// 主流程（不是本脚本）拿到结果后，渲染 markdown 写入 docs/plan/代码审查报告-<timestamp>.md。

export const meta = {
  name: 'hily-deep-review',
  description: 'Hily iOS 代码深度审查（5 维并行 finder + 3 票对抗验证）',
  phases: [
    { title: 'Find', detail: '5 维度并行扫描' },
    { title: 'Verify', detail: '每发现 3 票对抗验证' },
    { title: 'Synthesize', detail: '合并去重 + 严重度仲裁' },
  ],
}

// ---------------------------------------------------------------------------
// 维度定义（对齐 docs/plan/代码审查报告-202606231230.md 的 5 维度划分）
// ---------------------------------------------------------------------------

const DIMENSIONS = [
  {
    key: 'ios-spec',
    label: 'iOS 平台规范',
    focus: `iOS 平台规范、Apple 提审合规、Info.plist 配置、Privacy Manifest、生命周期 API 用法。
重点检查：
- ITSAppUsesNonExemptEncryption 是否声明（项目用 AES）
- PrivacyInfo.xcprivacy 是否齐全（UserDefaults reason / NSPrivacyTracking / accessed API）
- ATS 是否显式声明 NSAllowsArbitraryLoads=false
- SF Symbol 字符串字面量散落
- Dynamic Type / 无障碍 accessibilityLabel 缺失
- 时区是否固定 Asia/Shanghai（项目业务约定）
`,
  },
  {
    key: 'concurrency',
    label: 'Swift 并发',
    focus: `Swift Concurrency 正确性、@MainActor 隔离、weak self、actor、SDK 回调线程切换。
重点检查：
- @Published 字段是否保证 main queue 写
- SDK 回调（Agora / NIM / FaceUnity）是否切到正确 actor
- Task { } 闭包内 weak self 是否补全
- CIImage / CVPixelBuffer 跨线程 ARC 安全（CLAUDE.md v5.3.1 已知坑）
- AVCaptureSession 后台中断/恢复线程
- DispatchQueue 与 Task.sleep 在后台行为差异（CLAUDE.md P1-4 已知坑）
`,
  },
  {
    key: 'memory',
    label: '内存与资源',
    focus: `引用循环、deinit 缺失、NotificationCenter observer 残留、CF 跨语言桥接。
重点检查：
- ObservableObject 类是否补 deinit 兜底（CLAUDE.md P1-5/P1-6 已知坑）
- closure capture self 强引用
- AgoraRtcEngineKit / NIMSDK / FURenderKit 销毁链路
- NotificationCenter observer 是否在 deinit / tearDown 移除
- @StateObject 延迟 deinit 风险
- CoreFoundation 返回值 CF_RETURNS_NOT_RETAINED 桥接（OC 桥）
`,
  },
  {
    key: 'swiftui-perf',
    label: 'SwiftUI 性能',
    focus: `SwiftUI 失效风暴、Identity 不稳定、顶层动画污染、不当的 @State / @StateObject / @ObservedObject 使用。
重点检查：
- 单一巨型 ObservableObject 引发失效风暴
- 顶层 .animation(_:value:) 污染整树 transaction
- switch case 内重复出现的子 View 触发 dismantle（.claude/rules/swiftui-camera-preview.md 规则 1）
- Timer.publish 在 View 内驱动业务计时器（应收敛进 Store）
- 高频 @Published 字段引发整页重渲染（如 networkDebugInfo ≥1Hz）
- ForEach Identity 不稳定
`,
  },
  {
    key: 'security',
    label: '安全与隐私',
    focus: `凭据存储、日志泄露、网络通信、AES 密钥硬编码、cert pinning。
重点检查：
- token / imToken / loginUuid 是否在 Keychain（CLAUDE.md 明确约定）
- 裸 print 含敏感字段（token 前缀、响应体、用户信息）
- AES key / IV / appId / OCP key 硬编码进二进制
- 多环境密钥隔离（xcconfig）
- ATS / cert pinning 缺失
- 是否有越狱检测 / 反调试（直播 App 通常不需要，避免 App Store 4.0 误伤）
`,
  },
]

// ---------------------------------------------------------------------------
// Schema 定义
// ---------------------------------------------------------------------------

const FINDINGS_SCHEMA = {
  type: 'object',
  required: ['findings'],
  additionalProperties: false,
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['title', 'file', 'severity', 'risk', 'fix'],
        additionalProperties: false,
        properties: {
          title: { type: 'string', description: '简短问题描述（≤40 字）' },
          file: { type: 'string', description: '文件相对路径，相对 projectRoot' },
          line: { type: 'string', description: '行号或行范围，如 "104" 或 "104-118"，未知填 "?"' },
          severity: {
            type: 'string',
            enum: ['P0', 'P1', 'P2'],
            description: 'P0 必须改、P1 应该改、P2 可以改',
          },
          risk: { type: 'string', description: '不修的具体后果（避免泛泛而谈）' },
          fix: { type: 'string', description: '具体修复建议，给代码片段或路径' },
        },
      },
    },
  },
}

const VERDICT_SCHEMA = {
  type: 'object',
  required: ['isReal', 'confidence', 'reasoning'],
  additionalProperties: false,
  properties: {
    isReal: { type: 'boolean', description: '这个发现是否是真实问题（默认怀疑为假）' },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
    reasoning: { type: 'string', description: '判断理由，≤80 字' },
    severityAdjust: {
      type: 'string',
      enum: ['keep', 'upgrade', 'downgrade'],
      description: '严重度建议：保留 / 上调一级 / 下调一级',
    },
  },
}

// ---------------------------------------------------------------------------
// 主流程
// ---------------------------------------------------------------------------

const { scope, files, timestamp, projectRoot } = args || {}

if (!Array.isArray(files) || files.length === 0) {
  log('⚠️  files 列表为空，无法审查')
  return { findings: [], scope, timestamp, fileCount: 0 }
}

log(`审查范围：scope=${scope}，文件数=${files.length}，时间戳=${timestamp}`)

const filesBlock = files.map((f) => `- ${f}`).join('\n')

const findPrompt = (dim) => `你是 Hily iOS 工程代码审查员。

# 工程背景
- Hily 是 Swift 5 + SwiftUI iOS 16 工程，主播端直播 App
- 工程根：${projectRoot}
- 关键约定见工程内 CLAUDE.md 与 .claude/rules/*
- 多个 v5.x 系列已知坑已在 CLAUDE.md 记录，对回归极敏感

# 待审查文件
${filesBlock}

# 审查维度
**${dim.label}**

${dim.focus}

# 任务
对上述文件，**仅从 ${dim.label} 维度** 审查，找出真实存在的问题。

要求：
1. 用 Read 工具实际读文件，不要凭空臆测
2. 每个发现给出准确的 file:line（不知道行号填 "?"）
3. severity 标注 P0 / P1 / P2（参考下方标准）
4. risk 必须具体（"不修会导致 XXX"），不要 "可能有风险" 这种空话
5. fix 给具体修复路径或代码片段
6. **不要重复同一问题在不同文件的多次出现**，挑代表性的报，注明 "等 N 处"
7. **不要把已知设计取舍当问题报**（参考 CLAUDE.md "业务约束所致不可改" 清单：双重 MD5、固定 AES key/IV、dev 密钥硬编码、deviceId UUID 等）

# severity 标准
- **P0**：明确违反 CLAUDE.md 约定 / 提审阻塞 / 有崩溃或数据泄露风险 / 用户可感知功能性 bug
- **P1**：稳定性/性能/合规问题，不阻塞功能但影响生产质量
- **P2**：代码风格/可维护性/边角优化

输出 findings 数组（可以为空）。`

const verifyPrompt = (f, lens) => `你是 Hily iOS 代码审查的**独立验证者**，视角：${lens}。

# 待验证发现
- 文件：${f.file}:${f.line}
- 标题：${f.title}
- 严重度：${f.severity}
- 风险描述：${f.risk}
- 修复建议：${f.fix}

# 你的视角
${
  lens === 'correctness'
    ? '严格判断这个发现是否是真实问题。读源码、读相关 spec、读 CLAUDE.md 已知坑。默认怀疑为假，需要证据才确认。'
    : lens === 'severity-calibration'
      ? '判断严重度评级是否合理。可能被高报或低报。结合实际业务影响（功能阻塞 / 用户感知 / 安全风险）评估。'
      : '判断修复建议是否合理可执行。fix 是否会引入新问题、是否考虑了边界情况、是否与现有架构兼容。'
}

# 任务
读 ${f.file} 相关行确认事实，给出 isReal 判断 + reasoning（≤80 字）+ severityAdjust（severity-calibration 视角时必填）。

**默认 isReal=false 除非有证据。** 不要为了合群而通过虚假发现。`

// ---------------------------------------------------------------------------
// pipeline: 5 维 finder → 每发现 3 票 verify
// ---------------------------------------------------------------------------

const VERIFY_LENSES = ['correctness', 'severity-calibration', 'fix-validity']

const dimensionResults = await pipeline(
  DIMENSIONS,
  // Stage 1: finder
  (dim) =>
    agent(findPrompt(dim), {
      label: `find:${dim.key}`,
      phase: 'Find',
      schema: FINDINGS_SCHEMA,
    }),
  // Stage 2: 每个 finding 3 票投票
  (finderResult, dim) => {
    const findings = (finderResult && finderResult.findings) || []
    if (findings.length === 0) {
      log(`  ${dim.label}: 0 个发现`)
      return []
    }
    log(`  ${dim.label}: ${findings.length} 个发现进入验证`)
    return parallel(
      findings.map((f) => () =>
        parallel(
          VERIFY_LENSES.map((lens) => () =>
            agent(verifyPrompt(f, lens), {
              label: `verify:${dim.key}:${(f.file || '?').split('/').pop()}:${lens}`,
              phase: 'Verify',
              schema: VERDICT_SCHEMA,
            })
          )
        ).then((votes) => {
          const validVotes = votes.filter(Boolean)
          const realCount = validVotes.filter((v) => v.isReal).length
          // severity 仲裁：取众数；upgrade > keep > downgrade
          const adjusts = validVotes.map((v) => v.severityAdjust).filter(Boolean)
          const adjust = adjusts.includes('upgrade')
            ? 'upgrade'
            : adjusts.filter((a) => a === 'downgrade').length >= 2
              ? 'downgrade'
              : 'keep'
          return {
            finding: f,
            dimension: dim.label,
            dimensionKey: dim.key,
            realCount,
            totalVotes: validVotes.length,
            adjust,
            votes: validVotes,
          }
        })
      )
    )
  }
)

// ---------------------------------------------------------------------------
// Stage 3: 合并去重 + 严重度仲裁
// ---------------------------------------------------------------------------

phase('Synthesize')

const allVerified = dimensionResults.flat().filter(Boolean)
const realFindings = allVerified.filter((r) => r.realCount >= 2)

log(`总发现：${allVerified.length}，对抗验证通过（≥2 票）：${realFindings.length}`)

// 严重度调整
const adjustSeverity = (sev, adjust) => {
  const order = ['P2', 'P1', 'P0']
  const idx = order.indexOf(sev)
  if (idx < 0) return sev
  if (adjust === 'upgrade') return order[Math.min(idx + 1, order.length - 1)]
  if (adjust === 'downgrade') return order[Math.max(idx - 1, 0)]
  return sev
}

// 去重：同一 file + 标题 ≥80% 相似度的合并（用 LLM 判断太重，这里用简单规则）
const seen = new Map() // key: `${file}::${title.slice(0,20)}` -> index
const merged = []
for (const r of realFindings) {
  const f = r.finding
  const adjustedSeverity = adjustSeverity(f.severity, r.adjust)
  const key = `${f.file || '?'}::${(f.title || '').slice(0, 20)}`
  if (seen.has(key)) {
    // 已存在则跳过（保留先到者）
    continue
  }
  seen.set(key, merged.length)
  merged.push({
    severity: adjustedSeverity,
    title: f.title,
    file: f.file,
    line: f.line || '?',
    dimension: r.dimension,
    risk: f.risk,
    fix: f.fix,
    confidence: r.realCount === 3 ? 'high' : 'medium',
  })
}

// 排序：P0 > P1 > P2，同级按 file 排
const sevOrder = { P0: 0, P1: 1, P2: 2 }
merged.sort((a, b) => {
  const s = (sevOrder[a.severity] ?? 9) - (sevOrder[b.severity] ?? 9)
  if (s !== 0) return s
  return (a.file || '').localeCompare(b.file || '')
})

// 编号
const p0 = merged.filter((m) => m.severity === 'P0')
const p1 = merged.filter((m) => m.severity === 'P1')
const p2 = merged.filter((m) => m.severity === 'P2')
p0.forEach((m, i) => (m.id = `P0-${i + 1}`))
p1.forEach((m, i) => (m.id = `P1-${i + 1}`))
p2.forEach((m, i) => (m.id = `P2-${i + 1}`))

log(`最终输出：P0=${p0.length}，P1=${p1.length}，P2=${p2.length}`)

return {
  findings: [...p0, ...p1, ...p2],
  counts: { P0: p0.length, P1: p1.length, P2: p2.length, total: merged.length },
  scope,
  timestamp,
  fileCount: files.length,
}
