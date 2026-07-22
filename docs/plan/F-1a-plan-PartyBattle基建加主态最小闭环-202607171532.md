# F-1a · PartyBattle 基建 + 主态最小闭环 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development`（推荐）or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 落地 PartyBattle 基础数据/服务/状态机/IM 路由/主态 9 个 UI 组件 + 阵营↔麦位映射 + PartyRoomView 集成（含视频位 replace），房主端完成 SELECTING → RUNNING → ENDED → 冷却 5 态闭环，真机验收。

**F-1a 主态 UI 范围明示（vs spec §6.1 10 组件）**：F-1a 做 9 个主态组件；第 10 个 `PartyBattleGiftPanelTabs`（客态送礼面板红蓝 Tab）**deferred F-1b**（属客态观众送礼链路）。同理 `PartyRoomAudioSeatCell.displayGiftCount` 的"PK 期按 uid 从 battleStore.redMembers/blueMembers 查 personalGems 替换显示"**deferred F-1b**（主态本轮不需要，房主端主要看红蓝分总数已由 RunningHud 承担）。

**Architecture:** 独立 `Sources/Party/Battle/` 模块 + `PartyBattleStore.shared` 单例状态机（对齐 H5 partyBattle.ts 语义）；REST 走 `PartyAPIClient`（sapi 域已就绪）；IM 走 `PartyBattleMessageRouter` 12 case 分发（1100-1112）；UI 走 SwiftUI overlay/sheet 挂到 PartyRoomView；PartyRoomView.handlePkTap / toolMenu.startPk wire 到 store。

**Tech Stack:** Swift 5 + SwiftUI + Combine（200ms 聚合）+ Timer（cooldown ticker）+ 现有 `PartyAPIClient` / `NIMChatroomManager` / `AppLogger.party`

**Spec 依据：** `docs/plan/F-1-spec-PartyBattle-PK-202607141808.md` v2（已收敛 §12 待用户确认清单）

**里程碑：** F-1a（本 plan 范围）· F-1b/F-1c 单独 plan 后续起草

**F-1a 完工前必答（§12 收敛必答清单）**：
- A3 approveApply 拒绝时 IM 1102/1108 是否 fire
- A4 applications 是否分页
- A5 startNow 非法调用 response code
- A6 forceEnd 后 durationSec / endedEarly / cooldownLeftSec 字段值
- A8 RUNNING 期观众申请上麦通过后是否发 1101

---

## §0 前置纪律（每 Task 开始前必读）

**编译工作流**（xcodegen-podinstall-binding rule）：
- 新加 `.swift` 文件 → `./bin/regen.sh` 一条龙（关 Xcode → xcodegen generate → pod install → sanity check → 打开 workspace）
- 每 Task 完成后可用 `xcodebuild build -workspace Hily.xcworkspace -scheme Hily -destination 'generic/platform=iOS' -configuration Debug CODE_SIGNING_ALLOWED=NO 2>&1 > /tmp/hily-build.log && grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/hily-build.log | tail -20` (xcodebuild-log-filter-split rule)

**TDD 铁律**（superpowers:test-driven-development）：Test 先失败 → 实现最小代码 → Test 通过 → refactor → commit。禁止跳步。

**Commit 纪律**（git-workflow.md）：
- Format: `<type>: [scope] <description>`
- F-1a scope 用 `[派对房 PK]`
- 一 task 一 commit，禁止 batch；禁止 `--no-verify`

**关键 rules**：
- [ios-decode-userid-compat.md](../.claude/rules/ios-decode-userid-compat.md) — Codable uid/userId String/Int 双兼容
- [im-payload-real-log-over-code-assumption.md](../.claude/rules/im-payload-real-log-over-code-assumption.md) — IM payload 首次真机 log 校对
- [api-http-method-strict.md](../.claude/rules/api-http-method-strict.md) — POST/GET method + path 严格校验
- [agent-recon-field-names-unverified.md](../.claude/rules/agent-recon-field-names-unverified.md) — 字段名首次真机 log 抓取校对
- [swiftui-body-type-check-timeout.md](../.claude/rules/swiftui-body-type-check-timeout.md) — body 复杂时抽 perform: methodName / @ViewBuilder
- [swiftui-button-plain-hitarea.md](../.claude/rules/swiftui-button-plain-hitarea.md) — icon+label cell 加 .contentShape(Rectangle())
- [sf-symbol-usage-preflight.md](../.claude/rules/sf-symbol-usage-preflight.md) — 新 SF Symbol name 需验证
- [prefer-shared-component-over-adhoc.md](../.claude/rules/prefer-shared-component-over-adhoc.md) — 优先复用 CachedAsyncImage/AvatarView

---

## §1 文件蓝图（依赖顺序）

```
Sources/Party/Battle/
├── Models/
│   ├── PartyBattleTypes.swift              # PartyBattleStatus enum + DoubleOrString wrapper
│   ├── PartyBattleModels.swift             # State + Team + Member + TopMember
│   ├── PartyBattleAPIModels.swift          # 10 endpoints Request/Response
│   ├── PartyBattleIMPayloads.swift         # 12 attachType payload Codable
│   └── PartyBattleServiceError.swift       # 服务层错误枚举
├── Services/
│   ├── PartyBattleService.swift            # 10 endpoints + config 拉取
│   └── PartyBattleGlobalConfigParser.swift # Java Map style config parser
├── PartyBattleStore.swift                  # @MainActor 单例状态机
├── PartyBattleSeatLayout.swift             # 阵营↔麦位映射（spec §6.3）
├── PartyBattleMessageRouter.swift          # 12 attachType → action 分发
└── UI/
    ├── PartyBattleInitiatePopup.swift
    ├── PartyBattleSelectingPanel.swift
    ├── PartyBattleSelectingStartStrip.swift
    ├── PartyBattleRunningHud.swift
    ├── PartyBattleHostBottomMarquee.swift
    ├── PartyBattleEndedSettlement.swift
    ├── PartyBattleForceEndConfirm.swift
    ├── PartyBattleCooldownToast.swift
    ├── PartyBattleRulesPopup.swift
    └── PkSelectingVideoTripleView.swift    # SELECTING 期三视频位布局（spec §6.2）

Sources/Core/Extensions/
└── Double+CompactFormatted.swift           # K/M 格式化（spec §6.4；若已存在跳过）

修改：
Sources/Party/Models/PartyAttachType.swift        # 增补 1100-1112 case + 移出降噪表
Sources/Party/NIM/PartyMessageRouter.swift        # 补 case 转发 battle router
Sources/Party/PartyStore.swift                    # + clearGiftValueCount(uids:) API
Sources/Party/UI/PartyRoomView.swift              # wire handlePkTap + toolMenu.startPk + overlay/sheet + 视频位 replace
Sources/Party/UI/Components/PartyRoomBigSeatCell.swift 或 seat cluster view  # 加 RUNNING 期红蓝色边（若适用）

F-1a 不做（F-1b 范围明示）：
- Sources/Party/Battle/UI/PartyBattleGiftPanelTabs.swift（客态送礼红蓝 Tab）
- PartyRoomAudioSeatCell.displayGiftCount PK 覆盖逻辑

测试：
HilyTests/Party/Battle/
├── PartyBattleTypesTests.swift               # DoubleOrString/Status enum decode
├── PartyBattleModelsTests.swift              # State/Member Codable
├── PartyBattleAPIModelsTests.swift           # 10 endpoints request/response Codable
├── PartyBattleIMPayloadsTests.swift          # 12 attachType payload Codable
├── PartyBattleGlobalConfigParserTests.swift  # Java Map style parse
├── PartyBattleStoreStateMachineTests.swift   # 5 态 + 迁移守卫
├── PartyBattleStoreSideEffectsTests.swift    # onSelectingStart 侵入 PartyStore + preservePersonal + 200ms 聚合 + cooldown ticker + tickLeft
├── PartyBattleMessageRouterTests.swift       # 12 case 分发
├── PartyBattleSeatLayoutTests.swift          # slot idx ↔ seatIndex 映射
└── Fixtures/
    └── PartyBattleTestFixtures.swift         # PartyBattleState.testFixture / BattleSelectingStartPayload.stub / PartyRoomSeat.stub / PartyStore._setSeatsForTesting / _setRoomInfoForTesting DEBUG helpers
```

**每加/删/改一批 .swift 文件后跑一次 `./bin/regen.sh`**（xcodegen 会 sync pbxproj）。

---

## Phase 1: 数据类型层（3 tasks · ~1h）

### Task 1: PartyBattleStatus + DoubleOrString wrapper

**Files:**
- Create: `Sources/Party/Battle/Models/PartyBattleTypes.swift`
- Create: `HilyTests/Party/Battle/PartyBattleTypesTests.swift`
- Modify: `project.yml`（追加 HilyTests.sources 白名单条目，详见 hily-tests-target-whitelist-convention rule）

- [ ] **Step 1: 写失败测试** — `PartyBattleTypesTests.swift`

```swift
import XCTest
@testable import Hily

final class PartyBattleTypesTests: XCTestCase {

    // MARK: - PartyBattleStatus
    func testStatusRawValues() {
        XCTAssertEqual(PartyBattleStatus.selecting.rawValue, 1)
        XCTAssertEqual(PartyBattleStatus.running.rawValue, 2)
        XCTAssertEqual(PartyBattleStatus.ended.rawValue, 3)
        XCTAssertEqual(PartyBattleStatus.forceEnded.rawValue, 4)
        XCTAssertEqual(PartyBattleStatus.cooldown.rawValue, 5)
    }

    // MARK: - DoubleOrString decode 三兼容
    func testDoubleOrStringDecodeDouble() throws {
        let json = "12.5".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 12.5)
    }
    func testDoubleOrStringDecodeInt64() throws {
        let json = "1234567890123456".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 1234567890123456.0)
    }
    func testDoubleOrStringDecodeString() throws {
        let json = "\"999999.99\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 999999.99)
    }
    func testDoubleOrStringDecodeEmptyString() throws {
        let json = "\"\"".data(using: .utf8)!
        let v = try JSONDecoder().decode(DoubleOrString.self, from: json)
        XCTAssertEqual(v.doubleValue, 0)
    }
    func testDoubleOrStringEncodeRoundTrip() throws {
        let orig = DoubleOrString.double(12.5)
        let encoded = try JSONEncoder().encode(orig)
        let decoded = try JSONDecoder().decode(DoubleOrString.self, from: encoded)
        XCTAssertEqual(decoded.doubleValue, 12.5)
    }
}
```

