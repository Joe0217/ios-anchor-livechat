import Foundation
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "RouletteService")

/// Roulette 数据源 protocol（对齐 H5 [api/roulette/index.ts](H5) 4 endpoints）
///
/// **API 契约**（POST 全部，AES-128-CBC + Base64 加密走 `APIClient.shared.post`）：
/// - `queryConfig`: `/api/wheel/queryWheelConfigByAnchorId`  body `{searchValue: userId}`
///   → `{wheelSectorList: [{presetId, text}], price: Int, enabled: "0"|"1"}`
/// - `saveConfig`:  `/api/wheel/addWheelConfig`  body `{addWheelSector, enabled, liveRoomId, price}`
///   → `{wheelSectors: [{presetId, text}]}`
/// - `changeStatus`: `/api/wheel/changeWheelStatus`  body `{addWheelSector, enabled, liveRoomId, price}`
///   → null
/// - `presetTexts`: `/api/wheel/queryPresetText`  body `{}` → `[{id, text}]`（或 `{list:[...]}` 兼容）
protocol RouletteServiceProtocol {
    func queryConfig(anchorUserId: String) async throws -> RouletteConfig
    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws -> RouletteConfig
    func changeStatus(config: RouletteConfig, enabled: Bool, liveRoomId: String) async throws
    func presetTexts() async throws -> RoulettePresetTexts
}

// MARK: - Fakes（预览 / 开发无网络时用）

struct RouletteServiceFakes: RouletteServiceProtocol {
    func queryConfig(anchorUserId: String) async throws -> RouletteConfig {
        try await Task.sleep(nanoseconds: 200_000_000)
        return RouletteConfig(
            enabled: false,
            price: 100,
            sectors: [
                RouletteSector(presetId: "1", text: "Kiss"),
                RouletteSector(presetId: "2", text: "Wink"),
                RouletteSector(presetId: "3", text: "Dance"),
                RouletteSector(presetId: "4", text: "Sing"),
            ]
        )
    }

    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws -> RouletteConfig {
        try await Task.sleep(nanoseconds: 200_000_000)
        return config
    }

    func changeStatus(config: RouletteConfig, enabled: Bool, liveRoomId: String) async throws {
        try await Task.sleep(nanoseconds: 200_000_000)
    }

    func presetTexts() async throws -> RoulettePresetTexts {
        try await Task.sleep(nanoseconds: 150_000_000)
        return RoulettePresetTexts(items: [
            RoulettePreset(id: "p1", text: "Kiss"),
            RoulettePreset(id: "p2", text: "Wink"),
            RoulettePreset(id: "p3", text: "Dance"),
            RoulettePreset(id: "p4", text: "Sing"),
            RoulettePreset(id: "p5", text: "Blow Kiss"),
            RoulettePreset(id: "p6", text: "Wave"),
            RoulettePreset(id: "p7", text: "Smile"),
            RoulettePreset(id: "p8", text: "Say Hi"),
        ])
    }
}

// MARK: - Real（H 里程碑接入生产 API）

struct RouletteServiceReal: RouletteServiceProtocol {

    func queryConfig(anchorUserId: String) async throws -> RouletteConfig {
        let data = try await APIClient.shared.post(
            "/api/wheel/queryWheelConfigByAnchorId",
            body: ["searchValue": anchorUserId]
        )
        guard let dict = Self.jsonObject(data) as? [String: Any] else {
            return .defaultConfig  // 后端返 null 视为"未配置过"
        }
        return Self.parseConfig(dict: dict)
    }

