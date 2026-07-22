import XCTest

/// CryptoUtil 加解密对齐 H5 的特征测试。
/// 待测源码（CryptoUtil/AppConfig 等）已通过 project.yml 的 HilyTests.sources 编进 HilyTests 模块，
/// 与测试代码同 module，无需 `@testable import`。
///
/// Test target config values are non-sensitive fixtures supplied by AppConfig.TestDefaults.
final class CryptoUtilTests: XCTestCase {

    // MARK: - MD5（大写十六进制）

    func testMD5Upper_emptyString_matchesRFC1321Vector() {
        XCTAssertEqual(CryptoUtil.md5Upper(""), "D41D8CD98F00B204E9800998ECF8427E")
    }

    func testMD5Upper_abc_matchesRFC1321Vector() {
        XCTAssertEqual(CryptoUtil.md5Upper("abc"), "900150983CD24FB0D6963F7D28E17F72")
    }

    func testMD5Upper_outputIsAlwaysUppercaseHex32() {
        let hex = CryptoUtil.md5Upper("any input \u{4e2d}\u{6587}")
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(hex, hex.uppercased())
        XCTAssertTrue(hex.allSatisfy { ("0"..."9").contains($0) || ("A"..."F").contains($0) })
    }

    // MARK: - 登录密码：MD5(MD5(password + appId))

    func testLoginPassword_isDoubleUppercaseMD5OfPasswordPlusAppId() {
        let pwd = "test123"
        let inner = CryptoUtil.md5Upper(pwd + AppConfig.appId)
        let expected = CryptoUtil.md5Upper(inner)
        XCTAssertEqual(CryptoUtil.loginPassword(pwd), expected)
    }

    func testLoginPassword_outputIs32UpperHex() {
        let hex = CryptoUtil.loginPassword("anyPwd")
        XCTAssertEqual(hex.count, 32)
        XCTAssertEqual(hex, hex.uppercased())
    }

    // MARK: - AES-128-CBC + PKCS7 + Base64（请求体加密）

    func testAESCBC_encryptDecryptRoundTrip_asciiPlainText() {
        let plain = "{\"foo\":\"bar\",\"n\":42}"
        guard let cipher = CryptoUtil.aesEncryptToBase64(plain) else {
            return XCTFail("\u{52a0}\u{5bc6}\u{8fd4}\u{56de} nil")
        }
        XCTAssertFalse(cipher.isEmpty)
        // base64 \u{5fc5}\u{987b}\u{4e0d}\u{542b}\u{660e}\u{6587}
        XCTAssertFalse(cipher.contains(plain))

        // \u{8d70}\u{53cd}\u{5411}\u{89e3}\u{5bc6}：Base64 \u{2192} Hex \u{2192} aesDecryptFromHex
        guard let cipherData = Data(base64Encoded: cipher) else {
            return XCTFail("base64 \u{89e3}\u{5305}\u{5931}\u{8d25}")
        }
        let hex = cipherData.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(CryptoUtil.aesDecryptFromHex(hex), plain)
    }

    func testAESCBC_encryptDecryptRoundTrip_unicodeAndEmptyJSON() {
        let cases = [
            "{}",
            "{\"k\":\"\u{4e2d}\u{6587}\u{6d4b}\u{8bd5}\"}",
            "{\"emoji\":\"\u{1F389}\u{1F525}\"}",
            String(repeating: "a", count: 1024)
        ]
        for plain in cases {
            guard let base64 = CryptoUtil.aesEncryptToBase64(plain),
                  let cipherData = Data(base64Encoded: base64) else {
                return XCTFail("\u{52a0}\u{5bc6}\u{5931}\u{8d25}: \(plain.prefix(20))")
            }
            let hex = cipherData.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(CryptoUtil.aesDecryptFromHex(hex), plain, "round-trip \u{4e0d}\u{4e00}\u{81f4}: \(plain.prefix(20))")
        }
    }

    func testAESCBC_encryptIsDeterministicWithFixedIV() {
        // CBC + \u{56fa}\u{5b9a} IV \u{2192} \u{540c}\u{660e}\u{6587}\u{52a0}\u{5bc6}\u{7ed3}\u{679c}\u{5fc5}\u{4e00}\u{81f4}（\u{8fd9}\u{662f} H5 \u{5b9e}\u{73b0}\u{7684}\u{73b0}\u{72b6}、\u{5bfb}\u{5168}使的是同一 IV）
        let plain = "{\"hello\":\"world\"}"
        XCTAssertEqual(CryptoUtil.aesEncryptToBase64(plain), CryptoUtil.aesEncryptToBase64(plain))
    }

