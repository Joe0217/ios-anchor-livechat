# UserCardPopup 重构:sheet 化 + H5 主播端视觉/功能对齐

**日期**: 2026-07-14
**里程碑**: H(IM 与礼物墙完善)期内的用户名片组件重构
**档级**: B 档(单组件 refactor + 3 接口,其中 2 接口复用现成 Service)
**改动预估**: ~450 行(新组件 250 + Model+Service+Store 扩 100 + 调用点 20 + L10n 20 + spec 60)

---

## §0 H5/安卓源码二次校验

- **H5 蓝本**: `anchor-livechat-h5/src/views/liveSetting/components/userCard.vue`(package.json = `livechat-anchor-app` = 主播端 H5)
- **H5 双场景澄清**(user 挑错的关键点):
  - `views/liveSetting/` = 主播自己开播的房 → 名片对象**只可能是用户**(userType=1 观众/送礼者)
  - `views/liveRoom/` = 主播看别的主播房(顶部注释"其他主播的直播房") → 从 rank 弹出的名片可能是**主播**(userType=2/3, `rankType===1 anchorUid`)
- **iOS 主播端本次覆盖范围**: 只做前者(iOS 无"看别的主播房"功能,路线图 A→J 不含)。**userCard 遇到的永远是用户**,H5 蓝本里 `isAnchor` 分支**不实现**(UI 一律用户态渲染)
- **iOS 现有基建复用**:
  - `AvatarView`(Sources/Core/AvatarView.swift)—— 已集成 `headwearURL`(H5 `<head-frame>` 头饰道具框对应)
  - `UserProfileService.shared.follow(request:)` / `.block(request:)` —— 已实现 `/api/user/followUser` / `/api/user/blockUser` + AppToast + notification
  - `BlocklistService.shared.removeBlock(...)` —— 已实现 `/api/user/removeBlockUser`
  - `CachedAsyncImage` / `UserLevelBadge` / `PublicChatVipBadge` / `AppToastCenter`
- **API 契约差异**:
  - fetch 走 `POST /api/user/getAnchorPersonalCard` body `{ searchValue: userId }`(iOS 项目内**首次接入**)
  - decode 走 5 路 fallback + userId String/Int 双兼容(对齐 `.claude/rules/ios-decode-userid-compat.md` + `agent-recon-field-names-unverified.md`)—— 真机首拉必须 grep log 验证字段名

---

## §1 业务契约(F 全列)

### F-1 打开名片卡

调用点(4 处)通过 `UserCardPopup(userId:isPresented:onAvatarTap:onMessageTap:)` 声明式挂载。sheet 触发即 `Store.loadIfNeeded()`,`.idle → .loading → .loaded/.error`。

### F-2 展示信息(自上而下,一律用户态)

- **左上 Block pill**: 未拉黑=红字 `#FF4340`+浅粉底;已拉黑=白字 55%+浅白底。tap 见 F-6
- **头像**: `AvatarView(size:86, kind:.user, headwearURL:headwearUrl, headwearRatio:1.35)` `.offset(y:-45)` 悬空 sheet 顶
  - iOS 16.4+: `.presentationBackground(.clear)` 让悬空效果生效
  - iOS 16.0-16.3: fallback 到贴顶(不悬空,视觉略损但语义正确)
  - **外圈粉紫渐变环 5px + 白色 mask 环**(H5 `.photo-bg` 视觉核心,SwiftUI 手写)
- **昵称**: 18pt bold, center, 单行截断
- **UID**: `UID: xxx`, 14pt, `.white.opacity(0.5)`, center
- **meta row**: 性别 pill(♀=`#FF1AA7`/♂=`#205FFF`)+ 年龄 + 国旗 emoji + Lv 徽章(`UserLevelBadge`)+ VIP 徽章(`PublicChatVipBadge`)+ medals row(横排,每个 16pt 图)
- **fans/follow row**: `fans 数字` `followers 标签` `follow 数字` `following 标签`(数字 18pt bold + 标签 14pt 50% 白)
- **liveWelcome**: 有则显示,13pt, 50% 白, center, 单行截断
- **礼物墙**: 深紫渐变 `#23175E→#1E1449` 卡片,rounded 12pt, padding 15h 10v
  - 有礼物: 横滚 row,每格 40x40 图 + 名字 10pt + `X count` 12pt
  - 无礼物: 空态文案 "No gifts sent yet!" 14pt 50% 白 center
  - 左右箭头(项数>5 显示): 左右 chevron 系统图标,tap 滚一屏
