import Foundation

/// 转盘配置（对齐 H5 liveRoulettePopup.vue wheel config）
struct RouletteConfig: Equatable {
    /// 转盘启用状态
    var enabled: Bool
    /// 单次转盘参与价（钻石）
    var price: Int
    /// 4-8 个奖项文案
    var sectors: [String]

    static let defaultConfig = RouletteConfig(
        enabled: false,
        price: 100,
        sectors: []
    )
}

/// H5 后端返回的预设文案（onMounted queryPresetText 拉取）
struct RoulettePresetTexts: Equatable {
    let texts: [String]
    static let empty = RoulettePresetTexts(texts: [])
}
