import Foundation
import os

/// 开播设置页 Store（B-spec-开播设置页 §2.2）。
///
/// 收敛副作用：`getMyLiveRoom` 预拉、4 项 checkCanLive、`LiveService.startLive` 三接口串行 +
/// 错误分流（1004/1005 短路、-1 cover fail-safe、其他统一 message）。
///
/// 与 `LiveSettingsLock.shared` 联动：进入 `.starting` lock；View 消失 or `.error` 恢复时 unlock。
@MainActor
final class LiveSettingsStore: ObservableObject {
    // MARK: - Published

    @Published private(set) var state: LiveSettingsState = .loading
    @Published var title: String = "" {
        didSet {
            // 红队 🟠#6：用户改简介清 error；🟠#7：UTF-16 200 字符软限制裁尾
            if case .error = state { state = .editing }
            let limit = 200
            if title.utf16.count > limit {
                // 内部赋值不会二次触发 didSet；String(decoding:as:) 遇代理对中间边界自动补 U+FFFD 不崩
                title = String(decoding: title.utf16.prefix(limit), as: UTF16.self)
            }
        }
    }

    /// 从 getMyLiveRoom 拉到的默认封面 URL；用户上传新封面后被覆盖；空 = cover 校验失败
    @Published private(set) var coverUrl: String?

    /// v5：Cover 上传态。上传中 UI 显示 loading overlay 在 Cover 卡片上。
    @Published private(set) var isUploadingCover = false

    /// v5：私 call 礼物选择（对齐 H5 `gitfSetup` 单选）。nil = 未选（privateCallOpen=0）。
    @Published private(set) var selectedGift: GiftListData?

    /// startLive 成功后的房间信息。View 通过 `.navigationDestination(item:)` 感知 push LiveRoomView
    @Published private(set) var roomInfo: LiveRoomInfo?

    /// 用户端预检 toast（对齐 H5 `showToast(...)`）：checkCanLive 4 项失败时短暂显示，2s 自清。
    /// **与 `state=.error` 区分语义**：toast = 用户可修正的边界（简介/封面/冷却/IM），
    /// error banner = 接口/系统错误（当前仅 cover 上传失败保留 banner；load/startLive 的
    /// 无权限/API 报错走 `showErrorAndDismiss` → toast + auto pop）。
    @Published var toastMessage: String?
    private var toastClearTask: Task<Void, Never>?

    /// 无直播权限 / 开播接口报错时，展示 toast 后自动 pop 返回。
    /// View 侧 `.onChange(of: shouldDismiss)` 观察此信号调用 `dismiss()`。
    @Published var shouldDismiss: Bool = false
    private var dismissTask: Task<Void, Never>?

    /// 心愿承诺规范弹窗（对齐 H5 `showWishRuleModal` index.vue:240-248 + wishlist-rule-modal.vue）。
    /// 触发条件：首次开播 + 有 wishlist + 有 promise + 未同意规范
    @Published var showWishRuleModal: Bool = false
    private let wishRuleAgreedKey = "wishRuleAgreed"

    /// v5：私 call 礼物最低价格约束（对齐 H5 `liveCallGiftLimit.min = 4999` 硬编码兜底）。
    /// **stage 3 补齐**：接受 getMyLiveRoom 后端下发的 `minGiftPrice` 覆盖（对齐 H5 index.vue:130-135）
    @Published private(set) var privateCallGiftMinPrice: Int64 = 4999

    // MARK: - Deps

    private let session: SessionStore
    private let lock: LiveSettingsLock
    private let logger = Logger(subsystem: "com.anchor.livechat", category: "LiveSettingsStore")

    init(session: SessionStore = .shared, lock: LiveSettingsLock = .shared) {
        self.session = session
        self.lock = lock
    }

    // MARK: - Lifecycle

