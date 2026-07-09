import Foundation

/// EditProfile 单测用 mock，实现 `EditProfileServiceProtocol`。
///
/// 用法：预置各方法结果 → 注入 Store 单测；unhandled 场景 fallback 到 default（避免 nil crash）。
final class FakeEditProfileService: EditProfileServiceProtocol, @unchecked Sendable {

    // MARK: - 注入结果

    var checkUserInfoResult: Result<CheckUserInfoResponse, Error> = .success(
        CheckUserInfoResponse(nickname: nil, signature: nil, greetMsgs: nil)
    )
    var userInfoResult: Result<UserInfoWithReviewResponse, Error> = .success(
        UserInfoWithReviewResponse(
            anchorInfo: FakeEditProfileService.emptyAnchorInfo,
            latestIconAndCallVideo: nil,
            picList: nil
        )
    )
    var updateUserInfoResult: Result<Void, Error> = .success(())
    var uploadImageResult: Result<String, Error> = .success("https://cdn.example.com/image.jpg")
    var uploadVideoResult: Result<String, Error> = .success("https://cdn.example.com/video.mp4")

    /// 模拟接口延迟（秒）
    var delaySeconds: Double = 0

    // MARK: - 调用记录

    private(set) var updateCalls: [UpdateUserInfoRequest] = []
    private(set) var uploadImageCalls: [(byteCount: Int, preset: ImageCompressionPreset)] = []
    private(set) var uploadVideoCalls: [(byteCount: Int, ext: String)] = []
    private(set) var checkUserInfoCallCount: Int = 0
    private(set) var userInfoCallCount: Int = 0

    // MARK: - EditProfileServiceProtocol

    func fetchCheckUserInfo() async throws -> CheckUserInfoResponse {
        checkUserInfoCallCount += 1
        try await simulateDelay()
        return try checkUserInfoResult.get()
    }

    func fetchUserInfoWithReview() async throws -> UserInfoWithReviewResponse {
        userInfoCallCount += 1
        try await simulateDelay()
        return try userInfoResult.get()
    }

    func updateUserInfo(_ request: UpdateUserInfoRequest) async throws {
        updateCalls.append(request)
        try await simulateDelay()
        _ = try updateUserInfoResult.get()
    }

    func uploadImage(data: Data, preset: ImageCompressionPreset) async throws -> String {
        uploadImageCalls.append((byteCount: data.count, preset: preset))
        try await simulateDelay()
        return try uploadImageResult.get()
    }

    func uploadVideo(data: Data, fileExtension: String) async throws -> String {
        uploadVideoCalls.append((byteCount: data.count, ext: fileExtension))
        try await simulateDelay()
        return try uploadVideoResult.get()
    }

    // MARK: - Helpers

    private func simulateDelay() async throws {
        if delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
    }

    // MARK: - Fixture builders

    static let emptyAnchorInfo = AnchorInfo(
        userId: 1001,
        nickname: "",
        icon: "",
        sex: 2,
        age: 20,
        countryCode: "US",
        signature: "",
        signatureVaild: 1,
        level: 1,
        levelName: "SS",
        callPrice: 100,
        upsNum: 0,
        fansNum: 0,
        friendsNum: 0,
        pictures: nil,
        videos: nil,
        picList: nil,
        greetMsgs: nil,
        callVideoUrl: nil,
        giftList: nil,
        chatBubble: nil,
        activeTycoon: nil,
        email: nil,
        birthday: nil,
        phone: nil,
        inviteCode: nil,
        language: nil,
        countryId: nil
    )

    /// 完整数据 fixture（loading 后 draft 有全部字段）
    static func populatedAnchorInfo(
        nickname: String = "OriginalName",
        icon: String = "https://cdn.example.com/original.jpg",
        signature: String = "OriginalBio",
        pictures: [MediaAsset]? = nil,
        videos: [MediaAsset]? = nil,
        greetMsgs: [GreetMsg]? = nil,
        callVideoUrl: String? = nil
    ) -> AnchorInfo {
        AnchorInfo(
            userId: 1001,
            nickname: nickname,
            icon: icon,
            sex: 2,
            age: 20,
            countryCode: "US",
            signature: signature,
            signatureVaild: 1,
            level: 1,
            levelName: "SS",
            callPrice: 100,
            upsNum: 0,
            fansNum: 0,
            friendsNum: 0,
            pictures: pictures,
            videos: videos,
            picList: nil,
            greetMsgs: greetMsgs,
            callVideoUrl: callVideoUrl,
            giftList: nil,
            chatBubble: nil,
            activeTycoon: nil,
            email: nil,
            birthday: nil,
            phone: nil,
            inviteCode: nil,
            language: nil,
            countryId: nil
        )
    }

    static func mediaAsset(id: Int, url: String = "https://cdn.example.com/img.jpg", vaild: Int = 1) -> MediaAsset {
        MediaAsset(assetId: id, url: url, coverUrl: nil, vaild: vaild, createTime: nil)
    }

    static func greetMsg(id: Int, content: String) -> GreetMsg {
        GreetMsg(serverId: id, contentDetail: content)
    }
}