- [ ] **Step 2: 加白名单 + regen**

在 `project.yml` 中 `targets.HilyTests.sources` 添加 `PartyBattleTypesTests.swift` 相关源码引用（跟已有 HilyTests 白名单同格式）。然后：

```bash
./bin/regen.sh
```

预期：sanity check 通过 · workspace 打开成功。

- [ ] **Step 3: 跑测试验证失败**

```bash
xcodebuild test -workspace Hily.xcworkspace -scheme Hily \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:HilyTests/PartyBattleTypesTests \
  2>&1 > /tmp/hily-test.log
grep -E "Test Case|Executed" /tmp/hily-test.log | tail -20
```

预期：FAIL with "cannot find PartyBattleStatus / DoubleOrString in scope"

- [ ] **Step 4: 写最小实现** — `PartyBattleTypes.swift`

```swift
import Foundation

enum PartyBattleStatus: Int, Codable {
    case selecting = 1
    case running   = 2
    case ended     = 3
    case forceEnded = 4
    case cooldown  = 5
}

enum DoubleOrString: Codable, Equatable {
    case double(Double)
    case string(String)
    case none

    var doubleValue: Double {
        switch self {
        case .double(let d): return d
        case .string(let s): return Double(s) ?? 0
        case .none: return 0
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let i = try? c.decode(Int64.self) { self = .double(Double(i)); return }
        if let s = try? c.decode(String.self), !s.isEmpty { self = .string(s); return }
        self = .none
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .none: try c.encodeNil()
        }
    }
}
```

- [ ] **Step 5: 跑测试验证通过**

```bash
xcodebuild test -workspace Hily.xcworkspace -scheme Hily \
  -destination 'platform=iOS Simulator,name=iPhone 15' \
  -only-testing:HilyTests/PartyBattleTypesTests \
  2>&1 > /tmp/hily-test.log
grep -E "Test Case|Executed" /tmp/hily-test.log | tail -10
```

预期：5 passed / 0 failed

- [ ] **Step 6: Commit**

```bash
git add Sources/Party/Battle/Models/PartyBattleTypes.swift \
        HilyTests/Party/Battle/PartyBattleTypesTests.swift \
        project.yml Hily.xcodeproj Hily.xcworkspace
git commit -m "feat: [派对房 PK] PartyBattleStatus 枚举 + DoubleOrString wrapper + 单测"
```

---

### Task 2: PartyBattleServiceError enum

**Files:**
- Create: `Sources/Party/Battle/Models/PartyBattleServiceError.swift`

- [ ] **Step 1: 写实现**（无需单测，纯 enum 声明）

```swift
import Foundation

enum PartyBattleServiceError: Error, LocalizedError, Equatable {
    case invalidResponse
    case notAuthorized                  // A5 待真机验证 code；先占位
    case notInPk
    case pkAlreadyRunning
    case cooldownActive(leftSec: Int)
    case switchTeamRejected
    case unknownServer(code: String, message: String?)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "PartyBattle: invalid response"
        case .notAuthorized: return "PartyBattle: not authorized"
        case .notInPk: return "PartyBattle: not in a PK"
        case .pkAlreadyRunning: return "PartyBattle: PK already running"
        case .cooldownActive(let s): return "PartyBattle: cooldown \(s)s"
        case .switchTeamRejected: return "PartyBattle: switch team rejected"
        case .unknownServer(let c, let m): return "PartyBattle: [\(c)] \(m ?? "")"
        }
    }
}
```

- [ ] **Step 2: Regen + build sanity check**

```bash
./bin/regen.sh
xcodebuild build -workspace Hily.xcworkspace -scheme Hily \
  -destination 'generic/platform=iOS' -configuration Debug \
  CODE_SIGNING_ALLOWED=NO 2>&1 > /tmp/hily-build.log
grep -E "error:|BUILD (SUCCEEDED|FAILED)" /tmp/hily-build.log | tail -5
```

预期：BUILD SUCCEEDED

- [ ] **Step 3: Commit**

```bash
git add Sources/Party/Battle/Models/PartyBattleServiceError.swift \
        project.yml Hily.xcodeproj Hily.xcworkspace
git commit -m "feat: [派对房 PK] PartyBattleServiceError 错误枚举占位"
```

---

### Task 3: PartyBattleModels — State/Team/Member/TopMember Codable

**Files:**
- Create: `Sources/Party/Battle/Models/PartyBattleModels.swift`
- Create: `HilyTests/Party/Battle/PartyBattleModelsTests.swift`

**参考 spec §4.1 完整字段定义**（已提供 Swift 代码）

- [ ] **Step 1: 写失败测试** — 覆盖 fixture decode + uid Int64/String 双兼容

```swift
import XCTest
@testable import Hily

final class PartyBattleModelsTests: XCTestCase {

    func testBattleStateDecode_fixtureFromH5State() throws {
        // 从 H5 partyBattle.ts fixture 派生（真机 log 校对前先用占位 JSON）
        let json = """
        {
          "pkId":"pk_1001",
          "battleId":1,
          "roomId":1234567890123456,
          "status":2,
          "templateId":1,
          "templateName":"3v3",
          "selectingDurationSec":60,
          "durationSec":300,
          "leftSec":180,
          "hostUid":1000001,
          "hostRole":1,
          "currentUserTeam":1,
          "redTeam":{"count":3,"members":[{"uid":10001,"nickname":"A","avatar":"a.png","personalScore":100.5,"personalGems":90}]},
          "blueTeam":{"count":3,"members":[]},
          "neutral":{"count":0,"members":[]},
          "redTop":[{"uid":10001,"nickname":"A","avatar":"a.png","contribution":"999.5"}],
          "blueTop":[],
          "redCrownUid":10001,
          "blueCrownUid":null,
          "redScore":1200.5,
          "blueScore":"800",
          "redGems":1000,
          "blueGems":700,
          "winnerTeam":null,
          "cooldownLeftSec":0
        }
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(PartyBattleState.self, from: json)
        XCTAssertEqual(state.pkId, "pk_1001")
        XCTAssertEqual(state.status, .running)
        XCTAssertEqual(state.roomId, 1234567890123456)
        XCTAssertEqual(state.redScore.doubleValue, 1200.5)
        XCTAssertEqual(state.blueScore.doubleValue, 800)
        XCTAssertEqual(state.redGems?.doubleValue, 1000)
        XCTAssertEqual(state.redTeam.members.count, 1)
        XCTAssertEqual(state.redTop.first?.contribution?.doubleValue, 999.5)
    }

    func testBattleMemberUidStringInt64Compat() throws {
        // H5 fixture: uid 可能是 String 或 Int64
        let jsonStr = "{\"uid\":\"10001\",\"nickname\":\"A\"}".data(using: .utf8)!
        let jsonInt = "{\"uid\":10001,\"nickname\":\"A\"}".data(using: .utf8)!
        let mStr = try JSONDecoder().decode(BattleMember.self, from: jsonStr)
        let mInt = try JSONDecoder().decode(BattleMember.self, from: jsonInt)
        XCTAssertEqual(mStr.uid, 10001)
        XCTAssertEqual(mInt.uid, 10001)
    }
}
```

- [ ] **Step 2: 加白名单 + regen + 跑测试验证失败**

- [ ] **Step 3: 写实现** — `PartyBattleModels.swift`

按 spec §4.1 完整实现 `PartyBattleState / BattleTeam / BattleMember / BattleTopMember`。**BattleMember.uid 需用 `Int64OrString` decoder wrapper 支持 String/Int64 双兼容**（对齐 ios-decode-userid-compat rule）：

```swift
struct BattleMember: Codable, Equatable, Identifiable {
    var id: String { String(uid) }
    let uid: Int64
    let nickname: String?
    let avatar: String?
    var personalScore: DoubleOrString?
    var personalGems: DoubleOrString?
    var isCrownHolder: Bool?

    enum CodingKeys: String, CodingKey {
        case uid, nickname, avatar, personalScore, personalGems, isCrownHolder
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int64.self, forKey: .uid) { uid = i }
        else if let s = try? c.decode(String.self, forKey: .uid), let i = Int64(s) { uid = i }
        else { throw DecodingError.dataCorruptedError(forKey: .uid, in: c,
              debugDescription: "uid neither Int64 nor String") }
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        personalScore = try c.decodeIfPresent(DoubleOrString.self, forKey: .personalScore)
        personalGems = try c.decodeIfPresent(DoubleOrString.self, forKey: .personalGems)
        isCrownHolder = try c.decodeIfPresent(Bool.self, forKey: .isCrownHolder)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uid, forKey: .uid)
        try c.encodeIfPresent(nickname, forKey: .nickname)
        try c.encodeIfPresent(avatar, forKey: .avatar)
        try c.encodeIfPresent(personalScore, forKey: .personalScore)
        try c.encodeIfPresent(personalGems, forKey: .personalGems)
        try c.encodeIfPresent(isCrownHolder, forKey: .isCrownHolder)
    }
}
```

同理 `PartyBattleState.roomId / hostUid` 用 Int64（如后端可能返 String，同款 CodingKeys + 双 decode）。

- [ ] **Step 4: 跑测试验证通过**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleState/Team/Member/TopMember Codable + uid Int64/String 兼容"
```

---

## Phase 2: API 契约 + IM Payload 层（3 tasks · ~1.5h）

### Task 4: PartyBattleAPIModels — 10 endpoints Request/Response

**Files:**
- Create: `Sources/Party/Battle/Models/PartyBattleAPIModels.swift`
- Create: `HilyTests/Party/Battle/PartyBattleAPIModelsTests.swift`

**参考 spec 附录 C** 10 个端点定义。

- [ ] **Step 1: 写失败测试** — 覆盖每个 endpoint request encode + response decode 各一条

```swift
import XCTest
@testable import Hily