    /// View onAppear 首调：userType 守卫 → getMyLiveRoomRaw 预拉封面/简介。
    ///
    /// userType 守卫（对齐 `LivePrepareView.startLive():89-97`）：只有 `userType == 2`（已审核主播）放行。
    /// 无权限 / API 报错（含 code=1111 request.failed）走 `showErrorAndDismiss` → toast + 自动 pop 返回。
    func load() async {
        guard let user = session.user else {
            showErrorAndDismiss(L10n.livePrepareGuardUnverified)
            return
        }
        if user.userType != 2 {
            showErrorAndDismiss(user.userType == 9 ? L10n.livePrepareGuardAgent : L10n.livePrepareGuardUnverified)
            return
        }
        state = .loading
        do {
            let settings = try await LiveService.getMyLiveRoomRaw()
            coverUrl = settings["backgroundImgUrl"] as? String
            let existingDescribe = (settings["liveDescribe"] as? String) ?? ""
            if title.isEmpty { title = existingDescribe }  // 走过 didSet 会触发 utf16 裁尾（后端脏数据兜底）

            // stage 3 对齐 H5 index.vue:130-135：后端下发 minGiftPrice 覆盖默认 4999
            if let minPrice = intValue(settings["minGiftPrice"]), minPrice > 0 {
                privateCallGiftMinPrice = minPrice
            }

            // stage 3 对齐 H5 index.vue:117-128 `setPrivaCallGift`：回显上次已选私 call 礼物
            await restorePrivateCallGiftIfNeeded(from: settings)

            state = .editing
            logger.info("load ok cover=\(self.coverUrl?.isEmpty == false ? "yes" : "no") minGiftPrice=\(self.privateCallGiftMinPrice) selectedGift=\(self.selectedGift?.id ?? -1)")
        } catch let e as APIError {
            if e.code == "1004" || e.code == "1005" {
                // 登出 / 挤下线由 SessionStore 处理；本页短路
                return
            }
            // 无直播权限 / 接口报错：toast 提示后自动 pop（例：code=1111 request.failed）
            showErrorAndDismiss(String(format: L10n.livePrepareErrorPrefix, e.message, e.code))
        } catch {
            showErrorAndDismiss(String(format: L10n.livePrepareErrorGeneric, error.localizedDescription))
        }
    }

    // MARK: - Start Live

