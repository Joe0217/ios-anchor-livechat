import SwiftUI
import Combine
import UIKit

/// 全局顶部错误通知（GlobalErrorBanner）。
///
/// **触发路径**：
/// - APIClient / PartyAPIClient / SapiTokenStore 三链路所有请求失败点 post
///   `Notification.Name.apiRequestFailed`（userInfo["message"]: 优先后端 message）
/// - **系统级 NWPathMonitor 设备断网**：`NetworkReachability.$isReachable` 从 true→false
///   且持续 ≥3s 才 enqueue（防 WiFi↔cellular handoff / 隧道 blip）；额外 60s throttle
///   防 flapping spam；willEnterForeground 后 5s 冷却丢 backlog 事件。
///   **仅覆盖设备级 NWPath 不可达**——第三方 SDK 后端挂但设备联网正常（NIM/Agora RTM 服务
///   端故障、DNS 被劫）NWPathMonitor 感知不到，需各 SDK 自己接入 banner。
///  → 本 store 消费 → 顶部滑入红色胶囊条 3.5s 后自动收回。
///
/// **文案来源优先级**：userInfo["message"] → L10n.apiNetworkError 兜底（网络类失败文案统一）。
/// 业务侧不想弹全局 banner 时，网络请求传 `suppressCodes` 白名单让底层不 post。
///
/// **Cascade 合并**：3s 窗口内后续同类事件被静默丢弃，避免"一次心跳挂断触发 10+ 接口全解析失败"
/// 时 banner spam。3s 窗口过后新事件重新触发（含新动画）。
///
/// **接入位置**：RootView 顶层 overlay，zIndex 300（高于 CallView 100 / AutoOfflineDialog 200）。
///
/// **仿现有 SessionStore observer 模式**：observer 闭包 [weak self] + `Task { @MainActor in ... }`
/// 保证跨 actor 边界。
@MainActor
final class GlobalErrorBannerStore: ObservableObject {
    static let shared = GlobalErrorBannerStore()

    struct BannerItem: Equatable {
        let id: UUID
        let message: String
    }

    @Published private(set) var current: BannerItem?

    private let mergeWindow: TimeInterval = 3.0
    private let displayDuration: TimeInterval = 3.5
    /// 断网延迟 fire 阈值：断网持续 ≥3s 才真弹；短暂 flap（WiFi↔cellular handoff / 隧道 blip）取消
    private let unreachDebounce: TimeInterval = 3.0
    /// 断网 banner throttle：地铁/隧道场景 8-15s 循环 flap，60s 内不重弹避免 spam
    /// （20s throttle 仍会每 20s 弹一次；60s 更符合"用户已经知道在弱网"的产品预期）
    private let reachabilityBannerThrottle: TimeInterval = 60.0
    /// 前台恢复冷却：iOS 会把后台期间的 NWPath 事件排入 main queue backlog，回前台 drain
    /// 时 removeDuplicates 让 false 通过导致假 banner。冷却期内直接丢事件不启 pending
    /// （若在 handleReachabilityChange 里启 pending 再由 fire 端 gate 会与 debounce 交互出 bug）。
    /// 同源问题在声网 SDK 已修（[.claude/rules/swiftui-camera-preview.md](../.claude/rules/swiftui-camera-preview.md) §v5.3.2）
    private let foregroundCooldown: TimeInterval = 5.0

    private var windowEndsAt: Date?
    private var dismissTask: Task<Void, Never>?
    private var requestFailedObserver: NSObjectProtocol?
    private var cancellables = Set<AnyCancellable>()
    /// 回前台冷却期结束时间（Date）—— 之前的 reachability 事件都丢
    private var suppressReachabilityUntil: Date?
    /// 上一次 reachability banner 触发时间戳，用于 60s throttle
    private var lastReachabilityBannerAt: Date?
    /// 断网延迟 fire 的 pending task —— 期间恢复则 cancel
    private var pendingUnreachTask: Task<Void, Never>?

    private init() {
        // 通用请求失败通知：userInfo["message"] 优先，无则兜底 L10n.apiNetworkError
        // （与 reachability path 保持同一 fallback 文案，避免"同种网络失败两种文案"不一致）。
        requestFailedObserver = NotificationCenter.default.addObserver(
            forName: .apiRequestFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?["message"] as? String
            let msg = (raw?.isEmpty == false ? raw! : L10n.apiNetworkError)
            Task { @MainActor in
                self?.enqueue(message: msg)
            }
        }

        // HilyTests target 不启用 reachability 监听：NWPathMonitor 会在模拟器 launch 时触发
        // 瞬态 .unsatisfied，会把 banner state 泄漏到测试。与 APIClient 用 #if !HILY_TESTS
        // 包每处 GlobalErrorBannerNotify.post 的约定一致。
        #if !HILY_TESTS
        setupReachabilityMonitor()
        setupForegroundSuppression()
        #endif
    }

