import Foundation

/// `POST /api/user/updateUserInfo` 请求（I-spec §4.2.3）。
///
/// 智能字段检测：调用方只填变更且非审核中字段；全空返回 nil request → 不发接口直接 dismiss
/// （对齐 H5 handleSubmit L369-374 `back()` 无 toast）。
///
/// **id 类型策略**（对齐 rule ios-decode-userid-compat.md）：`picsDel/videosDel/callVideosDel/
/// delGreetList` 里 id 后端接收类型待 Step 1c 抓包证实（H5 findMissingIds 不做转换，透传服务端
/// 原生类型）。首轮用 `[Int]?`；抓包发现是 String → 迁移到 `[String]?`。
struct UpdateUserInfoRequest: Encodable, Equatable {
    var icon: String?
    var nickname: String?
    var signature: String?

    var pics: [String]?
    var picsDel: [Int]?

    var videos: [String]?
    var videosDel: [Int]?

    var callVideoUrl: String?
    var callVideosDel: [Int]?

    var addGreetList: [String]?
    var delGreetList: [Int]?

    /// 全字段皆 nil / 空数组 → 无变更 → dismiss 不发接口
    var isEmpty: Bool {
        icon == nil
            && nickname == nil
            && signature == nil
            && (pics?.isEmpty ?? true)
            && (picsDel?.isEmpty ?? true)
            && (videos?.isEmpty ?? true)
            && (videosDel?.isEmpty ?? true)
            && callVideoUrl == nil
            && (callVideosDel?.isEmpty ?? true)
            && (addGreetList?.isEmpty ?? true)
            && (delGreetList?.isEmpty ?? true)
    }
}
