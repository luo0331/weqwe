import SwiftUI

/// 实时仪表盘：状态、敌我剩余、示意棋盘、推演结果、事件流。
struct DashboardView: View {
    @EnvironmentObject var session: GameSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    statusCard
                    enemyCard(.leftEnemy)
                    enemyCard(.rightEnemy)
                    boardCard
                    notesCard
                    eventCard
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 120)
            }
            .background(Color.black)
            .navigationTitle("四国记牌器")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: 状态与控制
    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText).font(.subheadline.bold())
                Spacer()
                if let t = session.lastFrameAt {
                    Text("帧 \(DateFormatter.shortTime.string(from: t))")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            HStack(spacing: 10) {
                if session.roundActive {
                    Button(role: .destructive) { session.endRound() } label: {
                        Label("结束本局", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button { session.beginRound() } label: {
                        Label(session.awaitingBaseline ? "等待基准帧…" : "开始本局", systemImage: "play.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.awaitingBaseline)
                }
                Button { session.undoLastEvent() } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(session.events.isEmpty)
                Spacer()
                NavigationLink {
                    CalibrationView()
                } label: {
                    Label("校准", systemImage: "viewfinder")
                }
                .buttonStyle(.bordered)
            }
            .font(.footnote)
            if framesFlowing {
                Text(session.roundActive ? "录屏正常，后台分析中。" : "录屏已连接（帧正常到达）：点「开始本局」，然后把游戏切到布阵界面。")
                    .font(.caption).foregroundColor(.green)
            } else if session.isCapturing {
                Text("录屏似乎中断：帧没有到达。注意：系统自带的「屏幕录制」不会把画面传给本 App，要用本 App 的「① 启动录屏采集」。")
                    .font(.caption).foregroundColor(.orange)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("① 启动录屏采集").font(.caption.bold()).foregroundColor(.orange)
                            Text("弹窗里选「记牌器采集」→ 开始直播").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        BroadcastPickerView()
                            .frame(width: 48, height: 48)
                            .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
                    }
                    HStack(spacing: 8) {
                        Button {
                            if session.pip.isActive { session.pip.stop() } else { session.pip.start() }
                        } label: {
                            Label(session.pip.isActive ? "画中画运行中（点按关闭）" : "② 开启画中画小窗",
                                  systemImage: session.pip.isActive ? "pip.exit" : "pip.enter")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(session.pip.isActive ? .orange : .blue)
                    }
                    .font(.footnote)
                    Text("③ 切到微信四国军棋横屏对局：悬浮小窗实时显示左右敌情，本工具在后台自动分析。校准用「相册截图」最稳：游戏中截一张屏，再来选图框棋盘。")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
            if session.roundActive {
                Text("已开始记录。切到微信四国军棋对局，本工具会在后台自动跟踪。")
                    .font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private var framesFlowing: Bool {
        guard let t = session.lastFrameAt else { return false }
        return Date().timeIntervalSince(t) < 6
    }

    private var statusColor: Color {
        if session.roundActive { return .green }
        if session.awaitingBaseline { return .yellow }
        if framesFlowing { return .blue }
        return .gray
    }

    private var statusText: String {
        if session.roundActive { return "监控中 · 本局记录中" }
        if session.awaitingBaseline { return "等待基准帧（布阵界面）" }
        if framesFlowing { return "录屏已连接 · 分析中" }
        if session.isCapturing { return "采集中 · 未开始记录" }
        return "未采集"
    }

    // MARK: 敌方剩余卡片
    private func enemyCard(_ seat: Seat) -> some View {
        let s = session.engineSnapshot.summary(for: seat)
        let pieces = session.engineSnapshot.pieces
            .filter { $0.alive && $0.seat == seat }
            .sorted { a, b in
                let ad = a.definite != nil ? 0 : 1
                let bd = b.definite != nil ? 0 : 1
                if ad != bd { return ad < bd }
                return a.originNode < b.originNode
            }
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(Color(hex: seat.colorHex) ?? .gray).frame(width: 10, height: 10)
                Text(seat.label).font(.headline)
                Spacer()
                Text("剩 \(session.roundActive ? (s?.aliveTotal ?? 25) : 25)/25")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundColor(Color(hex: seat.colorHex))
            }
            estimateBar(s)
            HStack(spacing: 6) {
                let known = s?.deadKnown ?? [:]
                if known.isEmpty && (s?.deadUnknown ?? 0) == 0 {
                    Text("无损失").font(.caption).foregroundColor(.secondary)
                }
                ForEach(known.sorted { ($0.key.strength ?? -1) > ($1.key.strength ?? -1) }, id: \.key) { pair in
                    Text("\(pair.key.rawValue)×\(pair.value)")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.red.opacity(0.16), in: Capsule())
                }
                if let u = s?.deadUnknown, u > 0 {
                    Text("未知×\(u)")
                        .font(.caption2)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.gray.opacity(0.2), in: Capsule())
                }
            }
            if !pieces.isEmpty {
                VStack(spacing: 4) {
                    ForEach(pieces.prefix(4)) { p in
                        HStack(spacing: 8) {
                            Text(p.label).font(.caption2.monospaced()).foregroundColor(.secondary)
                            if let d = p.definite {
                                Text(d.rawValue).font(.caption.bold())
                            } else {
                                Text(candidatesText(p)).font(.caption).foregroundColor(.orange)
                            }
                            Spacer()
                        }
                    }
                    if pieces.count > 4 {
                        Text("… 共 \(pieces.count) 枚存活，详见棋盘点按")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(cardBG)
    }

    private func estimateBar(_ s: InferenceEngine.EnemySummary?) -> some View {
        GeometryReader { geo in
            let total = s?.estimate.values.reduce(0, +) ?? 0
            HStack(spacing: 2) {
                if total > 0, let s {
                    ForEach(Rank.allCases.sorted(by: >), id: \.self) { r in
                        if let v = s.estimate[r], v > 0.01 {
                            RoundedRectangle(cornerRadius: 3)
                                .fill((Color(hex: s.seat.colorHex) ?? .gray)
                                    .opacity(0.35 + 0.6 * Double(r.strength ?? 1) / 9))
                                .frame(width: max(3, geo.size.width * v / total))
                        }
                    }
                }
            }
        }
        .frame(height: 14)
    }

    private func candidatesText(_ p: InferenceEngine.Piece) -> String {
        let cs = p.candidates.sorted(by: >)
        if cs.isEmpty { return "?" }
        let lo = cs.last!, hi = cs.first!
        if cs.count <= 3 { return cs.map(\.short).joined(separator: "/") }
        return "\(lo.rawValue)~\(hi.rawValue)"
    }

    // MARK: 棋盘 / 推演 / 事件
    private var boardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("实时盘面").font(.headline)
            BoardCanvasView()
                .frame(height: 400)
                .background(Color(hex: "#101218"))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("点任意节点可查看推演详情或手动修正")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(14)
        .background(cardBG)
    }

    private var notesCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("敌方推演结果").font(.headline)
            if session.engineSnapshot.inconsistent {
                Label("检测到数据矛盾（可能是误识别），请检查最近事件或手动修正。", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundColor(.orange)
            }
            if session.engineSnapshot.notes.isEmpty {
                Text("暂无推演。敌方吃子后这里会自动给出该子的身份候选与概率。")
                    .font(.caption).foregroundColor(.secondary)
            }
            ForEach(Array(session.engineSnapshot.notes.enumerated()), id: \.offset) { _, n in
                Text(n).font(.footnote)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBG)
    }

    private var eventCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("事件日志").font(.headline)
            if session.events.isEmpty {
                Text("暂无事件").font(.caption).foregroundColor(.secondary)
            }
            ForEach(session.events.suffix(30)) { e in
                Text(e.text).font(.caption.monospaced())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBG)
    }

    private var cardBG: some View {
        RoundedRectangle(cornerRadius: 14)
            .fill(Color(hex: "#15171E") ?? Color.gray)
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.06)))
    }
}
