import Foundation

enum H5Bridge {
    static func action(from body: Any) -> H5BridgeAction? {
        guard let message = object(from: body),
              let type = message["type"] as? String, !type.isEmpty else { return nil }
        let payload = object(from: message["data"]) ?? message

        switch type.uppercased() {
        case "GETAPPPARAMS", "GET_APP_PARAMS":
            return .requestAppParams
        case "CLOSE", "CLOSEPAGE":
            return .close
        case "SET_NAV":
            return .setNavigationVisible(bool(payload["visible"], default: true))
        case "REPORT_SHUSHU", "REPORTSHUSHU":
            let event = string(payload["eventName"]) ?? string(payload["event"]) ?? ""
            guard !event.isEmpty else { return nil }
            return .report(event: event, properties: scalarStrings(payload["params"]))
        case "OPEN_BROWSER", "OPENBROWSER":
            let raw = string(payload["url"]) ?? string(message["url"])
            guard let raw, let url = URL(string: raw) else { return nil }
            return .openExternal(url)
        case "JUMP_WALLET", "JUMPWALLET":
            return .jumpWallet
        case "JUMP_RANKING", "JUMPRANKING":
            return .jumpRanking(
                pageType: string(payload["pageType"]),
                hideMonthTab: bool(payload["hideMonthTab"], default: false)
            )
        case "GO_LIVE", "JUMPLIVEROOM":
            return .goLive
        case "GO_ROOM", "JUMPPARTROOM":
            return .goRoom(roomId: string(payload["roomId"]))
        case "GO_PROFILE":
            return .goProfile(userId: string(payload["userId"]))
        default:
            return .unsupported(type: type)
        }
    }

    /// `WKScriptMessage` 可传 object，也有老活动页把整段 JSON 字符串传进来。
    private static func object(from value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let string = value as? String,
              let data = string.data(using: .utf8),
              JSONSerialization.isValidJSONObject(tryJSON(data)),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func tryJSON(_ data: Data) -> Any {
        (try? JSONSerialization.jsonObject(with: data)) ?? NSNull()
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String where !string.isEmpty: return string
        case let number as NSNumber where String(cString: number.objCType) != "c": return number.stringValue
        default: return nil
        }
    }

    private static func bool(_ value: Any?, default fallback: Bool) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String {
            return value == "1" || value.lowercased() == "true"
        }
        return fallback
    }

    /// 埋点仅接收扁平标量，拒绝对象/数组避免不受控 payload 进入 SDK。
    private static func scalarStrings(_ value: Any?) -> [String: String] {
        guard let dict = value as? [String: Any] else { return [:] }
        return dict.reduce(into: [:]) { result, element in
            guard element.key.utf8.count <= 80,
                  let value = string(element.value), value.utf8.count <= 1_024 else { return }
            result[element.key] = value
        }
    }
}
