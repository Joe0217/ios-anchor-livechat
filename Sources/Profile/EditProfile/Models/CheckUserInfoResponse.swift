import Foundation

/// `POST /api/anchor/checkUserInfo` 响应（I-spec §4.2.1）。
///
/// 语义：非 nil / 非空的字段表示"用户上一次提交后处于审核中"，编辑页据此禁用对应字段编辑。
/// - nickname 非 nil：昵称审核中
/// - signature 非 nil：简介审核中
/// - greetMsgs 非空：这些问候语审核中（展示为独立一段）
struct CheckUserInfoResponse: Decodable, Equatable {
    let nickname: String?
    let signature: String?
    let greetMsgs: [GreetMsg]?
}