final class PartyBattleAPIModelsTests: XCTestCase {

    func testStartRequestEncode() throws {
        let req = PartyBattleStartRequest(roomId: "1234567890", templateId: "1", durationSec: 300, hostInitialTeam: 1)
        let data = try JSONEncoder().encode(req)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["roomId"] as? String, "1234567890")
        XCTAssertEqual(dict["templateId"] as? String, "1")
        XCTAssertEqual(dict["durationSec"] as? Int, 300)
        XCTAssertEqual(dict["hostInitialTeam"] as? Int, 1)
    }

    func testTemplatesResponseDecode() throws {
        let json = "[{\"id\":\"1\",\"name\":\"3v3\",\"durationSec\":300},{\"id\":\"2\",\"name\":\"5v5\",\"durationSec\":600}]".data(using: .utf8)!
        let arr = try JSONDecoder().decode([PartyBattleTemplate].self, from: json)
        XCTAssertEqual(arr.count, 2)
        XCTAssertEqual(arr[0].name, "3v3")
    }

    func testStateResponseDecode_partialFields() throws {
        // 后端 partial payload 也应能 decode（optional 字段包容）
        let json = "{\"pkId\":\"pk_1\",\"battleId\":1,\"roomId\":123,\"status\":1,\"selectingDurationSec\":60,\"durationSec\":300,\"leftSec\":60,\"hostUid\":1,\"hostRole\":1,\"redTeam\":{\"count\":0,\"members\":[]},\"blueTeam\":{\"count\":0,\"members\":[]},\"neutral\":{\"count\":0,\"members\":[]},\"redTop\":[],\"blueTop\":[],\"redScore\":0,\"blueScore\":0,\"cooldownLeftSec\":0}".data(using: .utf8)!
        let s = try JSONDecoder().decode(PartyBattleState.self, from: json)
        XCTAssertEqual(s.status, .selecting)
    }

    // 其余 endpoints 同款一发一收各一条测试
    // - PartyBattleApplyMicRequest / ApplyMicResponse
    // - PartyBattleSwitchTeamRequest
    // - PartyBattleStartNowRequest
    // - PartyBattleForceEndRequest
    // - PartyBattleSettlementResponse
    // - PartyBattleApplicationsResponse
    // - PartyBattleApproveApplyRequest
}
```

- [ ] **Step 2: 加白名单 + regen + 跑测试验证失败**

- [ ] **Step 3: 写实现** — 按 spec 附录 C + `.claude/rules/api-http-method-strict.md`

```swift
import Foundation

// MARK: - Requests
struct PartyBattleStartRequest: Encodable {
    let roomId: String
    let templateId: String
    let durationSec: Int
    let hostInitialTeam: Int?
}
struct PartyBattleStateRequest: Encodable {
    let roomId: String
}
struct PartyBattleSwitchTeamRequest: Encodable {
    let pkId: String
    let targetTeam: Int
}
struct PartyBattleApplyMicRequest: Encodable {
    let pkId: String
    let desiredTeam: Int?
    let desiredMicId: Int?
}
struct PartyBattleStartNowRequest: Encodable { let pkId: String }
struct PartyBattleForceEndRequest: Encodable { let pkId: String }
struct PartyBattleSettlementRequest: Encodable { let pkId: String }
struct PartyBattleApproveApplyRequest: Encodable {
    let pkId: String
    let applyId: Int
    let approve: Bool
}

// MARK: - Responses
struct PartyBattleTemplate: Codable, Identifiable, Equatable {
    let id: String
    let name: String?
    let durationSec: Int?
}
struct PartyBattleStartResponse: Codable {
    let pkId: String?
    let battleId: Int?
    // 更多字段 F-1a 真机 log 抓后补齐
}
struct PartyBattleApplyMicResponse: Codable {
    let applyId: Int
    let desiredTeam: Int?
    let desiredMicId: Int?
}
struct PartyBattleSettlementResponse: Codable {
    let pkId: String
    let durationSec: Int?     // A6 待真机验证：自然结束必有；forceEnd 是否有？
    let winnerTeam: Int?
    let redScore: DoubleOrString?
    let blueScore: DoubleOrString?
    let redGems: DoubleOrString?
    let blueGems: DoubleOrString?
    let mvpSender: BattleMvp?
    let mvpReceiver: BattleMvp?
    let endedEarly: Bool?
    let cooldownLeftSec: Int?
}
struct BattleMvp: Codable {
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let value: DoubleOrString?

    enum CodingKeys: String, CodingKey { case uid, nickname, avatar, value }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let i = try? c.decode(Int64.self, forKey: .uid) { uid = i }
        else if let s = try? c.decode(String.self, forKey: .uid), let i = Int64(s) { uid = i }
        else { throw DecodingError.dataCorruptedError(forKey: .uid, in: c, debugDescription: "uid") }
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        value = try c.decodeIfPresent(DoubleOrString.self, forKey: .value)
    }
}
struct PartyBattleApplicationsResponse: Codable {
    let list: [PartyBattleApplication]
    // A4 待真机验证：是否含 pageSize/offset
}
struct PartyBattleApplication: Codable, Identifiable, Equatable {
    var id: Int { applyId }
    let applyId: Int
    let uid: Int64
    let nickname: String?
    let avatar: String?
    let desiredTeam: Int?
    let desiredMicId: Int?
    let createdAt: Int64?

    enum CodingKeys: String, CodingKey {
        case applyId, uid, nickname, avatar, desiredTeam, desiredMicId, createdAt
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applyId = try c.decode(Int.self, forKey: .applyId)
        if let i = try? c.decode(Int64.self, forKey: .uid) { uid = i }
        else if let s = try? c.decode(String.self, forKey: .uid), let i = Int64(s) { uid = i }
        else { throw DecodingError.dataCorruptedError(forKey: .uid, in: c, debugDescription: "uid") }
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        avatar = try c.decodeIfPresent(String.self, forKey: .avatar)
        desiredTeam = try c.decodeIfPresent(Int.self, forKey: .desiredTeam)
        desiredMicId = try c.decodeIfPresent(Int.self, forKey: .desiredMicId)
        createdAt = try c.decodeIfPresent(Int64.self, forKey: .createdAt)
    }
}
```

- [ ] **Step 4: 跑测试验证通过**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] 10 endpoints Request/Response Codable + 单测"
```

---

### Task 5: PartyBattleIMPayloads — 12 attachType payload Codable

**Files:**
- Create: `Sources/Party/Battle/Models/PartyBattleIMPayloads.swift`
- Create: `HilyTests/Party/Battle/PartyBattleIMPayloadsTests.swift`

**参考 spec §4.6 + §5.1** attachType 1100-1112 payload 字段映射。

- [ ] **Step 1: 写失败测试** — 12 case 分别 decode

覆盖：
- 1100 selectingStart（含 redTeam/blueTeam/neutral/redTop/blueTop）
- 1101 teamMemberChange（preservePersonal 场景 payload 少字段）
- 1102 applyPushed
- 1103 runningStart（durationSec/leftSec）
- 1105 leaderboardMerged（红蓝分数/gems/crown 增量）
- 1106 crownChanged
- 1109 endStub
- 1110 kind 分公屏
- 1112 cooldownEnd（无 payload）
- 1104/1107/1108/1111 fallback log（保留 case + payload 用 [String: Any] tolerant decode）

- [ ] **Step 2: 加白名单 + regen + 跑测试验证失败**

- [ ] **Step 3: 写实现** — 12 struct 按 spec §5.1 字段映射，Codable 用 `decodeIfPresent`（后端 partial payload 兼容）

**注意**（im-payload-real-log-over-code-assumption rule）：
- 字段名首次真机 log 抓取校对，不能凭 H5 partyBattle.ts assumption 拍板
- Router 层 decode 失败时 AppLogger 打 `dataKeys=` 一行 payload 全字段名，便于事后 fix

- [ ] **Step 4: 跑测试验证通过**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] 12 attachType payload Codable + 单测（字段名待真机 log 校对）"
```

---

### Task 6: PartyBattleGlobalConfigParser — Java Map style parse

**Files:**
- Create: `Sources/Party/Battle/Services/PartyBattleGlobalConfigParser.swift`
- Create: `HilyTests/Party/Battle/PartyBattleGlobalConfigParserTests.swift`

后端 `/api/index/getConfigByKey?searchValue=party_room_battle_config` 返回 `{party_room_battle_config: "{totalSwitch=1, cooldownDurationSec=60}"}` Java Map style（**非 JSON**）。

- [ ] **Step 1: 写失败测试**

```swift
final class PartyBattleGlobalConfigParserTests: XCTestCase {

    func testParseJavaMapStyle() {
        let raw = "{totalSwitch=1, cooldownDurationSec=60}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed.totalSwitch, 1)
        XCTAssertEqual(parsed.cooldownDurationSec, 60)
    }

    func testParseEmptyOrInvalid() {
        XCTAssertNil(PartyBattleGlobalConfigParser.parse(""))
        XCTAssertNil(PartyBattleGlobalConfigParser.parse("garbage"))
    }

    func testParseMissingFields_defaults() {
        let raw = "{totalSwitch=0}"
        let parsed = PartyBattleGlobalConfigParser.parse(raw)
        XCTAssertEqual(parsed?.totalSwitch, 0)
        XCTAssertNil(parsed?.cooldownDurationSec)
    }
}
```

- [ ] **Step 2: 写实现** — 简单正则/字符串分割：

```swift
struct PartyBattleGlobalConfig: Equatable {
    let totalSwitch: Int
    let cooldownDurationSec: Int?
}

enum PartyBattleGlobalConfigParser {
    static func parse(_ raw: String) -> PartyBattleGlobalConfig? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = String(trimmed.dropFirst().dropLast())
        var dict: [String: String] = [:]
        for pair in inner.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let k = kv[0].trimmingCharacters(in: .whitespaces)
            let v = kv[1].trimmingCharacters(in: .whitespaces)
            dict[k] = v
        }
        guard let switchStr = dict["totalSwitch"], let sw = Int(switchStr) else { return nil }
        let cd = dict["cooldownDurationSec"].flatMap { Int($0) }
        return PartyBattleGlobalConfig(totalSwitch: sw, cooldownDurationSec: cd)
    }
}
```

- [ ] **Step 3: 跑测试验证通过**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] 全局开关 Java Map style parser + 单测"
```

