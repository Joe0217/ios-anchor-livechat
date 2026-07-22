import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "AudiencePK")

/// H5 客态 PK 的只读状态。它只订阅和展示，不包含主播发起、邀请、结束 PK 的写操作。
@MainActor
final class AudiencePKStore: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case battling
        case punishing(winner: Int?)
    }

    struct Anchor: Equatable {
        let userId: Int
        let nickname: String
        let avatarURL: String?
        let agoraChannelId: String
        var score: Int
        var top3: [PKTopUser]
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var left: Anchor?
    @Published private(set) var right: Anchor?
    @Published private(set) var pkId = ""
    @Published private(set) var remainingSeconds = 0
    @Published private(set) var isOpponentMuted = false
    @Published private(set) var preparationSeconds = 0

    let router: AudiencePKNIMRouter
    private let service: AudiencePKServiceProtocol
    private var roomInfo: AudienceLiveRoomInfo?
    private var countdownTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init() {
        self.service = AudiencePKService()
        self.router = AudiencePKNIMRouter()
        router.store = self
    }

    deinit { countdownTask?.cancel() }

    var isShowing: Bool {
        if case .battling = phase { return true }
        if case .punishing = phase { return true }
        return false
    }

    var opponentChannelId: String? { right?.agoraChannelId.isEmpty == false ? right?.agoraChannelId : nil }
    var opponentUserId: Int? { right?.userId }
    var isPreparing: Bool { preparationSeconds > 0 && phase == .battling }

    func loadIfNeeded(room: AudienceLiveRoomInfo) {
        roomInfo = room
        guard room.initialPKStatus == 7 || room.initialPKStatus == 8 else { return }
        refresh(statusHint: room.initialPKStatus)
    }

    func refresh(statusHint: Int? = nil, playPreparation: Bool = false) {
        guard let roomInfo else { return }
        refreshGeneration &+= 1
        let generation = refreshGeneration
        phase = .loading

        Task { @MainActor [weak self, service] in
            do {
                let snapshot = try await service.fetch(anchorId: roomInfo.anchorUserId)
                guard let self, generation == self.refreshGeneration else { return }
                self.apply(snapshot: snapshot, fallbackRoom: roomInfo, statusHint: statusHint,
                           playPreparation: playPreparation)
            } catch {
                guard let self, generation == self.refreshGeneration else { return }
                logger.warning("audience PK refresh failed: \(String(describing: error), privacy: .private)")
                self.reset()
            }
        }
    }

    func handleScore(_ payload: [String: Any]) {
        let data = AudiencePKPayload.data(from: payload)
        guard let left, let right else { return }
        var updatedLeft = left
        var updatedRight = right
        updatedLeft.score = AudiencePKPayload.int(data["pkCounter"]) ?? updatedLeft.score
        updatedRight.score = AudiencePKPayload.int(data["oppositePkCounter"]) ?? updatedRight.score
        updatedLeft.top3 = AudiencePKPayload.top3(data["top3Users"] ?? data["top3User"])
        updatedRight.top3 = AudiencePKPayload.top3(data["oppositeTop3Users"] ?? data["oppositeTop3User"])
        self.left = updatedLeft
        self.right = updatedRight
    }

    func handleStatus(_ payload: [String: Any]) {
        let data = AudiencePKPayload.data(from: payload)
        guard let status = AudiencePKPayload.int(data["pkStatus"]) else { return }
        switch status {
        case 7:
            refresh(statusHint: status, playPreparation: true)
        case 8:
            guard left != nil, right != nil else {
                refresh(statusHint: status)
                return
            }
            handleScore(data)
            let seconds = AudiencePKPayload.seconds(data["pkPunishingDuration"]) ?? 120
            phase = .punishing(winner: AudiencePKPayload.int(data["result"]))
            startCountdown(seconds: seconds)
        case 9, -1:
            reset()
        default:
            break
        }
    }

    func handleMute(_ payload: [String: Any]) {
        let data = AudiencePKPayload.data(from: payload)
        isOpponentMuted = AudiencePKPayload.int(data["muteOppositeAnchor"] ?? payload["muteOppositeAnchor"]) == 1
    }

    func reset() {
        refreshGeneration &+= 1
        countdownTask?.cancel()
        countdownTask = nil
        phase = .idle
        left = nil
        right = nil
        pkId = ""
        remainingSeconds = 0
        isOpponentMuted = false
        preparationSeconds = 0
    }

    private func apply(snapshot: AudiencePKSnapshot,
                       fallbackRoom: AudienceLiveRoomInfo,
                       statusHint: Int?,
                       playPreparation: Bool) {
        guard snapshot.pkId.isEmpty == false,
              snapshot.right.userId > 0,
              snapshot.right.agoraChannelId.isEmpty == false else {
            reset()
            return
        }
        pkId = snapshot.pkId
        left = snapshot.left.replacingChannelIfEmpty(with: fallbackRoom.agoraChannelId)
        right = snapshot.right
        isOpponentMuted = snapshot.isOpponentMuted

        let status = snapshot.status ?? statusHint ?? 7
        if status == 8 {
            phase = .punishing(winner: snapshot.result)
            startCountdown(seconds: snapshot.punishingSeconds)
        } else {
            phase = .battling
            startCountdown(seconds: snapshot.remainingSeconds)
            if playPreparation { startPreparationCountdown() }
        }
    }

    private func startPreparationCountdown() {
        preparationSeconds = 5
        Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.preparationSeconds > 0, self.phase == .battling {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.preparationSeconds = max(0, self.preparationSeconds - 1)
            }
        }
    }

    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        remainingSeconds = max(0, seconds)
        countdownTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled, self.remainingSeconds > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.remainingSeconds = max(0, self.remainingSeconds - 1)
            }
        }
    }
}

