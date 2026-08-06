import Foundation

enum RegisterFeatureAvailability {
    /// 107 提审包暂不开放邀请码输入；恢复时只需打开此开关。
    static let isInvitationCodeEnabled = false
}

// MARK: - 导航路由

/// LoginView 顶层 NavigationStack 分派目标（对齐 spec §3.2 v3 + plan v2 MINOR-N4）
enum RegisterRoute: Hashable {
    case basicInfo
    case required
    case videoRecord
    case videoPreview
}

// MARK: - Country（getCountryList 响应元素）

struct Country: Codable, Identifiable, Hashable {
    let locale: String              // "ES" / "US" / ...
    let en: String                  // "Spain" / "United States"
    var id: String { locale }
    var flagAssetName: String { locale.lowercased() }   // 对齐 H5 flag png 命名约定（若 assets 未导入走 flagEmoji fallback）

    /// Unicode Regional Indicator Symbols 拼国旗 emoji（iOS 原生渲染，无需拷贝 png 资源）
    /// ES → 🇪🇸 / US → 🇺🇸 / CN → 🇨🇳 ...
    /// 若 locale 不是 2 字母 ISO code，返 fallback "🏳️"
    var flagEmoji: String {
        let code = locale.uppercased()
        guard code.count == 2 else { return "🏳️" }
        let base: UInt32 = 127397   // Regional Indicator Symbol Letter A (U+1F1E6) minus 'A' (0x41)
        var scalar = ""
        for c in code.unicodeScalars {
            guard c.value >= UnicodeScalar("A").value && c.value <= UnicodeScalar("Z").value,
                  let s = UnicodeScalar(base + c.value) else {
                return "🏳️"
            }
            scalar.append(String(s))
        }
        return scalar
    }
}

// MARK: - Language（Page 2 语言选择）

/// 7 项候选（对齐 spec §0.5 + 设计稿排序 English/French/Spanish/Russian/Arabic/Hindi/German）
enum RegisterLanguage: String, CaseIterable, Identifiable {
    case english = "English"
    case french  = "French"
    case spanish = "Spanish"
    case russian = "Russian"
    case arabic  = "Arabic"
    case hindi   = "Hindi"
    case german  = "German"
    var id: String { rawValue }
}

// MARK: - 照片上传任务

struct PhotoUploadTask: Identifiable, Equatable {
    let id: UUID
    let localData: Data
    var state: State

    enum State: Equatable {
        case uploading(progress: Double)
        case succeeded(url: String)
        case failed(error: String)
    }

    var isSucceeded: Bool {
        if case .succeeded = state { return true }
        return false
    }
    var succeededUrl: String? {
        if case .succeeded(let url) = state { return url }
        return nil
    }
}

// MARK: - 视频录制状态

enum VideoRecordState: Equatable {
    case idle
    case preparing
    case ready                                     // preview 就绪未开录
    case recording(elapsed: TimeInterval)          // 0..20
    case finished(localUrl: URL)                   // 录完 mov
    case failed(RegisterVideoError)
}

enum RegisterVideoError: Error, Equatable {
    case cameraDenied
    case microphoneDenied
    case sessionInterrupted
    case configFailed(String)
    case fileWriteFailed(String)
    case compressFailed(String)
    case uploadFailed(String)
}

// MARK: - 表单提交 body（内部构造用）

/// 一期 registerV2 / reSubmitView 提交 body（字段名参考 H5 `views/register/index.vue` formData + `type.ts`）
///
/// ⚠️ 精确字段名待 T1c.8 e2e 真接口调用错误时对齐（rule api-http-method-strict.md：先追 H5 字面接口调用，不推理；本项目一期先按 H5 formData 字段名跑，e2e 阶段真机 verify 后修）
struct RegisterSubmitBody {
    var email: String
    var password: String                           // 已两次 upper MD5（同 login pwd 处理，走 CryptoUtil.loginPassword）
    var iconUrl: String
    var nickname: String
    var birthday: String                           // "yyyy-MM-dd"
    var countryId: String                          // 以 H5 register formData 字段名 countryId 为准；抓包 T1c.8 verify
    var inviteCode: String
    var language: String                           // 逗号 join（H5 register.js formData.language）
    var picList: [String]                          // 6 OSS URLs
    var videos: [String]                           // 1 OSS URL
    var gender: Int = 2
    var deviceId: String
    var phone: String = ""

    /// 转 [String: Any] 供 APIClient.post
    func toDict() -> [String: Any] {
        return [
            "email": email,
            "password": password,
            "icon": iconUrl,                       // H5 register.vue:56 `icon: formData.icon[0]` 字面
            "nickname": nickname,
            "birthday": birthday,
            "countryId": countryId,
            "inviteCode": inviteCode,
            "language": language,
            "picList": picList,
            "videos": videos,
            "gender": gender,
            "deviceId": deviceId,
            "phone": phone
        ]
    }
}
