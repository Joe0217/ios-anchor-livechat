import Foundation
import Compression

/// gzip 解压工具（用于派对房 `1001 UPDATE_PARTY_ROOM_SEAT` 与 `2049 RECEIVE_PARTY_ROOM_GIFT_COMPRESSED`）。
///
/// gzip 格式：固定 10 字节头（魔术字 `0x1f 0x8b` + 压缩方法 + FLG + mtime + xflg + os）
/// + 可选字段（FEXTRA / FNAME / FCOMMENT / FHCRC，按 FLG 字段位决定是否出现）
/// + raw deflate 流
/// + 8 字节 trailer（CRC32 + ISIZE）。
///
/// 系统 `Compression` 框架的 `COMPRESSION_ZLIB` 是 raw deflate（RFC 1951），不直接支持 gzip 容器。
/// 本工具：拆 gzip 头 + 跳过可选字段 + 去尾 8 字节 trailer → 喂 raw deflate 给系统 API。
///
/// **真实帧字节布局待 M3 抓包确认（spec §1.5 #5）**：
/// - 如服务端送的是 base64(gzip(json))，调用方先 `Data(base64Encoded:)` 再调本工具
/// - 如压缩比 >8（buffer 不够），自动按 2× 扩容重试（最多 4 次）
enum GzipDecompressor {
    enum DecompressError: Error, LocalizedError {
        case invalidHeader
        case decodeFailed
        case bufferTooSmall

        var errorDescription: String? {
            switch self {
            case .invalidHeader: return "gzip: header 非法"
            case .decodeFailed: return "gzip: 解压失败"
            case .bufferTooSmall: return "gzip: 输出缓冲区不足"
            }
        }
    }

    /// 解压一段 gzip 字节流为原始数据。
    /// 输入既支持完整 gzip 容器（含 `0x1f 0x8b` 头），也支持 raw deflate（无头）。
    static func decompress(_ data: Data) throws -> Data {
        let (deflateStart, deflateEnd) = try stripGzipFraming(data)
        let body = data.subdata(in: deflateStart..<deflateEnd)
        return try inflateRawDeflate(body)
    }

    // MARK: - gzip framing

    /// 返回 raw deflate 起始 offset 与 end offset（不含 trailer）。
    /// 无 gzip 头时整段都视为 raw deflate。
    private static func stripGzipFraming(_ data: Data) throws -> (start: Int, end: Int) {
        guard data.count >= 2 else { return (0, data.count) }
        // 非 gzip：直接当 raw deflate
        guard data[0] == 0x1f, data[1] == 0x8b else { return (0, data.count) }
        // gzip 至少 10 字节头 + 8 字节 trailer
        guard data.count >= 18 else { throw DecompressError.invalidHeader }

        let flg = data[3]
        var offset = 10

        // FEXTRA（2 字节 xlen + xlen 数据）
        if flg & 0x04 != 0 {
            guard offset + 2 <= data.count else { throw DecompressError.invalidHeader }
            let xlen = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + xlen
            guard offset <= data.count else { throw DecompressError.invalidHeader }
        }
        // FNAME（C 字符串，0 结尾）
        if flg & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
            guard offset <= data.count else { throw DecompressError.invalidHeader }
        }
        // FCOMMENT（C 字符串，0 结尾）
        if flg & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
            guard offset <= data.count else { throw DecompressError.invalidHeader }
        }
        // FHCRC（2 字节）
        if flg & 0x02 != 0 {
            offset += 2
            guard offset <= data.count else { throw DecompressError.invalidHeader }
        }

        // raw deflate 范围 = [offset, count - 8)
        let end = data.count - 8
        guard offset < end else { throw DecompressError.invalidHeader }
        return (offset, end)
    }

    // MARK: - raw deflate

    /// 用系统 `compression_decode_buffer` + `COMPRESSION_ZLIB` 解 raw deflate。
    /// 输出 buffer 默认按输入 8× 估算，不够则 2× 扩容重试（最多 4 次 → 128×）。
    private static func inflateRawDeflate(_ body: Data) throws -> Data {
        var capacity = max(body.count * 8, 4096)
        for _ in 0..<4 {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { buffer.deallocate() }

            let decoded: Int = body.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(buffer, capacity, base, body.count, nil, COMPRESSION_ZLIB)
            }

            if decoded == 0 {
                throw DecompressError.decodeFailed
            }
            // decoded == capacity 视为 buffer 可能截断 → 扩容重试
            if decoded < capacity {
                return Data(bytes: buffer, count: decoded)
            }
            capacity *= 2
        }
        throw DecompressError.bufferTooSmall
    }
}
