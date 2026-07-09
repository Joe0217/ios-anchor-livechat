import XCTest

/// H-2 spec §1.11 / §2.1 / R5 · Model 层边界单测
final class ChatModelsTests: XCTestCase {

    // MARK: - AnchorMediaItem 组装

    func test_fromPicture_valid_returns_item() {
        let asset = MediaAsset(assetId: 1, url: "https://cdn/pic.jpg", coverUrl: nil, vaild: 1, createTime: 100)
        let item = AnchorMediaItem.fromPicture(asset)
        XCTAssertEqual(item?.kind, .image)
        XCTAssertEqual(item?.mediaUrl.absoluteString, "https://cdn/pic.jpg")
    }

    func test_fromPicture_nilURL_returns_nil() {
        let asset = MediaAsset(assetId: 1, url: nil, coverUrl: nil, vaild: 1, createTime: 100)
        XCTAssertNil(AnchorMediaItem.fromPicture(asset))
    }

    func test_fromPicture_invalidReviewState_returns_nil() {
        // vaild=3 被拒
        let asset = MediaAsset(assetId: 1, url: "https://cdn/pic.jpg", coverUrl: nil, vaild: 3, createTime: 100)
        XCTAssertNil(AnchorMediaItem.fromPicture(asset))
        // vaild=2 审核中
        let asset2 = MediaAsset(assetId: 1, url: "https://cdn/pic.jpg", coverUrl: nil, vaild: 2, createTime: 100)
        XCTAssertNil(AnchorMediaItem.fromPicture(asset2))
    }

    func test_fromVideo_valid_returns_item_with_cover() {
        let asset = MediaAsset(assetId: 2, url: "https://cdn/v.mp4", coverUrl: "https://cdn/v.jpg", vaild: 1, createTime: 200)
        let item = AnchorMediaItem.fromVideo(asset)
        XCTAssertEqual(item?.kind, .video)
        XCTAssertEqual(item?.coverUrl?.absoluteString, "https://cdn/v.jpg")
    }

    func test_compose_pictures_and_videos_sorted_desc_by_createTime() {
        let pics: [MediaAsset] = [
            .init(assetId: 1, url: "https://cdn/p1.jpg", coverUrl: nil, vaild: 1, createTime: 100),
            .init(assetId: 2, url: "https://cdn/p2.jpg", coverUrl: nil, vaild: 1, createTime: 300),
        ]
        let vids: [MediaAsset] = [
            .init(assetId: 3, url: "https://cdn/v.mp4", coverUrl: "https://cdn/v.jpg", vaild: 1, createTime: 200),
        ]
        let items = AnchorMediaItem.compose(pictures: pics, videos: vids)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].id, "2-https://cdn/p2.jpg", "createTime 300 最新在前")
        XCTAssertEqual(items[1].kind, .video, "createTime 200 视频次之")
    }

    func test_compose_filters_invalid_and_missing_url() {
        let pics: [MediaAsset] = [
            .init(assetId: 1, url: nil, coverUrl: nil, vaild: 1, createTime: 100),          // 无 url 剔除
            .init(assetId: 2, url: "https://cdn/p2.jpg", coverUrl: nil, vaild: 3, createTime: 100),  // 被拒剔除
            .init(assetId: 3, url: "https://cdn/p3.jpg", coverUrl: nil, vaild: 1, createTime: 100),  // 保留
        ]
        let items = AnchorMediaItem.compose(pictures: pics, videos: nil)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.mediaUrl.absoluteString, "https://cdn/p3.jpg")
    }

    // MARK: - MessageAttachParser 双分支 attachType

    func test_extractAttachType_string() {
        let attach: [String: Any] = ["attachType": "SEND_GIFT"]
        XCTAssertEqual(MessageAttachParser.extractAttachType(attach), .string("SEND_GIFT"))
    }

    func test_extractAttachType_number() {
        let attach: [String: Any] = ["attachType": NSNumber(value: -4)]
        XCTAssertEqual(MessageAttachParser.extractAttachType(attach), .number(-4))
    }

    /// Bool 桥接排除（objCType 'c'/'B' = Bool，不算 number）
    func test_extractAttachType_bool_not_treated_as_number() {
        let attach: [String: Any] = ["attachType": NSNumber(value: true)]
        XCTAssertNil(MessageAttachParser.extractAttachType(attach))
    }

    func test_extractAttachType_missing_returns_nil() {
        XCTAssertNil(MessageAttachParser.extractAttachType(["other": "x"]))
    }

    func test_parseCustom_returns_system_with_rawJSON() {
        let attach: [String: Any] = ["attachType": "UNKNOWN_TYPE", "extra": "x"]
        let raw = "{\"attachType\":\"UNKNOWN_TYPE\"}"
        guard case .system(let rawJSON) = MessageAttachParser.parseCustom(attach, rawJSON: raw) else { return XCTFail() }
        XCTAssertTrue(rawJSON.contains("UNKNOWN_TYPE"))
    }
}