    /// tap Start Live 入口：4 项 checkCanLive → startLive 三接口串行 → 成功赋 roomInfo（触发 push）。
    ///
    /// 状态锁：`.starting` 期间 `LiveSettingsLock.lock()` 让 MainTabView tabbar 拦截触摸，
    /// push 到 LiveRoomView 后 View 消失 → deinit → unlock。
    /// 1004/1005 短路 + `showErrorAndDismiss`（toast + auto pop）分支均显式 unlock，避免 tabbar 卡死。
    func startTapped() async {
        // P 项目权限管理：.live bit runtime guard · 走统一 gate helper（不 assertionFailure · Finding 4/8）
        guard SelfPermissionBridge.shared.gate(.live, action: "startTapped") else { return }
        // 无权限报错 pop 过渡期（showErrorAndDismiss 已排队 1.5s 后 dismiss），忽略后续开播点击
        if shouldDismiss { return }
        // 红队 🟠#6：入口自清 .error
        if case .error = state { state = .editing }

        guard state == .editing else {
            logger.warning("startTapped ignored: state=\(String(describing: self.state))")
            return
        }

        // 心愿承诺规范弹窗（对齐 H5 index.vue:240-248 showWishRuleModal）：
        // 首次开播 + 有 wishlist + 有 promise + 未同意规范 → 弹 modal 阻塞开播流程
        // 用户 Agree 后 onWishRuleAgree 会再次调用 startTapped 走完主流程
        let wishShared = WishSettingSharedStore.shared
        if !UserDefaults.standard.bool(forKey: wishRuleAgreedKey),
           !wishShared.wishlist.isEmpty,
           wishShared.promiseType != .none {
            showWishRuleModal = true
            return
        }

        // 4 项 checkCanLive（顺序对齐 H5 index.vue:191-208 不可改）
        // **stage 3**：改用 toast 展示（对齐 H5 `showToast`）—— state 保持 .editing 不进 error banner
        if let errMsg = checkCanLive() {
            showToast(errMsg)
            return
        }

        state = .starting
        lock.lock()

        do {
            let giftParam: (id: Int64, price: Int64)? = selectedGift.map { ($0.id, $0.giftPrice) }
            // L-spec：读 WishSettingSharedStore 组装 wishlistList / promiseType / promiseTemplateId / promiseText
            // （wishShared 已在函数顶部声明用于合规弹窗检查，此处复用）
            let wishlistPayload: [[String: Any]] = wishShared.wishlist.map {
                [
                    "id": $0.id,
                    "giftId": $0.giftId,
                    "name": $0.name,
                    "giftPrice": $0.giftPrice,
                    "giftSmallImg": $0.giftSmallImg,
                    "giftNum": $0.giftNum,
                    "sortWeight": $0.sortWeight,
                ]
            }
            let info = try await LiveService.startLive(
                liveDescribe: title.trimmingCharacters(in: .whitespacesAndNewlines),
                coverUrl: coverUrl,   // 用户新上传的封面（若有）或已存服务端 default
                gift: giftParam,
                wishlist: wishlistPayload,
                promiseType: wishShared.promiseType.rawValue,
                promiseTemplateId: wishShared.promiseTemplateId == 0 ? nil : wishShared.promiseTemplateId,
                promiseText: wishShared.promiseText.isEmpty ? nil : wishShared.promiseText
            )
            guard let ch = info.agoraChannelId, !ch.isEmpty,
                  let tk = info.rtcToken, !tk.isEmpty else {
                showErrorAndDismiss(L10n.livePrepareErrorNoChannel)
                return
            }
            roomInfo = info
            // 保持 .starting；View 侦测 roomInfo 非 nil 触发 push；LiveRoomView 接管后本 View 消失
        } catch let e as APIError {
            if e.code == "1004" || e.code == "1005" {
                // SessionStore 会处理登出流程 —— 本页短路 return（不写 errorMessage，避免与 SessionStore.errorMessage 双错）
                state = .editing  // 让 View 从 disabled 恢复；但 SessionStore.isLoggedIn 会驱动 RootView 跳登录
                lock.unlock()
                return
            }
            if e.code == "-1" {
                // 红队 🔴#4：LiveService 层 cover fail-safe（getMyLiveRoom 二拉时 cover 空）
                showErrorAndDismiss(L10n.liveErrorNoCover)
                return
            }
            // 接口报错（含 code=1111 request.failed）：toast 提示后自动 pop
            showErrorAndDismiss(String(format: L10n.livePrepareErrorPrefix, e.message, e.code))
        } catch {
            showErrorAndDismiss(String(format: L10n.livePrepareErrorGeneric, error.localizedDescription))
        }
    }

    /// 手动清除 error（View onChange 美颜参数时触发，红队 🟠#6）
    func clearErrorIfNeeded() {
        if case .error = state { state = .editing }
    }

    // MARK: - stage 3：回显上次已选私 call 礼物（对齐 H5 index.vue:117-128 setPrivaCallGift）

