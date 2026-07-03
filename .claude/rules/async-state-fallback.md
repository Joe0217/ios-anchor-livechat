# 异步派生状态的兜底设计

## 规则

**禁**：异步未就绪状态用 loading 占位作为产品稳定态。loading 在接口慢/失败/字段缺时变成永久 dead-state，用户感知是"卡死"，不是"加载中"。

**正路径**：用业务可用的兜底值立即渲染 → 异步数据到达后矫正 → 保留用户已有交互的业务语义。

## 适用场景

- 派生 UI 配置依赖远程数据（如 tab 顺序、UI 主题、特性开关、A/B 实验配置）
- 用户进入页面立即可见但配置异步拉取
- 字段可能 nil（后端字段二选一发，或者老版本字段名）

## 反例（trial step 3 真集成第一次反悔即遇到）

`LiveTabView` 的 `HomeTopTab` 顺序按 `isSLevelAnchor` 派生。原设计"段位未就绪 loading 占位"在真接口暴露 2 个连锁问题：

1. **接口未拉**：用户登录后 `AnchorInfoStore.loadIfNeeded` 尚未调用或网络慢 → `info=nil`、`mine=nil` → `hasLoadedTier=false` → 4 个 capsule 灰态 + ProgressView 永久转
2. **字段二选一**：`AnchorInfo.levelName: String?` 注释明确"若后端只发数字 level 此字段 nil"。原 `hasLoadedTier` 只看 levelName 非空 → 即使 level 数字到达也判 false → 同样永久卡

修复：
- `HomeTopTabStore(initialIsSLevel: true)` 默认按 S 级兜底立即渲染 4 个 tab
- `hasLoadedTier` 改为 `levelName` 非空 **或** `level` 非 nil 任一即就绪
- `isSLevelAnchor` 先 `levelName` 白名单，缺则 fallback `level` 数字映射（`AnchorTierClassifier.isSLevel(level:)` overload）
- 删除 `tierLoading` 视图分支

## 检查清单

写依赖异步数据的派生 view 时跑一遍：

- [ ] 派生数据有兜底默认值？（**不能只有 nil → loading 占位**）
- [ ] 兜底值对应"业务可用"而非"假数据"？（用户能正常点击操作，不只是装载视觉）
- [ ] 数据到达后矫正时业务语义稳定？（用户已交互过的状态/选中态不丢）
- [ ] 字段缺失/类型偷换/接口失败不会触发"永久 loading"？（loading 应有 timeout + 兜底退路）
- [ ] 多字段 ready 判定：考虑后端字段二选一发的情况，**或**逻辑而非**与**逻辑判 ready

## 与现有规则关联

- `error-handling.md` §"区分可恢复错误（重试/重连）与不可恢复错误"：本规则补充第三类——**接口未必失败但配置缺失**，不应当作可重试错误，而是用兜底立即可用
