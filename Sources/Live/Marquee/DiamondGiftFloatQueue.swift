import Combine
import Foundation
import os

/// 主播端钻石福袋生命周期。主播只被动展示，不能发起或抢福袋。
enum DiamondGiftState: Int, Comparable {
    case warming = 1
    case open = 2
    case settled = 3

    static func < (lhs: DiamondGiftState, rhs: DiamondGiftState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct DiamondGiftCurrent: Identifiable, Equatable {
    let id: Int64
    let roomId: Int64
    let senderId: String
    let senderName: String
    let senderAvatarURL: String?
    let tierName: String?
    let totalDiamonds: Int64
    let giftCount: Int
    let claimedCount: Int
    let claimedDiamonds: Int64
    let state: DiamondGiftState
    let warmupSeconds: Int
    let expirySeconds: Int
    let openAt: Int64
    let expireAt: Int64
    let claimType: String
    let refundDiamonds: Int64
    let topShareUserId: String
    let topShareUserName: String
    let topShareUserAvatarURL: String?
    let topShareDiamonds: Int64

    var countdownTarget: Int64 { state == .warming ? openAt : expireAt }
}

struct DiamondGiftWinner: Identifiable, Equatable {
    let id: String
    let userName: String
    let userAvatarURL: String?
    let diamonds: Int64
    let isTopShare: Bool
}

protocol DiamondGiftServiceProtocol {
    func fetchCurrent(roomId: Int64) async throws -> [DiamondGiftCurrent]
    func fetchWinners(giftId: Int64) async throws -> [DiamondGiftWinner]
}

struct DiamondGiftService: DiamondGiftServiceProtocol {
    func fetchCurrent(roomId: Int64) async throws -> [DiamondGiftCurrent] {
        let data = try await APIClient.shared.post("/api/diamondGift/roomCurrent", body: ["roomId": roomId])
        let raw = try JSONSerialization.jsonObject(with: data)
        let root = raw as? [String: Any] ?? [:]
        let list = (root["activeList"] as? [Any])
            ?? ((root["data"] as? [String: Any])?["activeList"] as? [Any])
            ?? []
        return list.compactMap { raw in
            let item = raw as? [String: Any] ?? [:]
            let state = Self.int64(item["state"])
            guard state == DiamondGiftState.warming.rawValue || state == DiamondGiftState.open.rawValue else {
                return nil
            }
            return Self.current(from: item)
        }
    }

    func fetchWinners(giftId: Int64) async throws -> [DiamondGiftWinner] {
        let data = try await APIClient.shared.post("/api/diamondGift/winners", body: ["giftId": giftId])
        let raw = try JSONSerialization.jsonObject(with: data)
        let list: [Any]
        if let direct = raw as? [Any] {
            list = direct
        } else if let root = raw as? [String: Any] {
            list = (root["list"] as? [Any]) ?? (root["data"] as? [Any]) ?? (root["result"] as? [Any]) ?? []
        } else {
            list = []
        }
        return list.enumerated().compactMap { index, raw in
            let item = raw as? [String: Any] ?? [:]
            let userId = Self.string(item["userId"] ?? item["id"])
            guard !userId.isEmpty else { return nil }
            return DiamondGiftWinner(
                id: userId,
                userName: Self.string(item["userName"] ?? item["nickname"] ?? item["nickName"]),
                userAvatarURL: Self.optionalString(item["userAvatar"] ?? item["avatar"] ?? item["icon"]),
                diamonds: Self.int64(item["diamonds"]),
                isTopShare: Self.bool(item["topShare"])
            )
        }
    }

    static func current(from data: [String: Any]) -> DiamondGiftCurrent? {
        let giftId = int64(data["giftId"] ?? data["id"])
        guard giftId > 0 else { return nil }
        let state = DiamondGiftState(rawValue: Int(int64(data["state"]))) ?? .warming
        return DiamondGiftCurrent(
            id: giftId,
            roomId: int64(data["roomId"]),
            senderId: string(data["senderId"]),
            senderName: string(data["senderName"] ?? data["senderNickName"] ?? data["senderNickname"] ?? data["nickName"] ?? data["nickname"] ?? data["userName"]),
            senderAvatarURL: optionalString(data["senderAvatar"] ?? data["senderIcon"] ?? data["avatar"] ?? data["icon"]),
            tierName: optionalString(data["tierName"]),
            totalDiamonds: int64(data["totalDiamonds"]),
            giftCount: Int(clamping: int64(data["giftCount"])),
            claimedCount: Int(clamping: int64(data["claimedCount"])),
            claimedDiamonds: int64(data["claimedDiamonds"]),
            state: state,
            warmupSeconds: Int(clamping: int64(data["warmupSeconds"], default: 10)),
            expirySeconds: Int(clamping: int64(data["expirySeconds"], default: 60)),
            openAt: timestamp(data["openAt"]),
            expireAt: timestamp(data["expireAt"]),
            claimType: string(data["claimType"]),
            refundDiamonds: int64(data["refundDiamonds"]),
            topShareUserId: string(data["topShareUserId"]),
            topShareUserName: string(data["topShareUserName"] ?? data["topUserName"] ?? data["userName"] ?? data["nickname"] ?? data["nickName"]),
            topShareUserAvatarURL: optionalString(data["topShareUserAvatar"] ?? data["topUserAvatar"] ?? data["userAvatar"] ?? data["avatar"]),
            topShareDiamonds: int64(data["topShareDiamonds"])
        )
    }

    static func string(_ raw: Any?) -> String {
        if let value = raw as? String, !value.isEmpty { return value }
        let value = int64(raw)
        return value == 0 ? "" : String(value)
    }

    static func optionalString(_ raw: Any?) -> String? {
        let value = string(raw)
        return value.isEmpty ? nil : value
    }

    static func int64(_ raw: Any?, default defaultValue: Int64 = 0) -> Int64 {
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber {
            let type = String(cString: value.objCType)
            return (type == "c" || type == "B") ? defaultValue : value.int64Value
        }
        if let value = raw as? String { return Int64(value) ?? defaultValue }
        return defaultValue
    }

    static func bool(_ raw: Any?) -> Bool {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String { return value == "1" || value.lowercased() == "true" }
        return false
    }

    static func timestamp(_ raw: Any?) -> Int64 {
        let number = int64(raw)
        guard number > 0 else { return 0 }
        return number < 10_000_000_000 ? number * 1_000 : number
    }
}

@MainActor
final class DiamondGiftStore: ObservableObject {
    @Published private(set) var activeList: [DiamondGiftCurrent] = []
    @Published var rulesVisible = false
    @Published var winnersVisible = false
    @Published private(set) var winners: [DiamondGiftWinner] = []
    @Published private(set) var winnersLoading = false

    var current: DiamondGiftCurrent? { activeList.first }
    var queueLength: Int { activeList.count }

    private let service: DiamondGiftServiceProtocol
    private var roomId: Int64 = 0
    private var activeListSetAt = Date.distantPast
    private var refreshToken = 0
    private var winnersRequestToken = 0
    private var settleTasks: [Int64: Task<Void, Never>] = [:]
    private var pendingHigherStates: [Int64: (state: DiamondGiftState, data: [String: Any])] = [:]

    init(service: DiamondGiftServiceProtocol = DiamondGiftService()) {
        self.service = service
    }

    func configure(roomId: Int64, refreshCurrent: Bool) {
        guard roomId > 0 else { resetForLeave(); return }
        if self.roomId != roomId { resetForLeave(); self.roomId = roomId }
        if refreshCurrent { Task { await refreshCurrentByRoom(roomId: roomId) } }
    }

    /// H5 在进入状态机前按业务 liveRecordId 过滤。1032 常不带 roomId，仍交由 giftId 链过滤。
    func acceptsImPayload(_ data: [String: Any]) -> Bool {
        let payloadRoomId = DiamondGiftService.int64(data["roomId"])
        return payloadRoomId == 0 || roomId == 0 || payloadRoomId == roomId
    }

    func onImSend(_ data: [String: Any]) {
        guard let gift = DiamondGiftService.current(from: data) else { return }
        guard !activeList.contains(where: { $0.id == gift.id }) else { return }
        if let pending = pendingHigherStates.removeValue(forKey: gift.id) {
            guard pending.state != .settled else { return }
            var opened = DiamondGiftService.current(from: data.merging(pending.data) { _, latest in latest }) ?? gift
            opened = withState(opened, .open)
            activeList.append(opened)
        } else {
            activeList.append(withState(gift, .warming))
        }
        sortAndMarkUpdated()
    }

    func onImOpen(_ data: [String: Any]) {
        let giftId = DiamondGiftService.int64(data["giftId"])
        guard giftId > 0 else { return }
        guard let index = activeList.firstIndex(where: { $0.id == giftId }) else {
            cacheHigherState(giftId: giftId, state: .open, data: data)
            return
        }
        pendingHigherStates.removeValue(forKey: giftId)
        activeList[index] = withState(activeList[index], .open)
        markUpdated()
    }

    func onImClaimed(_ data: [String: Any]) -> DiamondGiftClaim? {
        let giftId = DiamondGiftService.int64(data["giftId"])
        guard let index = activeList.firstIndex(where: { $0.id == giftId }) else { return nil }
        let claim = DiamondGiftClaim(
            giftId: giftId,
            userId: DiamondGiftService.string(data["userId"]),
            userName: DiamondGiftService.string(data["userName"] ?? data["senderName"] ?? data["nickName"] ?? data["nickname"]),
            diamonds: DiamondGiftService.int64(data["diamonds"])
        )
        let old = activeList[index]
        activeList[index] = DiamondGiftCurrent(
            id: old.id, roomId: old.roomId, senderId: old.senderId, senderName: old.senderName,
            senderAvatarURL: old.senderAvatarURL, tierName: old.tierName, totalDiamonds: old.totalDiamonds,
            giftCount: old.giftCount, claimedCount: old.claimedCount + 1,
            claimedDiamonds: old.claimedDiamonds + claim.diamonds, state: old.state,
            warmupSeconds: old.warmupSeconds, expirySeconds: old.expirySeconds, openAt: old.openAt,
            expireAt: old.expireAt, claimType: old.claimType, refundDiamonds: old.refundDiamonds,
            topShareUserId: old.topShareUserId, topShareUserName: old.topShareUserName,
            topShareUserAvatarURL: old.topShareUserAvatarURL, topShareDiamonds: old.topShareDiamonds
        )
        markUpdated()
        return claim
    }

    func onImSettled(_ data: [String: Any]) -> DiamondGiftSettlement? {
        guard let incoming = DiamondGiftService.current(from: data) else { return nil }
        let variant = DiamondGiftSettlement(incoming: incoming)
        guard let index = activeList.firstIndex(where: { $0.id == incoming.id }) else {
            cacheHigherState(giftId: incoming.id, state: .settled, data: data)
            return variant
        }
        pendingHigherStates.removeValue(forKey: incoming.id)
        let old = activeList[index]
        activeList[index] = DiamondGiftCurrent(
            id: old.id, roomId: old.roomId, senderId: old.senderId, senderName: old.senderName,
            senderAvatarURL: old.senderAvatarURL, tierName: old.tierName, totalDiamonds: old.totalDiamonds,
            giftCount: old.giftCount, claimedCount: old.claimedCount, claimedDiamonds: old.claimedDiamonds,
            state: .settled, warmupSeconds: old.warmupSeconds, expirySeconds: old.expirySeconds,
            openAt: old.openAt, expireAt: old.expireAt, claimType: incoming.claimType,
            refundDiamonds: incoming.refundDiamonds, topShareUserId: incoming.topShareUserId,
            topShareUserName: incoming.topShareUserName, topShareUserAvatarURL: incoming.topShareUserAvatarURL,
            topShareDiamonds: incoming.topShareDiamonds
        )
        markUpdated()
        scheduleSettledRemoval(giftId: incoming.id)
        return variant
    }

    func refreshCurrentByRoom(roomId: Int64) async {
        guard roomId > 0 else { return }
        let requestDate = Date()
        let token = refreshToken + 1
        refreshToken = token
        do {
            let remote = try await service.fetchCurrent(roomId: roomId)
                .filter { $0.state == .warming || $0.state == .open }
            guard self.roomId == roomId, refreshToken == token, activeListSetAt < requestDate else { return }
            let local = Dictionary(uniqueKeysWithValues: activeList.map { ($0.id, $0) })
            var merged = remote.map { remoteGift -> DiamondGiftCurrent in
                guard let existing = local[remoteGift.id], existing.state > remoteGift.state else { return remoteGift }
                return existing
            }
            merged += activeList.filter { localGift in
                localGift.state == .settled && !merged.contains(where: { $0.id == localGift.id })
            }
            activeList = merged.sorted { $0.id < $1.id }
            activeListSetAt = requestDate
        } catch {
            Logger(subsystem: "com.anchor.livechat", category: "DiamondGift")
                .warning("refresh current failed room=\(roomId, privacy: .public) error=\(String(describing: error), privacy: .private)")
        }
    }

    func loadWinners(giftId: Int64) async {
        guard giftId > 0, !winnersLoading else { return }
        winnersLoading = true
        let requestToken = winnersRequestToken + 1
        winnersRequestToken = requestToken
        do {
            let result = try await service.fetchWinners(giftId: giftId)
            guard winnersRequestToken == requestToken else { return }
            winners = result
        } catch {
            guard winnersRequestToken == requestToken else { return }
            winners = []
            Logger(subsystem: "com.anchor.livechat", category: "DiamondGift")
                .warning("load winners failed gift=\(giftId, privacy: .public) error=\(String(describing: error), privacy: .private)")
        }
        guard winnersRequestToken == requestToken else { return }
        winnersLoading = false
        winnersVisible = true
    }

    func resetForLeave() {
        refreshToken += 1
        winnersRequestToken += 1
        settleTasks.values.forEach { $0.cancel() }
        settleTasks.removeAll()
        pendingHigherStates.removeAll()
        activeList.removeAll()
        roomId = 0
        activeListSetAt = .distantPast
        rulesVisible = false
        winnersVisible = false
        winners.removeAll()
        winnersLoading = false
    }

    private func cacheHigherState(giftId: Int64, state: DiamondGiftState, data: [String: Any]) {
        guard giftId > 0 else { return }
        if let existing = pendingHigherStates[giftId], existing.state >= state { return }
        pendingHigherStates[giftId] = (state, data)
    }

    private func sortAndMarkUpdated() {
        activeList.sort { $0.id < $1.id }
        markUpdated()
    }

    private func markUpdated() { activeListSetAt = Date() }

    private func scheduleSettledRemoval(giftId: Int64) {
        settleTasks[giftId]?.cancel()
        settleTasks[giftId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self else { return }
            self.activeList.removeAll { $0.id == giftId }
            self.settleTasks.removeValue(forKey: giftId)
        }
    }

    private func withState(_ gift: DiamondGiftCurrent, _ state: DiamondGiftState) -> DiamondGiftCurrent {
        DiamondGiftCurrent(
            id: gift.id, roomId: gift.roomId, senderId: gift.senderId, senderName: gift.senderName,
            senderAvatarURL: gift.senderAvatarURL, tierName: gift.tierName, totalDiamonds: gift.totalDiamonds,
            giftCount: gift.giftCount, claimedCount: gift.claimedCount, claimedDiamonds: gift.claimedDiamonds,
            state: state, warmupSeconds: gift.warmupSeconds, expirySeconds: gift.expirySeconds,
            openAt: gift.openAt, expireAt: gift.expireAt, claimType: gift.claimType,
            refundDiamonds: gift.refundDiamonds, topShareUserId: gift.topShareUserId,
            topShareUserName: gift.topShareUserName, topShareUserAvatarURL: gift.topShareUserAvatarURL,
            topShareDiamonds: gift.topShareDiamonds
        )
    }
}

struct DiamondGiftClaim {
    let giftId: Int64
    let userId: String
    let userName: String
    let diamonds: Int64
}

enum DiamondGiftSettlement {
    case topShare(giftId: Int64, topUserId: String, topUserName: String, topUserAvatarURL: String?, diamonds: Int64)
    case expired(giftId: Int64, senderId: String, senderName: String, refundDiamonds: Int64)

    init?(incoming: DiamondGiftCurrent) {
        switch incoming.claimType {
        case "all":
            self = .topShare(giftId: incoming.id, topUserId: incoming.topShareUserId,
                             topUserName: incoming.topShareUserName, topUserAvatarURL: incoming.topShareUserAvatarURL,
                             diamonds: incoming.topShareDiamonds)
        case "expired" where incoming.topShareDiamonds > 0:
            self = .topShare(giftId: incoming.id, topUserId: incoming.topShareUserId,
                             topUserName: incoming.topShareUserName, topUserAvatarURL: incoming.topShareUserAvatarURL,
                             diamonds: incoming.topShareDiamonds)
        case "expired", "no_claim":
            self = .expired(giftId: incoming.id, senderId: incoming.senderId,
                            senderName: incoming.senderName, refundDiamonds: incoming.refundDiamonds)
        default:
            return nil
        }
    }
}

/// 钻石盲盒飘屏队列（对齐 H5 diamond-gift-float-screen.vue）
///
/// - 触发：attachType 1030 发包
/// - 队列：5s 出队一条（`diamondGiftFloatTimer`）
@MainActor
final class DiamondGiftFloatQueue: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let senderNickname: String
        let giftCount: Int
        let totalDiamonds: Int64
    }

