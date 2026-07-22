import Foundation

/// 转盘奖项（对齐 H5 liveRoulettePopup.vue `wheelSectorList` / `addWheelSector`）
///
/// H5 数据结构：`{ presetId: Number | '' , text: string, delete?: boolean }`
/// - `presetId=""` → 用户手动输入项
/// - `presetId="1"..."N"` → 从 presetText 选中项
/// - `isPlaceholder=true` → 对齐 H5 `delete:true` 语义；显示时补齐 4-8 用，保存前 filter 掉
struct RouletteSector: Equatable, Identifiable {
    /// SwiftUI ForEach 用；presetId 空则用 uuid 兜底（对同一 sector 保持稳定）
    let id: String
    var presetId: String
    var text: String
    var isPlaceholder: Bool

    init(presetId: String, text: String, isPlaceholder: Bool = false, id: String? = nil) {
        self.presetId = presetId
        self.text = text
        self.isPlaceholder = isPlaceholder
        self.id = id ?? (presetId.isEmpty ? UUID().uuidString : presetId)
    }
}

/// queryPresetText 响应项（H5 tjItems）
struct RoulettePreset: Equatable, Identifiable {
    let id: String
    let text: String
}

/// 转盘配置（对齐 H5 wheel config）
struct RouletteConfig: Equatable {
    var enabled: Bool
    var price: Int
    var sectors: [RouletteSector]

    static let defaultConfig = RouletteConfig(enabled: false, price: 0, sectors: [])
}

/// H5 后端返回的预设文案（onMounted queryPresetText 拉取）
struct RoulettePresetTexts: Equatable {
    let items: [RoulettePreset]
    static let empty = RoulettePresetTexts(items: [])
}

/// 猜拳（RPS · Rock Paper Scissors）规则参数（对齐 H5 §9.2.2 `rpsRulesSheet.vue` L5-11）。
///
/// H5 优先读 `liveStore.rpsConfig.{price, bestOf, grantedHours, medalCap}`；后端接口暂未对接，
/// 一期用默认值兜底。**v24 B2 iOS 仅落地组件 + 默认值**；接口对接留后期里程碑（H 附加或 J 收尾）。
struct RpsRulesConfig: Equatable {
    /// 每局价格（钻石）
    var price: Int = 300
    /// 局数（Best of N）
    var bestOf: Int = 3
    /// 获胜勋章基础小时数（H5 `grantedHours`）
    var medalBase: Int = 2
    /// 勋章累计上限小时数（H5 `medalCap`）
    var medalCap: Int = 72

    static let `default` = RpsRulesConfig()
}