@MainActor
final class AudiencePKNIMRouter: MessageRouter {
    weak var store: AudiencePKStore?

    func route(_ attachType: AttachType,
               payload: [String: Any],
               context: MessageContext) -> Bool {
        guard case .liveChatroom = context, let store else { return false }
        switch attachType {
        case .pkScoreUpdate:
            store.handleScore(payload)
        case .pkStatusBundle:
            store.handleStatus(payload)
        case .pkMuteBroadcast:
            store.handleMute(payload)
        default:
            return false
        }
        return true
    }
}

private struct AudiencePKSnapshot {
    let pkId: String
    let status: Int?
    let remainingSeconds: Int
    let punishingSeconds: Int
    let isOpponentMuted: Bool
    let result: Int?
    let left: AudiencePKStore.Anchor
    let right: AudiencePKStore.Anchor
}

private protocol AudiencePKServiceProtocol {
    func fetch(anchorId: Int) async throws -> AudiencePKSnapshot
}

private struct AudiencePKService: AudiencePKServiceProtocol {
    func fetch(anchorId: Int) async throws -> AudiencePKSnapshot {
        let data = try await PKService.getPkInfo(anchorId: anchorId)
        guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pkId = AudiencePKPayload.string(raw["pkId"]), !pkId.isEmpty else {
            throw APIError(code: "-1", message: L10n.liveRoomStatusFailed)
        }
        let opposite = AudiencePKPayload.data(from: raw["oppositePkInfoVo"] as? [String: Any] ?? [:])
        return AudiencePKSnapshot(
            pkId: pkId,
            status: AudiencePKPayload.int(raw["pkStatus"]),
            remainingSeconds: AudiencePKPayload.seconds(raw["pkDuration"]) ?? 0,
            punishingSeconds: AudiencePKPayload.seconds(raw["pkPunishingDuration"]) ?? 120,
            isOpponentMuted: AudiencePKPayload.int(raw["muteStatus"]) == 1,
            result: AudiencePKPayload.int(raw["result"]),
            left: AudiencePKPayload.anchor(from: raw),
            right: AudiencePKPayload.anchor(from: opposite)
        )
    }
}

private enum AudiencePKPayload {
    static func data(from raw: Any) -> [String: Any] {
        if let dict = raw as? [String: Any] {
            if let nested = dict["data"] { return data(from: nested) }
            return dict
        }
        if let text = raw as? String,
           let bytes = text.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
            return data(from: dict)
        }
        return [:]
    }

    static func anchor(from raw: [String: Any]) -> AudiencePKStore.Anchor {
        AudiencePKStore.Anchor(
            userId: int(raw["userId"]) ?? 0,
            nickname: string(raw["nickname"] ?? raw["nickName"]) ?? "",
            avatarURL: string(raw["icon"] ?? raw["avatar"]),
            agoraChannelId: string(raw["agoraChannelId"]) ?? "",
            score: int(raw["pkCounter"]) ?? 0,
            top3: top3(raw["top3RankList"] ?? raw["top3Users"] ?? raw["top3User"])
        )
    }

    static func top3(_ raw: Any?) -> [PKTopUser] {
        if let list = raw as? [[String: Any]] {
            return list.map {
                PKTopUser(userId: int($0["userId"]), icon: string($0["icon"]),
                          nickName: string($0["nickName"] ?? $0["nickname"]),
                          avatar: string($0["avatar"]), value: int($0["value"]))
            }
        }
        if let urls = raw as? [String] {
            return urls.map { PKTopUser(userId: nil, icon: $0, nickName: nil, avatar: nil, value: nil) }
        }
        return []
    }

    static func seconds(_ raw: Any?) -> Int? {
        guard let value = int(raw) else { return nil }
        // H5 注释 pkDuration 是毫秒；偶发接口直接给秒时保持原值，避免把 120 秒变为 0。
        return value > 1_000 ? value / 1_000 : value
    }

    static func string(_ raw: Any?) -> String? {
        if let value = raw as? String, !value.isEmpty { return value }
        if let value = int(raw) { return String(value) }
        return nil
    }

    static func int(_ raw: Any?) -> Int? {
        if raw is Bool { return nil }
        if let value = raw as? Int { return value }
        if let value = raw as? NSNumber {
            let type = String(cString: value.objCType)
            return type == "c" || type == "B" ? nil : value.intValue
        }
        if let value = raw as? String { return Int(value) }
        return nil
    }
}

private extension AudiencePKStore.Anchor {
    func replacingChannelIfEmpty(with fallback: String) -> Self {
        guard agoraChannelId.isEmpty else { return self }
        return Self(userId: userId, nickname: nickname, avatarURL: avatarURL,
                    agoraChannelId: fallback, score: score, top3: top3)
    }
}