- **底部按钮 row**:
  - Follow(未关注): 渐变紫 `#8E60E6→#D074E9`, 图标+"Follow", 18pt bold
  - Unfollow(已关注): outline `.white.opacity(0.5)` 边+`.white.opacity(0.2)` 填, 图标+"Followed", 18pt bold
  - Message: 实心 `#3625AA`, 图标+"Message", 18pt bold
  - 双按钮等宽 `w-[calc(50%-6px)]`, 6pt gap
  - **例外**: 调用点 `onMessageTap == nil`(ChatDetail 场景)时 Follow 全宽,Message 隐藏

### F-3 头像 tap

- 调 optional `onAvatarTap: (() -> Void)?`
- 各调用点决策:
  - **LiveRoomExtraOverlays** / **PartyRoomView** / **PKInviteSheet**: 传 `nil`(主播端直播间/派对房/PK 邀请里不跳,对齐 H5 `route.path === '/liveSetting'` 分支)
  - **ChatDetailView**: 传 `{ dismiss + push UserProfileRoute.userId(uid) }`
  - 传 nil 时头像不可 tap(无视觉指示)

### F-4 Follow tap

- 乐观 toggle: `isFollowed` 立即翻转 + `followerCount ±1`
- 后台调 `UserProfileService.shared.follow(request: FollowUserRequest(followUserId: Int(userId)!, followType: wasFollowed ? 2 : 1))`
- 成功: AppToastCenter 自动弹(`UserProfileService.follow` 内已实现)+ post `.followRelationChanged`
- 失败: log warning + revert(乐观 toggle 回滚)

### F-5 Message tap

- 调 `onMessageTap?(userId, yxAccid)` — 上层跳私聊页
- **isBlocked 或 yxAccid nil 时**: 按钮 `.disabled(true)`(H5 阻断同款)

### F-6 Block pill tap

- 未拉黑: 直接调 `UserProfileService.shared.block(request: BlockUserRequest(userId: Int(userId)!, type: 1, yxAccid: yxAccid ?? "", isLive: LiveStore.shared.state == .living ? 1 : 0))`;乐观 `isBlocked = true`;成功 post `.blocklistChanged`
- 已拉黑: 弹 `.confirmationDialog(L10n.userCardUnblockConfirmTitle)`,确认 → `BlocklistService.shared.removeBlock(userId: userId, yxAccid: yxAccid ?? "")`;乐观 `isBlocked = false`
- yxAccid nil 时按钮 `.disabled(true)`

### F-7 关闭

- 系统 sheet 手势(下拉/tap 外)+ 无自定义关闭按钮
- close 时 Store 保留 loaded 状态 —— 下次同 userId 打开 reuse cache?**本期不做 cache**,每次都重新 fetch(H5 也是 watch isShow immediate 重拉,与之对齐)

---

## §2 Model + 状态机

### UserCardInfo 扩展

```swift
struct UserCardInfo: Equatable {
    let userId: String
    let userType: Int          // + 保留字段(1用户/2主播/3虚拟/4机器人),本期 UI 不 branch
    let nickname: String
    let avatarUrl: String?
    let headwearUrl: String?   // + 新增,H5 giftData.headwear/headFrame → AvatarView.headwearURL
    let yxAccid: String?       // + Message/Block 必需
    let gender: Gender
    let age: Int?
    let countryEmoji: String?  // 派生:country → emoji(用现有 CountryEmoji.for(...) helper)
    let level: Int
    let levelName: String?
    let isVip: Bool
    let followerCount: Int     // 对应 H5 fans
    let followingCount: Int    // 对应 H5 follow
    let liveWelcome: String?   // + 新增
    let medals: [Medal]        // + 新增
    let giftWalls: [GiftWallItem]  // 扩:加 name 字段
    var isBlocked: Bool        // var:optimistic toggle
    var isFollowed: Bool       // var
}

struct Medal: Identifiable, Equatable {
    let id: String              // index-based(H5 有 "medal.id 非全量必传"注释)
    let imageUrl: String?
}

struct GiftWallItem: Identifiable, Equatable {
    let id: String              // giftId
    let iconUrl: String?        // + giftImg
    let name: String?           // + giftName
    let count: Int              // giftCount / num 兜底
}
```

### 状态机(保持不变)

```
idle → loadIfNeeded() → loading → success → loaded(info)
                                → fail    → error(msg) → retry() → loading
```

- optimistic toggle(follow/block/unblock)在 `.loaded` 态内更新 info,不切态
- API 失败 revert 到修改前的 info(不切态,只弹 toast)

### Store 关键方法签名

