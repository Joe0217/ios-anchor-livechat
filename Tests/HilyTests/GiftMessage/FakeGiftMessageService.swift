import Foundation

// HilyTests target 编译纯 Swift 源文件，PrivateMedia / Protocol 同 module。

/// 单测用 mock GiftMessageService。
final class FakeGiftMessageService: GiftMessageServiceProtocol {
    var limitResult: Result<PrivateMediaLimit, Error> = .success(.default)
    var listResult: Result<[PrivateMedia], Error> = .success([])
    var saveResult: Result<Void, Error> = .success(())
    var decryptResult: Result<String, Error> = .success("https://cdn.test/signed.mp4?token=x")
    var giftsResult: Result<[GiftMessageItem], Error> = .success([])

    private(set) var fetchLimitCallCount = 0
    private(set) var fetchListCallCount = 0
    private(set) var saveCalls: [[PrivateMediaOp]] = []
    private(set) var decryptCalls: [String] = []

    var delaySeconds: Double = 0

    func fetchLimit() async throws -> PrivateMediaLimit {
        fetchLimitCallCount += 1
        try await maybeSleep()
        return try limitResult.get()
    }

    func fetchList(userId: Int) async throws -> [PrivateMedia] {
        fetchListCallCount += 1
        try await maybeSleep()
        return try listResult.get()
    }

    func save(ops: [PrivateMediaOp]) async throws {
        saveCalls.append(ops)
        try await maybeSleep()
        try saveResult.get()
    }

    func decryptVideoUrl(originalUrl: String) async throws -> String {
        decryptCalls.append(originalUrl)
        try await maybeSleep()
        return try decryptResult.get()
    }

    func fetchGifts() async throws -> [GiftMessageItem] {
        try await maybeSleep()
        return try giftsResult.get()
    }

    private func maybeSleep() async throws {
        guard delaySeconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
    }
}

/// 单测用 mock upload service。
final class FakePrivateMediaUploadService: PrivateMediaUploadServiceProtocol {
    var uploadImageResult: Result<String, Error> = .success("https://oss.test/img1.jpg")
    var uploadVideoResult: Result<String, Error> = .success("https://oss.test/vid1.mp4")

    private(set) var uploadImageCalls: [Data] = []
    private(set) var uploadVideoCalls: [URL] = []

    func uploadImage(_ data: Data) async throws -> String {
        uploadImageCalls.append(data)
        return try uploadImageResult.get()
    }

    func uploadVideo(fileURL: URL) async throws -> String {
        uploadVideoCalls.append(fileURL)
        return try uploadVideoResult.get()
    }
}

// MARK: - fixture

extension PrivateMedia {
    static func fixture(id: String = "server_1",
                       iconType: Int = 1,
                       originalUrl: String = "https://oss.test/orig.jpg",
                       giftId: String = "100") -> PrivateMedia {
        PrivateMedia(
            id: id,
            iconType: iconType,
            originalUrl: originalUrl,
            signedUrl: nil,
            signedAt: nil,
            giftId: giftId,
            giftName: "Rose",
            giftPrice: 100
        )
    }
}

extension GiftMessageItem {
    static func fixture(id: String = "100", name: String = "Rose", price: Int = 100) -> GiftMessageItem {
        GiftMessageItem(id: id, name: name, iconUrl: nil, price: price)
    }
}

struct GiftMessageStubError: Error, LocalizedError {
    let kind: String
    var errorDescription: String? { "stub: \(kind)" }
}
