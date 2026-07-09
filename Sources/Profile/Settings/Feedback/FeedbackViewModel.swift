import Foundation
import SwiftUI
import os

private let logger = Logger(subsystem: "com.anchor.livechat", category: "FeedbackViewModel")

/// 反馈页 ViewModel（对齐 H5 `src/views/settings/feedBack/index.vue`）。
///
/// **表单契约**：
/// - 4 单选 category（必选）
/// - suggestion textarea（必填，maxlength 2000）
/// - email（必填，正则 `^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$`）
/// - photos 最多 3 张（可空）
///
/// **提交流程**：
/// 1. 前置校验 → email 正则失败直接 toast（H5 `showToast('Wrong email address')`）
/// 2. 逐张顺序上传（走 `ImageUploader.shared.uploadSerial(preset: .feedback)`）
///    - 任一张失败 → 立即中断 + toast，**已成功的 URL 保留在 uploadedPicUrls**（用户可重试单张补齐）
/// 3. 全部拿到 URL 后 → `POST /api/feedback/save` → 成功 toast + 路由 dismiss
@MainActor
final class FeedbackViewModel: ObservableObject {

    // MARK: - Form fields

    @Published var selectedType: FeedbackType? = nil
    @Published var message: String = ""
    @Published var email: String = ""
    /// 用户已选择但**未上传**的图片 raw data（PhotosPicker 回调塞入；提交时才上传）
    @Published var pendingPhotos: [Data] = []
    /// 已成功上传的 CDN URL（单张失败保留：用户重试时不重复上传）
    @Published private(set) var uploadedPicUrls: [String] = []

    // MARK: - State

    enum State: Equatable {
        case editing
        case submitting
        case success
    }
    @Published private(set) var state: State = .editing
    /// 顶部 toast 文案（2s 自清），成功/失败/校验错误统一走此字段
    @Published var toast: String? = nil

    // MARK: - Config

    static let maxMessageLength = 2000
    static let maxPhotoCount = 3
    /// 邮箱正则（对齐 H5 `views/settings/feedBack/index.vue:15`）
    private static let emailPattern = "^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$"

    private let service: FeedbackServiceProtocol
    private let networkErrorFallback: String
    private let wrongEmailFallback: String
    private let submitSuccessMessage: String

    init(service: FeedbackServiceProtocol = FeedbackService.shared,
         networkErrorFallback: String = L10n.feedbackSubmitFailed,
         wrongEmailFallback: String = L10n.feedbackWrongEmail,
         submitSuccessMessage: String = L10n.feedbackSubmitSuccess) {
        self.service = service
        self.networkErrorFallback = networkErrorFallback
        self.wrongEmailFallback = wrongEmailFallback
        self.submitSuccessMessage = submitSuccessMessage
    }

    // MARK: - Derived

    var canSubmit: Bool {
        state == .editing
            && selectedType != nil
            && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Actions

    func addPhoto(_ data: Data) {
        guard pendingPhotos.count + uploadedPicUrls.count < Self.maxPhotoCount else { return }
        pendingPhotos.append(data)
    }

    func removePendingPhoto(at index: Int) {
        guard pendingPhotos.indices.contains(index) else { return }
        pendingPhotos.remove(at: index)
    }

    func removeUploadedPhoto(at index: Int) {
        guard uploadedPicUrls.indices.contains(index) else { return }
        uploadedPicUrls.remove(at: index)
    }

    func clearToast() { toast = nil }

    /// 提交流程（对齐 H5 `submit()` 内嵌 pattern 校验 + postFeedback）
    func submit() async {
        guard state == .editing, let type = selectedType else { return }

        // 1. 邮箱正则校验（对齐 H5 `!pattern.test(email.value)` toast）
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !isValidEmail(trimmedEmail) {
            toast = wrongEmailFallback
            return
        }

        state = .submitting

        // 2. 上传 pending 图片（若有）—— 序列上传失败保留已成功 URL
        if !pendingPhotos.isEmpty {
            let result = await ImageUploader.shared.uploadSerial(
                rawDataList: pendingPhotos,
                preset: .feedback
            )
            uploadedPicUrls.append(contentsOf: result.urls)
            if let failedIdx = result.failedAt {
                // 部分失败：移除已成功索引之前的 pending 项，保留失败与之后的项供用户重试
                let successCount = result.urls.count
                pendingPhotos = Array(pendingPhotos.dropFirst(successCount))
                state = .editing
                toast = networkErrorFallback
                logger.error("upload partial failed at=\(failedIdx) success=\(successCount)")
                return
            }
            pendingPhotos.removeAll()
        }

        // 3. 提交表单
        do {
            let req = FeedbackRequest(
                pics: uploadedPicUrls,
                suggestion: message.trimmingCharacters(in: .whitespacesAndNewlines),
                feedbackType: type.rawValue,
                email: trimmedEmail
            )
            try await service.submit(req)
            state = .success
            toast = submitSuccessMessage
            let picCount = self.uploadedPicUrls.count
            logger.info("submit success type=\(type.rawValue, privacy: .public) picCount=\(picCount)")
        } catch {
            state = .editing
            toast = networkErrorFallback
            logger.error("submit failed: \(String(describing: error))")
        }
    }

    // MARK: - Private

    private func isValidEmail(_ s: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: Self.emailPattern) else { return false }
        let range = NSRange(location: 0, length: (s as NSString).length)
        return regex.firstMatch(in: s, range: range) != nil
    }
}