```swift
@MainActor
final class UserCardStore: ObservableObject {
    enum LoadState: Equatable { case idle, loading, loaded(UserCardInfo), error(String) }
    @Published private(set) var state: LoadState = .idle

    init(userId: String,
         service: UserCardServiceProtocol = UserCardServiceReal(),
         isLiveProvider: @MainActor @escaping () -> Bool = { LiveStore.shared.state == .living })

    func loadIfNeeded()
    func retry()
    func toggleFollow()      // optimistic + revert
    func toggleBlock()       // 未拉黑走 block API;已拉黑走 unblock API(caller 已在 View 层弹 confirm dialog)
}
```

---

## §3 Service

### 3.1 fetch(新接入)

```swift
struct UserCardServiceReal: UserCardServiceProtocol {
    func fetch(userId: String) async throws -> UserCardInfo {
        let body: [String: Any] = ["searchValue": userId]
        let data = try await APIClient.shared.post("/api/user/getAnchorPersonalCard", body: body)
        guard let info = Self.decodeCard(from: data) else {
            throw APIError(code: "decode", message: "Failed to decode user card")
        }
        return info
    }

    /// decode 走 5 路 fallback + userId String/Int 双兼容(对齐 UserProfileService.decodeDetail 模板)
    /// 字段名多路 alias(agent 从 H5 template 反推,真机首拉必须 grep log 验证):
    /// - nickname: `nickname` / `nickName`(H5 两种都用)
    /// - avatarUrl: `icon`
    /// - headwearUrl: `headwear` / `headFrame`
    /// - fans/follow: 后端字段名待真机验证
    /// - medals: `[{medalImageUrl}]`
    /// - giftWalls: `[{giftId, giftName, giftImg, giftCount}]`
    static func decodeCard(from data: Data) -> UserCardInfo? { ... }
}
```

### 3.2 follow / unfollow / block / unblock(全复用)

```swift
// follow/unfollow → UserProfileService.shared.follow(request:)
extension UserCardServiceReal {
    func follow(userId: String) async throws {
        guard let uid = Int(userId) else { throw APIError(code: "invalid_uid", message: "userId not Int") }
        try await UserProfileService.shared.follow(request: FollowUserRequest(followUserId: uid, followType: 1))
    }
    func unfollow(userId: String) async throws {
        guard let uid = Int(userId) else { throw APIError(code: "invalid_uid", message: "userId not Int") }
        try await UserProfileService.shared.follow(request: FollowUserRequest(followUserId: uid, followType: 2))
    }

    // block/unblock 由 Store 直调(需要 yxAccid + isLive,Service protocol 保持简单 signature 不改)
    func block(userId: String) async throws { /* 由 Store 走 UserProfileService.shared.block */ }
    func unblock(userId: String) async throws { /* 由 Store 走 BlocklistService.shared.removeBlock */ }
}
```

**决策**: block/unblock 需要 yxAccid + isLive(follow 不需要),但 UserCardServiceProtocol 签名保持 `(userId: String) -> Void` 简单。**改由 Store 直接持有 UserProfileService/BlocklistService**,不走 Service protocol。protocol 只承担 fetch + follow/unfollow。

### 3.3 API 契约表

| 能力 | 端点 | Method | Body | 复用 |
|---|---|---|---|---|
| fetch | `/api/user/getAnchorPersonalCard` | POST | `{searchValue}` | 新增 |
| follow/unfollow | `/api/user/followUser` | POST | `{followUserId, followType}` | UserProfileService |
| block | `/api/user/blockUser` | POST | `{userId, type:1, yxAccid, isLive}` | UserProfileService |
| unblock | `/api/user/removeBlockUser` | POST | `{userId, type:1, yxAccid}` | BlocklistService |

---

## §4 复用判断表(preflight cross-scene-component-reuse-preflight)

| 组件 | 位置 | 自持相机 | 自持 store | ignoresSafeArea | 结论 |
|---|---|---|---|---|---|
| `AvatarView` | Sources/Core/AvatarView.swift | ❌ | ❌ | ❌ | ✅ 复用,传 headwearURL |
| `CachedAsyncImage` | Sources/Core/ | ❌ | ❌ | ❌ | ✅ 复用(礼物图) |
| `UserLevelBadge` | Sources/Core/ | ❌ | ❌ | ❌ | ✅ 复用(Lv 徽章) |
| `PublicChatVipBadge` | Sources/PublicChat/ | ❌ | ❌ | ❌ | ✅ 复用(VIP 徽章) |
| `AppToastCenter` | Sources/Core/ | ❌ | ❌ | ❌ | ✅ 复用(follow 后 toast) |
| `PKPopupCard` | Sources/PK/UI/ | ❌ | ❌ | ❌ | ❌ **不复用**(形态不同,中央卡 vs 底部 sheet) |
| `CountryEmoji.for(...)` | 需 grep | - | - | - | ✅ 若存在则复用,否则简易 inline 派生 |

