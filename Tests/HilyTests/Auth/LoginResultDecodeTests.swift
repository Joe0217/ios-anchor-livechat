import XCTest

final class LoginResultDecodeTests: XCTestCase {
    func testDecodesNumericAndStringAuditStateFields() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "userType": "1",
          "valid": "1",
          "onReview": 1,
          "banAlways": "0",
          "bannedSubType": "24"
        }
        """.utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.userType, 1)
        XCTAssertEqual(result.valid, 1)
        XCTAssertEqual(result.onReview, true)
        XCTAssertEqual(result.banAlways, false)
        XCTAssertEqual(result.bannedSubType, 24)
    }

    func testDecodesPermissionVideoFromLoginPicListAndPersistsIt() throws {
        let data = Data("""
        {
          "userId": "7",
          "token": "token",
          "picList": [
            { "id": "11", "mediaType": "1", "mediaUrl": "https://cdn.example.com/photo.jpg" },
            { "id": 12, "mediaType": "1", "mediaUrl": "  \(ReviewAccountModePolicy.placeholderReviewVideoURL)  " }
          ]
        }
        """.utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.userId, 7)
        XCTAssertTrue(result.permissionVideoURLs.isEmpty)
        XCTAssertEqual(result.permissionModeMediaURLs.count, 2)
        XCTAssertEqual(
            ReviewAccountModePolicy.effectiveUserType(userInfo: result),
            107
        )

        let cached = try JSONDecoder().decode(
            LoginResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(cached.permissionModeMediaURLs, result.permissionModeMediaURLs)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: cached), 107)
    }

    func testDecodesPlaceholderFromLegacyVideoURLAlias() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "videos": [
            { "url": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)", "coverUrl": "https://cdn.example.com/cover.jpg" }
          ]
        }
        """.utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.permissionModeMediaURLs, [ReviewAccountModePolicy.placeholderReviewVideoURL])
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: result), 107)
    }

    func testNetworkDecodePreservesPlaceholderEvidenceWhenPicListContainsMalformedItems() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "picList": [
            42,
            { "unexpectedMediaPath": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)" }
          ]
        }
        """.utf8)

        let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

        XCTAssertTrue(result.isReviewModeResolved)
        XCTAssertEqual(result.reviewPlaceholderVideoMatched, true)
        XCTAssertTrue(result.permissionModeMediaURLs.isEmpty)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: result), 107)

        let restored = try JSONDecoder().decode(
            LoginResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertEqual(restored.reviewPlaceholderVideoMatched, true)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: restored), 107)
    }

    func testNetworkDecodeWithMissingProfileMediaStaysUnresolvedAnd107() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "latestIconAndCallVideo": [
            { "businessType": 3, "mediaUrl": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)" }
          ]
        }
        """.utf8)

        let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

        XCTAssertNil(result.reviewPlaceholderVideoMatched)
        XCTAssertFalse(result.isReviewModeResolved)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: result), 107)

        let restored = try JSONDecoder().decode(
            LoginResult.self,
            from: JSONEncoder().encode(result)
        )
        XCTAssertFalse(restored.isReviewModeResolved)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: restored), 107)
    }

    func testLegacyCachedResolvedFalseWithoutMediaStays107() throws {
        let cached = try JSONDecoder().decode(
            LoginResult.self,
            from: Data("""
            {
              "userId": 7,
              "token": "token",
              "reviewPlaceholderVideoMatched": false,
              "reviewModeResolved": true
            }
            """.utf8)
        )

        XCTAssertFalse(cached.isReviewModeResolved)
        XCTAssertNil(cached.resolvedReviewPlaceholderMatch)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: cached), 107)
    }

    func testPreviousEvidenceVersionCannotOpenFullModeWithoutMedia() throws {
        let cached = try JSONDecoder().decode(
            LoginResult.self,
            from: Data("""
            {
              "userId": 7,
              "token": "token",
              "reviewPlaceholderVideoMatched": false,
              "reviewModeResolved": true,
              "reviewModeEvidenceVersion": 1
            }
            """.utf8)
        )

        XCTAssertFalse(cached.isReviewModeResolved)
        XCTAssertNil(cached.resolvedReviewPlaceholderMatch)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: cached), 107)
    }

    func testNetworkDecodeWithExplicitEmptyMediaIsResolvedFullMode() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "picList": []
        }
        """.utf8)

        let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

        XCTAssertEqual(result.reviewModeResolved, true)
        XCTAssertEqual(result.reviewPlaceholderVideoMatched, false)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: result), 2)
    }

    func testNetworkDecodeWithMalformedMediaNeverOpensFullMode() throws {
        let malformedValues = ["[{}]", "[null]", "[\"\"]", "\"\""]

        for malformedValue in malformedValues {
            let data = Data("""
            {
              "userId": 7,
              "token": "token",
              "picList": \(malformedValue)
            }
            """.utf8)

            let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

            XCTAssertFalse(result.isReviewModeResolved, "value=\(malformedValue)")
            XCTAssertEqual(
                ReviewAccountModePolicy.effectiveUserType(userInfo: result),
                107,
                "value=\(malformedValue)"
            )
        }
    }

    func testMalformedLoginMediaStaysUnresolvedAfterSessionPersistence() throws {
        let result = try LoginResult.decodeNetworkResponse(
            from: Data("""
            {
              "userId": 7,
              "token": "token",
              "picList": [{}]
            }
            """.utf8),
            source: "test"
        )
        let restored = try JSONDecoder().decode(
            LoginResult.self,
            from: JSONEncoder().encode(result)
        )

        XCTAssertNotNil(restored.picList)
        XCTAssertFalse(restored.isReviewModeResolved)
        XCTAssertNil(restored.resolvedReviewPlaceholderMatch)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: restored), 107)
    }

    func testNetworkDecodeKeepsCanonicalOnlyURLInFullMode() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "picList": [
            { "mediaUrl": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)?signature=test" }
          ]
        }
        """.utf8)

        let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

        XCTAssertEqual(result.reviewPlaceholderVideoMatched, false)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: result), 2)
    }

    func testSubmittedPlaceholderIsIncludedWhenRegisterResponseOnlyContainsStringPhotos() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "picList": ["https://cdn.example.com/photo.jpg"]
        }
        """.utf8)
        let result = try LoginResult.decodeNetworkResponse(from: data, source: "test")

        let sessionResult = result.includingSubmittedPermissionVideoURLs([
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ])

        XCTAssertEqual(sessionResult.videos, [ReviewAccountModePolicy.placeholderReviewVideoURL])
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: sessionResult), 107)
    }

    func testSubmittedRealVideoOverridesStalePlaceholderInRegisterResponse() throws {
        let data = Data("""
        {
          "userId": 7,
          "token": "token",
          "picList": [
            { "mediaUrl": "https://cdn.example.com/photo.jpg", "mediaType": 1 },
            { "mediaUrl": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)", "mediaType": 2 }
          ],
          "videos": ["\(ReviewAccountModePolicy.placeholderReviewVideoURL)"]
        }
        """.utf8)
        let response = try LoginResult.decodeNetworkResponse(from: data, source: "test")
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: response), 107)

        let submittedVideo = "https://cdn.example.com/new-recording.mp4"
        let sessionResult = response.includingSubmittedPermissionVideoURLs([submittedVideo])

        XCTAssertEqual(sessionResult.reviewPlaceholderVideoMatched, false)
        XCTAssertEqual(sessionResult.videos, [submittedVideo])
        XCTAssertFalse(sessionResult.permissionModeMediaURLs.contains(
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ))
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: sessionResult), 2)
    }

    func testRegistrationVideoFallbackOnlyFillsMissingResponseMedia() throws {
        let missingMedia = try JSONDecoder().decode(
            LoginResult.self,
            from: Data("{ \"userId\": 7, \"token\": \"token\" }".utf8)
        )
        let filled = missingMedia.usingPermissionVideoURLsIfMissing([
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ])
        XCTAssertFalse(missingMedia.hasPermissionVideoInfo)
        XCTAssertFalse(missingMedia.isReviewModeResolved)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: missingMedia), 107)
        XCTAssertTrue(filled.hasPermissionVideoInfo)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: filled), 107)

        let resolvedEmpty = missingMedia.resolvingPermissionVideoURLs([])
        XCTAssertTrue(resolvedEmpty.isReviewModeResolved)
        XCTAssertEqual(resolvedEmpty.reviewPlaceholderVideoMatched, false)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: resolvedEmpty), 2)

        let responseMedia = try JSONDecoder().decode(
            LoginResult.self,
            from: Data("{ \"userId\": 7, \"token\": \"token\", \"videos\": [\"https://cdn.example.com/real.mp4\"] }".utf8)
        )
        let unchanged = responseMedia.usingPermissionVideoURLsIfMissing([
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ])
        XCTAssertEqual(unchanged.permissionVideoURLs, ["https://cdn.example.com/real.mp4"])
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: unchanged), 2)

        let knownEmptyMedia = try JSONDecoder().decode(
            LoginResult.self,
            from: Data("{ \"userId\": 7, \"token\": \"token\", \"videos\": [] }".utf8)
        )
        let knownEmptyUnchanged = knownEmptyMedia.usingPermissionVideoURLsIfMissing([
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ])
        XCTAssertTrue(knownEmptyUnchanged.hasPermissionVideoInfo)
        XCTAssertTrue(knownEmptyUnchanged.permissionVideoURLs.isEmpty)
        XCTAssertEqual(ReviewAccountModePolicy.effectiveUserType(userInfo: knownEmptyUnchanged), 2)
    }

    func testFallsBackFromTypeWhenUserTypeIsAbsent() throws {
        let data = Data("{ \"token\": \"token\", \"type\": \"2\", \"onReview\": false }".utf8)

        let result = try JSONDecoder().decode(LoginResult.self, from: data)

        XCTAssertEqual(result.userType, 2)
        XCTAssertEqual(result.type, 2)
        XCTAssertEqual(result.onReview, false)
    }

    func testMissingRoleFieldsRemainNilForFailClosedRouting() throws {
        let result = try JSONDecoder().decode(LoginResult.self, from: Data("{ \"token\": \"token\" }".utf8))

        XCTAssertNil(result.userType)
        XCTAssertNil(result.type)
    }

    func testDecodesRefreshedAnchorAuditState() throws {
        let data = Data("""
        {
          "userId": "7",
          "userType": "2",
          "valid": "1",
          "onReview": 0,
          "banAlways": 1,
          "bannedSubType": "12"
        }
        """.utf8)

        let result = try JSONDecoder().decode(AnchorInfo.self, from: data)

        XCTAssertEqual(result.userId, 7)
        XCTAssertEqual(result.userType, 2)
        XCTAssertEqual(result.valid, 1)
        XCTAssertEqual(result.onReview, false)
        XCTAssertEqual(result.banAlways, true)
        XCTAssertEqual(result.bannedSubType, 12)
    }

    func testProfilePermissionEvidenceRejectsMalformedItemsButAcceptsExplicitEmpty() throws {
        let explicitEmpty = try JSONDecoder().decode(
            AnchorInfo.self,
            from: Data("{ \"userId\": \"7\", \"picList\": [] }".utf8)
        )
        XCTAssertEqual(explicitEmpty.permissionVideoEvidence, [])

        let malformed = try JSONDecoder().decode(
            AnchorInfo.self,
            from: Data("{ \"userId\": 7, \"picList\": [{}] }".utf8)
        )
        XCTAssertNil(malformed.permissionVideoEvidence)

        let placeholder = try JSONDecoder().decode(
            AnchorInfo.self,
            from: Data("""
            {
              "userId": 7,
              "picList": [
                {},
                {
                  "id": "11",
                  "mediaType": "1",
                  "mediaUrl": "\(ReviewAccountModePolicy.placeholderReviewVideoURL)",
                  "vaild": "1"
                }
              ]
            }
            """.utf8)
        )
        XCTAssertTrue(
            placeholder.permissionVideoEvidence?
                .contains(ReviewAccountModePolicy.placeholderReviewVideoURL) == true
        )
        XCTAssertEqual(placeholder.picList?.last?.assetId, 11)
        XCTAssertEqual(placeholder.picList?.last?.mediaType, 1)
        XCTAssertEqual(placeholder.picList?.last?.vaild, 1)
    }

    func testFreshProfilePermissionEvidenceResolvesFirstLoginWithoutChangingMedia() throws {
        let unresolved = try LoginResult.decodeNetworkResponse(
            from: Data("{ \"userId\": 7, \"token\": \"token\" }".utf8),
            source: "test"
        )

        let fullMode = unresolved.applyingFreshProfilePermissionEvidence([])
        XCTAssertTrue(fullMode.isReviewModeResolved)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: fullMode), 2)
        XCTAssertNil(fullMode.videos)
        XCTAssertNil(fullMode.picList)

        let reviewMode = unresolved.applyingFreshProfilePermissionEvidence([
            ReviewAccountModePolicy.placeholderReviewVideoURL
        ])
        XCTAssertTrue(reviewMode.isReviewModeResolved)
        XCTAssertEqual(UserTypeExperience.effectiveUserType(userInfo: reviewMode), 107)
        XCTAssertNil(reviewMode.videos)
        XCTAssertNil(reviewMode.picList)
    }
}
