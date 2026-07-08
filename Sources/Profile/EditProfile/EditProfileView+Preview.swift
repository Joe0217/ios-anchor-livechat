import SwiftUI

#if DEBUG

// MARK: - Preview 工厂（对齐 spec §5 Preview 栏 ✓ 全 8 态）

extension EditProfileStore {
    /// 手工构造已 load 的 Store（跳过异步 fetch）
    @MainActor
    fileprivate static func preview(
        phase: EditProfilePhase = .editing,
        draft: DraftState = .empty,
        review: ReviewStatus = .none,
        snapshot: OriginalSnapshot = .empty,
        loadErrorMessage: String? = nil,
        toast: EditProfileToastKey? = nil
    ) -> EditProfileStore {
        let store = EditProfileStore(service: FakePreviewService())
        store._previewApply(
            phase: phase,
            draft: draft,
            review: review,
            snapshot: snapshot,
            loadErrorMessage: loadErrorMessage,
            transientToast: toast
        )
        return store
    }
}

/// Preview 用最小 Fake（真 service 走 EditProfileService，Preview 不需要真上传/请求）
private final class FakePreviewService: EditProfileServiceProtocol, @unchecked Sendable {
    func fetchCheckUserInfo() async throws -> CheckUserInfoResponse {
        CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil)
    }
    func fetchUserInfoWithReview() async throws -> UserInfoWithReviewResponse {
        UserInfoWithReviewResponse(
            anchorInfo: AnchorInfo(
                userId: 1, nickname: "Preview", icon: "", sex: 2, age: 20,
                countryCode: "US", signature: "", signatureVaild: 1,
                level: 1, levelName: "SS", callPrice: 100,
                upsNum: 0, fansNum: 0, friendsNum: 0,
                pictures: nil, videos: nil, greetMsgs: nil,
                callVideoUrl: nil, giftList: nil,
                chatBubble: nil, activeTycoon: nil,
                email: nil, birthday: nil, phone: nil, inviteCode: nil, language: nil, countryId: nil
            ),
            latestIconAndCallVideo: nil, picList: nil
        )
    }
    func updateUserInfo(_ request: UpdateUserInfoRequest) async throws {}
    func uploadImage(data: Data, preset: ImageCompressionPreset) async throws -> String { "" }
    func uploadVideo(data: Data, fileExtension: String) async throws -> String { "" }
}

// MARK: - Draft / Snapshot fixtures

private extension DraftState {
    static let editingFullFields = DraftState(
        nickname: "Alice",
        avatarUrl: "https://picsum.photos/200",
        signature: "Hello, I'm Alice. Nice to meet you here.",
        photos: [
            DraftMediaItem(id: "p1", serverId: 1, url: "https://picsum.photos/200?a", coverUrl: nil, uploadState: .idle),
            DraftMediaItem(id: "p2", serverId: 2, url: "https://picsum.photos/200?b", coverUrl: nil, uploadState: .idle),
            DraftMediaItem(id: "p-up", serverId: nil, url: "", coverUrl: nil, uploadState: .uploading(localId: "u1")),
            DraftMediaItem(id: "p-fail", serverId: nil, url: "", coverUrl: nil, uploadState: .failed(message: "timeout")),
        ],
        videos: [
            DraftMediaItem(id: "v1", serverId: 10, url: "https://picsum.photos/200?v", coverUrl: "https://picsum.photos/200?vc", uploadState: .idle),
        ],
        callVideo: nil,
        greetMsgs: [
            DraftGreetMsg(id: "g1", serverId: 500, content: "Hi!"),
            DraftGreetMsg(id: "g2", serverId: 501, content: "Welcome ♥"),
        ]
    )

    static let filledMax = DraftState(
        nickname: "Max",
        avatarUrl: "https://picsum.photos/200",
        signature: "Full",
        photos: (1...9).map {
            DraftMediaItem(id: "p\($0)", serverId: $0, url: "https://picsum.photos/200?f\($0)", coverUrl: nil, uploadState: .idle)
        },
        videos: [],
        callVideo: nil,
        greetMsgs: []
    )
}

private extension OriginalSnapshot {
    static let full = OriginalSnapshot(
        nickname: "Alice",
        avatarUrl: "https://picsum.photos/200",
        signature: "Hello",
        photos: [], videos: [], callVideo: nil, greetMsgs: [],
        hiddenRejectedPhotoIds: [], hiddenRejectedVideoIds: []
    )
}

// MARK: - Previews

/// #Preview 1 — 加载中态（N-24 冷启动）
#Preview("1 · loading") {
    EditProfileView(previewStore: EditProfileStore.preview(phase: .loading))
}

/// #Preview 2 — 编辑基态（P-1 正常打开，无审核 + 混合 tile 态覆盖 N-14/N-15）
#Preview("2 · editing normal") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .editing,
        draft: .editingFullFields,
        snapshot: .full
    ))
}

/// #Preview 3 — 3 字段全部审核中（N-1 / N-2 / N-3 / N-4）
#Preview("3 · all reviewing") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .editing,
        draft: .editingFullFields,
        review: ReviewStatus(
            nickname: true,
            signature: true,
            avatar: true,
            avatarRejected: false,
            reviewingGreetMsgs: [GreetMsg(serverId: 999, contentDetail: "Reviewing greet")]
        ),
        snapshot: .full
    ))
}

/// #Preview 4 — 相册满 9 张（N-9：AddMediaTile 不显示）
#Preview("4 · photos full 9") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .editing,
        draft: .filledMax,
        snapshot: .full
    ))
}

/// #Preview 5 — Saving 中（N-16/N-17 变体：整页 saving overlay）
#Preview("5 · saving") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .saving,
        draft: .editingFullFields,
        snapshot: .full
    ))
}

/// #Preview 6 — Success alert（P-2 保存成功）
#Preview("6 · success") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .success,
        draft: .editingFullFields,
        snapshot: .full
    ))
}

/// #Preview 7 — LoadError（N-5 / N-6：checkUserInfo 失败）
#Preview("7 · loadError") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .loadError("Connection failed"),
        loadErrorMessage: "Connection lost. Please retry."
    ))
}

/// #Preview 8 — Editing with toast（N-11/N-12/N-18 变体：显示 toast overlay）
#Preview("8 · editing + toast") {
    EditProfileView(previewStore: EditProfileStore.preview(
        phase: .editing,
        draft: .editingFullFields,
        snapshot: .full,
        toast: .imageTooLarge
    ))
}

#endif