    @Published private(set) var current: Item?

    private var pending: [Item] = []
    private var isPlaying: Bool = false
    private var displayTask: Task<Void, Never>?
    /// 对齐 H5 clearTimeout：离房/clear 后的旧任务不能清掉后续新飘屏。
    private var generation = 0

    /// 单条动画时长 + 队列间隔，对齐 H5 `playDiamondGiftFloat`。
    private let displayDuration: TimeInterval = 5.0
    private let interItemDelay: TimeInterval = 0.1

    func addToQueue(_ item: Item) {
        pending.append(item)
        playNextIfIdle()
    }

    func clear() {
        generation &+= 1
        displayTask?.cancel()
        displayTask = nil
        pending.removeAll()
        current = nil
        isPlaying = false
    }

    private func playNextIfIdle() {
        guard !isPlaying, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        current = next
        isPlaying = true
        let expectedGeneration = generation
        let duration = displayDuration
        let delay = interItemDelay
        displayTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                guard let self,
                      self.generation == expectedGeneration,
                      self.current?.id == next.id else { return }
                // H5 先隐藏当前项，再等一拍让下一个 v-if 重新挂载并播放 CSS 动画。
                self.current = nil
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.generation == expectedGeneration else { return }
                self.isPlaying = false
                self.displayTask = nil
                self.playNextIfIdle()
            } catch {
                return
            }
        }
    }
}