---

## §5 验收(F 全列 + R critical)

### F-验收(功能全列)

- [ ] F-1: 4 处 caller 均能弹起 sheet
- [ ] F-2: 视觉自上而下按 §1 列表渲染(真机看头像悬空效果 iOS 16.4+ 生效,iOS 16.0-16.3 贴顶)
- [ ] F-3: `onAvatarTap` nil 时头像不响应;非 nil 时 dismiss+push UserProfile
- [ ] F-4: Follow tap 立即翻转 UI + AppToast + 后台调接口 + notification
- [ ] F-5: Message tap 调 callback(nil 时按钮 disabled);isBlocked 或 yxAccid nil 也 disabled
- [ ] F-6: Block pill 未拉黑直接调;已拉黑弹 confirm dialog 后调
- [ ] F-7: 系统下拉手势关闭 sheet

### R-critical(反向 3-5 条)

- [ ] **R-1** decode 失败(字段名不对/后端空返)→ 进 `.error` 态显示 retry 按钮,不 crash
- [ ] **R-2** userId 后端返 Int(如 `1000001877`)→ String/Int 双兼容成功 decode(对齐 ios-decode-userid-compat)
- [ ] **R-3** yxAccid nil → Block pill / Message 按钮 disabled,不发起 API 请求
- [ ] **R-4** 主播自己不在直播中(LiveStore.state != .living)→ block API isLive=0 传对
- [ ] **R-5** ChatDetailView 内打开 sheet → Message 按钮隐藏 + Follow 全宽(防循环反调)

---

## §6 待验用户(仅 critical)

**真机首拉必查项**(agent-recon-field-names-unverified rule):

1. `getAnchorPersonalCard` 后端返回的**真实字段名**是否与 H5 template 一致?特别是:
   - `fans` vs `followerCount` vs `followers`
   - `follow` vs `following` vs `followingCount`
   - `nickName` vs `nickname`(H5 template 两种都用了)
   - `headwear` vs `headFrame` vs `headwearUrl`
   - `medals` 数组元素结构(`{medalImageUrl}` vs `{imageUrl}` vs `{img}`)
2. `giftWalls` 内元素:`giftCount` vs `num`,`giftImg` vs `icon`(H5 都兜底了,iOS 也兜底)
3. `isBlocked` / `isFollow`:后端返 Bool 还是 Int(0/1)?按 NSNumber cType 判别

**决策**: 起 impl 时字段名走 H5 template 反推 + 多路 alias 兜底;真机首拉 grep `[UserCardService] raw=` log 一次,不对齐再改 alias 就好。

---

## §7 impl 步骤(B 档合并 step)

Step 1 - **合并 impl**(Model+Store+Service+View+调用点+L10n 单 step):
1. Model 扩字段 + Medal struct + GiftWallItem 扩 name
2. Service protocol 精简(fetch + follow + unfollow),Real 实现 decodeCard 5 路 fallback,Fakes 补新字段
3. Store 加 `isLiveProvider` + 拆 block/unblock 直调 UserProfileService/BlocklistService + optimistic revert + post notification
4. UI 重写 sheet 形态 + 头像悬空 + 深紫渐变 + Block pill + medals row + 礼物墙横滚 + Follow/Message 双按钮
5. 4 调用点:LiveRoomExtraOverlays / PartyRoomView / ChatDetailView 改 `.sheet(item:)` 挂载 + 按语义传 callback
6. L10n 补 zh/en/ar/tr 4 语言(UID/liveWelcome 空态/Follow/Followed/Message/Blocked/removeBlockConfirm 等)

Step 2 - **真集成 + 真机验证**:
1. `xcodebuild build` 通过
2. 真机跑通:LiveRoom 里 tap 观众头像 → sheet 弹出 → 显示真实数据(grep log 验证字段名)
3. 验证 Follow / Block / Unblock / Message 4 交互

Step 3 - **反悔沉淀**(B 档规则):
- 反悔 0 → 跳过 rule 沉淀
- 反悔 ≥1 → 按类沉淀到 `.claude/rules/`

---

## §8 已知非目标(YAGNI)

- ❌ **isAnchor 双形态 UI**(iOS 主播端不需要,详见 §0)
- ❌ **cardFrame 卡片装饰边框**(用户明示不做,头像框走 AvatarView.headwearURL)
- ❌ **礼物墙曝光埋点**(H5 有 `reportShuShuCustomEvent`,iOS 埋点体系统一在 J 里程碑)
- ❌ **名片卡缓存**(每次都 refetch,H5 同款)
- ❌ **isAnchor=true 场景**(未来"看别的主播房"里程碑再启用 userType 字段)
