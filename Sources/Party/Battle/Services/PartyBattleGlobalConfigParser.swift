import Foundation

/// PartyBattle 全局开关配置
///
/// 后端 `/api/index/getConfigByKey?searchValue=party_room_battle_config` 返回：
/// `{ "party_room_battle_config": "{totalSwitch=1, cooldownDurationSec=60}" }`
/// 其中 value 是 **Java Map style** 字符串（非 JSON），需要自定义 parse。
struct PartyBattleGlobalConfig: Equatable {
    let totalSwitch: Int
    let cooldownDurationSec: Int?
}

/// Java Map style 字符串 parser，形如 `{key1=val1, key2=val2}`
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