---

## Phase 3: 服务层（1 task · ~1h）

### Task 7: PartyBattleService — 10 endpoints + config 拉取

**Files:**
- Create: `Sources/Party/Battle/Services/PartyBattleService.swift`

**依赖**：`PartyAPIClient.shared`（sapi 域已就绪）+ `AppConfigService`（config 拉取已就绪）+ `SapiTokenStore`（BAGSHOP_TOKEN 24h + 401 auto-retry 已就绪）

- [ ] **Step 0（前置 grep 验证依赖真实存在）**

```bash
grep -rn "class PartyAPIClient\|class SapiTokenStore\|class AppConfigService\|class AppConfigStore" Sources/ 2>/dev/null | head -15
grep -rn "func fetchString\|func fetch(key\|func fetchConfig" Sources/Core/ 2>/dev/null | head -10
```

**若 `AppConfigService.fetchString` 不存在**：用现有 `AppConfigStore.shared` 或 `AppConfigService.shared.fetch(keys:)` 等价 API，Step 1 实现按真实 API 调；不能凭 spec assumption 硬编。

- [ ] **Step 1: 写实现**（无独立单测，走 F-1a milestone 真机集成验证 — service 层是 API client 薄封装，单测 mock 边际收益低）

**关键**（DI 支撑测试）：加 `PartyBattleServiceProtocol`，`PartyBattleService` conform 它，让 store 层测试可注入 fake service。

```swift
import Foundation

protocol PartyBattleServiceProtocol: AnyObject {
    func fetchTemplates() async throws -> [PartyBattleTemplate]
    func start(_ req: PartyBattleStartRequest) async throws -> PartyBattleStartResponse?
    func fetchState(_ roomId: String) async throws -> PartyBattleState?
    func switchTeam(_ req: PartyBattleSwitchTeamRequest) async throws
    func applyMic(_ req: PartyBattleApplyMicRequest) async throws -> PartyBattleApplyMicResponse?
    func startNow(_ pkId: String) async throws
    func forceEnd(_ pkId: String) async throws
    func fetchSettlement(_ pkId: String) async throws -> PartyBattleSettlementResponse
    func fetchApplications(_ roomId: String) async throws -> PartyBattleApplicationsResponse
    func approveApply(_ req: PartyBattleApproveApplyRequest) async throws
    func fetchGlobalConfig() async throws -> PartyBattleGlobalConfig?
}

@MainActor
final class PartyBattleService: PartyBattleServiceProtocol {
    static let shared = PartyBattleService()
    private init() {}

    private let base = "/sapi/weidou/v1/client/party/battle"

    // MARK: - Templates
    func fetchTemplates() async throws -> [PartyBattleTemplate] {
        try await PartyAPIClient.shared.get("\(base)/templates")
    }

    // MARK: - Start / State
    func start(_ req: PartyBattleStartRequest) async throws -> PartyBattleStartResponse? {
        try await PartyAPIClient.shared.post("\(base)/start", body: req)
    }
    func fetchState(_ roomId: String) async throws -> PartyBattleState? {
        try await PartyAPIClient.shared.post("\(base)/state", body: PartyBattleStateRequest(roomId: roomId))
    }

    // MARK: - Switch / Apply Mic / Start Now / Force End
    func switchTeam(_ req: PartyBattleSwitchTeamRequest) async throws {
        let _: EmptyResponse? = try await PartyAPIClient.shared.post("\(base)/switchTeam", body: req)
    }
    func applyMic(_ req: PartyBattleApplyMicRequest) async throws -> PartyBattleApplyMicResponse? {
        try await PartyAPIClient.shared.post("\(base)/applyMic", body: req)
    }
    func startNow(_ pkId: String) async throws {
        let _: EmptyResponse? = try await PartyAPIClient.shared.post(
            "\(base)/startNow", body: PartyBattleStartNowRequest(pkId: pkId))
    }
    func forceEnd(_ pkId: String) async throws {
        let _: EmptyResponse? = try await PartyAPIClient.shared.post(
            "\(base)/forceEnd", body: PartyBattleForceEndRequest(pkId: pkId))
    }

    // MARK: - Settlement / Applications / Approve
    func fetchSettlement(_ pkId: String) async throws -> PartyBattleSettlementResponse {
        try await PartyAPIClient.shared.post("\(base)/settlement",
            body: PartyBattleSettlementRequest(pkId: pkId))
    }
    func fetchApplications(_ roomId: String) async throws -> PartyBattleApplicationsResponse {
        try await PartyAPIClient.shared.get("\(base)/applications?roomId=\(roomId)")
    }
    func approveApply(_ req: PartyBattleApproveApplyRequest) async throws {
        let _: EmptyResponse? = try await PartyAPIClient.shared.post(
            "\(base)/approveApply", body: req)
    }

    // MARK: - Global config
    func fetchGlobalConfig() async throws -> PartyBattleGlobalConfig? {
        let raw = try await AppConfigService.shared.fetchString(key: "party_room_battle_config")
        return PartyBattleGlobalConfigParser.parse(raw ?? "")
    }
}

private struct EmptyResponse: Decodable {}
```

**注意**（api-http-method-strict rule）：
- GET vs POST 严格对齐 spec 附录 C（templates / applications 走 GET，其他走 POST）
- 若 `AppConfigService.shared.fetchString` 不存在，用现有 `AppConfigStore` API 替代

- [ ] **Step 2: Regen + build sanity check**（fetchString 是否存在需 verify；若不存在改用等价 API）

```bash
grep -rn "class AppConfigService\|func fetchString\|fetchConfig" Sources/Core/ | head -10
```

- [ ] **Step 3: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleService 10 endpoints + global config"
```

---

## Phase 4: 状态机 + IM 路由（4 tasks · ~3h · 核心）

### Task 8: PartyBattleStore — 5 态状态机骨架 + 派生 getter 完整清单 + Fixture helper

**Files:**
- Create: `Sources/Party/Battle/PartyBattleStore.swift`
- Create: `HilyTests/Party/Battle/PartyBattleStoreStateMachineTests.swift`
- Create: `HilyTests/Party/Battle/Fixtures/PartyBattleTestFixtures.swift`（DEBUG-only）
- Modify: `Sources/Party/PartyStore.swift`（加 DEBUG-only `_setSeatsForTesting` / `_setRoomInfoForTesting` helper）

**参考 spec §3 + §4.2 + §6.1/§6.2 UI 依赖**：

**派生 getter 完整清单（Phase 5 UI 全依赖）**：
- 5 态基础：`isSelecting / isRunning / isEnded / isCoolingDown / isFunctionEnabled`
- 房间：`effectiveRoomId`（roomId=0 占位时 fallback `PartyStore.shared.roomInfo?.id`）
- 权限：`canManage`（`store.selfRole == .owner || .admin`；查 PartyStore.shared.selfRole）· `canStartPk`（`canManage && isFunctionEnabled && (state?.status ∉ {.running, .cooldown}) && roomTempIdInt == 1`）
- 分数显示：`redScoreDisplay / blueScoreDisplay`（spec §4.3 gems fallback getter）
- Sheet 控制：`showSettlementBinding`（`{ get { showSettlement } set { showSettlement = newValue } }` 双向绑定给 sheet(isPresented:)）
- Settlement 快照：`lastSettlement: PartyBattleSettlementResponse?`
- 强制结束态：`forceEnding: Bool`
- 模板列表：`templates: [PartyBattleTemplate]`（apiPartyBattleTemplates 拉取缓存）
- 阵营↔麦位（依赖 Task 15.5 PartyBattleSeatLayout）：`pkVideoSlotTeamClass(_ slotIdx: Int) -> Color?`（RUNNING 期视频位红蓝色边）· `redMembers: [BattleMember]` · `blueMembers: [BattleMember]` — 供 UI/audio-wrap 覆盖使用（F-1b displayGiftCount 用；F-1a 内先加 getter 骨架，UI 消费延后）

- [ ] **Step 0: 建 fixture helper**（先建，后续 test 依赖）

Create `Fixtures/PartyBattleTestFixtures.swift`：

```swift
#if DEBUG
import Foundation
@testable import Hily

extension PartyBattleState {
    static func testFixture(
        pkId: String = "pk_test",
        status: PartyBattleStatus = .selecting,
        roomId: Int64 = 1234567890,
        hostUid: Int64 = 1000001,
        redUids: [Int64] = [],
        blueUids: [Int64] = [],
        neutralUids: [Int64] = []
    ) -> PartyBattleState {
        // 按 PartyBattleState 字段构造最小合法实例
        // (略：spec §4.1 字段全部合理默认)
    }
}

struct BattleSelectingStartPayloadStub {
    static func stub(redUids: [Int64] = [], blueUids: [Int64] = [], neutralUids: [Int64] = [])
        -> BattleSelectingStartPayload { /* ... */ }
}

extension PartyRoomSeat {
    static func stub(userId: String, giftValueCount: Int64 = 0) -> PartyRoomSeat { /* ... */ }
}

extension PartyStore {
    func _setSeatsForTesting(_ seats: [PartyRoomSeat]) {
        // MainActor sync 设置内部 seatList
    }
    func _setRoomInfoForTesting(id: Int64) { /* ... */ }
    func _setRoleForTesting(_ role: PartyRoomRole) { /* ... */ }
    func _setRoomTempIdForTesting(_ tempId: Int) { /* ... */ }
}

extension PartyBattleStore {
    static func testInstance(service: PartyBattleServiceProtocol = FakeBattleService()) -> PartyBattleStore {
        PartyBattleStore(service: service, isTesting: true)
    }
    func _setStateForTesting(_ s: PartyBattleState) { state = s }
    func _applyStatusForTesting(_ status: PartyBattleStatus) { applyStatus(status) }
    func _startCooldownForTesting(leftSec: Int) { startCooldownTicker(leftSec: leftSec) }
    func _setTotalSwitchForTesting(_ v: Int) { totalSwitch = v }
    func _setShowSettlementForTesting(_ v: Bool) { showSettlement = v }
    func _enqueueLeaderboardForTesting(_ payload: BattleLeaderboardMergedPayload) async {
        await enqueueLeaderboardPayload(payload)
    }
    func _setTemplatesForTesting(_ templates: [PartyBattleTemplate]) { self.templates = templates }
}