    /// 订阅系统级网络可达变化，处理 debounce / throttle / cooldown。
    /// - `dropFirst()` 丢 subscribe-time 的 @Published 当前值 replay，避免"若 NetworkReachability
    ///   已 latch false 时 subscribe 立即弹假 banner"（也是冷启动无 WiFi + iOS 蜂窝权限弹窗前的
    ///   场景 —— NetworkReachability.waitUntilReachable 的存在初衷就是压制这里）。
    /// - `Task { @MainActor in ... }` 对齐 requestFailedObserver 的 hop pattern，保证 sink
    ///   closure 内的 @MainActor 状态读写始终在 main actor 上。
    private func setupReachabilityMonitor() {
        NetworkReachability.shared.$isReachable
            .dropFirst()
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] reachable in
                Task { @MainActor in
                    self?.handleReachabilityChange(reachable: reachable)
                }
            }
            .store(in: &cancellables)
    }

    /// 回前台监听：设定 5s reachability 冷却期，drain 期间的 NWPath backlog 事件不弹 banner。
    private func setupForegroundSuppression() {
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.suppressReachabilityUntil = Date().addingTimeInterval(self.foregroundCooldown)
                }
            }
            .store(in: &cancellables)
    }

    private func handleReachabilityChange(reachable: Bool) {
        // 前台冷却期：drain backlog 事件全丢，不启 pending（若延迟到 fire 端 gate 会与 debounce
        // 交互出 bug —— pending fire 在 t=3s，此时冷却 5s 未过 → 真断网也被拦下）
        if let until = suppressReachabilityUntil, Date() < until { return }
        if reachable {
            // 已恢复：取消尚未 fire 的 pending banner（真断网 <3s → 属短暂 flap，不打扰）
            pendingUnreachTask?.cancel()
            pendingUnreachTask = nil
        } else {
            // 断网：延 unreachDebounce 秒 fire；期间若恢复 → handleReachabilityChange(true) cancel
            pendingUnreachTask?.cancel()
            let delay = unreachDebounce
            pendingUnreachTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.enqueueReachabilityBanner()
            }
        }
    }

    /// reachability 触发的 banner：60s throttle 防 flapping spam，最后走通用 enqueue。
    private func enqueueReachabilityBanner() {
        let now = Date()
        if let last = lastReachabilityBannerAt, now.timeIntervalSince(last) < reachabilityBannerThrottle { return }
        lastReachabilityBannerAt = now
        enqueue(message: L10n.apiNetworkError)
    }

    deinit {
        // shared singleton，实际运行时 deinit 不会触发；这里的清理仅为未来 refactor 保险。
        if let obs = requestFailedObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    /// 触发 banner；3s 合并窗口内静默丢弃。
    func enqueue(message: String) {
        let now = Date()
        if let end = windowEndsAt, now < end { return }
        windowEndsAt = now.addingTimeInterval(mergeWindow)
        current = BannerItem(id: UUID(), message: message)
        scheduleDismiss()
    }

    /// 用户点关闭按钮 / 上滑关闭触发。
    /// 同步清空 windowEndsAt：用户主动 ack 后，"防连锁 spam" 的合并语义应重置，
    /// 否则剩余 3s 内落到的**其它类别**错误会被静默吞掉。
    func dismissNow() {
        dismissTask?.cancel()
        dismissTask = nil
        windowEndsAt = nil
        current = nil
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        let duration = displayDuration
        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }
}

/// 顶部错误 banner 视图。挂 RootView overlay(alignment: .top) 高 zIndex。
///
/// 视觉：safe area 顶部下方 6pt，胶囊条内深红背景 + 白字 + `⚠️` icon + 右侧关闭按钮。
/// 交互：右侧 ✕ 点关闭；胶囊条本身支持**向上滑动关闭**（release 时 translation.height < -30 触发）。
struct GlobalErrorBanner: View {
    @ObservedObject private var store = GlobalErrorBannerStore.shared
    /// 上滑关闭手势中的实时 offset（仅向上有效，release 时若未过阈值动画回弹）
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            if let item = store.current {
                bannerCapsule(item.message)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .offset(y: dragOffset)
                    .gesture(dismissDragGesture)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .animation(.easeInOut(duration: 0.22), value: store.current)
        // 只在**新 banner 出现**（nil → BannerItem）时 reset offset，避免下一次显示时残留位移。
        // dismiss 时（BannerItem → nil）**不动** dragOffset —— 保留当前上滑位置让 .move(edge:.top)
        // transition 从当前位置继续向上滑出，避免"先弹回 y=0 再滑出"的 pop-back 视觉抖动。
        .onChange(of: store.current) { newValue in
            if newValue != nil { dragOffset = 0 }
        }
    }

    /// 上滑关闭手势。minimumDistance=10 避开 tap；仅 vertical 主导才响应，避免误触横向手势。
    /// - dismiss 阈值：向上位移超过 30pt（release 时判定 + 保留同款 vertical-主导 guard）
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                // 仅向上滑动跟手；横向为主的手势不响应，让其它手势区域正常工作
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                if value.translation.height < 0 {
                    dragOffset = value.translation.height
                }
            }
            .onEnded { value in
                // 对齐 onChanged 的 guard：横向主导的对角滑动不判 dismiss，只回弹
                let verticalDominant = abs(value.translation.height) > abs(value.translation.width)
                if verticalDominant, value.translation.height < -30 {
                    // 与外层 transition(.move(edge: .top)) 匹配，视觉上向上滑出
                    store.dismissNow()
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        dragOffset = 0
                    }
                }
            }
    }

    private func bannerCapsule(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .foregroundStyle(.white)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Spacer(minLength: 8)
            Button {
                store.dismissNow()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.white)
                    .font(.system(size: 12, weight: .bold))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Dismiss"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule().fill(Color(red: 0.85, green: 0.16, blue: 0.16).opacity(0.95))
        )
        .shadow(color: Color.black.opacity(0.25), radius: 8, x: 0, y: 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
