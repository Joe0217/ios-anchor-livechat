import SwiftUI

/// 转盘只依据服务端已同步的轮次和阶段播放视觉过渡，绝不在客户端推导淘汰或获胜结果。
///
/// 视觉对齐 H5 `super-wheel-dial.vue`：
/// - 302×297 外框 + 247×247 内盘（外圈紫环由 `superWinnerWheelRing` 切图承载）
/// - 8 色扇区色板循环等分（对齐安卓 SuperWheelDialView）
/// - 头像沿扇区中点定位，半径 90pt，命中者外描红环 + 双层阴影 #F0625A
/// - 减速 6s `cubic-bezier(0.12, 0.6, 0.12, 1)` + 5 圈额外
/// - 中心 pointer 切图 90×115pt，奖池数字覆于 token 上（token 约在切图纵向 60% 处）
struct PartySuperWheelDial: View {
    let state: PartySuperWheelState
    let pool: Int64
    /// F3: Store 的 `spinTriggerCounter` 递增计数器 —— 每次 SPIN 广播都 &+= 1,
    /// Dial `onChange(of:)` 感知递增,保证多轮或 6s 内二次 SPIN 也能触发旋转。
    /// 比 `spinning: Bool` 更可靠(bool 在 true→true 时 SwiftUI 不发布变化)。
    let spinTrigger: Int

    @State private var rotation: Double = 0
    @State private var isSpinning6s = false
    @State private var frozenParticipants: [PartySuperWheelParticipant] = []
    @State private var lastRoundId: String = ""

    /// H5 SECTOR_COLORS。iOS 用 AngularGradient stops 精确等分。
    private static let sectorColors: [Color] = [
        Color(hex: 0xFBDE29),
        Color(hex: 0xF29DE8),
        Color(hex: 0xA2A8F4),
        Color(hex: 0xF8BA50),
        Color(hex: 0x83F0F7),
        Color(hex: 0xB26DF8),
        Color(hex: 0xF763DA),
        Color(hex: 0x8BF592),
    ]
    /// 无人参与时的内盘底色（H5 EMPTY_DIAL_COLOR）
    private static let emptyDialColor = Color(hex: 0xF4E8FF)

    /// 外框（切图）尺寸
    private let dialWidth: CGFloat = 302
    private let dialHeight: CGFloat = 297
    /// 内盘（转动区）直径
    private let rotorSize: CGFloat = 247
    /// 头像圆周半径
    private let seatRadius: CGFloat = 90
    /// 头像尺寸
    private let seatSize: CGFloat = 42
    /// 中心 pointer 切图渲染尺寸
    private let pointerWidth: CGFloat = 90
    private let pointerHeight: CGFloat = 115

    /// 是否进入盘面冻结阶段（转动 6/开奖 7）
    private var holdSeats: Bool {
        state.state == 6 || state.state == 7
    }

    /// 存活参与者按顺序占扇区（未冻结时用最新，冻结时用快照）
    private var aliveRaw: [PartySuperWheelParticipant] {
        state.participants.filter { $0.status == 1 }
    }
    private var aliveList: [PartySuperWheelParticipant] {
        holdSeats && !frozenParticipants.isEmpty ? frozenParticipants : aliveRaw
    }
    private var sectorCount: Int { max(aliveList.count, 1) }
    /// H5 seatOffsetDeg：仅 1 人时 0（整盘一色，头像回顶部），其余为扇区中点 = 180/n。
    private var seatOffsetDeg: Double {
        aliveList.count > 1 ? 180.0 / Double(aliveList.count) : 0
    }