// 补 testFixture 完整参数
extension PartyBattleState {
    static func testFixture(
        pkId: String = "pk_test",
        status: PartyBattleStatus = .selecting,
        roomId: Int64 = 1234567890,
        hostUid: Int64 = 1000001,
        leftSec: Int = 60,                        // 新增 tickLeft 测试用
        durationSec: Int = 300,
        selectingDurationSec: Int = 60,
        redUids: [Int64] = [],
        blueUids: [Int64] = [],
        neutralUids: [Int64] = []
    ) -> PartyBattleState { /* ... */ }
}

// FakeBattleService 用于 mock 断言调用顺序（Task 10c 需要）
final class FakeBattleService: PartyBattleServiceProtocol {
    var calls: [String] = []
    var settlementResponse: PartyBattleSettlementResponse?
    var settlementError: Error?
    var stateResponse: PartyBattleState?
    var templatesResponse: [PartyBattleTemplate] = []

    func fetchTemplates() async throws -> [PartyBattleTemplate] { calls.append("templates"); return templatesResponse }
    func fetchState(_ roomId: String) async throws -> PartyBattleState? { calls.append("state"); return stateResponse }
    func fetchSettlement(_ pkId: String) async throws -> PartyBattleSettlementResponse {
        calls.append("settlement")
        if let e = settlementError { throw e }
        return settlementResponse ?? PartyBattleSettlementResponse.stub()
    }
    // ... 其他 protocol methods stub
}
#endif
```

**关键**（DI 决策）：
- `PartyBattleService` 拆 `PartyBattleServiceProtocol` + `PartyBattleService: PartyBattleServiceProtocol`（本 task 补，Task 7 实现层顺带加 protocol conformance）
- `PartyBattleStore` init 接受 `service: PartyBattleServiceProtocol = PartyBattleService.shared`，测试注入 `FakeBattleService` 断言调用顺序（如 Task 10c 的 `onEnd(null) → refresh → fetchSettlement` 三步链路验证）

**Fixture 边界**（fresh engineer 必读）：
- ⚠️ 所有 `_setXxxForTesting` / `testInstance()` / `testFixture()` / `FakeBattleService` 均在 `#if DEBUG` guard 内，**禁止**在生产代码路径调用；仅 Preview 和 XCTest 允许
- Preview 复用 fixture 时按需引用 `#if DEBUG` extension；`#Preview { ... }` 块本身也在 DEBUG scope 内

**FakeBattleService 失败分支覆盖（Task 8 补）**：以下失败字段需在 FakeBattleService 中提供 stub 支持，Task 10c/10d 的错误路径测试用：
```swift
final class FakeBattleService: PartyBattleServiceProtocol {
    var settlementError: Error?      // Task 10c 静默 return null
    var stateError: Error?           // Task 10d refresh 失败静默
    var templatesError: Error?       // Task 10d loadTemplates 失败静默
    var startError: Error?           // Task 12 InitiatePopup 报错路径（若做）
    // ... 其他方法按需补
}
```

- [ ] **Step 1: 写失败测试** — 覆盖 R-04/06/07/08 + 5 态非法迁移守卫（spec §3.3） + canStartPk / canManage 派生逻辑

- [ ] **Step 1: 写失败测试** — 覆盖 R-04/06/07/08 + 5 态非法迁移守卫（spec §3.3）

```swift
final class PartyBattleStoreStateMachineTests: XCTestCase {
    var store: PartyBattleStore!

    override func setUp() async throws {
        store = await MainActor.run { PartyBattleStore.testInstance() }  // 独立测试实例
    }

    // R-04: 客态首次进 RUNNING 房 state=nil 构造默认
    @MainActor
    func testInitialStateIsIdle() {
        XCTAssertNil(store.state)
        XCTAssertFalse(store.isSelecting)
        XCTAssertFalse(store.isRunning)
    }

    @MainActor
    func testStatusDerivedGetters() {
        let s = PartyBattleState.testFixture(status: .running)
        store._setStateForTesting(s)
        XCTAssertTrue(store.isRunning)
        XCTAssertFalse(store.isSelecting)
    }

    @MainActor
    func testEffectiveRoomIdFallback() {
        // roomId=0 占位时用 PartyStore fallback
        let s = PartyBattleState.testFixture(roomId: 0)
        store._setStateForTesting(s)
        PartyStore.shared._setRoomInfoForTesting(id: 9999)
        XCTAssertEqual(store.effectiveRoomId, 9999)
    }

    // 5 态迁移非法守卫（spec §3.3）
    @MainActor
    func testIllegalTransition_runningToSelecting_isRejected() {
        store._setStateForTesting(PartyBattleState.testFixture(status: .running))
        store._applyStatusForTesting(.selecting)
        XCTAssertEqual(store.state?.status, .running)  // 拒绝，保留原态
    }

    // 派生 getter 完整清单
    @MainActor
    func testCanStartPk_ownerAndTemplateOne_returnsTrue() {
        PartyStore.shared._setRoleForTesting(.owner)
        PartyStore.shared._setRoomTempIdForTesting(1)
        store._setTotalSwitchForTesting(1)
        XCTAssertTrue(store.canStartPk)
    }
    @MainActor
    func testCanStartPk_wrongTemplate_returnsFalse() {
        PartyStore.shared._setRoomTempIdForTesting(2)
        XCTAssertFalse(store.canStartPk)
    }
    @MainActor
    func testCanStartPk_duringRunning_returnsFalse() {
        PartyStore.shared._setRoleForTesting(.owner)
        PartyStore.shared._setRoomTempIdForTesting(1)
        store._setTotalSwitchForTesting(1)
        store._setStateForTesting(PartyBattleState.testFixture(status: .running))
        XCTAssertFalse(store.canStartPk)
    }
    @MainActor
    func testShowSettlementBinding_setterFlipsShowSettlement() {
        store._setShowSettlementForTesting(true)
        store.showSettlementBinding.wrappedValue = false
        XCTAssertFalse(store.showSettlement)
    }
}
```

- [ ] **Step 2: 加白名单 + regen + 跑测试验证失败**

- [ ] **Step 3: 写实现** — `PartyBattleStore.swift`

**关键**（spec §4.2 + §3）：
- 单例 `PartyBattleStore.shared`
- `@Published private(set) var state: PartyBattleState?`
- 5 态派生 getter + `effectiveRoomId` fallback
- 5 态迁移守卫（spec §3.3 表）— 非法迁移仅 log warning + 保留原态
- 提供 `#if DEBUG` 的 `testInstance()` / `_setStateForTesting` / `_applyStatusForTesting` 支持单测

- [ ] **Step 4: 跑测试验证通过**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleStore 5 态状态机骨架 + 派生 getter + 迁移守卫"
```

---

### Task 9: PartyBattleStore — onSelectingStart 侵入 PartyStore + PartyStore.clearGiftValueCount API

**Files:**
- Modify: `Sources/Party/PartyStore.swift`（加 `clearGiftValueCount(uids:)` API）
- Modify: `Sources/Party/Battle/PartyBattleStore.swift`（加 `onSelectingStart(payload:)`）
- Create/Modify: `HilyTests/Party/Battle/PartyBattleStoreSideEffectsTests.swift`

**参考 spec §3.4.1**：只清红蓝队参战 uid 的 `seat.giftValueCount = 0`，中立位不清。

- [ ] **Step 1: 写失败测试** — R-24 侵入清麦位

```swift
@MainActor
func testOnSelectingStart_clearsRedBlueTeamMemberGiftValueOnly() async {
    // 3 个麦位：uid A 红队，uid B 蓝队，uid C 中立
    PartyStore.shared._setSeatsForTesting([
        PartyRoomSeat.stub(userId: "A", giftValueCount: 100),
        PartyRoomSeat.stub(userId: "B", giftValueCount: 200),
        PartyRoomSeat.stub(userId: "C", giftValueCount: 300),
    ])
    let payload = BattleSelectingStartPayload.stub(
        redUids: [10001], blueUids: [10002], neutralUids: [10003])
    // (A/B/C uid mapping to 10001/10002/10003)

    await store.onSelectingStart(payload)

    XCTAssertEqual(PartyStore.shared.seatList[0].giftValueCount, 0)  // A 红
    XCTAssertEqual(PartyStore.shared.seatList[1].giftValueCount, 0)  // B 蓝
    XCTAssertEqual(PartyStore.shared.seatList[2].giftValueCount, 300)  // C 中立不清
}
```

- [ ] **Step 2: 加 PartyStore.clearGiftValueCount(uids:) API**

```swift
// PartyStore.swift 尾部或 seat 管理段
@MainActor
func clearGiftValueCount(uids: Set<String>) {
    for i in seatList.indices where uids.contains(seatList[i].userId) {
        seatList[i].giftValueCount = 0
    }
    AppLogger.party.info("[PartyStore] clearGiftValueCount uids=\(uids.count, privacy: .public)")
}
```

- [ ] **Step 3: 加 PartyBattleStore.onSelectingStart 实现** — 按 spec §3.4.1

- [ ] **Step 4: 跑测试验证通过**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] onSelectingStart 侵入清麦位 + PartyStore.clearGiftValueCount API"
```

---

### Task 10a: PartyBattleStore — tickLeft 三段 + cooldown ticker

**Files:**
- Modify: `Sources/Party/Battle/PartyBattleStore.swift`
- Modify: `HilyTests/Party/Battle/PartyBattleStoreSideEffectsTests.swift`

**参考 spec §3.4.3 + §3.4.5**。

- [ ] **Step 1: 写失败测试**

