import Foundation

/// 派对房支持语言（`room/language/list` 返回）。
///
/// 对齐 H5 用户端 `livechat-h5/src/api/party/index.ts:33 apiGetLanguageList`
/// 与 `stores/modules/party.js:1354`（首项前端插 `{languageName:'All', languageCode:''}`）。
///
/// iOS 创房页 Room language picker 消费本 model。
struct PartyLanguage: Codable, Equatable, Identifiable, Hashable {
    let languageName: String
    let languageCode: String

    var id: String { languageCode }
}