    /// getMyLiveRoom 响应含 `giftId + giftPrice` → 拉 gift 列表匹配完整信息 → 回填 selectedGift。
    /// 若价格低于当前 privateCallGiftMinPrice 阈值 → 忽略（对齐 H5 `giftInfo.giftPrice >= min` 守卫）
    private func restorePrivateCallGiftIfNeeded(from settings: [String: Any]) async {
        guard selectedGift == nil else { return }  // 用户已手动选过（罕见）不覆盖
        guard let giftId = intValue(settings["giftId"]), giftId > 0 else { return }
        guard let giftPrice = intValue(settings["giftPrice"]), giftPrice >= privateCallGiftMinPrice else { return }

        // 先按后端已有字段构造 minimal（保底能显示价格，即便无 name/icon）
        // 名称/图标从 gift 列表查询补全（H5 走 giftStore 缓存；iOS 未缓存，主动拉一次）
        let minimal = GiftListData(
            id: giftId,
            name: (settings["giftName"] as? String) ?? "",
            giftPrice: giftPrice,
            giftSmallImg: (settings["giftSmallImg"] as? String) ?? "",
            giftImg: (settings["giftImg"] as? String) ?? ""
        )
        selectedGift = minimal

        // 若 name/icon 缺失，异步拉一次 gift list 匹配补全（不阻塞 load）
        if minimal.name.isEmpty || minimal.giftSmallImg.isEmpty {
            do {
                let list = try await GiftService.getGiftList(scene: .call)
                if let matched = list.first(where: { $0.id == giftId }) {
                    selectedGift = matched
                    logger.info("restorePrivateCallGift matched from list: \(matched.name)")
                }
            } catch {
                logger.warning("restorePrivateCallGift list fetch failed: \(String(describing: error))")
                // 保留 minimal 展示（价格 tile 仍可用）
            }
        }
    }

    /// Int/Int64/String 统一转 Int64（对齐 `.claude/rules/ios-decode-userid-compat.md`）
    private func intValue(_ v: Any?) -> Int64? {
        if let i = v as? Int64 { return i }
        if let i = v as? Int { return Int64(i) }
        if let n = v as? NSNumber {
            let cType = String(cString: n.objCType)
            guard cType != "c" && cType != "B" else { return nil }  // 排除 Bool 桥接
            return n.int64Value
        }
        if let s = v as? String, let i = Int64(s) { return i }
        return nil
    }