    func testAESCBC_decryptInvalidHex_returnsNil() {
        XCTAssertNil(CryptoUtil.aesDecryptFromHex("zz"))  // \u{975e}\u{6cd5} hex \u{5b57}\u{7b26}
        XCTAssertNil(CryptoUtil.aesDecryptFromHex("abc")) // \u{5947}\u{6570}\u{957f}\u{5ea6}
    }

    // FIXME: \u{77ed}\u{4e8e}\u{4e00}\u{5757}\u{7684}\u{5408}\u{6cd5} hex（\u{5982} "ab"）\u{5f53}\u{524d} CCCrypt \u{4e0d}\u{62a5} kCCAlignmentError，\u{4f1a}\u{8fd4}\u{56de}\u{5783}\u{573e}\u{89e3}\u{6790}\u{7ed3}\u{679c}。
    // \u{6076}\u{610f}/\u{8131}\u{578b}\u{670d}\u{52a1}\u{7aef}\u{4e0b}\u{53ef}\u{80fd}\u{7a7f}\u{900f} APIClient \u{7684} guard。\u{5f85}\u{4e0b}\u{4e00}\u{8f6e}\u{4f9b}\u{8bc4}\u{4f30}：\u{8981}\u{4e48}\u{4fee}\u{5728} crypt() \u{91cc}\u{52a0}\u{957f}\u{5ea6}\u{6821}\u{9a8c}，\u{8981}\u{4e48}\u{5728} APIClient \u{7684} envelope \u{89e3}\u{5bc6}\u{5904} guard。

    // MARK: - AES-128-ECB + PKCS7 + Hex（WebSocket \u{63e1}\u{624b}\u{4e13}\u{7528}，\u{4e0d}\u{8d70} aesKey/aesIV）

    func testAESECB_encryptToHex_isDeterministicForSameInput() {
        let plain = "{\"uid\":\"123\"}"
        XCTAssertEqual(CryptoUtil.aesEncryptECBToHex(plain), CryptoUtil.aesEncryptECBToHex(plain))
    }

    func testAESECB_encryptToHex_lengthIsMultipleOf32() {
        // ECB+PKCS7：\u{8f93}\u{51fa} = \u{6574}\u{6570}\u{4e2a} 16B \u{5757} \u{2192} hex \u{957f}\u{5ea6} = 32n
        for plain in ["a", "ab", String(repeating: "x", count: 15), String(repeating: "x", count: 16)] {
            let hex = CryptoUtil.aesEncryptECBToHex(plain) ?? ""
            XCTAssertFalse(hex.isEmpty, "\u{52a0}\u{5bc6}\u{8f93}\u{51fa}\u{4e3a}\u{7a7a}: \(plain.count)B")
            XCTAssertEqual(hex.count % 32, 0, "hex \u{957f}\u{5ea6} \(hex.count) \u{975e} 32 \u{500d}\u{6570}: \(plain.count)B")
            XCTAssertEqual(hex, hex.lowercased(), "ECB \u{6d41}\u{5e94}\u{8f93}\u{51fa}\u{5c0f}\u{5199} hex \u{5bf9}\u{9f50} H5")
        }
    }

    func testAESECB_encryptWithDifferentKey_producesDifferentCipher() {
        let plain = "{\"x\":1}"
        let a = CryptoUtil.aesEncryptECBToHex(plain, key: "test-ws-key-1234")
        let b = CryptoUtil.aesEncryptECBToHex(plain, key: "1234567890abcdef")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        XCTAssertNotEqual(a, b)
    }

    func testAESECB_keyOfWrongLength_returnsNil() {
        // AES-128 \u{5fc5}\u{987b} 16B \u{952e}；\u{4f20}\u{77ed}\u{952e}\u{5e94}\u{8fd4}\u{56de} nil
        XCTAssertNil(CryptoUtil.aesEncryptECBToHex("hi", key: "shortkey"))
    }

    // MARK: - Data(hexString:) \u{6269}\u{5c55}

    func testHexStringInit_parsesUppercaseAndLowercase() {
        XCTAssertEqual(Data(hexString: "00ff"), Data([0x00, 0xff]))
        XCTAssertEqual(Data(hexString: "00FF"), Data([0x00, 0xff]))
        XCTAssertEqual(Data(hexString: "DeAdBeEf"), Data([0xde, 0xad, 0xbe, 0xef]))
        XCTAssertEqual(Data(hexString: ""), Data())
    }

    func testHexStringInit_rejectsOddLengthAndInvalidChars() {
        XCTAssertNil(Data(hexString: "abc"))   // \u{5947}\u{6570}\u{957f}\u{5ea6}
        XCTAssertNil(Data(hexString: "gg"))    // \u{975e} hex \u{5b57}\u{7b26}
        XCTAssertNil(Data(hexString: "0z"))    // \u{6df7}\u{5408}
    }
}
