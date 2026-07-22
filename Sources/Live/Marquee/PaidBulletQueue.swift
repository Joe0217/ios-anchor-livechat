import Combine
import Foundation

/// 直播付费跑马灯的接收、过滤、顺序播放与点踩状态。
///
/// 直播和派对房均可能出现 numeric `attachType=1050`，因此本类只由直播
/// `NIMChatroomManager` 调用，绝不在共享 AttachType 路由中将 1050 解释为付费跑马灯。
@MainActor
final class PaidBulletQueue: ObservableObject {
    enum Scope: Int, Equatable {
        case room = 1
        case country = 2
        case global = 3
    }

    struct Context: Equatable {
        let roomId: Int
        let viewerUserId: Int
        let countryCode: String

        init(roomId: Int, viewerUserId: Int, countryCode: String) {
            self.roomId = roomId
            self.viewerUserId = viewerUserId
            self.countryCode = countryCode
        }
    }

    struct Item: Identifiable, Equatable {
        let billId: String
        let scope: Scope
        let content: String
        let hostShareAmount: Int64?
        let stayDuration: TimeInterval
        let senderUserId: Int
        let senderNickname: String
        let senderAvatarUrl: String?
        let roomId: Int?
        let hostUserId: Int?
        let targetCountryCodes: [String]

        var id: String { billId }
    }

    enum ReceiveResult: Equatable {
        case ignored
        case enqueued(item: Item, firstHostEarnings: Int64?)
    }

    @Published private(set) var current: Item?
    @Published private(set) var dislikedBillIds = Set<String>()
    @Published private(set) var dislikingBillIds = Set<String>()

    private var pending: [Item] = []
    private var seenBillIds = Set<String>()
    private var activeViewerUserId = 0
    private var isPlaying = false
    private let service: PaidBulletService
    private let defaults: UserDefaults

    private let queueLimit = 50
    private let earningsDateKey = "paidBullet.earningsToastDate"

    init(service: PaidBulletService, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
    }

    /// 接收直播 1050 广播。payload 可以是顶层对象，也可以是嵌套 JSON `data`。
    func receive(payload: Any, context: Context) -> ReceiveResult {
        guard context.roomId > 0,
              let raw = normalizedPayload(payload),
              let item = makeItem(raw) else {
            return .ignored
        }

        activeViewerUserId = context.viewerUserId
        guard !seenBillIds.contains(item.billId), shouldDeliver(item, context: context) else {
            return .ignored
        }

        seenBillIds.insert(item.billId)
        pending.append(item)
        if pending.count > queueLimit {
            let dropped = pending.removeFirst()
            seenBillIds.remove(dropped.billId)
        }
        playNextIfIdle()

        return .enqueued(item: item, firstHostEarnings: consumeFirstHostEarnings(item, context: context))
    }

    func canDislike(_ item: Item) -> Bool {
        item.hostUserId != nil && item.hostUserId == activeViewerUserId
    }

    func isDisliked(_ item: Item) -> Bool {
        dislikedBillIds.contains(item.billId)
    }

    func isDisliking(_ item: Item) -> Bool {
        dislikingBillIds.contains(item.billId)
    }

    /// 乐观置灰；请求失败时回滚，允许主播再次尝试。
    func dislike(_ item: Item) async throws {
        guard canDislike(item),
              !item.billId.isEmpty,
              !dislikedBillIds.contains(item.billId),
              !dislikingBillIds.contains(item.billId) else {
            return
        }
        dislikedBillIds.insert(item.billId)
        dislikingBillIds.insert(item.billId)
        defer { dislikingBillIds.remove(item.billId) }

        do {
            _ = try await service.dislike(billId: item.billId)
        } catch {
            dislikedBillIds.remove(item.billId)
            throw error
        }
    }

    func clear() {
        pending.removeAll()
        seenBillIds.removeAll()
        dislikedBillIds.removeAll()
        dislikingBillIds.removeAll()
        current = nil
        activeViewerUserId = 0
        isPlaying = false
    }

    /// 飘屏完成离场动画后由视图调用，再推进下一条。
    ///
    /// 停留时间会按正文跑马灯周期动态延长，不能由队列按广播里的原始时长抢先切换。
    func completePlayback(of item: Item) {
        guard current?.billId == item.billId else { return }
        current = nil
        isPlaying = false
        playNextIfIdle()
    }

