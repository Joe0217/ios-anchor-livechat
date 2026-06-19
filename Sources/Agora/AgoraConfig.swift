import Foundation

/// 声网接入配置（POC 用常量；正式接入时改为从后端 getAgoraRtmToken 动态获取）。
enum AgoraConfig {
    /// dev 环境 AppID（来自 H5 src/config/index.js）
    static let appId = "4af61c7a92f447d3a582308b5817dbd2"

    /// 频道名 —— 后端 getAgoraRtmToken 返回的 channelId
    static let channelId = "60c3eb97-1372-44da-b801-cefb8d932e88"

    /// RTC token —— 后端返回的 rtcToken。
    /// ⚠️ 会过期（通常数小时）。过期后 join 会报 token 失效，从后端重新取一个替换即可。
    static let token = "007eJxTYCgS1vhRrmD4MFoobccKp2VH5/zsvrei84ajtHpwY/LcWj8FBpPENDPDZPNES6M0ExPzFONEUwsjYwOLJFMLQ/OUpBQjsff6WWp/9bO+5Cy7xMjAyMACxCA+E5hkBpMsYJKBgYvB0AAEjCxMDQDVqidO"

    /// ⚠️ token 绑定的 uid，必须与后端签发时一致，否则 join 失败。
    /// 若后端用 uid 0（通配）签发，则任意 uid 均可，这里填 0。
    /// 若绑定了具体 userId，请改成你的 userId 数值。
    static let uid: UInt = 1000002850
}
