# IM payload 相关跨模块新功能：真机 log 优先于代码注释假设

> 来源：2026-07-09 GiftEffect 跨场景礼物特效引擎接入 3 环连锁反悔（attachType 语义假设错 / 字段名不匹配 / scopeId 派生不一致），每一环都要真机 log 才能揭露 —— 前面 27 tc 全绿 + 用户 build 通均无法预警。

## 规则

**接入 IM payload → 状态机 / 队列 / UI 时，"代码内的注释假设"必须真机 log 验证一次才可信**。3 类假设都会**静默失效**（无 crash / 无 warn / test 全绿）：

### 1. attachType 语义分类假设

代码内 comment 写"attachType X 是 A 类消息、Y 是 B 类"—— **可能是原作者的**假设，实际生产 payload 可能不遵循。

**真机验证方法**：让对方端触发该业务动作 → 抓 Console log 里 `attachType=` 和 `dataKeys=` 两行 → 与代码 case 对照。

**GiftEffect 真例（2026-07-09）**：
- iOS NIMChatroomManager comment 明写 "liveGiftRankUpdate(50) 只 rank 无 gift 明细 / sendGift(1) 带 gift 明细"
- 真机 log：**attachType=50 一条消息 dataKeys 同时含 rank + gift**（`giftPrice,giftId,giftName,giftIcon,smallImg,sendYxAccid,...`），attachType=1 **从未发过**
- 修：case .liveGiftRankUpdate 也调 intake，rank 与 gift 双消费

### 2. payload 字段命名对齐 H5 假设

decoder 里写 `payload["senderYxAccid"] ?? payload["fromAccid"]` —— **H5 type.ts 声明 vs 后端真实字段可能不一致**。

**真机验证方法**：抓 `dataKeys=` 一行 → 与 decoder 期望的 key 列表对照。

**GiftEffect 真例（2026-07-09）**：
- decoder 期望 `senderYxAccid` / `giftSmallImg`
- 真机 payload 是 `sendYxAccid` / `smallImg`（少一个 `er`、少 `gift` 前缀）
- 修：decoder decodeSender 追加 `sendYxAccid`；staticImg 追加 `smallImg`

### 3. 跨模块 scope key 派生一致性假设

UI modifier 声明"我是场景 X of scopeId Y"，IM handler 声明"入队场景 X of scopeId Z"——**若 Y 和 Z 来自不同数据源（业务 id vs 云信 id）就静默失配**。

**症状特殊**：Center enqueue 时 log `enqueue rejected: item=live active=live`（scene 相同但 scopeId 不同，若 log 只 print scene 会看错方向）。

**真机验证方法**：Center enqueue rejected log 必须**同时 print scene + scopeId 双字段**（现已改）；未来任何"跨模块场景 key"用法初次接入要真机测同房间收礼一次。

**GiftEffect 真例（2026-07-09）**：
- LiveRoomView modifier: `scopeId: String(store.roomId ?? 0)` = 业务 db id "1234567"
- NIMChatroomManager.enter: `roomId: "\(roomInfo.yxRoomId)"` = 云信 room id "11297788134"
- Center enqueue 里 activeKey.scopeId vs item.sceneKey.scopeId 不同 → reject → 无特效 + 无 log 显示 scopeId
- 修：modifier 也用 `roomInfo.yxRoomId ?? ""` 统一到云信 id

## 触发条件（接入前主动做的事）

任何"IM 消息 → 特效/UI/状态机"新链路 impl 时：

- [ ] impl plan 里明示"真机 log 验证" step，**不能只靠 unit tests + build 过判 done**（真根因永远在 payload 结构 + 跨模块派生里，unit tests 只测代码假设成立时的行为）
- [ ] 派 subagent 时 prompt 里明示：**"完成后必须真机跑一次让对方触发消息，抓 log 确认 dataKeys / attachType / scopeId 三点"**
- [ ] Center / Queue / Store 类的 "reject" / "drop" / "skip" 分支的 log 必须 print **区分不匹配用的两方数据源**（如 scopeId 双字段而非只 scene）—— 避免 debug 时看错方向

## 与既有规则关联

- [ios-decode-userid-compat.md](ios-decode-userid-compat.md) — 单字段 String/Int 双兼容；本 rule 补"字段名不匹配"层
- [api-http-method-strict.md](api-http-method-strict.md) — H5 声明不可信，追 store 层调用点；本 rule 是 payload 版本
- [root-cause-investigation.md](root-cause-investigation.md) §"证据链头往往在用户贴的 log 第一屏" — 本 rule 是具体到"IM payload" 的应用

## 不适用

- 单元 tests / builder pattern —— unit test 层无 IM payload，本 rule 只针对真机 IM 反悔
- 后端契约稳定的老接口（有历史真机 log 备档）
- pure UI 层调整（无 IM 数据流）

## 历史教训

- **2026-07-09 GiftEffect 引擎接入**：27 tc 全绿 + build 通 + 用户 regen 通 → 直播真机零特效。3 环真根因（attachType 分类假设 / 字段命名 / scopeId 派生）全需真机 log 才能揭露。回顾发现所有 3 环在 impl plan 起草期都是**"代码注释里明确写着"** 但真机与注释不一致。本 rule 沉淀为未来同类"IM payload 跨模块新功能"提前预警：impl 完成 ≠ 真机可用，中间必须 log 验证一次。