    private func shouldDeliver(_ item: Item, context: Context) -> Bool {
        switch item.scope {
        case .room:
            return item.roomId == context.roomId
        case .country:
            let country = normalizedCountryCode(context.countryCode)
            return !country.isEmpty && item.targetCountryCodes.contains(country)
        case .global:
            return true
        }
    }

    private func consumeFirstHostEarnings(_ item: Item, context: Context) -> Int64? {
        guard item.roomId == context.roomId,
              item.hostUserId == context.viewerUserId,
              let amount = item.hostShareAmount else {
            return nil
        }
        let today = Self.todayString()
        guard defaults.string(forKey: earningsDateKey) != today else { return nil }
        defaults.set(today, forKey: earningsDateKey)
        return amount
    }

    private func playNextIfIdle() {
        guard !isPlaying, !pending.isEmpty else { return }
        let next = pending.removeFirst()
        isPlaying = true
        current = next
    }

    private func makeItem(_ raw: [String: Any]) -> Item? {
        guard let billId = Self.string(raw["billId"]),
              let scopeRaw = Self.integer(raw["bulletScope"]),
              let scope = Scope(rawValue: scopeRaw) else {
            return nil
        }
        let targets = countryCodes(raw["targetCountryCodes"])
        // 对齐 H5：`Number(showDuration) || 5` 后再 `Math.max(1, value)`。
        // 因此 0/空/非法值回退 5 秒，正数小数保留，负数归为 1 秒。
        let requestedDuration = Self.decimal(raw["showDuration"]) ?? 5
        let duration = max(1, requestedDuration == 0 ? 5 : requestedDuration)
        return Item(
            billId: billId,
            scope: scope,
            content: Self.string(raw["content"]) ?? "",
            hostShareAmount: Self.int64(raw["hostShareAmount"]),
            stayDuration: duration,
            senderUserId: Self.integer(raw["senderUserId"]) ?? 0,
            senderNickname: Self.string(raw["senderNick"]) ?? "",
            senderAvatarUrl: Self.string(raw["senderAvatar"]),
            roomId: Self.integer(raw["roomId"]),
            hostUserId: Self.integer(raw["hostUserId"]),
            targetCountryCodes: targets
        )
    }

    private func normalizedPayload(_ payload: Any) -> [String: Any]? {
        if let object = payload as? [String: Any] {
            if object["billId"] != nil { return object }
            guard let nested = object["data"] else { return nil }
            return normalizedPayload(nested)
        }
        guard let text = payload as? String,
              let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func countryCodes(_ raw: Any?) -> [String] {
        if let values = raw as? [Any] {
            return values.compactMap { Self.string($0) }
                .map { normalizedCountryCode($0) }
                .filter { !$0.isEmpty }
        }
        if let text = raw as? String,
           let data = text.data(using: .utf8),
           let values = try? JSONSerialization.jsonObject(with: data) as? [Any] {
            return values.compactMap { Self.string($0) }
                .map { normalizedCountryCode($0) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    private func normalizedCountryCode(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    nonisolated static func string(_ raw: Any?) -> String? {
        if let text = raw as? String {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        if let value = int64(raw) { return String(value) }
        return nil
    }

    nonisolated static func integer(_ raw: Any?) -> Int? {
        guard let value = int64(raw) else { return nil }
        return Int(exactly: value)
    }

    nonisolated static func decimal(_ raw: Any?) -> Double? {
        if raw is Bool { return nil }
        let value: Double?
        if let number = raw as? NSNumber {
            let type = String(cString: number.objCType)
            value = type == "c" || type == "B" ? nil : number.doubleValue
        } else if let text = raw as? String {
            value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } else {
            value = nil
        }
        guard let value, value.isFinite else { return nil }
        return value
    }

    nonisolated static func int64(_ raw: Any?) -> Int64? {
        if raw is Bool { return nil }
        if let value = raw as? Int64 { return value }
        if let value = raw as? Int { return Int64(value) }
        if let value = raw as? NSNumber {
            let type = String(cString: value.objCType)
            guard type != "c", type != "B" else { return nil }
            return value.int64Value
        }
        if let value = raw as? String { return Int64(value) }
        return nil
    }

    nonisolated static func bool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool { return value }
        if let value = raw as? NSNumber { return value.boolValue }
        if let value = raw as? String {
            switch value.lowercased() {
            case "1", "true": return true
            case "0", "false": return false
            default: return nil
            }
        }
        return nil
    }
}