    func saveConfig(_ config: RouletteConfig, liveRoomId: String) async throws -> RouletteConfig {
        let body: [String: Any] = [
            "addWheelSector": Self.encodeSectors(config.sectors.filter { !$0.isPlaceholder }),
            "enabled": config.enabled ? "1" : "0",
            "liveRoomId": liveRoomId,
            "price": config.price,
        ]
        let data = try await APIClient.shared.post("/api/wheel/addWheelConfig", body: body)
        guard let dict = Self.jsonObject(data) as? [String: Any] else {
            return config
        }
        // 响应字段是 wheelSectors（不是 wheelSectorList）
        let sectors = Self.parseSectors(dict["wheelSectors"])
        return RouletteConfig(enabled: config.enabled, price: config.price, sectors: sectors)
    }

    func changeStatus(config: RouletteConfig, enabled: Bool, liveRoomId: String) async throws {
        let body: [String: Any] = [
            "addWheelSector": Self.encodeSectors(config.sectors.filter { !$0.isPlaceholder }),
            "enabled": enabled ? "1" : "0",
            "liveRoomId": liveRoomId,
            "price": config.price,
        ]
        _ = try await APIClient.shared.post("/api/wheel/changeWheelStatus", body: body)
    }

    func presetTexts() async throws -> RoulettePresetTexts {
        let data = try await APIClient.shared.post("/api/wheel/queryPresetText", body: [:])
        return RoulettePresetTexts(items: Self.parsePresets(Self.jsonObject(data)))
    }

    // MARK: - decode helpers

    private static func jsonObject(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    /// 解 queryConfig response `{wheelSectorList, price, enabled}`。缺字段默认零态。
    private static func parseConfig(dict: [String: Any]) -> RouletteConfig {
        let enabled = enabledFrom(dict["enabled"])
        let price = intFrom(dict["price"]) ?? 0
        let sectors = parseSectors(dict["wheelSectorList"])
        return RouletteConfig(enabled: enabled, price: price, sectors: sectors)
    }

    /// enabled 后端返 "0"/"1" 字符串或 0/1 数字，双兼容
    private static func enabledFrom(_ any: Any?) -> Bool {
        if let s = any as? String { return s == "1" }
        if let n = any as? NSNumber { return n.intValue == 1 }
        return false
    }

    private static func intFrom(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let s = any as? String { return Int(s) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    /// H5 sector 字段：`{presetId: Number|String|'', text: String}` → iOS 统一 String presetId
    /// 对齐 ios-decode-userid-compat rule
    private static func parseSectors(_ any: Any?) -> [RouletteSector] {
        guard let arr = any as? [[String: Any]] else { return [] }
        return arr.compactMap { d in
            let text = (d["text"] as? String) ?? ""
            guard !text.isEmpty else { return nil }
            var presetId = ""
            if let s = d["presetId"] as? String { presetId = s }
            else if let n = d["presetId"] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType != "c" && cType != "B" { presetId = n.stringValue }
            }
            return RouletteSector(presetId: presetId, text: text)
        }
    }

    /// queryPresetText 后端返顶层 `[...]` 或 `{list:[...]}` 双兼容（plan §后续 待抓包确认）
    private static func parsePresets(_ any: Any?) -> [RoulettePreset] {
        let arr: [[String: Any]]
        if let a = any as? [[String: Any]] { arr = a }
        else if let d = any as? [String: Any], let a = d["list"] as? [[String: Any]] { arr = a }
        else { return [] }

        return arr.compactMap { d in
            let text = (d["text"] as? String) ?? ""
            guard !text.isEmpty else { return nil }
            var id = ""
            if let s = d["id"] as? String { id = s }
            else if let n = d["id"] as? NSNumber {
                let cType = String(cString: n.objCType)
                if cType != "c" && cType != "B" { id = n.stringValue }
            }
            guard !id.isEmpty else { return nil }
            return RoulettePreset(id: id, text: text)
        }
    }

    /// 编码 sectors 供上传：`[{presetId, text}]`（对齐 H5 interactionList 结构）
    private static func encodeSectors(_ sectors: [RouletteSector]) -> [[String: Any]] {
        sectors.map { ["presetId": $0.presetId, "text": $0.text] }
    }
}
