import Combine
import Foundation
import os

/// 客服 yxAccId 数据源协议（HilyTests / Preview 用 fake 注入）。
@MainActor
protocol CustomerServiceIdProviderProtocol: AnyObject {
    /// 当前缓存值；未拉取过为 nil
    var customerYxAccId: String? { get }
    /// 用于订阅变化（登录后拉取到 → publisher fire）
    var customerYxAccIdPublisher: AnyPublisher<String?, Never> { get }
    /// 幂等拉取；已有值直接返；正在拉不重入
    func refreshIfNeeded() async
    /// 登出清空
    func clear()
}

/// 客服（Admin）yxAccId 内存缓存（H-1c 系统消息 3 入口 - Admin）。
///
/// **对齐 H5 `session.js:473-501` `hanldeGetCustomerServiceList`**：
/// - 调 `POST /api/im/getCustomerServiceList {}` 拿数组
/// - 取 `[0].imId` 作为客服 yxAccId
/// - 登录期间恒不变（登出清空）
///
/// **iOS 差异**：
/// - H5 用 pinia 持久化（sessionStorage），iOS 用内存缓存（登录期间不变；登出清空）
/// - 单例，登录后由 `MessageSessionStore` init 触发 `refreshIfNeeded()`
@MainActor
final class CustomerServiceIdStore: ObservableObject, CustomerServiceIdProviderProtocol {

    typealias Fetcher = () async throws -> [CustomerService]

    static let shared = CustomerServiceIdStore()

    @Published private(set) var customerYxAccId: String?
    var customerYxAccIdPublisher: AnyPublisher<String?, Never> {
        $customerYxAccId.eraseToAnyPublisher()
    }

    private let fetcher: Fetcher
    private var isFetching = false
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "CustomerServiceIdStore")

    /// 生产默认：调 `/api/im/getCustomerServiceList`。
    /// 测试通过 `init(fetcher:)` 注入 mock。
    private init() {
        self.fetcher = {
            let data = try await APIClient.shared.post("/api/im/getCustomerServiceList", body: [:])
            let list = try JSONDecoder().decode([CustomerService].self, from: data)
            return list
        }
    }

    /// 供 HilyTests / Preview 注入 mock（不写单例）。
    init(fetcher: @escaping Fetcher) {
        self.fetcher = fetcher
    }

    /// 幂等拉取：已有值直接返；正在拉不重入；成功后写 `@Published`。
    func refreshIfNeeded() async {
        if customerYxAccId != nil || isFetching { return }
        isFetching = true
        defer { isFetching = false }
        do {
            let list = try await fetcher()
            guard let first = list.first, let imId = first.imId, !imId.isEmpty else {
                logger.notice("[CustomerService] list 为空 or imId 缺失")
                return
            }
            customerYxAccId = imId
            logger.info("🟣 [CustomerService] fetched customerYxAccId=\(imId, privacy: .private)")
        } catch {
            logger.error("[CustomerService] fetch failed \(String(describing: error), privacy: .private)")
        }
    }

    /// 登出清空。
    func clear() {
        customerYxAccId = nil
    }
}

/// 客服列表返回项（`/api/im/getCustomerServiceList` 单项）。
///
/// **只解 imId**（H5 也只用这个字段）；其他字段（nickname/avatar 等）后端可能有但忽略。
struct CustomerService: Decodable {
    let imId: String?

    enum CodingKeys: String, CodingKey {
        case imId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // imId 后端可能 String/Int 混发（同 userId 兼容规则）
        if let s = try? c.decode(String.self, forKey: .imId), !s.isEmpty {
            self.imId = s
        } else if let i = try? c.decode(Int64.self, forKey: .imId) {
            self.imId = String(i)
        } else {
            self.imId = nil
        }
    }
}
