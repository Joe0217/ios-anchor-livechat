# Agent 侦察/H5 源码推断的字段名 **必须真机 log 验证** 才能定 Codable

> 来源：2026-07-10 E-spec v5 派对房创房重写 —— Explore agent 读 `livechat-h5/src/views/party/create.vue` 报"模板接口返 `roomTempId / imgUrl / createRoomLevel`"，Explore 报告中的字段名部分来自源码推断（`create.vue` 只是消费 `item.imgUrl` 等，不能反推 API 全字段），iOS PartyRoomTemplate 只 alias 了 `imgUrl` 漏了 4 个字段 —— 真机首次拉模板 decode 失败：
> ```
> [PartyAPI] decode array failed; raw=[{"roomTempId":4,"imgUrl":"...","voiceNum":5,"videoNum":0,"totalSeatNum":5,"createRoomLevel":1}]
> ```
> 实际后端返 `roomTempId/voiceNum/videoNum/totalSeatNum`，iOS model 用 `id/voiceSeatCount/videoSeatCount/seatCount` —— 5 字段有 4 个不匹配。

## 规则

**任何"HTTP response Codable model"的字段名来源为 Explore agent 报告 / H5 源码字面推断 / 安卓文档描述时，必须真机首次拉取 log 验证一次才能定稿**。

## 为什么会错

- **H5 源码通常只显式消费部分字段**（如 `item.imgUrl`, `item.roomTempId`）—— 剩下字段名要么 destructure 直接用（agent 看不到），要么从 store computed / TypeScript type 反推（type 声明本身也是开发者手写不可信，见 [ios-decode-userid-compat.md](ios-decode-userid-compat.md)）
- **Explore agent 短 context 抽取时会推断字段名**（如"seatCount"是根据 `voiceSeatCount + videoSeatCount` 命名对称习惯推测）—— 后端实际字段名可能完全不同
- **iOS 严格 Codable fail-loud**：一个字段名不匹配就整个 decode 失败（`decodeArrayOrEmpty` 也 fail），列表整体拉不到

## How to apply

新接一个 API model 时：

### Step 1：Explore agent / H5 源码 → 起草 model（字段名标"待验证"）

```swift
// PartyRoomTemplate v1 起草 —— 字段名来自 Explore agent 推断，未经真机验证
struct PartyRoomTemplate: Decodable {
    let id: Int              // ⚠️ 待验证，H5 用 roomTempId
    let voiceSeatCount: Int? // ⚠️ 待验证，H5 用 voiceNum
    // ...
}
```

### Step 2：真机首次拉取 → grep AppLogger log

跑真机拉一次接口，在 Console.app 或 Xcode 里搜 `[PartyAPI] decode` / `raw=[{...}]` — 拿到**后端真实返回**字段名。

### Step 3：加 CodingKeys 双向 alias（真机字段优先）

```swift
enum CodingKeys: String, CodingKey {
    case id, voiceSeatCount  // iOS 命名
    case roomTempId          // 后端真实字段（真机验证）
    case voiceNum            // 后端真实字段
}

init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    // 真机字段名优先（fallback 到 iOS 命名兜底）
    id = (try? c.decode(Int.self, forKey: .roomTempId)) ?? (try c.decode(Int.self, forKey: .id))
    voiceSeatCount = (try? c.decode(Int.self, forKey: .voiceNum))
                  ?? (try? c.decode(Int.self, forKey: .voiceSeatCount))
}
```

## 触发条件

写以下代码 pattern 之前必须 preflight：

- [ ] 新增 `Decodable/Codable struct` 直接对应某个后端 API response
- [ ] 字段名来源为"读 H5 / 安卓源码 / Explore agent 报告"而非"真机 log 抓取"
- [ ] Codable model 里所有字段都用 iOS 惯例命名（camelCase 意译）而无 CodingKeys 别名

## 与既有 rules 关联

- [ios-decode-userid-compat.md](ios-decode-userid-compat.md)：同源精神"H5 type.ts 类型声明不可信，追真机响应" —— 那 rule 针对类型（String/Int），本 rule 针对字段名
- [im-payload-real-log-over-code-assumption.md](im-payload-real-log-over-code-assumption.md)：同源精神但针对 IM payload；本 rule 补 HTTP response
- [api-http-method-strict.md](api-http-method-strict.md)：那 rule 针对 method + path，本 rule 针对 response body 字段名 —— 三条合起来构成"API 契约完整校验清单"

## 不适用

- 后端已经在多个场景真机验证过的稳定 model（如 UserProfile / LoginResult）
- Model 只用于 request body（无需 decode）
- 单元测试 fixture model（不接真接口）

## 历史教训

- **2026-07-10 E-spec v5**：Explore agent 报告 `livechat-h5/create.vue` 里推断字段 `roomTempId/imgUrl/createRoomLevel` —— 起草 model 只 alias `imgUrl`，漏 `roomTempId/voiceNum/videoNum/totalSeatNum` 4 个字段。**iOS Codable decode 失败 → 模板列表整体拉不到 → 创房核心功能瘫**。修复 = model 加 5 字段全 alias（roomTempId → id / voiceNum → voiceSeatCount / videoNum → videoSeatCount / totalSeatNum → seatCount / imgUrl → coverImage）。本 rule 沉淀让未来所有"agent 推断 → 直接落 Codable"路径提前 preflight 真机 log 验证。
