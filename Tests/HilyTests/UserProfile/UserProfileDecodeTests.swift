import XCTest

/// H-0 用户详情 decode 边界单测（spec §2.3 5 路 fallback + thumbs 派生 + 严格契约）。
///
/// 覆盖 spec §4 关键反向：
/// - R-2 result=null
/// - R-4 thumbs 缺失/非数组/单元素
/// - R-21 followed 缺失默认 false
/// - R-9（类比 BlocklistItem fail-loud）userId 类型偏移
/// - countryId vs country 字段（red team #2 落地：H5 dead fallback 不参）
/// - isBlocked 三态 nil/0/1
final class UserProfileDecodeTests: XCTestCase {

    // MARK: - Fallback 路径 1：null 字面量（R-2）

    func test_decodeDetail_fromNullLiteral_returnsNil() {
        let data = Data("null".utf8)
        XCTAssertNil(UserProfileService.decodeDetail(from: data))
    }

    // MARK: - Fallback 路径 2：顶层对象含 userId

    func test_decodeDetail_fromTopLevelObject_decodesCoreFields() {
        let json = """
        {
          "userId": "100001",
          "nickname": "Alice",
          "icon": "https://example.com/avatar.jpg",
          "gender": 2,
          "age": 24,
          "countryId": "US",
          "connRate": "85%",
          "yxAccid": "yx_100001",
          "followed": true,
          "isBlocked": 0
        }
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.userId, "100001")
        XCTAssertEqual(d?.nickname, "Alice")
        XCTAssertEqual(d?.icon, "https://example.com/avatar.jpg")
        XCTAssertEqual(d?.gender, 2)
        XCTAssertEqual(d?.age, 24)
        XCTAssertEqual(d?.countryId, "US")
        XCTAssertEqual(d?.connRate, "85%")
        XCTAssertEqual(d?.yxAccid, "yx_100001")
        XCTAssertEqual(d?.followed, true)
        XCTAssertEqual(d?.isBlocked, 0)
    }

    // MARK: - Fallback 路径 3：wrapped 字典

    func test_decodeDetail_fromWrappedDataKey_extracts() {
        let json = """
        {"data": {"userId":"1","nickname":"B"}}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.userId, "1")
        XCTAssertEqual(d?.nickname, "B")
    }

    func test_decodeDetail_fromWrappedResultKey_extracts() {
        let json = """
        {"result": {"userId":"2","nickname":"C"}}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.userId, "2")
    }

    func test_decodeDetail_fromWrappedProfileKey_extracts() {
        let json = """
        {"profile": {"userId":"3","nickname":"D"}}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.userId, "3")
    }

    func test_decodeDetail_fromWrappedUserKey_extracts() {
        let json = """
        {"user": {"userId":"4","nickname":"E"}}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.userId, "4")
    }

    // MARK: - Fallback 路径 4：顶层字典但无识别 key → nil + warn

    func test_decodeDetail_fromDictWithoutKnownKeys_returnsNil() {
        let json = """
        {"foo":"bar","total":0}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(json.utf8)),
                     "未知字典形态 → nil（让 step 3 反悔暴露）")
    }

    // MARK: - Fallback 路径 5：非 JSON

    func test_decodeDetail_fromGarbage_returnsNil() {
        XCTAssertNil(UserProfileService.decodeDetail(from: Data("not-json".utf8)))
    }

    // MARK: - userId String/Int 兼容（spec v3 修订，trial #3 step 3 真机反悔 #1）

    func test_decodeDetail_userIdAsInt_convertsToString() {
        // 真接口返 number (__NSCFNumber)，参 LiveListAnchor 同款兼容（H5 type.ts 类型声明不是真契约）
        let json = """
        {"userId":1000001877,"nickname":"Alice"}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.userId, "1000001877",
                       "userId Int 应转 String 兼容（spec v3）")
    }

    func test_decodeDetail_userIdAsLargeInt_convertsToString() {
        // 超过 Int32 范围验证 Int64 桥接
        let json = """
        {"userId":9999999999,"nickname":"X"}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.userId, "9999999999")
    }

    func test_decodeDetail_userIdAsBool_rejected() {
        // NSNumber 桥接陷阱：true/false 也匹配 NSNumber，但 objCType="c" 应排除
        let json = """
        {"userId":true,"nickname":"X"}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(json.utf8)),
                     "userId=Bool 应拒绝（cType c/B 排除）")
    }

    func test_decodeDetail_userIdMissing_returnsNil() {
        let json = """
        {"nickname":"NoUserId"}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(json.utf8)))
    }

    func test_decodeDetail_userIdEmptyString_returnsNil() {
        let json = """
        {"userId":"","nickname":"Empty"}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(json.utf8)),
                     "userId 空串视同非法")
    }

    // MARK: - thumbs 派生（R-4）

    func test_decodeDetail_thumbsAbsent_likesFavoriteZero() {
        let json = """
        {"userId":"1","nickname":"A"}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 0)
        XCTAssertEqual(d?.favorite, 0)
    }

    func test_decodeDetail_thumbsEmptyArray_likesFavoriteZero() {
        let json = """
        {"userId":"1","nickname":"A","thumbs":[]}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 0)
        XCTAssertEqual(d?.favorite, 0)
    }

    func test_decodeDetail_thumbsNotArray_likesFavoriteZero() {
        let json = """
        {"userId":"1","nickname":"A","thumbs":"not-array"}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 0)
        XCTAssertEqual(d?.favorite, 0)
    }

    func test_decodeDetail_thumbsOnlyOneItem_favoriteZero() {
        let json = """
        {"userId":"1","nickname":"A","thumbs":[{"num":100}]}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 100)
        XCTAssertEqual(d?.favorite, 0)
    }

    func test_decodeDetail_thumbsBothPresent_decodesLikeAndFavorite() {
        let json = """
        {"userId":"1","nickname":"A","thumbs":[{"num":1234},{"num":56}]}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 1234)
        XCTAssertEqual(d?.favorite, 56)
    }

    func test_decodeDetail_thumbsNumMissingOrNonInt_zero() {
        let json = """
        {"userId":"1","nickname":"A","thumbs":[{"foo":"bar"},{"num":"notInt"}]}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertEqual(d?.like, 0, "num 缺失 → 0")
        XCTAssertEqual(d?.favorite, 0, "num 非 Int → 0")
    }

    // MARK: - followed 字段（R-21 + red team #1）

    func test_decodeDetail_followedAbsent_defaultsFalse() {
        let json = """
        {"userId":"1","nickname":"A"}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.followed, false)
    }

    func test_decodeDetail_followedAsInt_failsTo_false() {
        // H5 模板用 followFlag === 1 是 bug；iOS 严格按契约 followed: Bool
        // 给 Int 视为契约偏移 → false 兜底（不抛错避免影响其他字段）
        let json = """
        {"userId":"1","nickname":"A","followed":1}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.followed, false)
    }

    func test_decodeDetail_followedAsBool_decoded() {
        let trueJson = """
        {"userId":"1","nickname":"A","followed":true}
        """
        let falseJson = """
        {"userId":"1","nickname":"A","followed":false}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(trueJson.utf8))?.followed, true)
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(falseJson.utf8))?.followed, false)
    }

    // MARK: - countryId vs country (red team #2 落地)

    func test_decodeDetail_countryIdPresent_used() {
        let json = """
        {"userId":"1","nickname":"A","countryId":"US"}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.countryId, "US")
    }

    func test_decodeDetail_onlyCountryFieldPresent_ignored() {
        // H5 模板 country || countryId 是 dead fallback；iOS 只看 countryId
        let json = """
        {"userId":"1","nickname":"A","country":"Canada"}
        """
        let d = UserProfileService.decodeDetail(from: Data(json.utf8))
        XCTAssertNil(d?.countryId, "country 字段不在 type.ts 契约里，iOS 不解析")
    }

    // MARK: - isBlocked 三态（R-22）

    func test_decodeDetail_isBlockedNullOrAbsent_nil() {
        let absent = """
        {"userId":"1","nickname":"A"}
        """
        let nullVal = """
        {"userId":"1","nickname":"A","isBlocked":null}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(absent.utf8))?.isBlocked)
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(nullVal.utf8))?.isBlocked)
    }

    func test_decodeDetail_isBlockedZero_decodedAs0() {
        let json = """
        {"userId":"1","nickname":"A","isBlocked":0}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.isBlocked, 0)
    }

    func test_decodeDetail_isBlockedOne_decodedAs1() {
        let json = """
        {"userId":"1","nickname":"A","isBlocked":1}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.isBlocked, 1)
    }

    // MARK: - giftList 解析（trial #3 反悔 #7）

    func test_decodeDetail_giftListAbsent_emptyArray() {
        let json = """
        {"userId":"1","nickname":"A"}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.giftList.count, 0)
    }

    func test_decodeDetail_giftListWithFullFields_decoded() {
        let json = """
        {"userId":"1","nickname":"A","giftList":[
          {"giftId":100,"giftImg":"https://img.com/a.png","giftName":"Rose","giftCount":12},
          {"giftId":200,"icon":"https://img.com/b.png","giftName":"Heart","num":5}
        ]}
        """
        let gifts = UserProfileService.decodeDetail(from: Data(json.utf8))?.giftList ?? []
        XCTAssertEqual(gifts.count, 2)
        XCTAssertEqual(gifts[0].giftId, 100)
        XCTAssertEqual(gifts[0].iconUrl, "https://img.com/a.png", "giftImg 优先")
        XCTAssertEqual(gifts[0].name, "Rose")
        XCTAssertEqual(gifts[0].count, 12, "giftCount 优先")
        XCTAssertEqual(gifts[1].giftId, 200)
        XCTAssertEqual(gifts[1].iconUrl, "https://img.com/b.png", "icon fallback")
        XCTAssertEqual(gifts[1].count, 5, "num fallback")
    }

    func test_decodeDetail_giftListMissingGiftId_skipped() {
        let json = """
        {"userId":"1","nickname":"A","giftList":[
          {"giftName":"NoId","giftCount":1},
          {"giftId":100,"giftName":"Valid","giftCount":2}
        ]}
        """
        let gifts = UserProfileService.decodeDetail(from: Data(json.utf8))?.giftList ?? []
        XCTAssertEqual(gifts.count, 1)
        XCTAssertEqual(gifts[0].giftId, 100)
    }

    func test_decodeDetail_giftListEmptyArray_emptyArray() {
        let json = """
        {"userId":"1","nickname":"A","giftList":[]}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.giftList.count, 0)
    }

    func test_decodeDetail_giftIdAsString_converted() {
        let json = """
        {"userId":"1","nickname":"A","giftList":[
          {"giftId":"100","giftName":"X","giftCount":1}
        ]}
        """
        let gifts = UserProfileService.decodeDetail(from: Data(json.utf8))?.giftList ?? []
        XCTAssertEqual(gifts.first?.giftId, 100, "giftId String 转 Int")
    }

    // MARK: - guardianList 解析（H5 getUserDetail 内嵌字段）

    func test_decodeDetail_guardianList_decodesEmbeddedAnchorsWithFlexibleId() {
        let json = """
        {
          "userId": 100,
          "guardianList": [
            { "anchorId": 200, "anchorNickname": "Gold Host", "anchorIcon": "https://example.com/gold.png", "levelCode": 3 },
            { "anchorId": "201", "anchorNickname": "Silver Host", "anchorIcon": "https://example.com/silver.png", "levelCode": 2 },
            { "anchorId": null, "anchorNickname": "Invalid" }
          ]
        }
        """

        let guardians = UserProfileService.decodeDetail(from: Data(json.utf8))?.guardianList

        XCTAssertEqual(guardians?.map(\.anchorId), ["200", "201"])
        XCTAssertEqual(guardians?.first?.nickname, "Gold Host")
        XCTAssertEqual(guardians?.last?.iconURL, "https://example.com/silver.png")
    }

    // MARK: - connRate 类型宽松收 String

    func test_decodeDetail_connRateAsString() {
        let json = """
        {"userId":"1","nickname":"A","connRate":"85%"}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.connRate, "85%")
    }

    func test_decodeDetail_connRateAsInt_convertedToString() {
        let json = """
        {"userId":"1","nickname":"A","connRate":85}
        """
        XCTAssertEqual(UserProfileService.decodeDetail(from: Data(json.utf8))?.connRate, "85")
    }

    func test_decodeDetail_connRateAbsent_nil() {
        let json = """
        {"userId":"1","nickname":"A"}
        """
        XCTAssertNil(UserProfileService.decodeDetail(from: Data(json.utf8))?.connRate)
    }
}