```swift
// R-10 冷却 ticker 归零 → onCooldownEnd
@MainActor
func testCooldownTicker_ticksTo0AndFiresOnCooldownEnd() async throws {
    store._startCooldownForTesting(leftSec: 2)
    XCTAssertEqual(store.cooldownLeftSec, 2)
    try await Task.sleep(nanoseconds: 2_500_000_000)
    XCTAssertEqual(store.cooldownLeftSec, 0)
}

// tickLeft SELECTING 归零 → RUNNING 迁移
@MainActor
func testTickLeft_selectingHitsZero_transitionsToRunning() {
    store._setStateForTesting(PartyBattleState.testFixture(status: .selecting, leftSec: 1))
    store.tickLeft()  // leftSec 1 → 0
    // 归零走 onRunningStart({durationSec}) 已存在分支只 set status=2 + leftSec
    XCTAssertEqual(store.state?.status, .running)
}
```

**注意**：tickLeft RUNNING 归零链路较复杂（onEnd(null) → refresh → fetchSettlement），放到 Task 10c 与 onEnd 一起。本 task 只覆盖 SELECTING 归零 + cooldown ticker。

- [ ] **Step 2: 写实现**

- cooldown ticker：`Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true)` 挂 store `private var cooldownTimer: Timer?`，reset 时 invalidate；归零调 `onCooldownEnd()` + invalidate
- tickLeft 作为 store action 由 View 层 `.onReceive(Timer.publish(every: 1))` 触发（不封装 timer 到 store 内部）
- SELECTING 归零仅 set status=.running + leftSec=durationSec；不发起 RUNNING API（onRunningStart 由 1103 或本地转态触发）

- [ ] **Step 3: 跑测试验证通过**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] tickLeft SELECTING 归零 + cooldown ticker + 单测"
```

---

### Task 10b: PartyBattleStore — 200ms 聚合 (1105) + preservePersonal (1101)

**Files:**
- Modify: `Sources/Party/Battle/PartyBattleStore.swift`
- Modify: `HilyTests/Party/Battle/PartyBattleStoreSideEffectsTests.swift`

**参考 spec §3.4.2 + §3.4.4**。

- [ ] **Step 1: 写失败测试**

```swift
// R-05 preservePersonal
@MainActor
func testOnTeamMemberChange_preservePersonalFromPreviousMembers() async {
    // 已有 state 含 uid=10001 personalScore=100；payload 少 personalScore
    // 预期：合并后 personalScore 仍为 100
    // 若 payload 带 personalScore=50，则用 payload 值（payload 带值优先）
}

// 200ms trailing 聚合（1105）
@MainActor
func testLeaderboardMerged_200msTrailingAggregation() async throws {
    // 10ms 内连发 3 次 1105 → 200ms 后单次 commit
    // 断言：期间 state 未变；200ms 后 state 更新为最后一次合并结果
    await store._enqueueLeaderboardForTesting(payload1)
    await store._enqueueLeaderboardForTesting(payload2)
    await store._enqueueLeaderboardForTesting(payload3)
    XCTAssertEqual(store.state?.redScore.doubleValue, initialScore)  // 未 commit
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(store.state?.redScore.doubleValue, payload3.redScore.doubleValue)  // 已合并 commit
}
```

- [ ] **Step 2: 写实现**

**关键细节**（对齐 H5 partyBattle.ts:472-473）：
- 首条到达设 200ms 后 flush 定时器；后续到达合并 payload 字段但**不重置定时器**（trailing 语义）
- 200ms 到期集中 commit + 清 pendingLeaderboardPayload + 清 leaderboardFlushTask
- reset() 内 cancel flushTask + 清 pending payload
- preservePersonal：payload 中 personalScore/personalGems 缺失时按 uid 从旧 members 回填；payload 带值优先（`if merged.personalScore == nil { merged.personalScore = old.personalScore }`）

- [ ] **Step 3: 跑测试验证通过**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] 200ms trailing 聚合 (1105) + preservePersonal (1101) + 单测"
```

---

### Task 10c: PartyBattleStore — onEnd 三分类 (stub/full/null) + fetchSettlement + tickLeft RUNNING 归零

**Files:**
- Modify: `Sources/Party/Battle/PartyBattleStore.swift`
- Modify: `HilyTests/Party/Battle/PartyBattleStoreSideEffectsTests.swift`

**参考 spec §3.4.3 + §1.1 onEnd 分类字段**。

- [ ] **Step 1: 写失败测试**

```swift
// R-09 onEnd 三分类
@MainActor
func testOnEnd_stubPayload_setsCooldownFallbackOnly() async {
    // stub：settlement 无 durationSec 字段（IM 1109 stub）
    // 预期：cooldownLeftSec > 0 + showSettlement=false（不弹 sheet 等 API settlement）
}
@MainActor
func testOnEnd_fullSettlement_showsSettlement() async {
    // full：settlement 含 durationSec（API /settlement 响应）
    // 预期：showSettlement=true + cooldownLeftSec=settlement.cooldownLeftSec
}
@MainActor
func testOnEnd_null_writesCooldownFallbackOnly() async {
    // null：tickLeft RUNNING 归零场景本地路径
    // 预期：不触发 fetchSettlement（防重复请求）+ cooldownLeftSec 用 store.cooldownDurationSec 或 60s fallback
}

// tickLeft RUNNING 归零 三步链路
@MainActor
func testTickLeft_runningHitsZero_triggersOnEndNullAndRefreshAndFetchSettlement() async {
    // 步骤：onEnd(null) → refresh(roomId) → fetchSettlement().then(覆盖 cooldownLeftSec)
    // 用 mock service 断言三次调用顺序
}

// fetchSettlement 错误静默 return null
@MainActor
func testFetchSettlement_serverError_returnsNull() async {
    // mock 抛错 → 断言 lastSettlement 保持 nil + 无 crash
}
```

- [ ] **Step 2: 写实现**

- `isFullSettlement = settlement && typeof settlement.durationSec === 'number'`（partyBattle.ts:552 对齐）
- `onEnd(null)` 不触发 fetchSettlement，只写 cooldownLeftSec fallback
- tickLeft RUNNING 归零三步：`onEnd(null)` → `refresh(roomId)` → `fetchSettlement().then(覆盖 cooldownLeftSec)`
- fetchSettlement 错误静默 return null（无 trackLog，对齐 partyBattle.ts:612-614）
- cooldown 兜底优先级：`settlement.cooldownLeftSec > store.cooldownDurationSec > COOLDOWN_SEC_FALLBACK(60)`

- [ ] **Step 3: 跑测试验证通过**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] onEnd 三分类 + fetchSettlement + tickLeft RUNNING 归零 + 单测"
```

---

### Task 10d: PartyBattleStore — refreshIfNeeded + loadTemplatesIfNeeded 入口 action

**Files:**
- Modify: `Sources/Party/Battle/PartyBattleStore.swift`
- Modify: `HilyTests/Party/Battle/PartyBattleStoreSideEffectsTests.swift`

**依据**：
- Task 22 `PartyRoomView.task` 需要 `battleStore.refreshIfNeeded(roomId:)` 冷启拉状态
- Task 12 `PartyBattleInitiatePopup` 需要 `battleStore.loadTemplatesIfNeeded()` 拉模板列表填充 chip

**参考 spec §3.2**：refresh 是"客态直接进 RUNNING 房 / 冷启动 / 断网重连"的兜底入口。

- [ ] **Step 1: 写失败测试**

```swift
// refresh 走 fake service state → 应用 status/timeline
@MainActor
func testRefreshIfNeeded_appliesStateFromService() async throws {
    let fake = FakeBattleService()
    fake.stateResponse = PartyBattleState.testFixture(status: .running)
    let store = PartyBattleStore.testInstance(service: fake)
    await store.refreshIfNeeded(roomId: "1234")
    XCTAssertEqual(store.state?.status, .running)
    XCTAssertTrue(fake.calls.contains("state"))
}

@MainActor
func testRefreshIfNeeded_serviceReturnsNil_leavesStateNil() async {
    let fake = FakeBattleService()
    fake.stateResponse = nil
    let store = PartyBattleStore.testInstance(service: fake)
    await store.refreshIfNeeded(roomId: "1234")
    XCTAssertNil(store.state)
}

@MainActor
func testLoadTemplatesIfNeeded_populatesTemplates() async throws {
    let fake = FakeBattleService()
    fake.templatesResponse = [PartyBattleTemplate(id: "1", name: "3v3", durationSec: 300)]
    let store = PartyBattleStore.testInstance(service: fake)
    await store.loadTemplatesIfNeeded()
    XCTAssertEqual(store.templates.count, 1)
    XCTAssertEqual(store.templates.first?.name, "3v3")
}

@MainActor
func testLoadTemplatesIfNeeded_twiceOnlyFetchesOnce() async {
    let fake = FakeBattleService()
    fake.templatesResponse = [/* ... */]
    let store = PartyBattleStore.testInstance(service: fake)
    await store.loadTemplatesIfNeeded()
    await store.loadTemplatesIfNeeded()
    XCTAssertEqual(fake.calls.filter { $0 == "templates" }.count, 1)  // 幂等
}
```

- [ ] **Step 2: 写实现**

```swift
@MainActor
func refreshIfNeeded(roomId: String) async {
    do {
        if let s = try await service.fetchState(roomId) {
            applyRefreshedState(s)   // 内部按 status 决定进 SELECTING / RUNNING / cooldown
        }
    } catch {
        AppLogger.party.error("[PartyBattleStore] refresh failed: \(error, privacy: .public)")
    }
}

@MainActor
func loadTemplatesIfNeeded() async {
    guard templates.isEmpty else { return }
    do {
        templates = try await service.fetchTemplates()
    } catch {
        AppLogger.party.error("[PartyBattleStore] loadTemplates failed: \(error, privacy: .public)")
    }
}
```

- [ ] **Step 3: 跑测试验证通过**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] refreshIfNeeded + loadTemplatesIfNeeded 入口 action + 单测"
```

**调用入口绑定**（fresh engineer 必读）：
- `refreshIfNeeded(roomId:)` 触发点：Task 22 `PartyRoomView.task { await battleStore.refreshIfNeeded(roomId: store.effectiveRoomId) }` — 冷启动/进房自动 refresh；断网重连兜底通过 network monitor 观察后二次触发（Task 22 补）
- `loadTemplatesIfNeeded()` 触发点：Task 12 `PartyBattleInitiatePopup.task { await store.loadTemplatesIfNeeded() }` — sheet 打开时按需拉；幂等 guard `templates.isEmpty` 已保护重入

