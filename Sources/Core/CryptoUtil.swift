import Foundation
import CommonCrypto
import CryptoKit

/// 与 H5 对齐的加解密工具。
/// - 请求体：AES-128-CBC + PKCS7 → Base64（对应 crypto.js 的 aesHexEncrypt，encrypted.toString() 默认 Base64）
/// - 响应体 result：Hex 密文 → AES 解密（对应 aesHexDecrypt，Hex.parse）
/// - 密码：两次大写 MD5
enum CryptoUtil {

    // MARK: - MD5（大写十六进制）

    static func md5Upper(_ text: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// 登录密码：MD5(MD5(password + appId))，两次均大写
    static func loginPassword(_ password: String) -> String {
        md5Upper(md5Upper(password + AppConfig.appId))
    }

    // MARK: - AES-128-CBC

    /// 加密 JSON 字符串 → Base64（请求体，主接口默认 key/iv）
    static func aesEncryptToBase64(_ plain: String) -> String? {
        aesEncryptToBase64(plain, key: AppConfig.aesKey, iv: AppConfig.aesIV)
    }

    /// Hex 密文 → 解密为字符串（响应体 result，主接口默认 key/iv）
    static func aesDecryptFromHex(_ hex: String) -> String? {
        aesDecryptFromHex(hex, key: AppConfig.aesKey, iv: AppConfig.aesIV)
    }

    /// 参数化加密：sapi 用独立 key/iv（H5 .env VITE_AES_KEY_BAGSHOP_URL / VITE_AES_IV_BAGSHOP_URL）
    static func aesEncryptToBase64(_ plain: String, key: String, iv: String) -> String? {
        guard let input = plain.data(using: .utf8),
              let out = crypt(data: input, operation: kCCEncrypt, key: key, iv: iv) else { return nil }
        return out.base64EncodedString()
    }

    /// 参数化解密：sapi 响应 result Hex 用独立 key/iv
    static func aesDecryptFromHex(_ hex: String, key: String, iv: String) -> String? {
        guard let input = Data(hexString: hex),
              let out = crypt(data: input, operation: kCCDecrypt, key: key, iv: iv) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func crypt(data: Data, operation: Int, key: String, iv: String) -> Data? {
        let keyData = Data(key.utf8)
        let ivData = Data(iv.utf8)
        guard keyData.count == kCCKeySizeAES128, ivData.count == kCCBlockSizeAES128 else { return nil }

        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesCrypted = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    ivData.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(operation),
                                CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, keyData.count,
                                ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                bufferPtr.baseAddress, bufferSize,
                                &numBytesCrypted)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.removeSubrange(numBytesCrypted..<buffer.count)
        return buffer
    }

    // MARK: - AES-128-ECB（Hex 输出）—— 专给 WebSocket 握手用
    //
    // ⚠️ 与主接口的 CBC+Base64 完全是两套不同的 AES：
    //   H5 src/utils/index.js:361 encryptAes(data):
    //     key='9976kk4322578894'（不是主接口的 9986…）
    //     mode=ECB（不是 CBC，故无 IV）
    //     输出 encrypted.ciphertext.toString() = 小写 Hex（不是 Base64）
    // 注：H5 那里写了 `iv: srcs` 看似传了 IV，但 CryptoJS ECB 模式会**忽略**该参数，实际行为等价于
    // "无 IV"。本端 CCCrypt 传 nil IV 与 H5 ECB 实际行为完全等价。
    // 接入点：仅 WSHeartbeat 握手时的 ciphertext query 参数用。
    // 密钥由 xcconfig 注入到 Info.plist，AppConfig.wsAesKey 兜底回 dev 默认值。

    static func aesEncryptECBToHex(_ plain: String, key: String = AppConfig.wsAesKey) -> String? {
        guard let input = plain.data(using: .utf8) else { return nil }
        let keyData = Data(key.utf8)
        guard keyData.count == kCCKeySizeAES128 else { return nil }

        let bufferSize = input.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var numBytesCrypted = 0

        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            input.withUnsafeBytes { dataPtr in
                keyData.withUnsafeBytes { keyPtr in
                    CCCrypt(CCOperation(kCCEncrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode | kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, keyData.count,
                            nil,  // ECB 不用 IV
                            dataPtr.baseAddress, input.count,
                            bufferPtr.baseAddress, bufferSize,
                            &numBytesCrypted)
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.removeSubrange(numBytesCrypted..<buffer.count)
        return buffer.map { String(format: "%02x", $0) }.joined()
    }
}

extension Data {
    /// 十六进制字符串 → Data。
    /// 按 UTF-8 字节切而非 `[Character]`：Character 可能是多字节字位簇，含非 ASCII 时
    /// `chars[i...i+1]` 会越界 / 取错字符。hex 只含 ASCII，按字节切既安全又快。
    init?(hexString: String) {
        let bytes = Array(hexString.utf8)
        guard bytes.count % 2 == 0 else { return nil }
        var data = Data(capacity: bytes.count / 2)
        for i in stride(from: 0, to: bytes.count, by: 2) {
            let hi = Self.hexNibble(bytes[i])
            let lo = Self.hexNibble(bytes[i + 1])
            guard hi >= 0, lo >= 0 else { return nil }
            data.append(UInt8(hi << 4 | lo))
        }
        self = data
    }

    private static func hexNibble(_ b: UInt8) -> Int {
        switch b {
        case 0x30...0x39: return Int(b - 0x30)               // 0–9
        case 0x41...0x46: return Int(b - 0x41) + 10          // A–F
        case 0x61...0x66: return Int(b - 0x61) + 10          // a–f
        default: return -1
        }
    }
}
