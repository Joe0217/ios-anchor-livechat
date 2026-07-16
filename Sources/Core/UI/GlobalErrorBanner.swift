import SwiftUI
import Combine

/// 全局顶部错误通知（GlobalErrorBanner）。
///
/// **触发路径**：APIClient / PartyAPIClient / SapiTokenStore 三链路的所有请求失败点
///  → post `Notification.Name.apiRequestFailed`（userInfo["message"]: String，优先后端 message）
///    或旧的 `.apiResponseParseFailed`（兼容路径，无 message 时兜底 L10n）
///  → 本 store observer 消费 → 顶部滑入红色胶囊条 3.5s 后自动收回。
///
/// **文案来源优先级**：userInfo["message"] → L10n.apiResponseParseFailed 兜底。
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

    private var windowEndsAt: Date?
    private var dismissTask: Task<Void, Never>?
    private var requestFailedObserver: NSObjectProtocol?

    private init() {
        // 通用请求失败通知：userInfo["message"] 优先，无则兜底 L10n。
        // APIClient / PartyAPIClient / SapiTokenStore 所有错误抛出点统一走此通知
        // （envelope-parse-fail 也走这里，userInfo["message"] 传 L10n.apiResponseParseFailed）。
        requestFailedObserver = NotificationCenter.default.addObserver(
            forName: .apiRequestFailed,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?["message"] as? String
            let msg = (raw?.isEmpty == false ? raw! : L10n.apiResponseParseFailed)
            Task { @MainActor in
                self?.enqueue(message: msg)
            }
        }
    }

    deinit {
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
