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

    /// 加密 JSON 字符串 → Base64（请求体）
    static func aesEncryptToBase64(_ plain: String) -> String? {
        guard let input = plain.data(using: .utf8),
              let out = crypt(data: input, operation: kCCEncrypt) else { return nil }
        return out.base64EncodedString()
    }

    /// Hex 密文 → 解密为字符串（响应体 result）
    static func aesDecryptFromHex(_ hex: String) -> String? {
        guard let input = Data(hexString: hex),
              let out = crypt(data: input, operation: kCCDecrypt) else { return nil }
        return String(data: out, encoding: .utf8)
    }

    private static func crypt(data: Data, operation: Int) -> Data? {
        let keyData = Data(AppConfig.aesKey.utf8)
        let ivData = Data(AppConfig.aesIV.utf8)
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
}

extension Data {
    /// 十六进制字符串 → Data
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            data.append(byte)
            i += 2
        }
        self = data
    }
}