---

### Task 11: PartyAttachType 增补 + PartyBattleMessageRouter + PartyMessageRouter 集成

**Files:**
- Modify: `Sources/Party/Models/PartyAttachType.swift`（增补 1100-1112 case + 移出降噪表）
- Create: `Sources/Party/Battle/PartyBattleMessageRouter.swift`
- Modify: `Sources/Party/NIM/PartyMessageRouter.swift`（补 case 转发 battle router）
- Create: `HilyTests/Party/Battle/PartyBattleMessageRouterTests.swift`

**参考 spec §5**：12 attachType → action 映射；主路由 payload 扁平（`ext.attachType/data`），兜底路由嵌套（`customParser.data.type/payload`）。

- [ ] **Step 1: 写失败测试** — R-15 12 case 分发

```swift
final class PartyBattleMessageRouterTests: XCTestCase {

    @MainActor
    func testRoute1100_selectingStart_callsStoreAction() async {
        let router = PartyBattleMessageRouter()
        let store = PartyBattleStore.testInstance()
        router._storeForTesting = store
        let payloadJson: [String: Any] = ["pkId": "pk_1", /* ... */]
        await router.route(attachType: 1100, payload: payloadJson)
        XCTAssertEqual(store.state?.pkId, "pk_1")
        XCTAssertEqual(store.state?.status, .selecting)
    }

    // 1101 / 1102 / 1103 / 1105 / 1106 / 1109 / 1110 / 1112 同款
    // 1104 / 1107 / 1108 / 1111 → fallback log 分支
}
```

- [ ] **Step 2: 加 PartyAttachType case 1100-1112 + 从 `PartyKnownButUnhandledAttachType.codes` 移出**

- [ ] **Step 3: 写 PartyBattleMessageRouter** — 12 case switch + fallback log；每 case decode payload 到对应 Codable + 调 store action

- [ ] **Step 4: PartyMessageRouter.swift:186 附近的 `.battleHeartbeat, .battleGiftNotify, .battleForceEndConfirm, .battleApplyPendingNotice` case 分支替换** — 转发到 `PartyBattleMessageRouter.shared.route()`

- [ ] **Step 5: 跑测试验证通过**
- [ ] **Step 6: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleMessageRouter 12 case 分发 + PartyAttachType 增补 + PartyMessageRouter 集成"
```

---

### Task 11.5: PartyBattleSeatLayout — 阵营↔麦位映射

**Files:**
- Create: `Sources/Party/Battle/PartyBattleSeatLayout.swift`
- Create: `HilyTests/Party/Battle/PartyBattleSeatLayoutTests.swift`

**参考 spec §6.3**：麦位固定映射（红队 slot 0-4 → seatIndex 4-8；蓝队 slot 0-4 → seatIndex 9-13）。

- [ ] **Step 1: 写失败测试**

```swift
final class PartyBattleSeatLayoutTests: XCTestCase {
    func testRedSlotSeatIndex_mapping() {
        XCTAssertEqual(PartyBattleSeatLayout.redSlotSeatIndex(0), 4)
        XCTAssertEqual(PartyBattleSeatLayout.redSlotSeatIndex(4), 8)
    }
    func testBlueSlotSeatIndex_mapping() {
        XCTAssertEqual(PartyBattleSeatLayout.blueSlotSeatIndex(0), 9)
        XCTAssertEqual(PartyBattleSeatLayout.blueSlotSeatIndex(4), 13)
    }
}
```

- [ ] **Step 2: 加白名单 + regen + 跑测试验证失败**

- [ ] **Step 3: 写实现**

```swift
enum PartyBattleSeatLayout {
    static func redSlotSeatIndex(_ slotIdx: Int) -> Int { 4 + slotIdx }
    static func blueSlotSeatIndex(_ slotIdx: Int) -> Int { 9 + slotIdx }
}
```

- [ ] **Step 4: 跑测试验证通过**
- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleSeatLayout 阵营↔麦位映射工具 + 单测"
```

---

### Task 11.7: Double+CompactFormatted extension — K/M 差值格式化

**Files:**
- 前置 grep：`grep -rn "compactFormatted\|extension Double" Sources/Core/Extensions/ Sources/DesignSystem/ 2>/dev/null | head -5`
- Create（若无）：`Sources/Core/Extensions/Double+CompactFormatted.swift`
- Create: `HilyTests/Core/Extensions/DoubleCompactFormattedTests.swift`

**参考 spec §6.4**：`1_000_000 → M` / `1_000 → K` / 保留 2 位小数 / 整数不 trailing 0。

**若已有同名 extension**（`prefer-shared-component-over-adhoc.md` rule）→ 跳过本 task，Task 15 (RunningHud) 直接复用现有。

- [ ] **Step 1: 前置 grep 验证是否已存在**

- [ ] **Step 2（若不存在）：写失败测试 + 实现 + commit**（同 Task 1 结构）

```swift
extension Double {
    var compactFormatted: String {
        let n = self
        if n >= 1_000_000 {
            let m = n / 1_000_000
            return m.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(m))M" : String(format: "%.2fM", m)
        }
        if n >= 1_000 {
            let k = n / 1_000
            return k.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(k))K" : String(format: "%.2fK", k)
        }
        return n.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(n))" : String(format: "%.2f", n)
    }
}
```

测试覆盖：0 / 500 / 999 / 1000 / 1500 / 999999 / 1_000_000 / 1_234_567 边界。

```bash
git commit -m "feat: [公共] Double.compactFormatted K/M 差值格式化 + 单测"
```

---

## Phase 5: UI 组件层（9 tasks + 1 layout view · ~3.5h · 主态 UI）

### Task 12: PartyBattleInitiatePopup

**Files:**
- Create: `Sources/Party/Battle/UI/PartyBattleInitiatePopup.swift`

**参考 spec §6.1**：模板 chip 单选 + 时长 3/5/10 chip 单选 + 站队 R/B/N toggle + Confirm → `store.start(...)`

- [ ] **Step 1: 写实现** — SwiftUI sheet content

- [ ] **Step 2: `#Preview` 三态：初始态 / 选中态 / loading**

- [ ] **Step 3: Regen + build sanity**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyBattleInitiatePopup + Preview 三态"
```

**通用要求（Task 12-20 每个 UI 组件都遵守）**：
- swiftui-body-type-check-timeout rule — 复杂 body 抽 `perform: methodName` / `@ViewBuilder` computed property
- swiftui-button-plain-hitarea rule — icon+label cell 加 `.contentShape(Rectangle())`
- sf-symbol-usage-preflight — 新增 SF Symbol 用现有 grep 命中的：`crown.fill / bolt.fill / flame.fill / xmark / clock`
- prefer-shared-component-over-adhoc — 头像用 `CachedAsyncImage` / `AvatarView`；金额格式化用现有 `Double.compactFormatted`（若无则新增 extension 到 `Sources/Core/Extensions/`）
- L10n — 所有文案走 `Localizable.strings`；首版占位英文（tr/ar 阶段 J 补齐）
- semantic direction — 用 `.leading/.trailing` 不用 `.left/.right`

---

### Task 13: PartyBattleSelectingPanel
### Task 14: PartyBattleSelectingStartStrip
### Task 15: PartyBattleRunningHud
### Task 16: PartyBattleHostBottomMarquee
### Task 17: PartyBattleEndedSettlement
### Task 18: PartyBattleForceEndConfirm
### Task 19: PartyBattleCooldownToast
### Task 20: PartyBattleRulesPopup

**每 task 结构与 Task 12 相同**（4 步：实现 → Preview 三态 → regen + build → commit）。

按 spec §6.1 表格 store getter 依赖 + 关键交互实现。EndedSettlement 中的 MVP 卡最复杂（送礼/收礼双卡 + Win Team 大字 + 分数 VS + endedEarly 副标题），单独多花时间。

**每个 commit 前挂一次 xcodebuild build sanity check**（xcodebuild-log-filter-split rule 拆两条）。

---

### Task 20.5: PkSelectingVideoTripleView — SELECTING 期三视频位布局

**Files:**
- Create: `Sources/Party/Battle/UI/PkSelectingVideoTripleView.swift`

**参考 spec §6.2 麦位 replace 逻辑** + `PartyBattleSeatLayout` (Task 11.5)：SELECTING 期视频位（bigSeats）由 replace 为 PkSelectingVideoTripleView，负责三视频位红蓝阵营站队 UI。

**输入参数**：`bigSeats: [PartyRoomSeat]`（PartyStore 现有）+ `battleStore: PartyBattleStore`。

**关键交互**：
- 参战麦位显示红/蓝色边（依 `battleStore.state?.redTeam.members` / `blueTeam.members` uid 匹配）
- 中立麦位灰色边
- Preview 三态：红队站满 / 双队站满 / 空态

- [ ] **Step 1: 写实现**
- [ ] **Step 2: Preview 三态**
- [ ] **Step 3: Regen + build sanity**
- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] PkSelectingVideoTripleView SELECTING 期三视频位阵营站队 UI"
```

---

## Phase 6: PartyRoomView 集成 + 真机 DoD（3 tasks · ~1.5h）

### Task 21: PartyRoomView wire handlePkTap + toolMenu.startPk

**Files:**
- Modify: `Sources/Party/UI/PartyRoomView.swift:259 handlePkTap + :1133 toolMenu.startPk`

**参考 spec §6.2**：wire 到 `battleStore.isRunning / isCoolingDown / else` 三分支 → 弹对应 sheet

- [ ] **Step 1: 写实现** — 替换现有两处 TODO 占位

- [ ] **Step 2: 加 `@StateObject private var battleStore = PartyBattleStore.shared`**（若已有 `.shared` 单例，用 `@ObservedObject` 或直接读）

- [ ] **Step 3: 加 3 个 `@State private var showXxx = false`**（InitiatePopup / ForceEndConfirm / CooldownToast）

- [ ] **Step 4: Regen + build sanity**