    /// 显示 toast 2s 后自动清空。重复触发会 cancel 前一个任务，避免闪烁 / stale 覆盖
    func showToast(_ msg: String) {
        toastMessage = msg
        toastClearTask?.cancel()
        toastClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.toastMessage = nil }
        }
    }

    /// 无直播权限 / 开播接口报错统一入口：toast 提示后 1.5s 自动 pop 返回。
    ///
    /// 内部一并调 `lock.unlock()` 兜底解锁（`.starting` 分支路径可能在报错前锁定过 tabbar），
    /// 并把 state 回退到 `.editing`，避免 toast 期间底部按钮仍显示 "Starting..." spinner 混淆。
    /// 复用现有 `showToast` 的 2s 自清逻辑；dismiss 触发时 view 已随之 pop，无 UI 残留。
    private func showErrorAndDismiss(_ msg: String) {
        switch state {
        case .loading, .starting:
            state = .editing
        default:
            break
        }
        lock.unlock()
        showToast(msg)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.shouldDismiss = true }
        }
    }

    // MARK: - 心愿承诺规范弹窗回调（对齐 H5 onWishRuleAgree / onWishRuleClose index.vue:399-406）

    /// 用户 Agree 心愿承诺规范：调后端 clickAgreement + 本地持久化标志 + 关 modal + 递归调 startTapped 继续主流程
    /// 后端调用失败静默（对齐 H5 wishlist-rule-modal.vue:19 `catch { silent }`）
    func onWishRuleAgree() async {
        // fire-and-forget 后端记录（失败不阻塞用户开播）
        do {
            try await LiveService.clickWishAgreement()
        } catch {
            logger.warning("clickWishAgreement failed (silent per H5): \(String(describing: error))")
        }
        UserDefaults.standard.set(true, forKey: wishRuleAgreedKey)
        showWishRuleModal = false
        // 递归调 startTapped 继续开播主流程（此时 wishRuleAgreed=true，跳过 modal 分支）
        await startTapped()
    }

    /// 用户 Cancel 关 modal：仅关闭，不持久化，用户下次 tap Start Live 仍弹
    func onWishRuleClose() {
        showWishRuleModal = false
    }

    /// 二次开播复用 store（bug fix：LiveSettings 是 push 而非 dismantle 到 LiveRoomView，pop 回来时 store 仍是 .starting）
    ///
    /// **触发场景**：用户 tap Start Live → push LiveRoomView（store.state = .starting, roomInfo != nil, lock 锁定）→ 下播 pop →
    /// 回到 LiveSettings 但 store 仍是"已开播中"状态 → 再 tap Start Live 命中 `guard state == .editing` 静默 return → 按钮转圈不消失
    ///
    /// **调用点**：View `.onAppear` 检测 `roomInfo != nil`（已开播过标志），主动 reset 允许再次开播。
    /// 保留 title/coverUrl/selectedGift（用户可能相同配置再开播）；仅重置生命周期字段。
    func resetForReuse() {
        state = .editing
        roomInfo = nil
        lock.unlock()
        logger.info("resetForReuse: allow re-enter Start Live after pop from LiveRoomView")
    }

    // MARK: - v5: Cover 上传

    /// 上传新封面：复用 `ImageUploader.shared.upload(preset: .moment)`（对齐 H5 max 2MB / q 0.7 / max 2048px）。
    /// - parameter data: PhotosPicker 拿到的原图 raw data（HEIC/PNG/JPG）
    /// - throws: ImageCompressor.CompressError / APIError / OssUploadError（View 层 catch 后转 state.error）
    func uploadCover(data: Data) async {
        // starting 期间禁上传（loading 态允许——用户刚进页面就上传属于罕见但合法）
        guard state != .starting else { return }
        if case .error = state { state = .editing }
        isUploadingCover = true
        defer { isUploadingCover = false }
        do {
            let url = try await ImageUploader.shared.upload(rawData: data, preset: .moment)
            self.coverUrl = url
            logger.info("cover uploaded: \(url, privacy: .public)")
        } catch let e as APIError {
            state = .error(String(format: L10n.livePrepareErrorPrefix, e.message, e.code))
        } catch {
            state = .error(String(format: L10n.livePrepareErrorGeneric, error.localizedDescription))
        }
    }

    // MARK: - v5: 私 call 礼物选择

    /// CommonGiftPanel `.callGate` factory 回调；nil = 用户 confirm 但无选中（"移除"语义）。
    func setSelectedGift(_ gift: GiftListData?) {
        if case .error = state { state = .editing }
        // 硬性守护：低于 min 直接拒绝（Panel 已过滤，此处为二重保险）
        if let g = gift, g.giftPrice < privateCallGiftMinPrice {
            selectedGift = nil
            return
        }
        selectedGift = gift
    }

    // MARK: - Private

    /// checkCanLive 4 项。返回 nil 全过；返回非 nil 是待 toast 的错误文案。
    /// 顺序对齐 H5 `views/liveSetting/index.vue:191-208`（不可乱序）。
    private func checkCanLive() -> String? {
        // 1. 简介非空
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return L10n.prepareTitleEmpty
        }
        // 2. 封面非空（默认封面从 getMyLiveRoom 拉；用户端不上传）
        guard let cover = coverUrl, !cover.isEmpty else {
            return L10n.prepareCoverEmpty
        }
        // 3. 距上次下播 ≥60s
        if let secs = LastEndLiveTracker.secondsSinceLast, secs < 60 {
            return L10n.prepareCooldown
        }
        // 4. IM 在线
        if !NIMService.shared.isLogined {
            return L10n.prepareIMOffline
        }
        return nil
    }

    deinit {
        // 兜底：View 意外销毁（tab 切走、系统内存回收）时确保 tabbar 解锁
        // deinit nonisolated（Swift 6）—— MainActor 隔离 lock 需要跨 actor 调用
        let lockRef = lock
        Task { @MainActor in lockRef.unlock() }
    }
}
