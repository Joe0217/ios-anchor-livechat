import Foundation

/// `live_anchor_face_check_config` 的归一化配置。
struct LiveAnchorFaceCheckConfig: Equatable, Sendable {
    let remindDuration: Int
    let autoStopDuration: Int
    let whiteList: Set<Int>
    var remindDur: Int { remindDuration }
    var autoStopDur: Int { autoStopDuration }

    init(remindDuration: Int, autoStopDuration: Int, whiteList: Set<Int>) {
        self.remindDuration = max(0, remindDuration)
        self.autoStopDuration = max(0, autoStopDuration)
        self.whiteList = whiteList
    }

    init(remindDur: Int, autoStopDur: Int, whiteList: [Int]) {
        self.init(remindDuration: remindDur, autoStopDuration: autoStopDur, whiteList: Set(whiteList))
    }

    static func parse(_ value: Any?) -> LiveAnchorFaceCheckConfig? {
        guard let value else { return nil }
        let text: String
        if let string = value as? String { text = string.trimmingCharacters(in: .whitespacesAndNewlines) }
        else if JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value), let string = String(data: data, encoding: .utf8) { text = string }
        else { return nil }
        guard !text.isEmpty else { return nil }
        let data = Data(text.utf8)
        let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
            ?? (try? JSONSerialization.jsonObject(with: Data(normalizeLegacy(text).utf8), options: [.fragmentsAllowed]))
        guard let dict = object as? [String: Any] else { return nil }
        return .init(remindDuration: nonNegativeInt(dict["remindDur"]),
                     autoStopDuration: nonNegativeInt(dict["autoStopDur"]),
                     whiteList: parseIDs(dict["whiteList"]))
    }

    private static func normalizeLegacy(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "\\\"", with: "\"")
        s = s.replacingOccurrences(of: #"([A-Za-z_][A-Za-z0-9_]*)\s*:"#, with: #""$1":"#, options: .regularExpression)
        s = s.replacingOccurrences(of: #"'([^']*)'"#, with: #""$1"#, options: .regularExpression)
        return s
    }

    private static func nonNegativeInt(_ value: Any?) -> Int {
        if let n = value as? NSNumber { return max(0, n.intValue) }
        if let s = value as? String, let n = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)) { return max(0, n) }
        return 0
    }

    private static func parseIDs(_ value: Any?) -> Set<Int> {
        guard let values = value as? [Any] else { return [] }
        return Set(values.compactMap { item -> Int? in
            if let n = item as? NSNumber, n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue { return n.intValue }
            if let s = item as? String, let n = Int(s) { return n }
            return nil
        })
    }
}

extension AppConfigService {
    static func fetchFaceCheckConfig() async -> LiveAnchorFaceCheckConfig? {
        do {
            let values = try await fetch(keys: ["live_anchor_face_check_config"])
            return LiveAnchorFaceCheckConfig.parse(values["live_anchor_face_check_config"])
        } catch { return nil }
    }
}
