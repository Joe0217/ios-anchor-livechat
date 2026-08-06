import Foundation

/// 注册表单校验纯函数（对齐 spec §6.4 + H5 `components/registerForm.vue:129-153` 8 校验规则）
///
/// 抽为独立 struct 是为了 TDD 单元可测（不依赖 Store / SwiftUI），
/// 便于注册资料规则和 Nickname 15 字符边界保持一致。
struct RegisterFormValidator {

    /// Page 1 (BasicInfo) 4 字段校验
    func validatePage1(iconUrl: String?, nickname: String, birthday: String, countryCode: String?) -> RegisterValidationResult {
        if (iconUrl ?? "").isEmpty { return .missingAvatar }
        if nickname.trimmingCharacters(in: .whitespaces).isEmpty { return .missingNickname }
        if birthday.isEmpty { return .missingBirthday }
        if (countryCode ?? "").isEmpty { return .missingCountry }
        return .ok
    }

    /// 有邀请码时至少 6 张资料照片，否则至少 1 张；审核视频不阻断注册。
    func validatePage2(languages: [String], picUrls: [String], inviteCode: String) -> RegisterValidationResult {
        if languages.isEmpty { return .missingLanguage }
        if picUrls.count < requiredProfilePhotoCount(inviteCode: inviteCode) { return .missingPhotos }
        return .ok
    }

    func requiredProfilePhotoCount(inviteCode: String) -> Int {
        inviteCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 6
    }

    /// Nickname 长度校验（对齐 H5 register form `maxlength="15"`）
    ///
    /// Swift String.count 是 grapheme cluster 单位，一个 emoji = 1 count，与 H5 maxlength 语义对齐
    func isNicknameLenValid(_ s: String) -> Bool {
        return s.count <= 15
    }
}

enum RegisterValidationResult: Equatable {
    case ok
    case missingAvatar
    case missingNickname
    case missingBirthday
    case missingCountry
    case missingLanguage
    case missingPhotos
}
