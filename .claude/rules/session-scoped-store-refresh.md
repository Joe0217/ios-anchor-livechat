# 账号级 store：logout clear + login refresh 双入口

> 来源：2026-07-06 切账号后 profile 显示旧账号 bug；3 轮盲改（clear 加固 / epoch 竞态 guard）都没修好，真根因是 login 后未主动触发 refresh，view 层 `.task/.onAppear` 因 keep-alive/identity 复用等隐藏路径漏触发

## 规则

**缓存服务端"当前用户数据"的单例 store** 必须**同时**挂 SessionStore 两个入口：

1. `logout()` 里 `store.clear()`
2. `login()` 成功分支加 `Task { await store.refresh() }`

**禁止**只做 (1) 依赖 view 层 `.task/.onAppear` 触发首次拉取。

## 谁适用

| 类型 | 例子 | 本 rule |
|---|---|---|
| 快照类（GET 当前用户资料/余额/背包） | AnchorInfoStore / 未来 WalletStore | ✅ 必须 |
| 连接类（长连接/token） | NIMOnlineKeeper/CallStore | ❌ 已由 RootView.syncSessionDependent 覆盖 |
| 闸门/过滤类 | IMSceneGate | 部分（只需 clear） |
| UI 偏好类 | BeautySettingsStore/HomeTopTabStore | ❌ 与账号无关 |

## Why

SwiftUI view lifecycle 存在**隐藏路径**让 `.task/.onAppear` 不触发或时机漂移：keep-alive
(MainTabView ZStack + opacity)、view identity 复用、结构化 concurrency cancel 传播。**把
"新账号数据必须重拉"这件事绑在 view lifecycle 上等于把正确性押在 SwiftUI 内部实现细节上**。

反例：AnchorInfoStore 用 `hasLoadedOnce` 短路 loadIfNeeded，A 登录后 view 触发一次拉了 A 数据
hasLoadedOnce=true；A logout → clear 置 false；B login 后新 view 的 `.onAppear` 因 keep-alive
架构没触发（或触发了但时序有问题），hasLoadedOnce 未被重置为 true → ProfileView `.task`
依然短路 → 显示 A。真修复不是加清理/加竞态 guard，是 login 里主动 `refresh()`。

## checklist

新加账号级 store 时逐条过：

- [ ] `SessionStore.logout()` 加 `MyStore.shared.clear()`
- [ ] `SessionStore.login()` 成功分支加 `Task { await MyStore.shared.refresh() }`
- [ ] `MyStore.refresh()` 内**不**短路（不 check hasLoadedOnce 之类）
- [ ] `MyStore.clear()` 除了清 in-memory 状态，还要清持久化（keychain/UserDefaults 里 A
      账号的快照），否则冷启动 loadFromDisk 会恢复 A 数据

## 已加固清单

- ✅ AnchorInfoStore（2026-07-06 修复）
- 未来新增账号级 store 时加入本表

## 与既有 rule 关联

- [swiftui-keepalive-publisher-isolation.md](swiftui-keepalive-publisher-isolation.md) 讲
  keep-alive 下 publisher 订阅隔离；本 rule 补"keep-alive 下**数据源刷新触发**不能只靠 view lifecycle"
- [root-cause-investigation.md](root-cause-investigation.md) §2 讲上溯纪律；本 rule 是上溯之后
  应发现的具体架构缺陷