    var body: some View {
        ZStack {
            // 外圈紫环 + 灯泡 + 米色内盘（静态切图）
            CDNAssetImage("superWinnerWheelRing")
                .resizable()
                .scaledToFit()
                .frame(width: dialWidth, height: dialHeight)

            // 扇区旋转层：内盘尺寸 247，圆形裁剪 + 8 色扇 + 头像
            ZStack {
                Circle().fill(sectorFill)
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 0)

                ForEach(Array(aliveList.enumerated()), id: \.element.id) { index, participant in
                    seatAvatar(participant, isHit: !isSpinning6s
                               && state.state == 7
                               && participant.userId == state.eliminatedUserId)
                        .offset(seatOffset(index: index))
                }
            }
            .frame(width: rotorSize, height: rotorSize)
            .clipShape(Circle())
            .rotationEffect(.degrees(rotation))

            // 中心指针 + 奖池覆盖（静态）。H5：pointer 顶距 dial 顶 85pt。
            // dial 中心 = 148.5，pointer 中心 = 85 + 115/2 = 142.5，offset = -6
            CDNAssetImage("superWinnerPointer")
                .resizable()
                .scaledToFit()
                .frame(width: pointerWidth, height: pointerHeight)
                .overlay(alignment: .top) {
                    // 数字中心距 pointer 顶 60%（token 位置）；元素高约 30，offset = 69 - 15 = 54
                    VStack(spacing: 2) {
                        CDNAssetImage("giftPanelBalanceCoin")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 14, height: 14)
                        Text("\(pool)")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .monospacedDigit()
                            .environment(\.layoutDirection, .leftToRight)
                    }
                    .offset(y: 54)
                }
                .offset(y: -6)
        }
        .frame(width: dialWidth, height: dialHeight)
        .onAppear {
            lastRoundId = state.roundId
        }
        .onChange(of: state.roundId) { newRoundId in
            resetForNewRound(newRoundId: newRoundId)
        }
        // 冻结座位:进入 SPIN/REVEAL 期间拍一张快照,不再让后端提前落库的淘汰状态收缩盘面
        .onChange(of: holdSeats) { hold in
            if hold && frozenParticipants.isEmpty {
                frozenParticipants = aliveRaw
            } else if !hold {
                frozenParticipants = []
            }
        }
        // 旋转触发由 Store spinTriggerCounter 递增驱动 —— 每次 SPIN 广播 counter+1,
        // onChange 必触发,即使 6s 内二次 SPIN 也不会丢(bool 信号在 true→true 时会丢)。
        .onChange(of: spinTrigger) { _ in
            startSpinAnimation()
        }
        .onChange(of: aliveRaw.count) { _ in
            guard !isSpinning6s else { return }
            // 归一到最近整圈：让顶部指针落在扇区分界线上而非头像上
            let normalized = (rotation / 360).rounded() * 360
            if abs(normalized - rotation) > .ulpOfOne {
                var tx = Transaction()
                tx.disablesAnimations = true
                withTransaction(tx) { rotation = normalized }
            }
        }
        .accessibilityLabel(L10n.PartyRoom.superWheelTitle)
    }

    // MARK: - Sector

    /// 按存活人数等分的 AngularGradient（每扇区两个色 stop 确保硬边界）
    private var sectorFill: AngularGradient {
        let n = aliveList.count
        if n == 0 {
            return AngularGradient(
                gradient: Gradient(colors: [Self.emptyDialColor]),
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(270)
            )
        }
        if n == 1 {
            let c = Self.sectorColors[0]
            return AngularGradient(
                gradient: Gradient(colors: [c, c]),
                center: .center,
                startAngle: .degrees(-90),
                endAngle: .degrees(270)
            )
        }
        var stops: [Gradient.Stop] = []
        for i in 0..<n {
            let color = Self.sectorColors[i % Self.sectorColors.count]
            let start = Double(i) / Double(n)
            let end = Double(i + 1) / Double(n)
            stops.append(.init(color: color, location: start))
            stops.append(.init(color: color, location: end))
        }
        // 从 12 点方向(-90°)起顺时针分布,与头像 seatOffset(index=0 时 angleDeg=step/2 位于扇区 0 中点) 严格匹配。
        // 用 startAngle=0°(3 点)会让扇区旋转 90°,头像刚好落在分界线上。
        return AngularGradient(
            gradient: Gradient(stops: stops),
            center: .center,
            startAngle: .degrees(-90),
            endAngle: .degrees(270)
        )
    }

    // MARK: - Avatar

    @ViewBuilder
    private func seatAvatar(_ participant: PartySuperWheelParticipant, isHit: Bool) -> some View {
        CachedAsyncImage(url: participant.avatar.flatMap(URL.init(string:)), contentMode: .fill, persistent: true) {
            Circle().fill(Color.white.opacity(0.22))
        }
        .frame(width: seatSize, height: seatSize)
        .background(Circle().fill(Color.white))
        .clipShape(Circle())
        .overlay(
            Circle().stroke(isHit ? Color(hex: 0xF0625A) : Color.white,
                            lineWidth: isHit ? 3 : 1)
        )
        .shadow(color: isHit ? Color(hex: 0xF0625A) : .clear,
                radius: isHit ? 6 : 0)
        .shadow(color: isHit ? Color.white : .clear,
                radius: isHit ? 1 : 0)
        .opacity(participant.status == 2 ? 0.35 : 1)
    }

    private func seatOffset(index: Int) -> CGSize {
        let step = 360.0 / Double(sectorCount)
        let angleDeg = Double(index) * step + seatOffsetDeg
        let rad = angleDeg * .pi / 180
        return CGSize(width: sin(rad) * seatRadius, height: -cos(rad) * seatRadius)
    }

    // MARK: - Rotation

    /// 由 Store isDialAnimating 从 false→true 驱动。计算命中扇区(优先 eliminatedUserId,
    /// 兜底 winner/sectorIndex),用 `withAnimation` 命令式播 6s cubic-bezier 减速动画。
    /// 与 H5 dial `watch(props.spinning)` 逻辑等价。
    private func startSpinAnimation() {
        // 冻结座位快照(若未拍)
        if frozenParticipants.isEmpty {
            frozenParticipants = aliveRaw
        }
        let participants = aliveList
        guard !participants.isEmpty else { return }

        // 命中扇区:淘汰者优先(SPIN 分支),否则 winner(直跳 FINAL 兜底),最后 sectorIndex
        let targetUserId = state.eliminatedUserId
            ?? state.winnerId
            ?? state.winner?.userId
        let hitIdx = targetUserId.flatMap { id in
            participants.firstIndex(where: { $0.userId == id })
        }
        let idx = hitIdx ?? state.sectorIndex ?? 0
        let normalizedIdx = ((idx % participants.count) + participants.count) % participants.count
        let n = participants.count
        let step = 360.0 / Double(n)
        let base = -(Double(normalizedIdx) * step + seatOffsetDeg)
        var target = base
        while target <= rotation { target += 360 }
        target += 5 * 360

        isSpinning6s = true
        withAnimation(.timingCurve(0.12, 0.6, 0.12, 1, duration: 6)) {
            rotation = target
        }
    }

    private func resetForNewRound(newRoundId: String) {
        guard newRoundId != lastRoundId else { return }
        lastRoundId = newRoundId
        frozenParticipants = []
        isSpinning6s = false
        var tx = Transaction()
        tx.disablesAnimations = true
        withTransaction(tx) { rotation = 0 }
    }
}