- [ ] **Step 5: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyRoomView wire handlePkTap + toolMenu.startPk 到 battleStore"
```

---

### Task 22: PartyRoomView 布局 overlay + sheet + 视频位 replace + 冷启 refresh

**Files:**
- Modify: `Sources/Party/UI/PartyRoomView.swift body + bigSeatRow / seat cluster view`

**参考 spec §6.2 布局叠加 + 麦位 replace**：

**A. Overlay / Sheet 叠加**：
- `.overlay(alignment: .top)` — SelectingPanel / RunningHud
- `.overlay(alignment: .bottom)` — SelectingStartStrip / HostBottomMarquee
- `.sheet(isPresented:)` — InitiatePopup / EndedSettlement / ForceEndConfirm / RulesPopup
- `.overlay(alignment: .top)` — CooldownToast（2s 自清 toast，用现有 `SystemToast` 或类似公共组件）

**B. 视频位 replace（本 task 关键新增）**：
- `bigSeatRow` 内加分支：
  - `battleStore.isSelecting` → 换成 `PkSelectingVideoTripleView(bigSeats:, battleStore:)`（Task 20.5 已建）
  - `battleStore.isRunning` → 保留原三视频布局，为每格加 `.overlay { RoundedRectangle().stroke(battleStore.pkVideoSlotTeamClass(slotIdx) ?? .clear, lineWidth: 3) }` 红蓝色边（依 Task 8 派生 getter `pkVideoSlotTeamClass`）
  - else → 原 `bigSeatRow` 逻辑
- **注意**（swiftui-body-type-check-timeout rule）：video 位 replace 若在 bigSeatRow 内嵌 if/else 让 body 变复杂 → 抽 `@ViewBuilder private var pkAwareBigSeatRow: some View` computed property 承载三分支

**C. 冷启动 + 断网兜底**：
- `.task { await battleStore.refreshIfNeeded(roomId:) }` — 冷启动直接落 PK 房自动 refresh（R-20）
- 断网重连 refresh 兜底（R-21，接现有 network monitor / RootView `syncSessionDependent` 类似模式）

**D. F-1a 不做（deferred F-1b）**：
- `PartyRoomAudioSeatCell.displayGiftCount` PK 覆盖逻辑（客态观众送礼场景，房主端 RunningHud 已承担总分展示）

- [ ] **Step 1: A/B/C 三部分逐 modifier 挂到 body**

- [ ] **Step 2: 若 body 报 "unable to type-check in reasonable time" → 按 swiftui-body-type-check-timeout rule 抽 perform:/@ViewBuilder property**

- [ ] **Step 3: Regen + build sanity**

- [ ] **Step 4: Commit**

```bash
git commit -m "feat: [派对房 PK] PartyRoomView 布局 overlay/sheet + PK 视频位 replace + 冷启 refresh + 断网兜底"
```

---

### Task 23: 真机 DoD 验收 + §12 收敛必答 5 项 log 抓

**Files:** 无（真机验证 + 反馈 log 到 spec §12）

**参考 spec §9.1 真机 DoD** + **§12 收敛必答清单**。

- [ ] **Step 1: 准备双机** — iPhone 15/13（或用户可用的两台设备），账号 A 创房主，账号 B 观众

- [ ] **Step 2: 主态跑通 F-01/02/03/04/05/07/08/09/10**

按 spec §8.1 清单逐项：
- 房主开 PK → InitiatePopup 3 时长档 + 3 站队 → Confirm → status=1 SELECTING（F-01/02/03）
- SELECTING 60s 倒计时 UI 正常 + "Start Now"（F-03）
- status=2 RUNNING，B 送礼 → 主态 HUD 分数刷新（F-04/05）
- status=3 ENDED，EndedSettlement 显示 Win Team / 大比分 / 双 MVP（F-07/08）
- status=4/5 冷却 → CooldownToast（F-09）
- status 归 idle 可重新发起（F-10）

- [ ] **Step 3: R-16 IM 1100/1103/1105/1109/1112 真机 log 抓 dataKeys 校对**

跑真机时 Xcode Console 抓 log `[PartyBattleMessageRouter] attachType=XXXX dataKeys=[...]`；每个 attachType 至少抓一次，与代码 decode 期望字段名对照。**发现不匹配立即 fix payload Codable 字段名**（对齐 im-payload-real-log-over-code-assumption rule）。

- [ ] **Step 4: R-20 冷启动直接落 PK 房 refresh 恢复** — 房主开 PK 后重启 App，落回房内应自动 refresh 恢复 PK UI

- [ ] **Step 5: R-21 断网重连 refresh 兜底** — 房主开 PK 后飞行模式 5s 恢复，PK UI 应自动 refresh

- [ ] **Step 6: §12 收敛必答清单逐项闭合**

按 spec §9.1 新增的"§12 收敛必答清单"5 项：
- **A3** 抓 `approveApply(approve=false)` 后 IM 1102/1108 是否 fire — 若不 fire 则观众端不 sink IM
- **A4** 抓 `applications` response 字段名 — 若无分页字段则 iOS 一次拉全量
- **A5** 非房主/房管调用 `startNow` 的 response code — 补 `PartyBattleServiceError` 对应枚举
- **A6** `forceEnd` 后 `settlement.durationSec / endedEarly / cooldownLeftSec` — 确认 `endedEarly=true` 是否为强制结束唯一区分依据
- **A8** RUNNING 期观众申请上麦通过后是否发 1101 — 若发则 spec §3.2 "RUNNING 中途切队"路径生产可用

**每项抓到 log 后**：更新 spec §12 对应项标注"F-1a 已确认，值=xxx"或"F-1a 未复现，F-1b 再验证"。

- [ ] **Step 7: 提交 F-1a 完成 retro**

Create: `docs/plan/F-1a-retro-YYYYMMDDHHMM.md`

包含：
- 反悔清单（step 3 有几次反悔 + 5 方向归类）
- §12 收敛必答清单实际结论
- 是否有新 rule 沉淀（按 feature-pipeline-complexity-tier sink rule）
- F-1b 启动前需要修的遗留项

- [ ] **Step 8: Commit**

```bash
git add docs/plan/F-1a-retro-*.md docs/plan/F-1-spec-PartyBattle-PK-*.md
git commit -m "docs: [派对房 PK] F-1a 真机验收 + §12 收敛必答 5 项闭合 + retro"
```

---

## §7 附录：Task 依赖图（v2 · 含新增 tasks）

```
Task 1 (Types) ─┬─→ Task 3 (Models) ─┬─→ Task 4 (API Models) ──→ Task 7 (Service+Protocol) ─┐
                │                    └─→ Task 5 (IM Payloads) ────────────────────────────┤
Task 2 (Errors)─┘                                                                          ├→ Task 8 (Store 骨架+Fixture+FakeBattleService) ─→ Task 9 (侵入) ─→ Task 10a/10b/10c (副作用 3 拆) ─→ Task 10d (refreshIfNeeded+loadTemplates) ─→ Task 11 (Router)
                                                                                           │
Task 6 (Config Parser) ─────────────────────────────────────────────────────────────────────┘

Task 11 完成 → Task 11.5 (SeatLayout) + Task 11.7 (Double.compactFormatted) 独立可并行

Task 11.5 / 11.7 完成 → Task 12-20 (UI × 9) 可并行 → Task 20.5 (PkSelectingVideoTripleView)

Task 20.5 完成 → Task 21 (wire) → Task 22 (布局 + 视频位 replace) → Task 23 (真机 DoD)
```

**并行建议**：
- Phase 1（Task 1-3）严格串行
- Phase 2（Task 4-6）Task 4/5/6 完全独立可并行（若走 subagent-driven-development 可 3 subagent 同时跑）
- Phase 3（Task 7）依赖 Phase 2 全部
- Phase 4（Task 8/9/10a/10b/10c/11）严格串行（状态机骨架 → 侵入 → 副作用 → 路由）
- Phase 4 尾（Task 11.5/11.7）独立可并行
- Phase 5（Task 12-20）9 UI 组件独立可并行；Task 20.5 依赖 Task 11.5
- Phase 6（Task 21-23）严格串行

---

## §8 完成标准

**F-1a 完工条件**（缺一不可）：
1. Task 1-22 所有 commit 落地（Task 1 / 2 / 3 / 4 / 5 / 6 / 7 / 8 / 9 / 10a / 10b / 10c / 10d / 11 / 11.5 / 11.7 / 12-20 (9 UI) / 20.5 / 21 / 22，共 23 个 commit ± Task 11.7 视 grep 结果决定）
2. Task 23 真机 DoD 全部勾选（F-01/02/03/04/05/07/08/09/10 + R-16/20/21）
3. §12 收敛必答 5 项（A3/A4/A5/A6/A8）逐项抓到 log 或明示"F-1b 复验"
4. `docs/plan/F-1a-retro-*.md` 提交
5. spec 更新（若 §12 补齐或状态机需修订）
6. code-review skill 跑一次 `/review deep` 全绿或已修

**下一步**：F-1a 完成后启动 F-1b（客态观战 + 观众端能力 + `PartyBattleGiftPanelTabs` + `PartyRoomAudioSeatCell.displayGiftCount` PK 覆盖）—— 新 plan 起草。

---

**Plan v3.1 完成**（v3 → v3.1：Task 8 补 fixture DEBUG 边界警示 + FakeBattleService 失败分支 stub 清单；Task 10d 补 refreshIfNeeded/loadTemplatesIfNeeded 调用入口绑定说明。v2 → v3：Task 7 加 PartyBattleServiceProtocol 支撑 DI；Task 8 Fixture 段补全 test seam helpers + FakeBattleService；新加 Task 10d refreshIfNeeded + loadTemplatesIfNeeded 入口 action。v1 → v2：加 PartyBattleSeatLayout / Double.compactFormatted / PkSelectingVideoTripleView / Fixture helpers 单独 task；Task 8 派生 getter 完整清单；Task 10 拆 10a/10b/10c；Task 22 加视频位 replace；Task 7 加 grep 前置；F-1a 主态 UI 范围明示 vs F-1b 客态）。**writing-plans skill 3 轮 review 闭环，Plan approved 进入 execute。**
